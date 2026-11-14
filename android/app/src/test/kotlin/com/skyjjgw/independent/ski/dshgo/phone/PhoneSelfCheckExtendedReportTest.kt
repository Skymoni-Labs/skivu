package com.skyjjgw.independent.ski.dshgo.phone

import com.skyjjgw.independent.ski.dshgo.phone.PhoneSelfCheckReport.Profile
import com.skyjjgw.independent.ski.dshgo.phone.PhoneSelfCheckReport.Reason
import com.skyjjgw.independent.ski.dshgo.phone.PhoneSelfCheckReport.Stage
import com.skyjjgw.independent.ski.dshgo.phone.PhoneSelfCheckReport.State
import com.skyjjgw.independent.ski.dshgo.phone.selfcheck.TargetContract.FrameStage
import org.junit.Assert.*
import org.junit.Test

class PhoneSelfCheckExtendedReportTest {
    private fun report() = PhoneSelfCheckReport(Profile.TARGET_C2)
    private fun row(r: PhoneSelfCheckReport, stage: Stage) = r.toMaps().first { it["stage"] == stage.wire }
    private fun text(r: PhoneSelfCheckReport, stage: Stage = Stage.TEXT_ASCII,
                     ok: Any? = true, error: Any? = null, attempted: Any? = true, accepted: Any? = true,
                     matched: Any? = true, complete: Any? = true, actualText: Any? = true,
                     nonce: Any? = "n", version: Any? = 1, vector: Any? = null, focus: Any? = null) =
        r.acceptTargetText(stage, "owner", "run", "n", "owner", "run", nonce, version, ok, error,
            attempted, accepted, matched, complete, actualText, 20, vector, focus)
    private fun frame(r: PhoneSelfCheckReport, stage: FrameStage, ok: Any? = true,
                      error: Any? = null, matched: Any? = true, complete: Any? = true,
                      pixels: Any? = true, nonce: Any? = "n") =
        r.acceptTargetFrame(stage, "owner", "run", "n", "owner", "run", nonce, 1, ok, error,
            matched, complete, pixels, 30)
    private fun baseline(r: PhoneSelfCheckReport, vector: Any? = "baseline", focus: Any? = "baseline") {
        assertEquals(8, r.acceptTargetCreate("owner", "run", "n", "owner", "run", "n", 1,
            true, null, true, 8, 1, vector, focus))
    }
    private fun launched(r: PhoneSelfCheckReport, vector: Any? = "unchanged", focus: Any? = "unchanged") {
        assertTrue(r.acceptTargetRead("owner", "run", "n", "owner", "run", "n", 1,
            true, null, true, true, true, 2, vector, focus))
    }
    private fun finishMain(r: PhoneSelfCheckReport, nonce: Any? = "release", vector: Any? = "unchanged", focus: Any? = "unchanged") =
        r.acceptFinalMain("owner", "run", "release", "owner", "run", nonce, 1, true, null, vector, focus)

    @Test fun extendedProfileDoesNotInventOcrScrollBackOrMainSuccess() {
        val r = report()
        for (stage in listOf(Stage.OCR, Stage.INPUT_PROBE, Stage.SCROLL, Stage.BACK, Stage.MAIN)) {
            r.update(stage, State.PASS, true)
            assertEquals("not_run", row(r, stage)["state"])
            assertEquals(false, row(r, stage)["observed"])
        }
        assertEquals("notInstalled", row(r, Stage.OCR)["reason"])
        assertTrue(text(r))
        assertTrue(text(r, stage = Stage.TEXT_ZH))
        assertEquals("pass", row(r, Stage.TEXT_ASCII)["state"])
        assertEquals("pass", row(r, Stage.TEXT_ZH)["state"])
        assertEquals("target_c2", Profile.parse("target_c2")?.wire)
    }

    @Test fun acceptedTextWithUnknownPostReadSurvivesCleanupAndCancellation() {
        val r = report()
        assertFalse(text(r, ok = false, error = "treeCleanupPending", matched = null, complete = null, actualText = null))
        assertEquals("unknown", row(r, Stage.TEXT_ASCII)["state"])
        assertEquals(true, row(r, Stage.TEXT_ASCII)["observed"])
        r.update(Stage.CLEANUP, State.UNKNOWN, false, Reason.CLEANUP_FAILED)
        r.finishPending(cancelled = true)
        assertEquals("unknown", row(r, Stage.TEXT_ASCII)["state"])
        assertEquals(true, row(r, Stage.TEXT_ASCII)["observed"])
        assertEquals("treeCleanupPending", row(r, Stage.TEXT_ASCII)["reason"])
    }

