package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.selfcheck.TargetContract
import org.junit.Assert.*
import org.junit.Test

/** The same raw-node accumulator used by Core's complete pre/post walks. No Android node stubs. */
class SelfCheckTargetC2EvidenceTest {
    private val run = "123e4567-e89b-42d3-a456-426614174001"
    private fun id(name: String) = TargetContract.viewId(Proto.APP_PACKAGE, name)
    private fun evidence(expected: String = TargetContract.ZH_TEXT, phase: Int = 1) =
        SelfCheckTargetEvidence(run, 1, true, expected, phase)
    private fun fill(e: SelfCheckTargetEvidence, text: CharSequence? = TargetContract.ZH_TEXT,
                     phase: String = "1", editable: Boolean = true, visible: Boolean = true, hint: Boolean = false) {
        e.observe(id(TargetContract.MARKER_ID), true, null, TargetContract.marker(run), true, false)
        e.observe(id(TargetContract.COUNTER_ID), true, "1", null, true, false)
        e.observe(id(TargetContract.BUTTON_ID), true, "button", null, true, true)
        e.observe(id(TargetContract.EDIT_ID), visible, text, null, true, false, editable, hint)
        e.observeBounds(id(TargetContract.EDIT_ID), 0, 0, 400, 60)
        e.observe(id(TargetContract.PATTERN_ID), visible, null, "fixed pattern", true, false)
        e.observeBounds(id(TargetContract.PATTERN_ID), 0, 100, 320, 228)
        e.observe(id(TargetContract.PHASE_ID), visible, phase, null, true, false)
    }

    @Test fun fixedChineseAndRawPhaseAreActualIndependentRequirements() {
        val good = evidence(); fill(good)
        assertTrue(good.targetMatched); assertTrue(good.textMatched); assertTrue(good.counterMatched)
        val staleText = evidence(); fill(staleText, TargetContract.ASCII_TEXT)
        assertTrue(staleText.targetMatched); assertFalse(staleText.textMatched)
        val stalePhase = evidence(); fill(stalePhase, phase = "0")
        assertFalse(stalePhase.targetMatched)
    }

    @Test fun duplicateOrInvisibleOrNoneditableFixedNodesCannotMatchTarget() {
        val duplicate = evidence(); fill(duplicate)
        duplicate.observe(id(TargetContract.PATTERN_ID), true, null, null, true, false)
        assertFalse(duplicate.targetMatched)
        val hidden = evidence(); fill(hidden, visible = false); assertFalse(hidden.targetMatched)
        val readonly = evidence(); fill(readonly, editable = false); assertFalse(readonly.targetMatched)
    }

    @Test fun rawBoundsAreOnlyCollectedForFixedC2NodesAndMustFitGeometry() {
        val e = evidence(); fill(e)
        assertTrue(e.needsBounds(id(TargetContract.PATTERN_ID)))
        assertFalse(e.needsBounds(id(TargetContract.MARKER_ID)))
        assertFalse(SelfCheckTargetEvidence(run, 1).needsBounds(id(TargetContract.PATTERN_ID)))
        assertTrue(checkNotNull(e.patternBounds).inside(720, 1600))
        e.observeBounds(id(TargetContract.PATTERN_ID), -1, 100, 320, 228)
        assertFalse(checkNotNull(e.patternBounds).inside(720, 1600))
    }

    @Test fun oversizedReadbackIsRejectedBeforeStringMaterialization() {
        val oversized = object : CharSequence {
            override val length = 4097
            override fun get(index: Int): Char = error("not needed")
            override fun subSequence(startIndex: Int, endIndex: Int): CharSequence = error("not needed")
            override fun toString(): String = error("must not materialize oversized text")
        }
        val e = evidence(); fill(e, oversized)
        assertFalse(e.textMatched)
    }

    @Test fun EmptyInitialEditorMayExposeHintButHintNeverMatchesEnteredText() {
        val initial = evidence("", 0); fill(initial, null, "0")
        assertTrue(initial.textMatched)
        val post = evidence(); fill(post, hint = true)
        assertTrue(post.targetMatched)
        assertFalse(post.textMatched)
    }
}
