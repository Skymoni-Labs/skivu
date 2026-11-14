package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

/** Real production sampler/comparator, not simulated ATMS or a platform-release assertion. */
class SelfCheckMainSamplesTest {
    private val row = SelfCheckMainSamples.Task(1, 0, 0, "local/component", 0, true, true)
    private val focus = SelfCheckMainSamples.Focus(0, 1)
    private val before = SelfCheckMainSamples.Slot.BEFORE_CREATE
    private val after = SelfCheckMainSamples.Slot.AFTER_LAUNCH
    private val end = SelfCheckMainSamples.Slot.AFTER_RELEASE
    private val unknown = SelfCheckMainSamples.Value.UNAVAILABLE

    @Test fun missingBaselineNeverBecomesUnchangedAndTwoQueriesAreIndependent() {
        var n = 0
        val samples = SelfCheckMainSamples({ if (n++ == 0) throw IllegalStateException() else listOf(row) }, { focus })
        assertEquals(unknown, samples.sample(before).vector)
        val actual = samples.sample(after)
        assertEquals(unknown, actual.vector)
        assertEquals(SelfCheckMainSamples.Value.UNCHANGED, actual.focus)
    }

    @Test fun eachSlotIsAttemptedOnceIncludingFailureAndReleaseResult() {
        var vectors = 0; var focuses = 0
        val samples = SelfCheckMainSamples({ vectors++; listOf(row) }, { focuses++; throw IllegalStateException() })
        samples.sample(before)
        val result = samples.sample(end)
        repeat(10) { assertSame(result, samples.sample(end)) }
        assertEquals(2, vectors); assertEquals(2, focuses)
        assertEquals(unknown, result.focus)
    }

    @Test fun globalFocusChangeIsVisibleEvenWhenMainVectorHasNotChanged() {
        var current = focus
        val samples = SelfCheckMainSamples({ listOf(row) }, { current })
        samples.sample(before); current = SelfCheckMainSamples.Focus(7, 2)
        val result = samples.sample(after)
        assertEquals(SelfCheckMainSamples.Value.UNCHANGED, result.vector)
        assertEquals(SelfCheckMainSamples.Value.CHANGED, result.focus)
    }

    @Test fun orderDoesNotMatterButEarlierChangedSlotNeverGetsRewrittenByRecovery() {
        var rows = listOf(row, row.copy(id = 2, position = 1, component = null))
        val samples = SelfCheckMainSamples({ rows }, { focus })
        samples.sample(before); rows = rows.reversed()
        assertEquals(SelfCheckMainSamples.Value.UNCHANGED, samples.sample(after).vector)
        rows = listOf(row.copy(visible = false))
        val changed = samples.sample(SelfCheckMainSamples.Slot.AFTER_INPUTS)
        rows = listOf(row, row.copy(id = 2, position = 1, component = null))
        assertEquals(SelfCheckMainSamples.Value.UNCHANGED, samples.sample(end).vector)
        assertEquals(SelfCheckMainSamples.Value.CHANGED, changed.vector)
        assertSame(changed, samples.sample(SelfCheckMainSamples.Slot.AFTER_INPUTS))
    }

    @Test fun OverBudgetWrongDisplayAndDuplicateRootsAreUnavailableNotTruncated() {
        for (rows in listOf(List(65) { row.copy(id = it, position = it) }, listOf(row.copy(display = 7)), listOf(row, row))) {
            val samples = SelfCheckMainSamples({ rows }, { focus })
            assertEquals(unknown, samples.sample(before).vector)
        }
    }

    @Test fun PostSampleBeforeBaselineCannotBeRetroactivelyReclassified() {
        val samples = SelfCheckMainSamples({ emptyList() }, { focus })
        val early = samples.sample(after)
        assertEquals(unknown, early.vector)
        samples.sample(before)
        assertSame(early, samples.sample(after))
        assertEquals(SelfCheckMainSamples.Value.UNCHANGED, samples.sample(end).vector)
    }
}
