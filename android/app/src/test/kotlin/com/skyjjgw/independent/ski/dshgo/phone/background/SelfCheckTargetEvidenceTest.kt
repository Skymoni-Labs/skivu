package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.selfcheck.TargetContract
import org.junit.Assert.*
import org.junit.Test

/** The exact accumulator consumed by Core.walk. These are not AccessibilityNodeInfo tests. */
class SelfCheckTargetEvidenceTest {
    private val run = "12345678-1234-1234-1234-123456789012"
    private fun id(name: String) = TargetContract.viewId(Proto.APP_PACKAGE, name)
    private fun marker(e: SelfCheckTargetEvidence, description: CharSequence? = TargetContract.marker(run), visible: Boolean = true) =
        e.observe(id(TargetContract.MARKER_ID), visible, null, description, true, false)
    private fun counter(e: SelfCheckTargetEvidence, text: CharSequence? = "0") =
        e.observe(id(TargetContract.COUNTER_ID), true, text, null, true, false)
    private fun button(e: SelfCheckTargetEvidence, enabled: Boolean = true, clickable: Boolean = true) =
        e.observe(id(TargetContract.BUTTON_ID), true, "Tap", null, enabled, clickable)

    @Test fun rawMarkerSurvivesOrdinaryPrivacyLabelRedactionWithoutChangingThatLabelPath() {
        val raw = TargetContract.marker(run)
        assertNotEquals(raw, BackgroundTree.label(raw, raw, false, false, false))
        val evidence = SelfCheckTargetEvidence(run, 0)
        marker(evidence); counter(evidence); button(evidence)
        assertTrue(evidence.targetMatched); assertTrue(evidence.counterMatched)
    }

    @Test fun onlyOriginalRunRawDescriptionAndFixedResourceIdCanMatch() {
        val wrongRun = SelfCheckTargetEvidence(run, 0)
        marker(wrongRun, TargetContract.marker("123e4567-e89b-42d3-a456-426614174000"))
        counter(wrongRun); button(wrongRun); assertFalse(wrongRun.targetMatched)
        val wrongId = SelfCheckTargetEvidence(run, 0)
        wrongId.observe("another.app:id/${TargetContract.MARKER_ID}", true, null, TargetContract.marker(run), true, false)
        counter(wrongId); button(wrongId); assertFalse(wrongId.targetMatched)
        val wrongSource = SelfCheckTargetEvidence(run, 0)
        wrongSource.observe(id(TargetContract.MARKER_ID), true, TargetContract.marker(run), null, true, false)
        counter(wrongSource); button(wrongSource); assertFalse(wrongSource.targetMatched)
    }

    @Test fun counterMustBeExactlyZeroBeforeTapAndOneAfterTap() {
        for (expected in listOf(0, 1)) for (text in listOf("0", "1", "2", "01", " 1", "1\n")) {
            val evidence = SelfCheckTargetEvidence(run, expected)
            marker(evidence); counter(evidence, text); button(evidence)
            assertTrue(evidence.targetMatched)
            assertEquals(text == expected.toString(), evidence.counterMatched)
        }
    }

    @Test fun duplicateFixedNodesCannotProduceAValidTarget() {
        for (duplicate in listOf(TargetContract.MARKER_ID, TargetContract.COUNTER_ID, TargetContract.BUTTON_ID)) {
            val evidence = SelfCheckTargetEvidence(run, 0)
            marker(evidence); counter(evidence); button(evidence)
            evidence.observe(id(duplicate), true, "0", TargetContract.marker(run), true, true)
            assertFalse(evidence.targetMatched)
        }
    }

    @Test fun invisibleMarkerAndDisabledOrNonclickableButtonFail() {
        val hidden = SelfCheckTargetEvidence(run, 0)
        marker(hidden, visible = false); counter(hidden); button(hidden); assertFalse(hidden.targetMatched)
        for ((enabled, clickable) in listOf(false to true, true to false)) {
            val evidence = SelfCheckTargetEvidence(run, 0)
            marker(evidence); counter(evidence); button(evidence, enabled, clickable)
            assertFalse(evidence.targetMatched)
        }
    }

    @Test fun oversizedDescriptionIsRejectedBeforeMaterializingIt() {
        val oversized = object : CharSequence {
            override val length = 100_000
            override fun get(index: Int): Char = error("must not read oversized value")
            override fun subSequence(startIndex: Int, endIndex: Int): CharSequence = error("must not slice")
            override fun toString(): String = error("must not allocate raw value")
        }
        val evidence = SelfCheckTargetEvidence(run, 0)
        marker(evidence, oversized); counter(evidence); button(evidence)
        assertFalse(evidence.targetMatched)
    }
}
