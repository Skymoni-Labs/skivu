package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.phone.*
import org.junit.Assert.*
import org.junit.Test

class ScreenFormatTest {
    private fun format(vararg nodes: UiNode): FormattedScreen {
        val bounds = Box(0, 0, 400, 800)
        return ScreenFormat.format(ScreenInput("s1", "Example", "example.app", 400, 800, false,
            listOf(UiWindow(1, WindowKind.APP, "example.app", null, bounds, UiNode(bounds = bounds, children = nodes.toList())))))
    }

    private fun buttonWindows(viewId: String?): List<UiWindow> {
        val frame = Box(0, 0, 400, 800)
        val button = UiNode(className = "android.widget.Button", text = "继续", clickable = true,
            viewId = viewId, bounds = Box(0, 100, 300, 150))
        return listOf(UiWindow(1, WindowKind.APP, "example.app", null, frame,
            UiNode(bounds = frame, children = listOf(button))))
    }

    private fun buttonElement(viewId: String?): ScreenElement = ScreenFormat.format(
        ScreenInput("s1", "Example", "example.app", 400, 800, false, buttonWindows(viewId)),
    ).elements.single()

    @Test fun aChangedButtonViewIdCannotResolveAnOldScreenElement() {
        val old = buttonElement("example.app:id/next_button")
        val fresh = ScreenFormat.index(buttonWindows("example.app:id/pay_button"))
        assertNull(fresh.firstOrNull { it.fingerprint == old.fingerprint })
        assertEquals(old.fingerprint,
            ScreenFormat.index(buttonWindows("example.app:id/next_button")).single().fingerprint)
    }

    @Test fun acquiringOrLosingAButtonViewIdAlsoInvalidatesItsIdentity() {
        for ((before, after) in listOf(null to "example.app:id/pay_button", "example.app:id/pay_button" to null)) {
            val old = buttonElement(before)
            assertNull(ScreenFormat.index(buttonWindows(after)).firstOrNull { it.fingerprint == old.fingerprint })
        }
        assertEquals(buttonElement(null).fingerprint, ScreenFormat.index(buttonWindows(null)).single().fingerprint)
    }

    @Test fun sameButtonLabelCanRequireANewConfirmationBecauseOfItsViewId() {
        val tasks = PhoneTasks().apply { begin(); approve("example.app") }
        val gate = SafetyGate({ PhonePolicies() }, tasks, { null })
        fun verdict(viewId: String?): SafetyGate.Verdict {
            val el = buttonElement(viewId)
            val target = TargetInfo("s1", el.id, el.role, el.label, "example.app", "Example",
                el.password, el.secret, el.editable, el.viewId)
            return gate.checkWrite(WriteKind.TAP, target, "example.app", "Example")
        }
        assertTrue(verdict("example.app:id/next_button") is SafetyGate.Verdict.Allow)
        val changed = verdict("example.app:id/pay_button") as SafetyGate.Verdict.Confirm
        assertEquals("sensitive:pay", changed.reason)
    }

    @Test fun passwordContentsNeverAppearAndCodesAreSecret() {
        val screen = format(
            UiNode(className = "android.widget.EditText", text = "never-visible-password", hint = "密码",
                bounds = Box(0, 100, 300, 150), editable = true, password = true),
            UiNode(className = "android.widget.EditText", text = "123456", hint = "验证码",
                bounds = Box(0, 200, 300, 250), editable = true),
        )
        assertFalse(screen.text.contains("never-visible-password"))
        assertFalse(screen.text.contains("123456"))
        assertTrue(screen.elements.any { it.password })
        assertTrue(screen.elements.any { it.secret && !it.password })
    }

    @Test fun warningMarkerAndWriteGateUseTheSameSensitiveSource() {
        val screen = format(UiNode(className = "android.widget.Button", text = "发送",
            bounds = Box(0, 100, 300, 150), clickable = true))
        val element = screen.elements.single()
        assertTrue(screen.text.contains("⚠"))
        val tasks = PhoneTasks().apply { begin(); approve("example.app") }
        val gate = SafetyGate({ PhonePolicies() }, tasks, { null })
        val target = TargetInfo("s1", element.id, element.role, element.label, "example.app", "Example",
            element.password, element.secret, element.editable, element.viewId)
        val verdict = gate.checkWrite(WriteKind.TAP, target, "example.app", "Example") as SafetyGate.Verdict.Confirm
        assertEquals("sensitive:${element.sensitiveWord}", verdict.reason)
    }

