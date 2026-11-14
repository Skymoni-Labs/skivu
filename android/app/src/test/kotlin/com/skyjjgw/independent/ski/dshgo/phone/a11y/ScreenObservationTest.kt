package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.*
import org.junit.Test

class ScreenObservationTest {
    private val frame = Box(0, 0, 400, 800)

    private fun observation(
        pkg: String = "example.app", window: Int = 1, bounds: Box = frame, keyboard: Boolean? = false,
        unavailable: Boolean = false, incomplete: Boolean = false, elements: List<String> = listOf("one"),
    ) = ScreenObservation(
        pkg, listOf(UiWindow(window, WindowKind.APP, pkg, null, bounds, null)), frame,
        keyboard, unavailable, incomplete, elements,
    )

    @Test fun emptyToEmptyCannotVerifyAnActionOrScrollEnd() {
        val before = observation(elements = emptyList())
        val after = observation(elements = emptyList())
        assertFalse(after.comparableTo(before))
        for (scrolled in listOf(false, true)) {
            assertEquals(ScreenVerdict.UNVERIFIABLE, ScreenVerdict.note(after.comparableTo(before), after.changedFrom(before), null, scrolled))
        }
    }

    @Test fun readableToEmptyIsAChangeButNotVerification() {
        val before = observation()
        val after = observation(unavailable = true, elements = emptyList())
        assertTrue(after.changedFrom(before))
        assertFalse(after.comparableTo(before))
        assertEquals(ScreenVerdict.UNVERIFIABLE, ScreenVerdict.note(after.comparableTo(before), after.changedFrom(before), null, true))
    }

    @Test fun differentAppsAndWindowsInvalidateCoordinatesEvenWithIdenticalElements() {
        val before = observation()
        for (after in listOf(observation(pkg = "another.app"), observation(window = 2), observation(bounds = Box(0, 0, 400, 450)))) {
            assertTrue(after.changedFrom(before))
            assertFalse(after.sameContext(before))
            assertFalse(after.reusableCoordinates(before))
        }
        val empty = observation(elements = emptyList())
        val another = observation(pkg = "another.app", elements = emptyList())
        assertTrue(another.changedFrom(empty))
        assertEquals(ScreenVerdict.UNVERIFIABLE, ScreenVerdict.note(another.comparableTo(empty), another.changedFrom(empty), null, false))
    }

    @Test fun keyboardClosureIsObservedWithoutPretendingTheContentChanged() {
        val before = observation(keyboard = true)
        val after = observation(keyboard = false)
        assertTrue(after.changedFrom(before))
        assertEquals(ScreenVerdict.KEYBOARD_HIDDEN, after.keyboardChange(before))
        assertEquals(ScreenVerdict.KEYBOARD_SHOWN, before.keyboardChange(after))
        assertFalse(after.reusableCoordinates(before))
    }

    @Test fun unknownKeyboardStateIsNeverReportedAsHiddenOrShown() {
        val unknown = observation(keyboard = null)
        assertNull(unknown.keyboardChange(observation(keyboard = true)))
        assertNull(unknown.keyboardChange(observation(keyboard = false)))
        assertNull(observation(keyboard = true).keyboardChange(unknown))
        assertNull(observation(keyboard = false).keyboardChange(unknown))
        assertFalse(unknown.reusableCoordinates(unknown))
        assertNull(observation(pkg = "another.app", keyboard = false).keyboardChange(observation(keyboard = true)))
    }

    @Test fun missingContentWarningSurvivesAKnownKeyboardTransition() {
        val before = observation(keyboard = true)
        val after = observation(keyboard = false, unavailable = true, elements = emptyList())
        val note = ScreenVerdict.note(after.comparableTo(before), after.changedFrom(before), after.keyboardChange(before), false)
        assertTrue(note.contains(ScreenVerdict.KEYBOARD_HIDDEN))
        assertTrue(note.contains(ScreenVerdict.UNVERIFIABLE))
    }

    @Test fun usableCanvasMayReuseCoordinatesWithoutNumberedElements() {
        val before = observation(elements = emptyList())
        assertTrue(observation(elements = emptyList()).reusableCoordinates(before))
        assertFalse(observation(unavailable = true, elements = emptyList()).reusableCoordinates(before))
        val incomplete = observation(incomplete = true, elements = emptyList())
        assertFalse(incomplete.reusableCoordinates(before))
        val readable = observation()
        val partial = observation(incomplete = true)
        assertFalse(partial.comparableTo(readable))
        assertFalse(readable.comparableTo(partial))
        assertFalse(partial.reusableCoordinates(readable))
        assertEquals(ScreenVerdict.UNVERIFIABLE, ScreenVerdict.note(partial.comparableTo(readable), partial.changedFrom(readable), null, true))
    }

    @Test fun contentAndStateChangesInvalidateCoordinateReuse() {
        val before = observation(elements = listOf("target|old input"))
        val after = observation(elements = listOf("target|new input"))
        assertTrue(after.changedFrom(before))
        assertFalse(after.reusableCoordinates(before))
        assertTrue(after.comparableTo(before))
    }

    @Test fun unchangedSecretFieldsNeverAuthorizeCoordinatesFromTheirMaskedImage() {
        val inputBox = Box(20, 100, 380, 180)
        val fields = listOf(
            UiNode(bounds = inputBox, password = true),
            UiNode(bounds = inputBox, editable = true, hint = "验证码"),
            UiNode(bounds = inputBox, editable = true, desc = "支付密码"),
            UiNode(bounds = inputBox, editable = true, viewId = "example.app:id/otp_input"),
            UiNode(bounds = inputBox, editable = true, text = "verification code", showingHint = true),
        )
        for (field in fields) {
            val root = UiNode(bounds = frame, children = listOf(
                UiNode(bounds = frame, children = listOf(field)),
                UiNode(bounds = Box(20, 300, 380, 360), text = "Ordinary button", clickable = true),
            ))
            val windows = listOf(UiWindow(1, WindowKind.APP, "example.app", null, frame, root))
            fun capture() = ScreenObservation("example.app", windows, frame, false, false, false,
                ScreenFormat.observationKeys(windows))
            val before = capture(); val current = capture()
            assertEquals(listOf(inputBox), secretFieldBounds(windows))
            assertTrue(current.sameContext(before))
            assertFalse(current.changedFrom(before))
            assertFalse(current.reusableCoordinates(before))
            assertFalse(before.reusableCoordinates(current))
        }
    }

    @Test fun ordinaryInputValuesAreNotSecretLabelsForCoordinateSafety() {
        val field = UiNode(bounds = Box(20, 100, 380, 180), editable = true,
            hint = "Search", text = "password verification code otp", showingHint = false)
        val windows = listOf(UiWindow(1, WindowKind.APP, "example.app", null, frame,
            UiNode(bounds = frame, children = listOf(field))))
        val before = ScreenObservation("example.app", windows, frame, false, false, false,
            ScreenFormat.observationKeys(windows))
        val current = ScreenObservation("example.app", windows, frame, false, false, false,
            ScreenFormat.observationKeys(windows))
        assertTrue(secretFieldBounds(windows).isEmpty())
        assertTrue(current.reusableCoordinates(before))
    }
}
