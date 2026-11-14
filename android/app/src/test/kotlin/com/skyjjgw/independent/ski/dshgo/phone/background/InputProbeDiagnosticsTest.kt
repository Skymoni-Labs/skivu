package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.ExecutionException

/** Real production probe/codec/gate classes. Source only in 710: JVM/Android not run. */
class InputProbeDiagnosticsTest {
    private val point = InputProbe.Target(11, 180, 400)
    private val privateText = "token=secret /private/screen-content"

    @Test fun setupFailureKeepsCodeAndCauseButExportsOnlySafeFacts() {
        var time = 100L
        val probe = InputProbe(11) { time }
        probe.entered(InputProbeDiagnostics.Stage.PRESENTATION_CREATE)
        val cause = SecurityException(privateText)
        time = 117L
        probe.fail(cause)
        var sends = 0
        val failure = assertThrows(InputProbe.Failure::class.java) {
            probe.verify({ 100L }, { _, _ -> sends++ }, 0, 0)
        }
        assertEquals("inputWindowNotReady", failure.code)
        assertSame(cause, failure.cause)
        assertEquals(0, sends)
        assertEquals("probe-v1;stage=presentation_create;type=SecurityException;elapsedMs=17",
            failure.observation!!.encode())
        assertFalse(failure.observation!!.encode().contains(privateText))
    }

    @Test fun frameTimeoutIsDistinctAndFrozenBeforeCleanup() {
        var time = 0L
        val probe = InputProbe(11) { time }
        probe.entered(InputProbeDiagnostics.Stage.FRAME_COMMIT_WAIT)
        // A synchronous show callback may already have advanced beyond the returning show call.
        probe.entered(InputProbeDiagnostics.Stage.VIEW_LAYOUT_WAIT)
        time = 3000L
        val failure = assertThrows(InputProbe.Failure::class.java) {
            probe.verify({ 100L }, { _, _ -> fail("no ready target: must not inject") }, 0, 0)
        }
        probe.entered(InputProbeDiagnostics.Stage.CLEANUP)
        time = 4000L
        assertEquals("inputWindowNotReady", failure.code)
        assertEquals("probe-v1;stage=frame_commit_wait;type=TimeoutException;elapsedMs=3000",
            probe.observation(failure).encode())
    }

    @Test fun missingReceiptIsStillOneSendAndNotWindowFailure() {
        val probe = InputProbe(11) { 0L }.also { it.ready(point) }
        var sends = 0
        val failure = assertThrows(InputProbe.Failure::class.java) {
            probe.verify({ 100L }, { _, _ -> sends++ }, 0, 0)
        }
        assertEquals(1, sends)
        assertEquals("inputUnconfirmed", failure.code)
        assertEquals(InputProbeDiagnostics.Stage.RECEIPT_WAIT, failure.observation!!.stage)
        assertEquals("TimeoutException", failure.observation!!.exceptionType)
    }

    @Test fun sendExceptionRetainsIdentityAndInputStage() {
        val probe = InputProbe(11) { 0L }.also { it.ready(point) }
        val cause = SecurityException(privateText)
        assertSame(cause, assertThrows(SecurityException::class.java) {
            probe.verify({ 100L }, { _, _ -> throw cause }, 0, 0)
        })
        assertEquals("probe-v1;stage=input_send;type=SecurityException;elapsedMs=0",
            probe.observation(cause).encode())
    }

    @Test fun matchingReceiptStillCompletesWithoutReplay() {
        val probe = InputProbe(11) { 0L }.also { it.ready(point) }
        var sends = 0
        probe.verify({ 100L }, { target, time ->
            sends++
            probe.accept(target.displayId, time, 0, target.x.toFloat(), target.y.toFloat())
            probe.accept(target.displayId, time, 1, target.x.toFloat(), target.y.toFloat())
        }, 0, 0)
        assertEquals(1, sends)
    }

    private class PrivateScreenException(message: String) : Exception(message)

