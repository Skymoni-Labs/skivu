package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.*
import org.junit.Test

class MainFocusSelectionTest {
    @Test fun absoluteRangeAndReversedSelectionMustMatchBothObservedEndpoints() {
        val sample = FocusReadback.Sample("abcd", 3, 1, 10)
        assertTrue(focusSampleMatchesSelection(sample, 13, 11))
        assertFalse(focusSampleMatchesSelection(sample, 11, 13))
        assertFalse(focusSampleMatchesSelection(sample, 13, 12))
    }
    @Test fun unknownOffsetCannotInventAnAbsolutePreDispatchSelection() {
        assertFalse(focusSampleMatchesSelection(FocusReadback.Sample("abc", 1, 1, -1), 1, 1))
        assertFalse(focusSampleMatchesSelection(null, 0, 0))
        assertFalse(focusSampleMatchesSelection(FocusReadback.Sample("", 0, 0, 0), -1, -1))
        assertTrue(focusSampleMatchesSelection(FocusReadback.Sample("", 0, 0, 0), 0, 0))
    }
    @Test fun selectionCannotSplitEmojiOrUseAnEdgeHalfSurrogate() {
        val emoji = "\uD83D\uDE00"
        assertFalse(focusSampleMatchesSelection(FocusReadback.Sample(emoji, 1, 1, 0), 1, 1))
        assertTrue(focusSampleMatchesSelection(FocusReadback.Sample(emoji, 0, 2, 0), 0, 2))
        assertFalse(focusSampleMatchesSelection(FocusReadback.Sample("\uDE00a", 0, 0, 0), 0, 0))
        assertFalse(focusSampleMatchesSelection(FocusReadback.Sample("a\uD83D", 2, 2, 0), 2, 2))
    }
    @Test fun invalidRangesAndIntegerOverflowDoNotMatch() {
        assertFalse(focusSampleMatchesSelection(FocusReadback.Sample("a", 2, 2, 0), 2, 2))
        assertFalse(focusSampleMatchesSelection(FocusReadback.Sample("a", 1, 1, Int.MAX_VALUE), Int.MIN_VALUE, Int.MIN_VALUE))
        assertFalse(focusSampleMatchesSelection(FocusReadback.Sample("a".repeat(4097), 0, 0, 0), 0, 0))
    }
}
