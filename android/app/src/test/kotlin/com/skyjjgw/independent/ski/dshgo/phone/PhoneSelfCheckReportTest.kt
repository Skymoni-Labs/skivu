package com.skyjjgw.independent.ski.dshgo.phone

import com.skyjjgw.independent.ski.dshgo.phone.PhoneSelfCheckReport.Reason
import com.skyjjgw.independent.ski.dshgo.phone.PhoneSelfCheckReport.Profile
import com.skyjjgw.independent.ski.dshgo.phone.PhoneSelfCheckReport.Stage
import com.skyjjgw.independent.ski.dshgo.phone.PhoneSelfCheckReport.State
import org.junit.Assert.*
import org.junit.Test

/** The production report consumes these exact fields from the real Bundle reply. No Android stubs. */
class PhoneSelfCheckReportTest {
    private fun row(report: PhoneSelfCheckReport, stage: Stage) =
        report.toMaps().single { it["stage"] == stage.wire }

    private fun target() = PhoneSelfCheckReport(Profile.TARGET_C1)

    private fun create(report: PhoneSelfCheckReport, owner: Any? = "owner", run: Any? = "run",
                       nonce: Any? = "create", version: Any? = 1, ok: Any? = true,
                       error: Any? = null, ready: Any? = true, id: Any? = 7): Int? =
        report.acceptTargetCreate("owner", "run", "create", owner, run, nonce, version,
            ok, error, ready, id, 10)

    private fun read(report: PhoneSelfCheckReport, ok: Any? = true, error: Any? = null,
                     matched: Any? = true, complete: Any? = true, counter: Any? = true): Boolean =
        report.acceptTargetRead("owner", "run", "read", "owner", "run", "read", 1,
            ok, error, matched, complete, counter, 20)

    private fun tap(report: PhoneSelfCheckReport, ok: Any? = true, error: Any? = null,
                    attempted: Any? = true, matched: Any? = true, complete: Any? = true,
                    counter: Any? = true, nonce: Any? = "tap"): Boolean =
        report.acceptTargetTap("owner", "run", "tap", "owner", "run", nonce, 1,
            ok, error, attempted, matched, complete, counter, 30)

    @Test fun newReportNeverInventsActivityTextOcrOrMainResults() {
        val report = PhoneSelfCheckReport()
        assertEquals(16, report.toMaps().size)
        for (step in report.toMaps()) {
            assertEquals("not_run", step["state"])
            assertEquals(false, step["observed"])
        }
    }

    @Test fun actualDeliveryRemainsPassedWhenCleanupIsUnconfirmed() {
        val report = PhoneSelfCheckReport()
        assertTrue(report.acceptProbe("resource", "resource", 1, true, true, true, null, null, 42))
        report.update(Stage.CLEANUP, State.UNKNOWN, false, Reason.CLEANUP_FAILED)
        report.finishPending(cancelled = true)
        assertEquals("pass", row(report, Stage.INPUT_PROBE)["state"])
        assertEquals(true, row(report, Stage.INPUT_PROBE)["observed"])
        assertEquals("unknown", row(report, Stage.CLEANUP)["state"])
        for (stage in listOf(Stage.LAUNCH, Stage.TREE, Stage.TEXT_ASCII, Stage.TEXT_ZH,
                Stage.CAPTURE, Stage.CONTINUITY, Stage.MAIN, Stage.OCR)) {
            assertEquals("not_run", row(report, stage)["state"])
        }
    }

    @Test fun successWithAnErrorIsContradictoryAndNeverGreen() {
        for ((error, injectionError) in listOf(
                "private contact and message" to null, null to "inputUnconfirmed", "" to null)) {
            val report = PhoneSelfCheckReport()
            assertFalse(report.acceptProbe("resource", "resource", 1, true, true, true,
                error, injectionError, 10))
            for (stage in listOf(Stage.DISPLAY, Stage.INPUT_PROBE)) {
                assertEquals("unknown", row(report, stage)["state"])
                assertEquals("invalidResponse", row(report, stage)["reason"])
            }
            assertFalse(report.toMaps().toString().contains("private contact"))
        }
    }

    @Test fun replyIdentityVersionTypesAndTruthTableMustAllMatch() {
        val invalid = listOf(
            listOf("other", 1, true, true, true),
            listOf(42, 1, true, true, true),
            listOf("resource", 1L, true, true, true),
            listOf("resource", 1, "true", true, true),
            listOf("resource", 1, true, 1, true),
            listOf("resource", 1, true, true, "true"),
            listOf("resource", 1, true, true, false),
            listOf("resource", 1, false, true, true),
            listOf("resource", 1, false, false, false),
        )
        for (fields in invalid) {
            val report = PhoneSelfCheckReport()
            assertFalse(report.acceptProbe("resource", fields[0], fields[1], fields[2],
                fields[3], fields[4], null, null, 0))
            assertTrue(report.toMaps().none { it["state"] == "pass" })
        }
    }

