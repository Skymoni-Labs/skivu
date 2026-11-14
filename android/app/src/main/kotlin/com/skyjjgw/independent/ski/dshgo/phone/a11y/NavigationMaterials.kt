package com.skyjjgw.independent.ski.dshgo.phone.a11y

/** Finite diagnostic projection. No tree/string/node is retained outside the projected result. */
internal object NavigationMaterials {
    const val MAX_BYTES = 16 * 1024
    private val labels = mapOf("nav_notebook" to "files", "nav_todo" to "todo",
        "nav_quicknote" to "quicknote", "nav_more" to "more")
    private val ids = labels.keys + setOf("bottom_navigation_bar", "main__view_pager_container")
    sealed interface Result
    class Sample(val fields: Map<String, Any?>, val current: () -> Boolean) : Result
    data class Unavailable(val reason: String) : Result

    fun bounds(box: Box): List<Int> = listOf(box.left, box.top, box.right, box.bottom)

    /** Only whitelisted nodes reach action lookup. Repeated ids remain separate evidence. */
    fun project(root: UiNode, publicLabels: Map<String, String>,
                actionIds: (UiNode) -> List<Int>?): List<Map<String, Any?>>? {
        val output = ArrayList<Map<String, Any?>>()
        var valid = true
        fun visit(node: UiNode, parent: Int?, inBar: Boolean) {
            if (!valid) return
            val key = ids.firstOrNull { node.viewId == "${MarkorNavigation.PACKAGE}:id/$it" }
            var local: Int? = null
            if (key != null) {
                if (output.size == 32) { valid = false; return }
                val actions = actionIds(node)
                if (actions == null || actions.size > 32) { valid = false; return }
                local = output.size + 1
                output += mapOf("localId" to local, "idKey" to key, "bounds" to bounds(node.bounds),
                    "parentLocalId" to parent, "withinNavigationBar" to inBar,
                    "selected" to node.selected, "enabled" to node.enabled, "password" to node.password,
                    "editable" to node.editable, "clickable" to node.clickable,
                    "longClickable" to node.longClickable, "rawChildCount" to node.rawChildCount,
                    "actions" to actions.toList(), "labelResourceKey" to labels[key],
                    "descriptionMatchesResource" to labels[key]?.let {
                        val expected = publicLabels[key]
                        !expected.isNullOrBlank() && node.desc == expected
                    })
            }
            node.children.forEach { visit(it, local, inBar || key == "bottom_navigation_bar") }
        }
        visit(root, null, false)
        return output.takeIf { valid }
    }
}
