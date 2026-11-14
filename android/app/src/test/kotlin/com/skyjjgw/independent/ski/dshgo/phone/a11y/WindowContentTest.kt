package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.*
import org.junit.Test

class WindowContentTest {
    private val frame = Box(0, 0, 400, 800)

    @Test fun emptyShellsAreUnreadableAtAnyWindowSizeOrDepth() {
        for (bounds in listOf(frame, Box(0, 0, 400, 350), Box(40, 100, 360, 500))) {
            val leaf = UiNode(className = "android.view.View", bounds = bounds)
            val shell = UiNode(className = "android.widget.FrameLayout", bounds = bounds, children = listOf(
                UiNode(className = "android.widget.LinearLayout", bounds = bounds, children = listOf(leaf)),
            ))
            assertFalse(WindowContent.usable(leaf))
            assertFalse(WindowContent.usable(shell))
        }
        assertFalse(WindowContent.usable(null))
        assertFalse(WindowContent.usable(UiNode(className = "android.widget.TextView", bounds = frame)))
    }

    @Test fun usefulDescendantsAreNotEmptyShells() {
        val leaves = listOf(
            UiNode(text = "Ready", bounds = frame),
            UiNode(hint = "Search", bounds = frame),
            UiNode(clickable = true, bounds = frame),
            UiNode(editable = true, bounds = frame),
            UiNode(scrollable = true, bounds = frame),
        )
        for (leaf in leaves) {
            assertTrue(WindowContent.usable(UiNode(className = "android.widget.FrameLayout", bounds = frame, children = listOf(leaf))))
        }
    }

    @Test fun textPoorCanvasStillSupportsTheImageWorkflow() {
        for (cls in listOf("android.view.SurfaceView", "android.view.TextureView", "example.app.ChartCanvas")) {
            val root = UiNode(className = "android.widget.FrameLayout", bounds = frame, children = listOf(UiNode(className = cls, bounds = frame)))
            assertTrue(cls, WindowContent.usable(root))
            val windows = listOf(UiWindow(1, WindowKind.APP, "example.app", null, frame, root))
            val screen = ScreenFormat.format(ScreenInput("s1", "Example", "example.app", 400, 800, false, windows))
            assertTrue(screen.elements.isEmpty())
            assertTrue(screen.text.contains(ScreenFormat.POOR_TREE_NOTE))
            assertFalse(WindowContent.unavailable(false, false, windows))
        }
    }

    @Test fun hiddenAndUnreadableBothBlockBlindActions() {
        val windows = listOf(UiWindow(1, WindowKind.APP, "example.app", null, frame, UiNode(bounds = frame)))
        assertTrue(WindowContent.unavailable(true, false, windows))
        assertTrue(WindowContent.unavailable(false, true, windows))
        assertTrue(WindowContent.unavailable(false, false, emptyList()))
        assertFalse(WindowContent.unavailable(false, false, windows))
    }

    @Test fun readableDialogSurvivesAMissingLowerRootButCoordinatesAreNotReusable() {
        val dialogBounds = Box(40, 200, 360, 500)
        val dialog = UiWindow(2, WindowKind.APP, "example.app", "Dialog", dialogBounds,
            UiNode(bounds = dialogBounds, children = listOf(UiNode(text = "Continue", clickable = true, bounds = Box(80, 350, 320, 420)))))
        val readablePrefix = listOf(dialog)
        val gap = WindowContent.rootGap(readablePrefix)
        assertEquals(WindowContent.RootGap.PARTIAL, gap)
        val unavailable = WindowContent.unavailable(gap == WindowContent.RootGap.FRONT, false, readablePrefix)
        assertFalse(unavailable)
        val screen = ScreenFormat.format(ScreenInput("s1", "Example", "example.app", 400, 800, false, readablePrefix))
        assertTrue(screen.text.contains("Continue"))
        assertEquals(ScreenFormat.index(readablePrefix).single().fingerprint, screen.element(1)!!.fingerprint)
        val keys = ScreenFormat.observationKeys(readablePrefix)
        val complete = ScreenObservation("example.app", readablePrefix, frame, false, false, false, keys)
        val partial = ScreenObservation("example.app", readablePrefix, frame, false, unavailable, gap == WindowContent.RootGap.PARTIAL, keys)
        assertFalse(partial.reusableCoordinates(complete))
        assertFalse(partial.comparableTo(complete))
        assertEquals(ScreenVerdict.UNVERIFIABLE, ScreenVerdict.note(partial.comparableTo(complete), partial.changedFrom(complete), null, true))
        assertEquals(WindowContent.RootGap.FRONT, WindowContent.rootGap(emptyList()))
        assertTrue(WindowContent.unavailable(true, false, emptyList()))
    }

    @Test fun keyboardUsesTheEntireEnumerationNotTheContentWindowPrefix() {
        val app = 1
        val ime = 2
        assertEquals(true, WindowContent.keyboardShown(listOf(app, app, app, app, ime), ime))
        assertEquals(true, WindowContent.keyboardShown(listOf(ime, app), ime))
        assertEquals(false, WindowContent.keyboardShown(listOf(app), ime))
        assertNull(WindowContent.keyboardShown(null, ime))
        assertNull(WindowContent.keyboardShown(emptyList(), ime))
    }

    @Test fun screenshotTimestampUsesUptimeMillisecondsNotNanosecondsOrElapsedRealtime() {
        val wall = 1_800_000_000_000L
        val uptime = 123_456_789L
        assertEquals(wall - 250L, ScreenshotClock.wallTime(uptime - 250L, uptime, wall))
        assertEquals(wall, ScreenshotClock.wallTime(uptime, uptime, wall))
    }
}