    @Test fun unknownTypesMessagesAndNestedCausesAreNotSerialized() {
        val stage = InputProbeDiagnostics.Stage.CLEANUP
        val unknown = InputProbeDiagnostics.observe(stage, PrivateScreenException(privateText), 70_000)
        assertEquals("probe-v1;stage=cleanup;type=OtherException;elapsedMs=60000", unknown.encode())
        assertEquals("IllegalStateException", InputProbeDiagnostics.observe(stage,
            ExecutionException(IllegalStateException(privateText)), 10).exceptionType)
        assertEquals("OtherException", InputProbeDiagnostics.observe(stage,
            ExecutionException(ExecutionException(SecurityException(privateText))), 10).exceptionType)
        assertEquals(0L, InputProbeDiagnostics.observe(stage, null, -1).elapsedMs)
    }

    @Test fun onlyExactBoundedProtocolCanBecomeExportedFacts() {
        val valid = "probe-v1;stage=frame_commit_wait;type=TimeoutException;elapsedMs=3000"
        assertEquals(valid, InputProbeDiagnostics.decode(valid)!!.encode())
        for (bad in listOf<String?>(null, "IllegalStateException", "", valid + ";message=$privateText",
            valid.replace("frame_commit_wait", "private_screen"), valid.replace("TimeoutException", "PrivateScreenException"),
            valid.replace("3000", "-1"), valid.replace("3000", "60001"), valid.replace("3000", "999999999999999999"),
            "x".repeat(161))) assertNull(InputProbeDiagnostics.decode(bad))
        val old = BackgroundGateState.Snapshot(true, false, "inputWindowNotReady", "old raw $privateText")
        assertEquals(mapOf("v" to 1, "observed" to false, "connectionFailure" to false),
            InputProbeDiagnostics.snapshot(old))
        assertEquals(false, InputProbeDiagnostics.snapshot(BackgroundGateState.Snapshot(gateDetail = valid))["observed"])
    }

    @Test fun acceptedReceiptSuccessIsExplicitAndDoesNotInventElapsedTime() {
        val gate = BackgroundGateState()
        assertTrue(gate.update(gate.begin { true }!!, true, null, true, null, null) is BackgroundGateState.Update.Accepted)
        assertEquals(mapOf("v" to 1, "observed" to true, "connectionFailure" to false, "result" to "success"),
            InputProbeDiagnostics.snapshot(gate.snapshot))
    }

    @Test fun staleAndBusyProbesCannotOverwriteTheOnlySnapshot() {
        val gate = BackgroundGateState()
        val old = gate.begin { true }!!
        val current = gate.begin { true }!!
        assertTrue(gate.update(current, true, null, true, null, null) is BackgroundGateState.Update.Accepted)
        val before = gate.snapshot
        val detail = "probe-v1;stage=presentation_show;type=IllegalStateException;elapsedMs=7"
        assertSame(BackgroundGateState.Update.Cancelled, gate.update(old, true, null, false, "inputWindowNotReady", detail))
        assertSame(before, gate.snapshot)
        assertSame(BackgroundGateState.Update.Busy, gate.update(gate.begin { true }!!, false, "probeBusy", false, "inputWindowNotReady", detail))
        assertSame(before, gate.snapshot)
        assertEquals("success", InputProbeDiagnostics.snapshot(gate.snapshot)["result"])
    }

    @Test fun retryConnectionFailureAndResetFollowExistingGateLifetime() {
        val gate = BackgroundGateState()
        val detail = "probe-v1;stage=presentation_show;type=IllegalStateException;elapsedMs=7"
        assertTrue(gate.update(gate.begin { true }!!, true, null, false, "inputWindowNotReady", detail) is BackgroundGateState.Update.Accepted)
        val retry = gate.begin { true }!!
        assertEquals("failure", InputProbeDiagnostics.snapshot(gate.snapshot)["result"])
        val channel = Any()
        assertTrue(gate.failed(retry, 1, channel))
        val failed = gate.snapshot
        assertEquals(true, InputProbeDiagnostics.snapshot(failed)["connectionFailure"])
        assertEquals("presentation_show", InputProbeDiagnostics.snapshot(failed)["stage"])
        gate.connected(failed, Any())
        assertEquals(false, InputProbeDiagnostics.snapshot(gate.snapshot)["connectionFailure"])
        gate.reset()
        assertSame(BackgroundGateState.Update.Cancelled, gate.update(retry, true, null, false, "inputWindowNotReady", detail))
        assertEquals(mapOf("v" to 1, "observed" to false, "connectionFailure" to false),
            InputProbeDiagnostics.snapshot(gate.snapshot))
    }
}
