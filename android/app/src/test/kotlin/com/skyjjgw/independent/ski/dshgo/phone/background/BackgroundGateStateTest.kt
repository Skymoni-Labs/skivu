package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundGateStateTest {
    @Test fun startsWithAllCapabilitiesUnknown() {
        val state = BackgroundGateState()

        assertEquals(
            BackgroundGateState.Snapshot(null, null, null, null),
            state.snapshot,
        )
    }

    @Test fun busyProbeLeavesUnknownCapabilitiesUntouched() {
        val state = BackgroundGateState()
        val before = state.snapshot

        assertSame(BackgroundGateState.Update.Busy, state.update(state.begin { true }!!, false, "probeBusy", false, "busyInputError", "busyDetail"))

        assertEquals(
            BackgroundGateState.Snapshot(null, null, null, null),
            state.snapshot,
        )
        assertSame(before, state.snapshot)
    }

    @Test fun busyProbePreservesSuccessfulCapabilitiesAndDetail() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, true, null, "trustedDisplayReady") is BackgroundGateState.Update.Accepted)
        val before = state.snapshot

        assertSame(BackgroundGateState.Update.Busy, state.update(state.begin { true }!!, false, "probeBusy", false, "busyInputError", "busyDetail"))

        assertEquals(
            BackgroundGateState.Snapshot(true, true, null, "trustedDisplayReady"),
            state.snapshot,
        )
        assertSame(before, state.snapshot)
    }

    @Test fun busyProbePreservesFailedCapabilitiesErrorAndDetail() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, false, "displayRejected", false, "inputRejected", "failedDetail") is BackgroundGateState.Update.Accepted)
        val before = state.snapshot

        assertSame(BackgroundGateState.Update.Busy, state.update(state.begin { true }!!, true, "probeBusy", true, null, "busyDetail"))

        assertEquals(
            BackgroundGateState.Snapshot(false, false, "inputRejected", "failedDetail"),
            state.snapshot,
        )
        assertSame(before, state.snapshot)
    }

    @Test fun busyProbeDoesNotTurnUnknownInjectionIntoFailure() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, null, null, "displayOnly") is BackgroundGateState.Update.Accepted)
        val before = state.snapshot

        assertSame(BackgroundGateState.Update.Busy, state.update(state.begin { true }!!, false, "probeBusy", false, "busyInputError", null))

        assertEquals(
            BackgroundGateState.Snapshot(true, null, null, "displayOnly"),
            state.snapshot,
        )
        assertSame(before, state.snapshot)
    }

    @Test fun realDisplayFailureReplacesPreviouslySuccessfulCapabilities() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, true, null, "ready") is BackgroundGateState.Update.Accepted)

        assertTrue(state.update(state.begin { true }!!, false, "displayRejected", null, null, "displayDenied") is BackgroundGateState.Update.Accepted)

        assertEquals(
            BackgroundGateState.Snapshot(false, null, null, "displayDenied"),
            state.snapshot,
        )
    }

    @Test fun realInjectionFailureUpdatesErrorWithoutLosingDisplaySuccess() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, true, null, "ready") is BackgroundGateState.Update.Accepted)

        assertTrue(state.update(state.begin { true }!!, true, null, false, "inputRejected", "injectionDenied") is BackgroundGateState.Update.Accepted)

        assertEquals(
            BackgroundGateState.Snapshot(true, false, "inputRejected", "injectionDenied"),
            state.snapshot,
        )
    }

    @Test fun subsequentFailureReplacesOldErrorAndDetail() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, false, "displayRejected", false, "oldInputError", "oldDetail") is BackgroundGateState.Update.Accepted)

        assertTrue(state.update(state.begin { true }!!, true, null, false, "newInputError", "newDetail") is BackgroundGateState.Update.Accepted)

        assertEquals(
            BackgroundGateState.Snapshot(true, false, "newInputError", "newDetail"),
            state.snapshot,
        )
    }

    @Test fun successfulInjectionClearsOldErrorAndAbsentDetail() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, false, "displayRejected", false, "oldInputError", "oldDetail") is BackgroundGateState.Update.Accepted)

        assertTrue(state.update(state.begin { true }!!, true, null, true, "irrelevantInputError", null) is BackgroundGateState.Update.Accepted)

        assertEquals(
            BackgroundGateState.Snapshot(true, true, null, null),
            state.snapshot,
        )
    }

    @Test fun unknownInjectionAlsoClearsOldError() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, false, "oldInputError", "oldDetail") is BackgroundGateState.Update.Accepted)

        assertTrue(state.update(state.begin { true }!!, false, "displayRejected", null, "irrelevantInputError", "displayDenied") is BackgroundGateState.Update.Accepted)

        assertEquals(
            BackgroundGateState.Snapshot(false, null, null, "displayDenied"),
            state.snapshot,
        )
    }

    @Test fun resetClearsFailedCapabilitiesErrorAndDetail() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, false, "displayRejected", false, "inputRejected", "failedDetail") is BackgroundGateState.Update.Accepted)

        state.reset()

        assertEquals(
            BackgroundGateState.Snapshot(null, null, null, null),
            state.snapshot,
        )
    }

    @Test fun resetClearsSuccessfulCapabilitiesAndAllowsFreshResult() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, true, null, "ready") is BackgroundGateState.Update.Accepted)

        state.reset()

        assertEquals(
            BackgroundGateState.Snapshot(null, null, null, null),
            state.snapshot,
        )
        assertTrue(state.update(state.begin { true }!!, false, "displayRejected", false, "freshInputError", "freshDetail") is BackgroundGateState.Update.Accepted)
        assertEquals(
            BackgroundGateState.Snapshot(false, false, "freshInputError", "freshDetail"),
            state.snapshot,
        )
    }
    @Test fun acceptedSuccessRemainsThisAttemptsResultAfterAnotherProbeFails() {
        val state = BackgroundGateState()
        val first = state.update(state.begin { true }!!, true, null, true, null, null)
            as BackgroundGateState.Update.Accepted

        state.update(state.begin { true }!!, false, "displayRejected", null, null, null)

        assertTrue(first.receipt.trustedDisplayOk)
        assertEquals(true, first.receipt.injectOk)
        assertEquals(false, state.snapshot.trustedDisplayOk)
        assertNull(state.snapshot.injectOk)
    }

    @Test fun acceptedFailureIsNotReplacedByLaterSuccessOrReset() {
        val state = BackgroundGateState()
        val detail = "probe-v1;stage=receipt_wait;type=TimeoutException;elapsedMs=7"
        val first = state.update(state.begin { true }!!, true, null, false, "inputUnconfirmed", detail)
            as BackgroundGateState.Update.Accepted

        state.update(state.begin { true }!!, true, null, true, null, null)
        state.reset()

        assertEquals(false, first.receipt.injectOk)
        assertEquals(BackgroundGateState.InjectFailure.UNCONFIRMED, first.receipt.injectFailure)
        assertEquals(InputProbeDiagnostics.Observation(InputProbeDiagnostics.Stage.RECEIPT_WAIT, "TimeoutException", 7),
            first.receipt.observation)
        assertEquals(BackgroundGateState.Snapshot(), state.snapshot)
    }

    @Test fun newerBeginCancelsOldResponseInsteadOfProducingAReceipt() {
        val state = BackgroundGateState()
        val old = state.begin { true }!!
        val current = state.begin { true }!!
        val before = state.snapshot

        assertSame(BackgroundGateState.Update.Cancelled, state.update(old, true, null, true, null, null))
        assertSame(before, state.snapshot)
        assertTrue(state.update(current, true, null, null, null, null) is BackgroundGateState.Update.Accepted)
    }

    @Test fun busyIsAnAttemptResultAndNeverAReceiptOfHistoricalSuccess() {
        val state = BackgroundGateState()
        state.update(state.begin { true }!!, true, null, true, null, null)
        val before = state.snapshot

        val busy = state.update(state.begin { true }!!, false, "probeBusy", false, "inputUnconfirmed", null)

        assertSame(BackgroundGateState.Update.Busy, busy)
        assertSame(before, state.snapshot)
    }

    @Test fun cancelledBusyResponseCannotBeClassifiedUsingANewerProbe() {
        val state = BackgroundGateState()
        var wanted = true
        val old = state.begin { wanted }!!
        wanted = false

        assertSame(BackgroundGateState.Update.Cancelled, state.update(old, false, "probeBusy", null, null, null))
        state.begin { true }
        assertSame(BackgroundGateState.Update.Cancelled, state.update(old, false, "probeBusy", null, null, null))
    }

    @Test fun receiptPreservesUnknownInjectionAndDropsIrrelevantFailure() {
        val state = BackgroundGateState()
        for (inject in listOf(null, true, false)) {
            val accepted = state.update(state.begin { true }!!, true, null, inject, "inputWindowNotReady", null)
                as BackgroundGateState.Update.Accepted
            assertEquals(inject, accepted.receipt.injectOk)
            assertEquals(if (inject == false) BackgroundGateState.InjectFailure.WINDOW_NOT_READY else null,
                accepted.receipt.injectFailure)
        }
    }

    @Test fun receiptCannotCarryRawErrorsOrUnrecognizedDetails() {
        val state = BackgroundGateState()
        for (detail in listOf("private-page-content", "x".repeat(161),
            "probe-v1;stage=receipt_wait;type=PrivateName;elapsedMs=7",
            "probe-v1;stage=private_page;type=TimeoutException;elapsedMs=7",
            "probe-v1;stage=receipt_wait;type=TimeoutException;elapsedMs=60001")) {
            val accepted = state.update(state.begin { true }!!, false, "private-error", false, "private-input", detail)
                as BackgroundGateState.Update.Accepted
            assertEquals(BackgroundGateState.InjectFailure.OTHER, accepted.receipt.injectFailure)
            assertNull(accepted.receipt.observation)
            assertFalse(accepted.receipt.toString().contains("private"))
        }
    }

    @Test fun laterConnectionFailureCannotChangeAnAcceptedReceipt() {
        val state = BackgroundGateState()
        val first = state.update(state.begin { true }!!, true, null, true, null, null)
            as BackgroundGateState.Update.Accepted
        val retry = state.begin { true }!!
        assertTrue(state.failed(retry, 1, Any()))
        val failed = state.snapshot
        state.connected(failed, Any())

        assertEquals(BackgroundGateState.Receipt(true, true, null, null), first.receipt)
        assertNull(state.snapshot.connectionError)
    }
}