    @Test fun textRejectsContradictionsPartialPostFactsWrongIdentityAndVersion() {
        val invalid = listOf<(PhoneSelfCheckReport) -> Boolean>(
            { text(it, attempted = "true") }, { text(it, accepted = 1) },
            { text(it, nonce = "old") }, { text(it, version = 1L) },
            { text(it, error = "") }, { text(it, ok = false) },
            { text(it, ok = false, accepted = false) },
            { text(it, ok = false, complete = false) },
            { text(it, ok = false, matched = null) },
            { text(it, ok = false, actualText = null) },
            { text(it, ok = false, attempted = false, accepted = false, matched = null, complete = null, actualText = null) },
        )
        for (call in invalid) {
            val r = report()
            assertFalse(call(r))
            assertEquals("unknown", row(r, Stage.TEXT_ASCII)["state"])
            assertEquals("invalidResponse", row(r, Stage.TEXT_ASCII)["reason"])
        }
    }

    @Test fun platformRejectionAndNoAttemptHaveDistinctObservedFacts() {
        val rejected = report()
        assertFalse(text(rejected, ok = false, error = "inputRejected", accepted = false,
            matched = null, complete = null, actualText = null))
        assertEquals("fail", row(rejected, Stage.TEXT_ASCII)["state"])
        assertEquals(true, row(rejected, Stage.TEXT_ASCII)["observed"])
        val before = report()
        assertFalse(text(before, ok = false, error = "private-field", attempted = false, accepted = null,
            matched = null, complete = null, actualText = null))
        assertEquals("fail", row(before, Stage.TEXT_ASCII)["state"])
        assertEquals(false, row(before, Stage.TEXT_ASCII)["observed"])
        assertEquals("other", row(before, Stage.TEXT_ASCII)["reason"])
        assertFalse(before.toMaps().toString().contains("private-field"))
    }

    @Test fun framesRequireExactCompleteReplyAndContinuationFinishesAtItsLastFixedSlot() {
        val r = report()
        assertTrue(frame(r, FrameStage.CAPTURE))
        assertEquals("pass", row(r, Stage.CAPTURE)["state"])
        assertTrue(frame(r, FrameStage.CONTINUITY_FIRST))
        assertEquals("running", row(r, Stage.CONTINUITY)["state"])
        assertTrue(frame(r, FrameStage.CONTINUITY_SECOND))
        assertEquals("running", row(r, Stage.CONTINUITY)["state"])
        assertTrue(frame(r, FrameStage.CONTINUITY_THIRD))
        assertEquals("pass", row(r, Stage.CONTINUITY)["state"])
        val bad = report()
        assertFalse(frame(bad, FrameStage.CAPTURE, complete = false))
        assertEquals("invalidResponse", row(bad, Stage.CAPTURE)["reason"])
        assertEquals(false, row(bad, Stage.CAPTURE)["observed"])
    }

    @Test fun laterBadFrameCannotEraseEarlierVerifiedContinuityObservation() {
        val r = report()
        assertTrue(frame(r, FrameStage.CONTINUITY_FIRST))
        assertFalse(frame(r, FrameStage.CONTINUITY_SECOND, nonce = "old"))
        assertEquals("unknown", row(r, Stage.CONTINUITY)["state"])
        assertEquals(true, row(r, Stage.CONTINUITY)["observed"])
        assertEquals("invalidResponse", row(r, Stage.CONTINUITY)["reason"])
        val rejected = report()
        assertTrue(frame(rejected, FrameStage.CONTINUITY_FIRST))
        assertFalse(frame(rejected, FrameStage.CONTINUITY_SECOND, ok = false,
            error = "targetFrameMismatch", matched = false, complete = false, pixels = false))
        assertEquals(true, row(rejected, Stage.CONTINUITY)["observed"])
        assertEquals("unknown", row(rejected, Stage.CONTINUITY)["state"])
    }