    @Test fun attemptedInputWithoutReceiptMeansUnknownNotNoInput() {
        val report = PhoneSelfCheckReport()
        assertTrue(report.acceptProbe("resource", "resource", 1, false, true, false,
            "inputUnconfirmed", "inputUnconfirmed", 55))
        assertEquals("pass", row(report, Stage.DISPLAY)["state"])
        assertEquals("unknown", row(report, Stage.INPUT_PROBE)["state"])
        assertEquals(true, row(report, Stage.INPUT_PROBE)["observed"])
        assertEquals("inputUnconfirmed", row(report, Stage.INPUT_PROBE)["reason"])
    }

    @Test fun windowPreparationFailureDoesNotClaimInputWasSent() {
        val report = PhoneSelfCheckReport()
        assertTrue(report.acceptProbe("resource", "resource", 1, false, true, null,
            "inputWindowNotReady", "inputWindowNotReady", 50))
        assertEquals("fail", row(report, Stage.INPUT_PROBE)["state"])
        assertEquals("inputWindowNotReady", row(report, Stage.INPUT_PROBE)["reason"])
        val beforeWindow = PhoneSelfCheckReport()
        beforeWindow.update(Stage.INPUT_PROBE, State.RUNNING, false)
        assertTrue(beforeWindow.acceptProbe("resource", "resource", 1, false, false, null,
            "locked", null, 2))
        assertEquals("not_run", row(beforeWindow, Stage.INPUT_PROBE)["state"])
        assertEquals(false, row(beforeWindow, Stage.INPUT_PROBE)["observed"])
    }

    @Test fun cancelledPendingStepsCannotRemainRunningInAFinalReport() {
        val report = PhoneSelfCheckReport()
        report.update(Stage.CHANNEL, State.PASS, true)
        report.update(Stage.DISPLAY, State.RUNNING, false)
        report.update(Stage.INPUT_PROBE, State.RUNNING, false)
        report.finishPending(cancelled = true)
        assertEquals("pass", row(report, Stage.CHANNEL)["state"])
        assertEquals("cancelled", row(report, Stage.DISPLAY)["state"])
        assertEquals("cancelled", row(report, Stage.INPUT_PROBE)["state"])
    }

    @Test fun unknownFaultsAndUnboundedDurationAreNotExported() {
        val report = PhoneSelfCheckReport()
        val raw = "phone=13800000000 secret-message"
        assertTrue(report.acceptProbe("resource", "resource", 1, false, false, null,
            raw, null, Long.MAX_VALUE))
        assertEquals("other", row(report, Stage.DISPLAY)["reason"])
        assertEquals(Int.MAX_VALUE.toLong(), row(report, Stage.DISPLAY)["durationMs"])
        report.update(Stage.CLEANUP, State.UNKNOWN, false, Reason.CLEANUP_FAILED, -1)
        assertEquals(0L, row(report, Stage.CLEANUP)["durationMs"])
        assertFalse(report.toMaps().toString().contains(raw))
        assertTrue(report.toMaps().all { "owner" !in it && "runHandle" !in it && "detail" !in it })
    }

    @Test fun targetProfileNeverInventsProbeTextOcrOrMainSuccess() {
        val report = target()
        for (stage in listOf(Stage.INPUT_PROBE, Stage.TEXT_ASCII, Stage.TEXT_ZH,
                Stage.CAPTURE, Stage.CONTINUITY, Stage.OCR, Stage.MAIN)) {
            report.update(stage, State.PASS, true)
            assertEquals("not_run", row(report, stage)["state"])
        }
        report.update(Stage.MAIN, State.FAIL, false, Reason.TARGET_WRONG_MAIN)
        assertEquals("not_run", row(report, Stage.MAIN)["state"])
        report.update(Stage.MAIN, State.FAIL, true, Reason.TARGET_WRONG_MAIN)
        report.update(Stage.MAIN, State.PASS, true)
        assertEquals("fail", row(report, Stage.MAIN)["state"])
        assertEquals("targetWrongMain", row(report, Stage.MAIN)["reason"])
        assertEquals(Profile.PROBE_B, PhoneSelfCheckReport().profile)
        assertNull(Profile.parse("future_profile"))
    }

    @Test fun targetCreateRequiresExactEchoesTypesAndActualPositiveDisplay() {
        assertEquals(7, create(target()))
        val invalid = listOf<(PhoneSelfCheckReport) -> Int?>(
            { create(it, owner = "other") }, { create(it, run = "old") },
            { create(it, nonce = "old") }, { create(it, version = 1L) },
            { create(it, ok = "true") }, { create(it, ready = 1) },
            { create(it, id = 0) }, { create(it, id = 7L) },
            { create(it, ready = false, id = null) }, { create(it, error = "") },
        )
        for (call in invalid) {
            val report = target()
            assertNull(call(report))
            assertEquals("unknown", row(report, Stage.DISPLAY)["state"])
            assertEquals("invalidResponse", row(report, Stage.DISPLAY)["reason"])
        }
    }

