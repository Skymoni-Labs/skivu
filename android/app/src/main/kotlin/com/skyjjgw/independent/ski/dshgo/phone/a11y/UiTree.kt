package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.phone.SensitiveWords

// A plain copy of the accessibility tree: what ScreenFormat needs and nothing
// Android-typed, so the formatting rules run in a JVM test. TreeCapture
// fills it from AccessibilityNodeInfo; tests build it by hand.

/** Screen rectangle in pixels (left/top inclusive, right/bottom exclusive, like android.graphics.Rect). */
data class Box(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width get() = right - left
    val height get() = bottom - top
    val centerX get() = (left + right) / 2
    val centerY get() = (top + bottom) / 2
    val isEmpty get() = width <= 0 || height <= 0
    val area: Long get() = if (isEmpty) 0L else width.toLong() * height

    fun contains(x: Int, y: Int) = x >= left && x < right && y >= top && y < bottom

    /** Vertical overlap as a share of the shorter box: 1.0 = same row. */
    fun rowOverlap(other: Box): Double {
        val overlap = minOf(bottom, other.bottom) - maxOf(top, other.top)
        val shorter = minOf(height, other.height)
        return if (overlap <= 0 || shorter <= 0) 0.0 else overlap.toDouble() / shorter
    }

    fun intersect(other: Box) = Box(maxOf(left, other.left), maxOf(top, other.top), minOf(right, other.right), minOf(bottom, other.bottom))

    override fun toString() = "$left,$top,$right,$bottom"
}

/** Which ways a scrollable node can move right now (from its action list). */
object Scroll {
    const val FORWARD = 1
    const val BACKWARD = 2
    const val UP = 4
    const val DOWN = 8
    const val LEFT = 16
    const val RIGHT = 32
}

/** One accessibility node. [ref] indexes the capture's native node list (-1 in tests). */
class UiNode(
    val ref: Int = -1,
    val className: String = "",
    val text: String? = null,
    val desc: String? = null,
    val hint: String? = null,
    val viewId: String? = null,
    val bounds: Box,
    val clickable: Boolean = false,
    val longClickable: Boolean = false,
    val editable: Boolean = false,
    val scrollable: Boolean = false,
    val checkable: Boolean = false,
    val checked: Boolean = false,
    val selected: Boolean = false,
    val focused: Boolean = false,
    val enabled: Boolean = true,
    val password: Boolean = false,
    val heading: Boolean = false,
    /** The editable shows its hint (API 26+); [text] is then the hint, not content. */
    val showingHint: Boolean = false,
    /** [Scroll] bits. */
    val scroll: Int = 0,
    /** Chromium's `chromeRole` / Compose's role description, lower-cased (`link`, `tab`, `button`). */
    val roleHint: String? = null,
    /** API 30 stateDescription (Compose switches, custom widgets). */
    val stateDesc: String? = null,
    /** RangeInfo current / max, when the node is a slider or progress. */
    val rangeCurrent: Float? = null,
    val rangeMax: Float? = null,
    val children: List<UiNode> = emptyList(),
    /** Raw native facts for ordinary visual targets; missing facts never imply a leaf/click action. */
    val rawChildCount: Int = -1,
    val actionClick: Boolean = false,
)

enum class WindowKind { APP, SYSTEM }

/** One window that the snapshot reads, top-most first in [ScreenInput.windows]. */
class UiWindow(
    val id: Int,
    val kind: WindowKind,
    val packageName: String?,
    val title: String?,
    val bounds: Box,
    val root: UiNode?,
)

/** Secret fields in the whole captured tree, including nodes omitted from the text listing. */
internal fun secretFieldBounds(windows: List<UiWindow>): List<Box> {
    val bounds = ArrayList<Box>()
    fun visit(node: UiNode) {
        val hint = node.hint?.takeIf { it.isNotBlank() } ?: node.text?.takeIf { node.showingHint }
        if (node.password || (node.editable && SensitiveWords.secretHit(hint, node.desc, node.viewId) != null)) {
            bounds += node.bounds
        }
        node.children.forEach(::visit)
    }
    windows.forEach { it.root?.let(::visit) }
    return bounds
}

/**
 * collect's de-duplication: by text, in on-screen order. A row cut off at the list's edge
 * reads as part of its own text (only its summary is visible), so a text contained in an
 * item already collected is a repeat, and a text containing one replaces it in place.
 */
class CollectedItems {
    private val items = ArrayList<String>()
    var chars = 0
        private set

    /** True when [text] added something (a new item or a longer form of one). */
    fun add(text: String): Boolean {
        if (items.any { it == text || (text.length >= 4 && it.contains(text)) }) return false
        val shorter = items.indexOfFirst { it.length >= 4 && text.contains(it) }
        if (shorter >= 0) {
            chars += text.length - items[shorter].length
            items[shorter] = text
            return true
        }
        items += text
        chars += text.length
        return true
    }

    internal data class PageRead(val added: Int, val found: Boolean, val stopReason: String?)

    /** Keep the readable prefix even when this capture cannot justify another scroll. */
    internal fun readPage(texts: List<String>, until: String?, incomplete: Boolean): PageRead {
        var added = 0
        var found = false
        for (text in texts) if (add(text)) {
            added++
            if (until != null && text.contains(until, ignoreCase = true)) found = true
        }
        // l10n:keep agent screen result
        val stop = if (incomplete) "页面只读了一部分，无法确认列表是否到底" else null
        return PageRead(added, found, stop)
    }

    fun list(): List<String> = items.toList()
}
