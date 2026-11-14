package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundGateConnectionStateTest {
    // Values stand in for the two existing localized error resource IDs.
    private val notReady = 1
    private val noResponse = 2

    @Test fun anUnattemptedChannelIsUnknownNotFailed() {
        val state = BackgroundGateState()

        assertNull(state.snapshot.connectionError)
        assertNull(state.snapshot.trustedDisplayOk)
        assertNull(state.snapshot.injectOk)
    }

    @Test fun aFailedConnectionIsRecordedWithoutInventingCapabilityFailures() {
        val state = BackgroundGateState()
        val owner = state.begin { true }!!

        assertTrue(state.failed(owner, notReady))

        assertEquals(notReady, state.snapshot.connectionError)
        assertNull(state.snapshot.trustedDisplayOk)
        assertNull(state.snapshot.injectOk)
        assertNull(state.snapshot.injectError)
        assertNull(state.snapshot.gateDetail)
    }

    @Test fun noResponsePreservesThePreviousCapabilityFacts() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, false, "inputUnconfirmed", "detail") is BackgroundGateState.Update.Accepted)
        val before = state.snapshot

        assertTrue(state.failed(state.begin { true }!!, noResponse, Any()))

        assertEquals(before.copy(connectionError = noResponse), state.snapshot)
    }

    @Test fun anExplicitRetryClearsConnectionFailureAndPreservesCapabilities() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, false, "inputUnconfirmed", "detail") is BackgroundGateState.Update.Accepted)
        val old = state.begin { true }!!
        assertTrue(state.failed(old, noResponse, Any()))
        val before = state.snapshot

        val retry = state.begin { true }!!

        assertEquals(before.copy(connectionError = null), state.snapshot)
        assertFalse(state.failed(old, notReady))
        assertSame(BackgroundGateState.Update.Cancelled, state.update(old, false, "old", false, "old", "old"))
        assertTrue(state.update(retry, true, null, true, null, null) is BackgroundGateState.Update.Accepted)
        assertEquals(BackgroundGateState.Snapshot(true, true), state.snapshot)
    }

    @Test fun aCancelledRetryCannotEraseTheLastFailure() {
        val state = BackgroundGateState()
        assertTrue(state.failed(state.begin { true }!!, notReady))
        val before = state.snapshot

        assertNull(state.begin { false })

        assertSame(before, state.snapshot)
    }

    @Test fun aNewUiIntentRejectsBothFailureAndSuccessFromTheOldProbe() {
        val state = BackgroundGateState()
        val actions = PrivilegedActionGate()
        val ticket = actions.select()
        val old = state.begin { actions.current(ticket) }!!
        actions.select()
        val before = state.snapshot

        assertFalse(state.failed(old, noResponse, Any()))
        assertSame(BackgroundGateState.Update.Cancelled, state.update(old, true, null, true, null, null))
        state.cancelUnwantedPending()

        assertFalse(state.current(old))
        assertSame(before, state.snapshot)
    }

    @Test fun cancellationDoesNotForgetAlreadyCompletedFacts() {
        val state = BackgroundGateState()
        var wanted = true
        val owner = state.begin { wanted }!!
        assertTrue(state.failed(owner, noResponse, Any()))
        val before = state.snapshot
        wanted = false

        state.cancelUnwantedPending()

        assertFalse(state.current(owner))
        assertSame(before, state.snapshot)
    }

    @Test fun accessOrModeResetClearsFailureAndRejectsTheOldProbe() {
        val state = BackgroundGateState()
        val old = state.begin { true }!!
        assertTrue(state.failed(old, notReady))

        state.reset()

        assertEquals(BackgroundGateState.Snapshot(), state.snapshot)
        assertFalse(state.failed(old, noResponse, Any()))
        assertSame(BackgroundGateState.Update.Cancelled, state.update(old, false, "old", false, "old", "old"))
        assertTrue(state.update(state.begin { true }!!, true, null, true, null, null) is BackgroundGateState.Update.Accepted)
    }

    @Test fun aHealthyReplacementClearsAnEarlierFailedConnection() {
        val state = BackgroundGateState()
        assertTrue(state.failed(state.begin { true }!!, notReady))
        val observed = state.snapshot

        state.connected(observed, Any())

        assertEquals(BackgroundGateState.Snapshot(), state.snapshot)
    }

    @Test fun anAliveChannelCannotEraseItsOwnNoResponseFailure() {
        val state = BackgroundGateState()
        val channel = Any()
        assertTrue(state.failed(state.begin { true }!!, noResponse, channel))
        val observed = state.snapshot

        state.connected(observed, channel)

        assertSame(observed, state.snapshot)
        assertEquals(noResponse, state.snapshot.connectionError)
    }

    @Test fun aFreshChannelClearsOnlyTransportFailureNotFailedCapabilities() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, false, "inputUnconfirmed", "detail") is BackgroundGateState.Update.Accepted)
        assertTrue(state.failed(state.begin { true }!!, noResponse, Any()))
        val observed = state.snapshot

        state.connected(observed, Any())

        assertEquals(observed.copy(connectionError = null), state.snapshot)
    }

    @Test fun aLateConnectionCannotClearANewerProbeFailure() {
        val state = BackgroundGateState()
        assertTrue(state.failed(state.begin { true }!!, notReady))
        val observed = state.snapshot
        assertTrue(state.failed(state.begin { true }!!, noResponse, Any()))
        val newer = state.snapshot

        state.connected(observed, Any())

        assertSame(newer, state.snapshot)
    }

    @Test fun anOldModeCannotClearAnIdenticalFailureAfterSwitchingAwayAndBack() {
        val state = BackgroundGateState()
        assertTrue(state.failed(state.begin { true }!!, notReady))
        val observed = state.snapshot
        state.reset()
        state.reset()
        assertTrue(state.failed(state.begin { true }!!, notReady))
        val newer = state.snapshot
        assertEquals(observed, newer)

        state.connected(observed, Any())

        assertSame(newer, state.snapshot)
    }
}
