package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.phone.Json
import org.junit.Assert.*
import org.junit.Test

class NavigationMaterialsTest {
    private val box = Box(0, 0, 100, 100)
    private fun node(key: String?, ref: Int, children: List<UiNode> = emptyList(), desc: String? = "PRIVATE_DESC") =
        UiNode(ref = ref, className = "PRIVATE_CLASS", text = "PRIVATE_TEXT", hint = "PRIVATE_HINT",
            stateDesc = "PRIVATE_STATE", desc = desc,
            viewId = key?.let { "net.gsantner.markor:id/$it" }, bounds = box, selected = true,
            rawChildCount = children.size, children = children)
    @Test fun onlyWhitelistedFieldsAndActionsLeaveTheProjection() {
        val root = node(null, 0, listOf(node("bottom_navigation_bar", 1, listOf(
            node("nav_more", 2), node("private_note", 3))), node("main__view_pager_container", 4)))
        val reads = mutableListOf<Int>()
        val rows = checkNotNull(NavigationMaterials.project(root, mapOf("nav_more" to "More")) {
            reads += it.ref; listOf(16)
        })
        assertEquals(listOf(1, 2, 4), reads); assertEquals(3, rows.size)
        val more = rows[1]
        assertEquals("nav_more", more["idKey"]); assertEquals(1, more["parentLocalId"])
        assertEquals(true, more["withinNavigationBar"]); assertEquals(false, more["descriptionMatchesResource"])
        assertEquals(listOf(16), more["actions"]); assertEquals(true, more["selected"])
        val json = Json.write(rows)
        assertFalse(json.contains("PRIVATE")); assertFalse(json.contains("private_note"))
        assertFalse(json.contains("hint")); assertFalse(json.contains("className"))
    }
    @Test fun duplicatesAndUnlistedImmediateParentsRemainExplicit() {
        val root = node("bottom_navigation_bar", 0, listOf(node(null, 1,
            listOf(node("nav_more", 2), node("nav_more", 3)))))
        val rows = checkNotNull(NavigationMaterials.project(root, emptyMap()) { emptyList() })
        assertEquals(listOf("bottom_navigation_bar", "nav_more", "nav_more"), rows.map { it["idKey"] })
        assertEquals(listOf(1, 2, 3), rows.map { it["localId"] })
        for (row in rows.drop(1)) {
            assertNull(row["parentLocalId"]); assertEquals(true, row["withinNavigationBar"])
            assertEquals(false, row["descriptionMatchesResource"])
        }
    }
    @Test fun recordAndActionLimitsRejectTheWholeProjection() {
        val full = node(null, 0, List(32) { node("nav_more", it + 1) })
        assertEquals(32, NavigationMaterials.project(full, emptyMap()) { List(32) { it } }!!.size)
        val overflow = node(null, 0, List(33) { node("nav_more", it + 1) })
        assertNull(NavigationMaterials.project(overflow, emptyMap()) { emptyList() })
        assertNull(NavigationMaterials.project(full, emptyMap()) { List(33) { it } })
        assertNull(NavigationMaterials.project(full, emptyMap()) { null })
    }
    @Test fun matchingUnicodeResourceExportsOnlyTheKeyAndBoolean() {
        val value = "公开🔎导航"
        val rows = checkNotNull(NavigationMaterials.project(node("nav_more", 1, desc = value),
            mapOf("nav_more" to value)) { listOf(16) })
        assertEquals("more", rows.single()["labelResourceKey"])
        assertEquals(true, rows.single()["descriptionMatchesResource"])
        assertFalse(Json.write(rows).contains(value))
    }
}
