package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

class VisualTargetsTest {
    private val viewport = VisualBounds(0, 0, 720, 1600)
    private fun root(children: Int = 1) = VisualNode(-1, "android.widget.FrameLayout", viewport,
        true, true, false, false, children, false, false, false, false, false, null, null, null, null)
    private fun button(parent: Int = 0, box: VisualBounds = VisualBounds(20, 30, 180, 100)) =
        VisualNode(parent, "android.widget.Button", box, true, true, true, true, 0,
            false, false, false, false, false, "Details", null, null, "example:id/details")
    private fun eligible(nodes: List<VisualNode>, complete: Boolean = true) = VisualTargets.eligible(nodes, viewport, complete)

    @Test fun ordinaryLeafButtonUsesRealAncestorChain() {
        assertEquals(listOf(1), eligible(listOf(root(), button())))
        val inner = root().copy(parentIndex = 0, className = "android.widget.LinearLayout")
        assertEquals(listOf(2), eligible(listOf(root(), inner, button(1))))
    }
    @Test fun siblingContainerBlocksEvenWhenItsChildDoesNotOverlap() {
        val sibling = root().copy(parentIndex = 0)
        val distant = button(2, VisualBounds(400, 800, 600, 900)).copy(className = "android.widget.TextView", clickable = false)
        assertTrue(eligible(listOf(root(2), button(), sibling, distant)).isEmpty())
    }
    @Test fun unknownOrInteractiveAncestorsAndSensitiveFieldsCannotBeTransparent() {
        for (ancestor in listOf(root().copy(className = "android.webkit.WebView"), root().copy(scrollable = true),
            root().copy(clickable = true), root().copy(description = "付款"))) {
            assertTrue(eligible(listOf(ancestor, button())).isEmpty())
        }
    }
    @Test fun MissingActionChildrenAndRawSemanticsRemainUnknown() {
        for (node in listOf(button().copy(actionClick = false), button().copy(rawChildCount = 1),
            button().copy(enabled = false), button().copy(editable = true), button().copy(checkable = true),
            button().copy(password = true), button().copy(text = null), button().copy(hint = "密码"),
            button().copy(description = " ".repeat(4097)))) {
            assertTrue(eligible(listOf(root(), node)).isEmpty())
        }
        assertTrue(eligible(listOf(root(), button()), false).isEmpty())
    }
    @Test fun outputTruncatedBlockerStillParticipatesInWholeTree() {
        val nodes = mutableListOf(root(121), button())
        repeat(119) { nodes += button(box = VisualBounds(400, 800, 600, 900)).copy(className = "android.widget.TextView", clickable = false) }
        nodes += root(0).copy(parentIndex = 0, bounds = button().bounds)
        assertTrue(eligible(nodes).isEmpty())
    }
    @Test fun overlapAndBrokenParentIndicesCannotGrant() {
        assertTrue(eligible(listOf(root(2), button(), button())).isEmpty())
        assertTrue(eligible(listOf(root(), button(parent = 1))).isEmpty())
        assertTrue(eligible(List(601) { root(0) }).isEmpty())
    }
}
