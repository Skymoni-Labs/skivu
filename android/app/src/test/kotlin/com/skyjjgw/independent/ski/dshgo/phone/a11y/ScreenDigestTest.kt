package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenDigestTest {
    private fun screen(vararg labels: String, id: String = "s7", pkg: String = "example.app", windowId: Int = 1): FormattedScreen {
        val frame = Box(0, 0, 400, 800)
        val nodes = labels.mapIndexed { i, text ->
            UiNode(className = "android.widget.Button", text = text, bounds = Box(0, 100 + i * 60, 400, 150 + i * 60), clickable = true)
        }
        val window = UiWindow(windowId, WindowKind.APP, pkg, "示例", frame, UiNode(bounds = frame, children = nodes))
        return ScreenFormat.format(ScreenInput(id, "示例", pkg, 400, 800, false, listOf(window)))
    }

    private fun digest(previousId: String?, previous: FormattedScreen?, currentId: String, current: FormattedScreen) =
        ScreenDigest.text(previousId, previous, currentId, current)

    @Test fun noPreviousScreenSendsEverything() {
        val now = screen("甲", "乙")
        assertEquals(now.text, digest(null, null, "s8", now))
    }

    @Test fun anIdenticalScreenCollapsesToOneLine() {
        val before = screen("甲", "乙")
        val after = screen("甲", "乙", id = "s8")
        val text = digest("s7", before, "s8", after)
        assertTrue(text, text.contains("（与 s7 相同，编号不变）"))
        assertFalse(text, text.contains("[1]"))
        assertTrue(text, text.contains("屏幕 s8"))
    }

    @Test fun onlyChangedLinesComeBackWhenTheIdsStillLineUp() {
        val before = screen("甲", "乙", "丙", "丁")
        val after = screen("甲", "乙2", "丙", "丁", id = "s8")
        val text = ScreenDigest.text("s7", before, "s8", after, observationChanged = true)
        assertTrue(text, text.contains("乙2"))
        assertFalse(text, text.contains("甲"))
        assertTrue(text, text.contains("（只列变化：其余 3 项与 s7 相同，编号不变）"))
    }

    @Test fun aDifferentElementCountSendsTheWholeScreen() {
        val before = screen("甲", "乙")
        val after = screen("甲", "乙", "丙", id = "s8")
        assertEquals(after.text, digest("s7", before, "s8", after))
    }

    @Test fun whenMostLinesChangedTheWholeScreenIsCheaperToRead() {
        val before = screen("甲", "乙", "丙")
        val after = screen("甲2", "乙2", "丙2", id = "s8")
        assertEquals(after.text, digest("s7", before, "s8", after))
    }

    @Test fun emptyScreensNeverClaimToMatch() {
        val after = screen(id = "s8")
        for (before in listOf(screen(), screen("甲"))) {
            val text = digest("s7", before, "s8", after)
            assertEquals(after.text, text)
            assertTrue(text.contains("没有可读的元素"))
            assertFalse(text.contains("相同，编号不变"))
        }
    }

    @Test fun differentAppsOrWindowsSendEverything() {
        val before = screen("甲", "乙")
        for (after in listOf(screen("甲", "乙", id = "s8", pkg = "another.app"), screen("甲", "乙", id = "s8", windowId = 2))) {
            assertEquals(after.text, digest("s7", before, "s8", after))
        }
    }

    @Test fun bracketedNumbersInLabelsCannotOverflowElementIds() {
        val label = "Stable [99999999999999999999]"
        val before = screen(label, "Before", "Stable 2", "Stable 3")
        val after = screen(label, "After", "Stable 2", "Stable 3", id = "s8")
        val text = digest("s7", before, "s8", after)
        assertTrue(text, text.contains("After"))
        assertFalse(text, text.contains(label))
        assertTrue(text, text.contains("只列变化"))
    }

    @Test fun aChangedContextCannotReuseThePreviousText() {
        val before = screen("甲", "乙")
        val after = screen("甲", "乙", id = "s8")
        assertEquals(after.text, ScreenDigest.text("s7", before, "s8", after, canReuse = false))
    }
}
