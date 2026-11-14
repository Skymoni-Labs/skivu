package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.*
import org.junit.Test

class FocusInputObservationTest {
    private val editor = FocusInputObservation.Editor("example.editor", 4, 1)

    @Test fun restartRetiresEvenIdenticalEditorAndSelection() {
        val state = FocusInputObservation()
        val token = state.replaceAdapter()
        state.start(token, editor, 2, 2)
        val first = state.snapshot()!!
        state.start(token, editor, 2, 2)
        assertFalse(state.isCurrent(first))
        assertTrue(state.snapshot()!!.editorGeneration > first.editorGeneration)
        assertEquals(FocusInputObservation.Composition.UNKNOWN, state.snapshot()!!.composition)
    }

    @Test fun negativeCachedCandidatesNeverProveAbsence() {
        val state = FocusInputObservation()
        val token = state.replaceAdapter()
        state.start(token, editor, 2, 2)
        val initial = state.snapshot()!!
        state.selection(token, 2, 2, -1, -1)
        assertFalse(state.isCurrent(initial))
        assertEquals(FocusInputObservation.Composition.UNKNOWN, state.snapshot()!!.composition)
        state.selection(token, 3, 3, 1, 3)
        assertEquals(FocusInputObservation.Composition.PRESENT, state.snapshot()!!.composition)
        state.selection(token, 3, 3, -1, -1)
        assertEquals(FocusInputObservation.Composition.UNKNOWN, state.snapshot()!!.composition)
    }

    @Test fun changedOrRepeatedSelectionRetiresPriorSnapshot() {
        val state = FocusInputObservation()
        val token = state.replaceAdapter()
        state.start(token, editor, 2, 4)
        val initial = state.snapshot()!!
        state.selection(token, 4, 2, -1, -1)
        val reverse = state.snapshot()!!
        assertFalse(state.isCurrent(initial))
        assertEquals(4, reverse.selectionStart)
        assertEquals(2, reverse.selectionEnd)
        state.selection(token, 4, 2, -1, -1)
        assertFalse(state.isCurrent(reverse))
    }

    @Test fun finishClearsFactsAndLateSelectionCannotRecreateThem() {
        val state = FocusInputObservation()
        val token = state.replaceAdapter()
        state.start(token, editor, 2, 2)
        val first = state.snapshot()!!
        state.finish(token)
        assertNull(state.snapshot())
        assertFalse(state.isCurrent(first))
        state.selection(token, 1, 1, -1, -1)
        assertNull(state.snapshot())
    }

    @Test fun replacedAndRetiredAdaptersCannotPublishOrClearNewEditor() {
        val state = FocusInputObservation()
        val old = state.replaceAdapter()
        state.start(old, editor, 1, 1)
        val token = state.replaceAdapter()
        state.start(token, editor, 2, 2)
        val current = state.snapshot()!!
        state.start(old, editor, 3, 3)
        state.selection(old, 4, 4, 1, 4)
        state.finish(old)
        assertTrue(state.isCurrent(current))
        state.retire()
        state.start(token, editor, 5, 5)
        state.selection(token, 5, 5, -1, -1)
        assertNull(state.snapshot())
    }
    @Test fun postAttemptIdentityAllowsSelectionButNeverAnEditorRestart() {
        val state = FocusInputObservation()
        val token = state.replaceAdapter()
        state.start(token, editor, 2, 2)
        val before = state.snapshot()!!
        state.selection(token, 5, 5, -1, -1)
        assertFalse(state.isCurrent(before))
        assertTrue(state.isEditorCurrent(token, before))
        state.start(token, editor, 5, 5)
        assertFalse(state.isEditorCurrent(token, before))
    }

    @Test fun finishRetireAndAdapterReplacementRejectPostAttemptIdentity() {
        for (boundary in 0..2) {
            val state = FocusInputObservation()
            val token = state.replaceAdapter()
            state.start(token, editor, 2, 2)
            val before = state.snapshot()!!
            when (boundary) {
                0 -> state.finish(token)
                1 -> state.retire()
                else -> state.replaceAdapter()
            }
            assertFalse(state.isEditorCurrent(token, before))
        }
    }
    @Test fun reconnectWaitsForStartAndNeverRevivesCapturedToken() {
        val state = FocusInputObservation()
        val old = state.replaceAdapter()
        state.start(old, editor, 2, 2)
        val captured = state.snapshot()!!
        state.retire()
        val replacement = state.replaceAdapter()
        assertNull(state.snapshot())
        state.selection(replacement, 2, 2, -1, -1)
        assertNull(state.snapshot())
        state.start(replacement, editor, 2, 2)
        assertFalse(state.isCurrent(captured))
        assertFalse(state.isEditorCurrent(old, captured))
        state.finish(old)
        assertNotNull(state.snapshot())
    }

}
