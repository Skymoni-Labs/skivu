package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.*
import org.junit.Test

class CollectedItemsPageTest {
    @Test fun incompletePagePreservesReadableListRowsAndStops() {
        val frame = Box(0, 0, 400, 800)
        val list = UiNode(bounds = frame, scrollable = true, children = listOf(
            UiNode(text = "Row alpha", bounds = Box(0, 100, 400, 150)),
            UiNode(text = "Row beta", bounds = Box(0, 200, 400, 250)),
        ))
        val windows = listOf(UiWindow(1, WindowKind.APP, "example.app", null, frame, list))
        val rows = ScreenFormat.index(windows).single { it.kind == ElementKind.LIST }.itemTexts
        val collected = CollectedItems().apply { add("Earlier page row") }
        val page = collected.readPage(rows, null, incomplete = true)
        assertEquals(listOf("Earlier page row", "Row alpha", "Row beta"), collected.list())
        assertEquals(2, page.added)
        assertFalse(page.found)
        assertEquals("页面只读了一部分，无法确认列表是否到底", page.stopReason)
        assertFalse(page.stopReason!!.contains("到底了"))
    }

    @Test fun completePageKeepsDeduplicationAndCaseInsensitiveUntil() {
        val collected = CollectedItems().apply { add("Row alpha") }
        val page = collected.readPage(listOf("Row alpha", "Row beta"), "BETA", incomplete = false)
        assertEquals(listOf("Row alpha", "Row beta"), collected.list())
        assertEquals(1, page.added)
        assertTrue(page.found)
        assertNull(page.stopReason)
    }

    @Test fun emptyIncompletePageStopsWithoutLosingEarlierRows() {
        val collected = CollectedItems().apply { add("Earlier page row") }
        val page = collected.readPage(emptyList(), null, incomplete = true)
        assertEquals(listOf("Earlier page row"), collected.list())
        assertEquals(0, page.added)
        assertFalse(page.found)
        assertEquals("页面只读了一部分，无法确认列表是否到底", page.stopReason)
    }
}
