package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.assertEquals
import org.junit.Test
import com.skyjjgw.independent.ski.dshgo.phone.a11y.FocusReadback.Kind
import com.skyjjgw.independent.ski.dshgo.phone.a11y.FocusReadback.Result
import com.skyjjgw.independent.ski.dshgo.phone.a11y.FocusReadback.Sample

class FocusReadbackTest {
    @Test fun emptyFieldAndEndWindowNeedNoInventedFieldBoundary() {
        assertEquals(Result(Kind.LOCAL_CONSISTENT, true), FocusReadback.compare(
            Sample("", 0, 0, 0), Sample("甲", 1, 1, 0), "甲"))
        assertEquals(Result(Kind.LOCAL_CONSISTENT, true), FocusReadback.compare(
            Sample("abc", 3, 3, 100), Sample("X", 1, 1, 103), "X"))
        assertEquals(Result(Kind.LOCAL_CONSISTENT, false), FocusReadback.compare(
            Sample("abc", 3, 3, -1), Sample("X", 1, 1, -1), "X"))
    }

    @Test fun movedWindowsAndReverseSelectionUseUtf16Positions() {
        for ((start, end) in listOf(2 to 4, 4 to 2)) {
            assertEquals(Result(Kind.LOCAL_CONSISTENT, true), FocusReadback.compare(
                Sample("甲乙AB丙丁", start, end, 100), Sample("乙😀丙", 3, 3, 101), "😀"))
        }
        assertEquals(Result(Kind.LOCAL_CONSISTENT, true), FocusReadback.compare(
            Sample("A😀B", 3, 1, 0), Sample("A中B", 2, 2, 0), "中"))
        // The before window covers only a selected substring; after may extend to its left.
        assertEquals(Result(Kind.LOCAL_CONSISTENT, false), FocusReadback.compare(
            Sample("AB", 0, 2, -1), Sample("前甲中乙后", 3, 3, -1), "中"))
    }

    @Test fun insertionMustBeCompleteAndEveryObservedOverlapMustMatch() {
        assertEquals(Kind.UNKNOWN, FocusReadback.compare(
            Sample("ab", 1, 1, 0), Sample("Zb", 1, 1, 3), "XYZ").kind)
        assertEquals(Kind.LOCAL_DIFFERENT, FocusReadback.compare(
            Sample("ab", 1, 1, 0), Sample("qXb", 2, 2, 0), "X").kind)
        assertEquals(Kind.LOCAL_DIFFERENT, FocusReadback.compare(
            Sample("ab", 1, 1, -1), Sample("aXq", 2, 2, -1), "X").kind)
        // Coverage can be insufficient while a different overlapping character is already proved.
        assertEquals(Kind.LOCAL_DIFFERENT, FocusReadback.compare(
            Sample("ab", 1, 1, 0), Sample("Qb", 1, 1, 3), "XYZ").kind)
    }

    @Test fun knownAbsoluteCaretCannotBeRepairedByRelativeAlignment() {
        assertEquals(Result(Kind.LOCAL_DIFFERENT, true), FocusReadback.compare(
            Sample("abc", 3, 3, 100), Sample("X", 1, 1, 104), "X"))
        assertEquals(Result(Kind.LOCAL_CONSISTENT, false), FocusReadback.compare(
            Sample("abc", 3, 3, 100), Sample("X", 1, 1, -1), "X"))
    }

    @Test fun repeatedTextIsOnlyACurrentCaretShapeNotAUniquePositionProof() {
        assertEquals(Result(Kind.LOCAL_CONSISTENT, false), FocusReadback.compare(
            Sample("甲AB乙甲AB乙", 1, 3, -1), Sample("甲中乙", 2, 2, -1), "中"))
        // No-op text is still locally consistent: consistency does not prove any action happened.
        assertEquals(Result(Kind.LOCAL_CONSISTENT, true), FocusReadback.compare(
            Sample("abc", 1, 2, 0), Sample("abc", 2, 2, 0), "b"))
    }

    @Test fun surrogateBoundaryAndMalformedInsertionDoNotBecomeMatches() {
        assertEquals(Kind.UNKNOWN, FocusReadback.compare(
            Sample("A😀B", 2, 2, 0), Sample("A😀XB", 4, 4, 0), "X").kind)
        assertEquals(Kind.UNKNOWN, FocusReadback.compare(
            Sample("", 0, 0, 0), Sample("\uD83D", 1, 1, 0), "\uD83D").kind)
        assertEquals(Kind.UNKNOWN, FocusReadback.compare(
            Sample("\uDE00a", 0, 0, 1), Sample("X\uDE00a", 1, 1, 1), "X").kind)
        // Window edges can contain halves outside the insertion and selection.
        assertEquals(Result(Kind.LOCAL_CONSISTENT, true), FocusReadback.compare(
            Sample("\uDE00ab\uD83D", 2, 2, 1), Sample("\uDE00a中b\uD83D", 3, 3, 1), "中"))
    }

    @Test fun combiningMarksAndZwjAreNotNormalizedOrCountedAsOneGlyph() {
        val family = "👨‍👩‍👧"
        assertEquals(Result(Kind.LOCAL_CONSISTENT, true), FocusReadback.compare(
            Sample("ab", 1, 1, 0), Sample("a${family}b", 1 + family.length, 1 + family.length, 0), family))
        assertEquals(Kind.LOCAL_DIFFERENT, FocusReadback.compare(
            Sample("ab", 1, 1, -1), Sample("aéb", 2, 2, -1), "e\u0301").kind)
    }

    @Test fun invalidOrOversizeSamplesAreUnknownWithoutClamping() {
        val before = Sample("ab", 1, 1, 0)
        for (after in listOf(Sample("aXb", -1, -1, 0), Sample("aXb", 4, 4, 0),
            Sample("aXb", 2, 2, -2), Sample("aXb", 1, 2, 0), Sample("z".repeat(4097), 2, 2, 0))) {
            assertEquals(Kind.UNKNOWN, FocusReadback.compare(before, after, "X").kind)
        }
        assertEquals(Kind.UNKNOWN, FocusReadback.compare(null, Sample("aXb", 2, 2, 0), "X").kind)
        assertEquals(Kind.UNKNOWN, FocusReadback.compare(before, null, "X").kind)
        assertEquals(Kind.UNKNOWN, FocusReadback.compare(before, Sample("aXb", 2, 2, 0), "X".repeat(501)).kind)
    }

    @Test fun offsetAdditionDoesNotWrapAtIntMaxValue() {
        assertEquals(Result(Kind.LOCAL_CONSISTENT, true), FocusReadback.compare(
            Sample("ab", 1, 1, Int.MAX_VALUE), Sample("aXb", 2, 2, Int.MAX_VALUE), "X"))
        assertEquals(Result(Kind.LOCAL_DIFFERENT, true), FocusReadback.compare(
            Sample("ab", 1, 1, Int.MAX_VALUE), Sample("aXb", 2, 2, 0), "X"))
    }
}
