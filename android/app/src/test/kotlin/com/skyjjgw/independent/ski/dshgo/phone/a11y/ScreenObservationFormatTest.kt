package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.*
import org.junit.Test

class ScreenObservationFormatTest {
    private val frame = Box(0, 0, 400, 800)

    private fun windows(text: String, focused: Boolean = false, password: Boolean = false, hint: String = "Search"): List<UiWindow> {
        val input = UiNode(className = "android.widget.EditText", hint = hint, text = text, focused = focused,
            editable = true, password = password, bounds = Box(0, 100, 400, 150))
        val buttons = (1..3).map { i -> UiNode(className = "android.widget.Button", text = "Button $i", clickable = true,
            bounds = Box(0, 200 + i * 60, 400, 250 + i * 60)) }
        return listOf(UiWindow(1, WindowKind.APP, "example.app", null, frame, UiNode(bounds = frame, children = listOf(input) + buttons)))
    }

    private fun format(windows: List<UiWindow>, id: String, keyboard: Boolean? = false) =
        ScreenFormat.format(ScreenInput(id, "Example", "example.app", 400, 800, keyboard, windows))

    @Test fun inputTextChangesTheObservationButNotTheTargetIdentity() {
        val beforeWindows = windows("old value")
        val afterWindows = windows("new value")
        val before = format(beforeWindows, "s1")
        val after = format(afterWindows, "s2")
        assertEquals(before.elements.first().fingerprint, after.elements.first().fingerprint)
        assertNotEquals(before.elements.first().observationKey, after.elements.first().observationKey)
        assertNotEquals(ScreenFormat.observationKeys(beforeWindows), ScreenFormat.observationKeys(afterWindows))
        val text = ScreenDigest.text("s1", before, "s2", after)
        assertTrue(text, text.contains("new value"))
        assertFalse(text, text.contains("（与 s1 相同，编号不变）"))
        assertFalse(text, text.contains("Button 1"))
    }

    @Test fun focusAndInputTextPastTheDisplayCapAreStillObservationChanges() {
        val text = "a".repeat(80)
        val before = format(windows(text), "s1")
        val after = format(windows(text + "b", focused = true), "s2")
        assertEquals(before.elements.first().fingerprint, after.elements.first().fingerprint)
        assertNotEquals(before.elements.first().observationKey, after.elements.first().observationKey)
        assertTrue(ScreenDigest.text("s1", before, "s2", after).contains("已聚焦"))
        val contentOnly = format(windows(text + "b"), "s2")
        assertNotEquals(before.elements.first().observationKey, contentOnly.elements.first().observationKey)
    }

    @Test fun passwordsAndCodesNeverEnterObservationSignatures() {
        for ((password, hint) in listOf(true to "Password", false to "验证码")) {
            val beforeWindows = windows("never-expose-secret-A", password = password, hint = hint)
            val afterWindows = windows("never-expose-secret-B", password = password, hint = hint)
            val before = format(beforeWindows, "s1")
            val after = format(afterWindows, "s2")
            assertEquals(before.elements.first().observationKey, after.elements.first().observationKey)
            assertEquals(ScreenFormat.observationKeys(beforeWindows), ScreenFormat.observationKeys(afterWindows))
            assertFalse(after.text.contains("never-expose-secret"))
            assertFalse(after.elements.any { it.observationKey.contains("never-expose-secret") })
        }
    }

    @Test fun observationSignaturesKeepExistingNumberMasking() {
        val screen = format(windows("4111111111111111"), "s1")
        assertFalse(screen.elements.first().observationKey.contains("4111111111111111"))
        assertTrue(screen.elements.first().observationKey.contains("«银行卡 ****1111»"))
    }

    @Test fun unknownKeyboardIsNotRenderedAsHidden() {
        val unknown = format(windows("value"), "s1", keyboard = null).text
        assertTrue(unknown.contains("键盘状态未知"))
        assertFalse(unknown.contains("键盘收起"))
        assertTrue(format(windows("value"), "s1", keyboard = true).text.contains("键盘弹出"))
    }

