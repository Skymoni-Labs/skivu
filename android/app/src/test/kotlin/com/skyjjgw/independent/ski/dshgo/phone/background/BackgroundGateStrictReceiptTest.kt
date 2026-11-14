package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundGateStrictReceiptTest {
    private val state = BackgroundGateState()
    private val expected = "original-owner"
    private fun accept(probe: BackgroundGateState.Probe, owner: Any? = expected, version: Any? = 1,
                       ok: Any? = true, display: Any? = true, inject: Any? = true,
                       error: Any? = null, injectError: Any? = null, detail: Any? = null) =
        state.updateStrict(probe, expected, owner, version, ok, display, inject, error, injectError, detail)

    @Test fun displayFactDoesNotComeFromOverallOkOrInventAnInputObservation() {
        val probe = state.begin { true }!!
        val notSent = accept(probe, ok = false, inject = null, error = "inputWindowNotReady")
            as BackgroundGateState.Update.Accepted
        assertTrue(notSent.receipt.trustedDisplayOk)
        assertNull(notSent.receipt.injectOk)
        assertEquals(BackgroundGateState.InjectFailure.WINDOW_NOT_READY, notSent.receipt.injectFailure)
        assertNull(state.snapshot.injectOk) // Never invent an attempted send just to retain its error.
        assertEquals("inputWindowNotReady", state.snapshot.injectError)
        val sent = accept(probe, ok = false, inject = false, error = "inputUnconfirmed")
            as BackgroundGateState.Update.Accepted
        assertTrue(sent.receipt.trustedDisplayOk)
        assertEquals(false, sent.receipt.injectOk)
        assertEquals(BackgroundGateState.InjectFailure.UNCONFIRMED, sent.receipt.injectFailure)
        val conflictingLabel = accept(probe, ok = false, inject = false, error = "inputWindowNotReady")
            as BackgroundGateState.Update.Accepted
        assertEquals(false, conflictingLabel.receipt.injectOk)
        assertEquals(BackgroundGateState.InjectFailure.UNCONFIRMED, conflictingLabel.receipt.injectFailure)
    }

    @Test fun exactOwnerVersionTypesAndTruthConjunctionAreRequired() {
        val probe = state.begin { true }!!
        val invalid = listOf(
            accept(probe, owner = "other"), accept(probe, version = 1L), accept(probe, ok = 1),
            accept(probe, display = "true"), accept(probe, inject = "true"),
            accept(probe, ok = false), accept(probe, display = false),
            accept(probe, error = "contradiction"), accept(probe, injectError = "contradiction"),
            accept(probe, ok = false, inject = false, error = 42),
        )
        invalid.forEach { assertSame(BackgroundGateState.Update.Invalid, it) }
        assertNull(state.snapshot.trustedDisplayOk)
    }

    @Test fun unknownRawErrorsAndDetailsAreNotForwardedToStatus() {
        val probe = state.begin { true }!!
        accept(probe, ok = false, inject = false, error = "PRIVATE_PACKAGE", injectError = "PRIVATE_BODY", detail = "PRIVATE_WINDOW")
        assertEquals("inputProbeFailed", state.snapshot.injectError)
        assertNull(state.snapshot.gateDetail)
    }

    @Test fun cancelledProbeCannotPublish() {
        var live = true
        val probe = state.begin { live }!!
        live = false
        state.cancelUnwantedPending()
        assertSame(BackgroundGateState.Update.Cancelled, accept(probe))
        assertNull(state.snapshot.trustedDisplayOk)
    }

    @Test fun aFailedConnectIsRememberedUntilTheNextConnectProbeOrReset() {
        state.connectionFailed(42) { true }
        assertEquals(42, state.snapshot.connectionError)
        state.connected(state.snapshot, Any())
        assertNull(state.snapshot.connectionError)
        state.connectionFailed(43) { false } // A revoked UI attempt publishes nothing.
        assertNull(state.snapshot.connectionError)
        state.connectionFailed(44) { true }
        state.begin { true }
        assertNull(state.snapshot.connectionError)
        state.connectionFailed(45) { true }
        state.reset()
        assertNull(state.snapshot.connectionError)
    }
}