    @Test fun targetCreateFailureCannotSupplyALaunchDisplayOrContradictSuccess() {
        val report = target()
        assertNull(create(report, ok = false, error = "treeCleanupPending"))
        assertEquals("unknown", row(report, Stage.DISPLAY)["state"])
        assertEquals("not_run", row(report, Stage.LAUNCH)["state"])
        val missing = target()
        assertNull(create(missing, ok = false, error = "displayUnsupported", ready = false, id = null))
        assertEquals("fail", row(missing, Stage.DISPLAY)["state"])
    }

    @Test fun targetLaunchAndTreePassOnlyTogetherFromCompleteActualRead() {
        for (values in listOf(listOf(false, true, true), listOf(true, false, true), listOf(true, true, false))) {
            val report = target()
            assertFalse(read(report, matched = values[0], complete = values[1], counter = values[2]))
            assertTrue(report.toMaps().none { it["state"] == "pass" })
        }
        val report = target()
        assertTrue(read(report))
        assertEquals("pass", row(report, Stage.LAUNCH)["state"])
        assertEquals("pass", row(report, Stage.TREE)["state"])
        assertEquals("not_run", row(report, Stage.TAP)["state"])
    }

    @Test fun targetReadFailureCannotAdvertiseAllSuccessfulFacts() {
        val report = target()
        assertFalse(read(report, ok = false, error = "treeCleanupPending"))
        assertEquals("unknown", row(report, Stage.LAUNCH)["state"])
        assertEquals("unknown", row(report, Stage.TREE)["state"])
        assertEquals("invalidResponse", row(report, Stage.TREE)["reason"])
        assertEquals("not_run", row(report, Stage.TAP)["state"])
    }

    @Test fun targetTapAttemptSurvivesUnknownOrChangedPostRead() {
        val report = target()
        assertFalse(tap(report, ok = false, error = "targetChanged", matched = null, complete = null, counter = null))
        assertEquals("unknown", row(report, Stage.TAP)["state"])
        assertEquals(true, row(report, Stage.TAP)["observed"])
        report.finishPending(cancelled = true)
        assertEquals(true, row(report, Stage.TAP)["observed"])
        val unchanged = target()
        assertFalse(tap(unchanged, ok = false, error = "targetReadbackMismatch", counter = false))
        assertEquals("fail", row(unchanged, Stage.TAP)["state"])
        assertEquals(true, row(unchanged, Stage.TAP)["observed"])
    }

    @Test fun confirmedCounterChangeIsNotErasedByCleanupOrCancellation() {
        val report = target()
        assertTrue(tap(report))
        report.update(Stage.CLEANUP, State.UNKNOWN, false, Reason.TARGET_CLEANUP_PENDING)
        report.finishPending(cancelled = true)
        assertEquals("pass", row(report, Stage.TAP)["state"])
        val failedClose = target()
        assertFalse(tap(failedClose, ok = false, error = "treeCleanupPending"))
        assertEquals("unknown", row(failedClose, Stage.TAP)["state"])
        assertEquals("invalidResponse", row(failedClose, Stage.TAP)["reason"])
    }

    @Test fun targetTapRejectsContradictionsOldNonceAndRawFaultContent() {
        val invalid = listOf<(PhoneSelfCheckReport) -> Boolean>(
            { tap(it, attempted = false) }, { tap(it, attempted = "true") },
            { tap(it, counter = false) }, { tap(it, matched = 1) },
            { tap(it, nonce = "old") }, { tap(it, error = "") },
            { tap(it, ok = false, attempted = false, matched = false, complete = false, counter = null) },
            { tap(it, ok = false, matched = null, complete = false, counter = null) },
            { tap(it, ok = false, matched = false, complete = null, counter = null) },
            { tap(it, ok = false, matched = false, complete = false, counter = false) },
        )
        for (call in invalid) {
            val report = target()
            assertFalse(call(report))
            assertEquals("invalidResponse", row(report, Stage.TAP)["reason"])
            assertEquals("unknown", row(report, Stage.TAP)["state"])
        }
        val report = target()
        assertFalse(tap(report, ok = false, error = "secret-contact-body", attempted = false,
            matched = null, complete = null, counter = null))
        assertEquals("fail", row(report, Stage.TAP)["state"])
        assertEquals(false, row(report, Stage.TAP)["observed"])
        assertEquals("other", row(report, Stage.TAP)["reason"])
        assertFalse(report.toMaps().toString().contains("secret-contact-body"))
    }
}
