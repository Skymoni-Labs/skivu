package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.phone.VisualBounds
import com.skyjjgw.independent.ski.dshgo.phone.VisualNode
import com.skyjjgw.independent.ski.dshgo.phone.VisualTargets

/** Plain bounded evidence from the same captured tree as the image. No native nodes escape. */
internal class MainVisualEvidence(window: UiWindow, screen: Box, complete: Boolean, private val occlusions: List<Box>) {
    private val nodes = ArrayList<VisualNode>()
    private val eligible: List<Int>
    init {
        var oversized = false
        fun visit(node: UiNode, parent: Int) {
            if (nodes.size > 600 || oversized) return
            if (listOf(node.text, node.desc, node.hint, node.viewId).any { (it?.length ?: 0) > 4096 }) {
                oversized = true; return // Unknown, never truncate a raw field into an ordinary label.
            }
            val index = nodes.size
            nodes += VisualNode(parent, node.className, node.bounds.visual(), true, node.enabled,
                node.clickable, node.actionClick, node.rawChildCount, node.editable, node.checkable,
                node.password, node.longClickable, node.scrollable, node.text, node.desc, node.hint, node.viewId)
            node.children.forEach { visit(it, index) }
        }
        window.root?.let { visit(it, -1) }
        eligible = VisualTargets.eligible(nodes, window.bounds.intersect(screen).visual(), complete && !oversized)
    }
    fun target(x: Int, y: Int): VisualNode? = eligible.map { nodes[it] }.singleOrNull { node ->
        node.bounds.contains(x, y) && occlusions.none { it.visual().overlaps(node.bounds) }
    }
    private fun Box.visual() = VisualBounds(left, top, right, bottom)
}
