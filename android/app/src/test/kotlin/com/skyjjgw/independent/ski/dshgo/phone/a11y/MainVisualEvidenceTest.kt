package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.*
import org.junit.Test

class MainVisualEvidenceTest {
    private val screen = Box(0, 0, 400, 800)
    private fun button(action: Boolean = true, rawChildren: Int = 0) = UiNode(
        className = "android.widget.Button", text = "Continue", bounds = Box(20, 40, 180, 100),
        clickable = true, actionClick = action, rawChildCount = rawChildren)
    private fun evidence(child: UiNode = button(), others: List<UiNode> = emptyList(), complete: Boolean = true,
                         occlusions: List<Box> = emptyList()): MainVisualEvidence {
        val children = listOf(child) + others
        val root = UiNode(className = "android.widget.FrameLayout", bounds = screen,
            children = children, rawChildCount = children.size)
        return MainVisualEvidence(UiWindow(1, WindowKind.APP, "example.app", null, screen, root), screen, complete, occlusions)
    }
    @Test fun rawClickAndChildFactsDriveTheSameActualClassifier() {
        assertNotNull(evidence().target(50, 60))
        assertNull(evidence(button(action = false)).target(50, 60))
        assertNull(evidence(button(rawChildren = 1)).target(50, 60))
        assertNull(evidence(complete = false).target(50, 60))
    }
    @Test fun nonAncestorContainerAndSystemChromeCannotBeIgnored() {
        val cover = UiNode(className = "android.widget.FrameLayout", bounds = Box(0, 0, 200, 200),
            rawChildCount = 0)
        assertNull(evidence(others = listOf(cover)).target(50, 60))
        assertNull(evidence(occlusions = listOf(Box(0, 0, 400, 70))).target(50, 60))
        assertNotNull(evidence(occlusions = listOf(Box(0, 0, 400, 20))).target(50, 60))
    }
    @Test fun changedNativeActionCannotMatchTheOldOrdinaryTarget() {
        val old = evidence().target(50, 60)
        val fresh = evidence(button(action = false)).target(50, 60)
        assertNotNull(old); assertNull(fresh); assertNotEquals(old, fresh)
    }
}
