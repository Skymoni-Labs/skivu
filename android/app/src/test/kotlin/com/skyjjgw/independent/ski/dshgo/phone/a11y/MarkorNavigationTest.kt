package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.*
import org.junit.Test

/** Actual raw-tree predicate tests, not installed-App/Android action or PackageManager evidence. */
class MarkorNavigationTest {
    private val pkg = MarkorNavigation.PACKAGE
    private val box = Box(0, 0, 400, 800)
    private val keys = listOf("nav_notebook", "nav_todo", "nav_quicknote", "nav_more")
    private val labels = keys.zip(listOf("Files", "To-Do", "QuickNote", "More")).toMap()
    private fun window(selected: String = "nav_notebook", duplicate: Boolean = false,
                       outside: Boolean = false, label: String = "More", enabled: Boolean = true): UiWindow {
        val nodes = keys.mapIndexed { i, key -> UiNode(ref = i, viewId = "$pkg:id/$key",
            desc = if (key == "nav_more") label else labels[key], bounds = Box(i * 100, 700, (i + 1) * 100, 800),
            selected = key == selected, enabled = if (key == "nav_more") enabled else true,
            clickable = key != selected, actionClick = key != selected) }
        val bar = UiNode(viewId = "$pkg:id/bottom_navigation_bar", bounds = Box(0, 700, 400, 800),
            children = if (outside) nodes.dropLast(1) else nodes)
        val pager = UiNode(viewId = "$pkg:id/main__view_pager_container", bounds = Box(0, 0, 400, 700))
        return UiWindow(7, WindowKind.APP, pkg, null, box, UiNode(bounds = box,
            children = listOf(bar, pager) + (if (outside) listOf(nodes.last()) else emptyList()) +
                (if (duplicate) listOf(nodes.last()) else emptyList())))
    }

    @Test fun selectedNonClickableTabIsAValidPostObservationWithoutAnotherClick() {
        val before = MarkorNavigation.inspect(listOf(window()), labels)!!
        assertEquals("nav_notebook", before.selected)
        assertTrue(before.moreCanClick)
        val after = MarkorNavigation.inspect(listOf(window(selected = "nav_more")), labels)!!
        assertEquals("nav_more", after.selected)
        assertFalse(after.moreCanClick)
        assertEquals(before.moreRef, after.moreRef)
    }

    @Test fun duplicateOrOutsideNavigationTargetsDoNotAcquireUniqueness() {
        assertNull(MarkorNavigation.inspect(listOf(window(duplicate = true)), labels))
        assertNull(MarkorNavigation.inspect(listOf(window(outside = true)), labels))
        assertNull(MarkorNavigation.inspect(listOf(window(), window()), labels))
    }

    @Test fun actualPublicLabelsAndEnabledFactsAreRequired() {
        assertNull(MarkorNavigation.inspect(listOf(window(label = "Private title")), labels))
        assertNull(MarkorNavigation.inspect(listOf(window(enabled = false)), labels))
        assertNull(MarkorNavigation.inspect(listOf(window()), emptyMap()))
        assertNull(MarkorNavigation.inspect(listOf(window(selected = "missing")), labels))
    }
}