    @Test fun phaseAdvanceFailureAndCancellationKeepExistingContinuityEvidence() {
        val r = report()
        assertTrue(frame(r, FrameStage.CONTINUITY_FIRST))
        r.update(Stage.CONTINUITY, State.UNKNOWN, false, Reason.TARGET_FRAME_UNAVAILABLE)
        assertEquals(true, row(r, Stage.CONTINUITY)["observed"])
        val cancelled = report()
        assertTrue(frame(cancelled, FrameStage.CONTINUITY_FIRST))
        cancelled.finishPending(cancelled = true)
        assertEquals("cancelled", row(cancelled, Stage.CONTINUITY)["state"])
        assertEquals(true, row(cancelled, Stage.CONTINUITY)["observed"])
    }

    @Test fun fourUnchangedSamplePairsRemainUnknownInsteadOfGlobalMainPass() {
        val r = report()
        baseline(r); launched(r)
        assertTrue(text(r, stage = Stage.TEXT_ZH, vector = "unchanged", focus = "unchanged"))
        finishMain(r)
        assertEquals("unknown", row(r, Stage.MAIN)["state"])
        assertEquals(true, row(r, Stage.MAIN)["observed"])
        assertEquals("mainSamplesUnchanged", row(r, Stage.MAIN)["reason"])
        r.update(Stage.MAIN, State.PASS, true)
        assertEquals("unknown", row(r, Stage.MAIN)["state"])
    }

    @Test fun absentBaselineCannotMakeLaterUnchangedOrChangedValuesEvidence() {
        val r = report()
        baseline(r, vector = "unavailable", focus = "unavailable")
        launched(r, vector = "changed", focus = "unchanged")
        assertTrue(text(r, stage = Stage.TEXT_ZH, vector = "unchanged", focus = "changed"))
        finishMain(r)
        assertEquals("unknown", row(r, Stage.MAIN)["state"])
        assertEquals(false, row(r, Stage.MAIN)["observed"])
        assertEquals("mainSamplesIncomplete", row(r, Stage.MAIN)["reason"])
        val independent = report()
        baseline(independent, vector = "unavailable", focus = "baseline")
        launched(independent, vector = "changed", focus = "unchanged")
        assertEquals("unknown", row(independent, Stage.MAIN)["state"])
        assertEquals(true, row(independent, Stage.MAIN)["observed"])
    }

    @Test fun observedSampleChangeAndWrongMainAreNotWashedAwayByLaterSamples() {
        val r = report()
        baseline(r); launched(r, focus = "changed")
        assertTrue(text(r, stage = Stage.TEXT_ZH, vector = "unchanged", focus = "unchanged"))
        finishMain(r)
        assertEquals("fail", row(r, Stage.MAIN)["state"])
        assertEquals("mainSamplesChanged", row(r, Stage.MAIN)["reason"])
        r.update(Stage.MAIN, State.FAIL, true, Reason.TARGET_WRONG_MAIN)
        finishMain(r, vector = null, focus = null)
        r.finishPending(cancelled = true)
        assertEquals("targetWrongMain", row(r, Stage.MAIN)["reason"])
        assertEquals(true, row(r, Stage.MAIN)["observed"])
    }

    @Test fun invalidFinalSampleIdentityCannotFillTheMissingLastPointOrUndoCleanup() {
        val r = report()
        baseline(r); launched(r)
        assertTrue(text(r, stage = Stage.TEXT_ZH, vector = "unchanged", focus = "unchanged"))
        r.update(Stage.CLEANUP, State.PASS, true)
        finishMain(r, nonce = "another-release")
        assertEquals("mainSamplesIncomplete", row(r, Stage.MAIN)["reason"])
        assertEquals("unknown", row(r, Stage.MAIN)["state"])
        assertEquals("pass", row(r, Stage.CLEANUP)["state"])
        r.acceptFinalMain("owner", "run", "release")
        assertEquals("pass", row(r, Stage.CLEANUP)["state"])
    }

    @Test fun oldProfilesCannotAcceptExtendedTextFrameOrMainResults() {
        for (profile in listOf(Profile.PROBE_B, Profile.TARGET_C1)) {
            val r = PhoneSelfCheckReport(profile)
            assertFalse(text(r))
            assertFalse(frame(r, FrameStage.CAPTURE))
            finishMain(r)
            assertEquals("not_run", row(r, Stage.TEXT_ASCII)["state"])
            assertEquals("not_run", row(r, Stage.CAPTURE)["state"])
            assertEquals("not_run", row(r, Stage.MAIN)["state"])
            assertNull(row(r, Stage.OCR)["reason"])
        }
    }
}
