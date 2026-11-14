package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.view.accessibility.AccessibilityEvent
import org.junit.Assert.*
import org.junit.Test

class PhoneWindowEventsTest {
    @Test fun windowsChangedWithoutAnOwnedOverlayInvalidatesTheImage() {
        assertTrue(PhoneA11yService.invalidatesVisual(AccessibilityEvent.TYPE_WINDOWS_CHANGED) { false })
    }

    @Test fun bothWindowEventsRetireUnknownAndOtherWindows() {
        for (type in listOf(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, AccessibilityEvent.TYPE_WINDOWS_CHANGED)) {
            assertTrue(PhoneA11yService.invalidatesVisual(type) { false })
            assertFalse(PhoneA11yService.invalidatesVisual(type) { true })
        }
    }

    @Test fun nonWindowEventsDoNotReadOverlayNodes() {
        for (type in listOf(AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED, AccessibilityEvent.TYPE_VIEW_FOCUSED)) {
            assertFalse(PhoneA11yService.invalidatesVisual(type) { error("unexpected overlay lookup") })
        }
    }
}