    @Test fun anUnreadableWindowIsNotCalledAPoorTree() {
        val frame = Box(0, 0, 400, 800)
        val windows = listOf(UiWindow(1, WindowKind.APP, "com.github.android", "GitHub", frame, UiNode(bounds = frame)))
        val unreadable = ScreenFormat.format(
            ScreenInput("s1", "GitHub", "com.github.android", 400, 800, false, windows,
                notes = listOf("提示：这一屏读不到"), unreadable = true),
        )
        assertFalse(unreadable.text.contains(ScreenFormat.POOR_TREE_NOTE))
        assertTrue(unreadable.text.contains("这一屏读不到"))

        // 同样的空树,没有"被过滤"的证据时,照旧说文字信息不足。
        val poor = ScreenFormat.format(ScreenInput("s2", "GitHub", "com.github.android", 400, 800, false, windows))
        assertTrue(poor.text.contains(ScreenFormat.POOR_TREE_NOTE))
    }

    @Test fun screenshotMasksIncludeFieldsOutsideTheTextBudget() {
        val frame = Box(0, 0, 400, 800)
        val passwordBox = Box(0, 500, 300, 550)
        val codeBox = Box(0, 600, 300, 650)
        val root = UiNode(bounds = frame, children = listOf(
            UiNode(bounds = passwordBox, password = true, editable = true),
            UiNode(bounds = codeBox, text = "验证码", showingHint = true, editable = true),
            UiNode(bounds = Box(0, 100, 300, 150), text = "ordinary", editable = true),
        ))
        val windows = listOf(UiWindow(1, WindowKind.APP, "example.app", null, frame, root))
        assertEquals(listOf(passwordBox, codeBox), secretFieldBounds(windows))
    }

    @Test fun splitWindowSourcesAreFilteredTogetherAndSurviveSnapshotCopies() {
        val display = Box(0, 0, 400, 800)
        val upper = Box(0, 0, 400, 400)
        val lower = Box(0, 400, 400, 800)
        val windows = listOf(
            UiWindow(7, WindowKind.APP, "allowed.app", "A", upper,
                UiNode(ref = 1, bounds = upper, children = listOf(
                    UiNode(ref = 2, text = "A_PUBLIC_MARKER", bounds = Box(10, 10, 300, 50))))),
            UiWindow(8, WindowKind.APP, "denied.app", "B", lower,
                UiNode(ref = 3, className = "android.widget.ListView", scrollable = true,
                    scroll = Scroll.FORWARD, bounds = lower, children = listOf(
                        UiNode(ref = 4, text = "B_PUBLIC_MARKER", bounds = Box(10, 410, 300, 450)))))
        )
        val formatted = ScreenFormat.format(ScreenInput("s1", "A", "allowed.app",
            display.width, display.height, false, windows))
        assertTrue(formatted.text.contains("A_PUBLIC_MARKER"))
        assertTrue(formatted.text.contains("B_PUBLIC_MARKER"))
        assertTrue(formatted.elements.any { it.packageName == "denied.app" })
        val list = ScreenFormat.index(windows).single { it.kind == ElementKind.LIST }
        assertEquals(8, list.windowId)
        assertTrue(list.itemTexts.any { it.contains("B_PUBLIC_MARKER") })
        val sources = windows.mapNotNull { it.packageName }.toSet()
        val snapshot = ScreenSnapshot("s1", formatted.text, "A", "allowed.app",
            readPackages = sources)
        val copied = snapshot.copy(image = byteArrayOf(1), imageMime = "image/png")
        assertEquals(sources, copied.readPackages)
        var policy = PhonePolicies()
        val gate = SafetyGate({ policy }, PhoneTasks(), { null })
        assertSame(copied, gate.filterScreen(copied))
        assertEquals("s1", gate.filterScreen(copied).id)
        policy = PhonePolicies(denyPackages = listOf("denied.app"))
        assertNull(gate.checkRead("allowed.app", "A"))
        assertEquals("deny-list", gate.checkRead("denied.app", "B")?.rule)
        val refused = gate.filterScreen(copied)
        assertFalse(refused.text.contains("A_PUBLIC_MARKER"))
        assertFalse(refused.text.contains("B_PUBLIC_MARKER"))
        assertNull(refused.image)
        assertEquals(sources, refused.readPackages)
        var policyReads = 0
        val changingGate = SafetyGate({
            policyReads++
            PhonePolicies(denyPackages = listOf(if (policyReads <= 2) "denied.app" else "allowed.app"))
        }, PhoneTasks(), { null })
        val changingResult = changingGate.filterScreen(copied)
        assertFalse(changingResult.text.contains("A_PUBLIC_MARKER"))
        assertFalse(changingResult.text.contains("B_PUBLIC_MARKER"))
        assertNull(changingResult.image)
        assertEquals(1, policyReads)
    }
}