    @Test fun listScrollStateChangesAppearInTheDigest() {
        fun screen(scroll: Int, id: String): FormattedScreen {
            val children = (1..4).map { UiNode(text = "Item $it", bounds = Box(0, 200 + it * 60, 400, 250 + it * 60)) }
            val list = UiNode(className = "android.widget.ScrollView", bounds = frame, scrollable = true, scroll = scroll, children = children)
            return format(listOf(UiWindow(1, WindowKind.APP, "example.app", null, frame, list)), id)
        }
        val before = screen(Scroll.FORWARD, "s1")
        val after = screen(Scroll.BACKWARD, "s2")
        assertEquals(before.elements.first().fingerprint, after.elements.first().fingerprint)
        val text = ScreenDigest.text("s1", before, "s2", after)
        assertTrue(text, text.contains("列表 [1] 可上滑"))
        assertFalse(text, text.contains("Item 1"))
    }

    @Test fun budgetHiddenObservationChangeCannotClaimTheScreenIsIdentical() {
        fun capture(lastLabel: String): List<UiWindow> {
            val nodes = (1..12).map { i -> UiNode(text = if (i == 12) lastLabel else "Stable row $i with visible content",
                bounds = Box(0, 100 + i * 40, 400, 130 + i * 40)) }
            return listOf(UiWindow(1, WindowKind.APP, "example.app", null, frame, UiNode(bounds = frame, children = nodes)))
        }
        fun budgeted(windows: List<UiWindow>, id: String) =
            ScreenFormat.format(ScreenInput(id, "Example", "example.app", 400, 800, false, windows, charBudget = 250))
        val beforeWindows = capture("Hidden row before")
        val afterWindows = capture("Hidden row after")
        val before = budgeted(beforeWindows, "s1")
        val after = budgeted(afterWindows, "s2")
        assertTrue(before.hidden > 0)
        assertTrue(after.hidden > 0)
        assertTrue(before.elements.isNotEmpty())
        assertEquals(before.elements.map { it.observationKey }, after.elements.map { it.observationKey })
        assertFalse(after.text.contains("Hidden row after"))
        val beforeObservation = ScreenObservation("example.app", beforeWindows, frame, false, false, false, ScreenFormat.observationKeys(beforeWindows))
        val afterObservation = ScreenObservation("example.app", afterWindows, frame, false, false, false, ScreenFormat.observationKeys(afterWindows))
        assertTrue(afterObservation.changedFrom(beforeObservation))
        val text = ScreenDigest.text("s1", before, "s2", after, observationChanged = afterObservation.changedFrom(beforeObservation))
        assertEquals(after.text, text)
        assertTrue(text, text.contains("另有"))
        assertFalse(text, text.contains("（与 s1 相同，编号不变）"))
    }

    @Test fun mergedRowsKeepTheChangedSecondElement() {
        fun screen(changed: String, id: String): FormattedScreen {
            val nodes = listOf(
                UiNode(className = "android.widget.Button", text = "Left", clickable = true, bounds = Box(0, 100, 100, 150)),
                UiNode(className = "android.widget.Button", text = changed, clickable = true, bounds = Box(200, 100, 300, 150)),
                UiNode(text = "Stable 1", bounds = Box(0, 300, 400, 350)),
                UiNode(text = "Stable 2", bounds = Box(0, 400, 400, 450)),
            )
            return format(listOf(UiWindow(1, WindowKind.APP, "example.app", null, frame, UiNode(bounds = frame, children = nodes))), id)
        }
        val before = screen("Old", "s1")
        val after = screen("发送", "s2")
        val text = ScreenDigest.text("s1", before, "s2", after)
        assertTrue(text, text.contains("发送"))
        assertTrue(text, text.contains("⚠[2]"))
        assertFalse(text, text.contains("Stable 1"))
    }
}
