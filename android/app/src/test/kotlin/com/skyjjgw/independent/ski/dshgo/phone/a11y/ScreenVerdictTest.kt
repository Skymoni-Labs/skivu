package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenVerdictTest {
    @Test fun failedOrUnconfirmedActionCannotAcquireACompletedOrEndOfListClaim() {
        for (comparable in listOf(false, true)) for (changed in listOf(false, true)) {
            val note = unconfirmedActionNote(comparable, changed, null)
            assertFalse(note.contains("动作已提交"))
            assertFalse(note.contains("到头"))
            if (!comparable || !changed) {
                assertTrue(note.contains("未确认"))
                assertTrue(note.contains("不要自动重试"))
            }
        }
        assertEquals(ScreenVerdict.KEYBOARD_HIDDEN,
            unconfirmedActionNote(false, false, ScreenVerdict.KEYBOARD_HIDDEN))
        assertEquals("", unconfirmedActionNote(true, true, null))
    }

    @Test fun aChangedTreeNeedsNoExplanation() {
        assertEquals("", ScreenVerdict.note(comparable = true, changed = true, keyboard = null, scrolled = false))
        assertEquals("", ScreenVerdict.note(comparable = true, changed = true, keyboard = null, scrolled = true))
    }

    @Test fun theKeyboardIsPartOfTheScreen() {
        assertEquals(
            ScreenVerdict.KEYBOARD_HIDDEN,
            ScreenVerdict.note(comparable = true, changed = false, keyboard = ScreenVerdict.KEYBOARD_HIDDEN, scrolled = false),
        )
        assertEquals(
            ScreenVerdict.KEYBOARD_SHOWN,
            ScreenVerdict.note(comparable = true, changed = true, keyboard = ScreenVerdict.KEYBOARD_SHOWN, scrolled = false),
        )
    }

    @Test fun nothingToCompareIsNotTheSameAsNoChange() {
        for (scrolled in listOf(false, true)) {
            for (changed in listOf(false, true)) {
                val note = ScreenVerdict.note(comparable = false, changed = changed, keyboard = null, scrolled = scrolled)
                assertEquals(ScreenVerdict.UNVERIFIABLE, note)
                assertFalse(note, note.contains("没有明显变化"))
                assertFalse(note, note.contains("到头"))
            }
        }
    }

    @Test fun scrollEndOnlyWithTwoReadableScreens() {
        assertEquals(
            ScreenVerdict.SCROLL_END,
            ScreenVerdict.note(comparable = true, changed = false, keyboard = null, scrolled = true),
        )
        assertEquals(
            ScreenVerdict.UNCHANGED,
            ScreenVerdict.note(comparable = true, changed = false, keyboard = null, scrolled = false),
        )
    }
}
