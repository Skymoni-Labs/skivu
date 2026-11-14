package com.skyjjgw.independent.ski.dshgo.phone

/** Native-only scope facts. A continuity token is renewed after any intervening unknown scope. */
sealed interface VisualScope {
    val screen: PhoneScreen
    val packageName: String
    data class Main(val driverEpoch: Any, val windowLifetime: Any, val windowId: Int,
                    override val packageName: String) : VisualScope {
        override val screen = PhoneScreen.MAIN
    }
    data class Background(val resourceOwner: String, val target: PhoneAppIdentity,
                          val continuity: Any) : VisualScope {
        override val screen = PhoneScreen.BACKGROUND
        override val packageName get() = target.packageName
    }
}

data class VisualTarget(val scope: VisualScope, val target: TargetInfo)

data class VisualBounds(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val valid get() = right > left && bottom > top
    fun contains(other: VisualBounds) = valid && other.valid && left <= other.left && top <= other.top && right >= other.right && bottom >= other.bottom
    fun contains(x: Int, y: Int) = valid && x >= left && x < right && y >= top && y < bottom
    fun overlaps(other: VisualBounds) = valid && other.valid && left < other.right && right > other.left && top < other.bottom && bottom > other.top
}

/** One bounded raw tree transaction; parentIndex is real recursion, never formatted indent. */
data class VisualNode(
    val parentIndex: Int, val className: String?, val bounds: VisualBounds,
    val visible: Boolean, val enabled: Boolean, val clickable: Boolean, val actionClick: Boolean,
    val rawChildCount: Int, val editable: Boolean, val checkable: Boolean, val password: Boolean,
    val longClickable: Boolean, val scrollable: Boolean,
    val text: String?, val description: String?, val hint: String?, val viewId: String?,
)

/** Conservative ordinary Button subset, shared by the two real screen drivers. */
object VisualTargets {
    private val containers = setOf("android.widget.FrameLayout", "android.widget.LinearLayout", "android.widget.RelativeLayout")
    private fun ordinary(n: VisualNode): Boolean {
        val fields = listOf(n.text, n.description, n.hint, n.viewId)
        return fields.none { (it?.length ?: 0) > 4096 || SafetyRules.sensitiveWord(it) != null || SafetyRules.isSecret(it) } &&
            !n.password && !n.editable && !n.checkable
    }
    fun eligible(nodes: List<VisualNode>, viewport: VisualBounds, complete: Boolean): List<Int> {
        if (!complete || nodes.isEmpty() || nodes.size > 600 || !viewport.valid) return emptyList()
        if (nodes.indices.any { nodes[it].parentIndex !in -1 until it || nodes[it].rawChildCount < 0 }) return emptyList()
        // Missing children cannot become a leaf merely because getChild failed.
        val children = IntArray(nodes.size)
        nodes.forEach { if (it.parentIndex >= 0) children[it.parentIndex]++ }
        if (nodes.indices.any { children[it] != nodes[it].rawChildCount }) return emptyList()
        return nodes.indices.filter { index ->
            val n = nodes[index]
            if (n.className !in setOf("android.widget.Button", "android.widget.ImageButton") || !n.visible || !n.enabled ||
                !n.clickable || !n.actionClick || n.scrollable || n.rawChildCount != 0 || !viewport.contains(n.bounds) || !ordinary(n) ||
                (n.text.isNullOrBlank() && n.description.isNullOrBlank())) return@filter false
            val ancestors = HashSet<Int>()
            var parent = n.parentIndex
            while (parent >= 0) { ancestors += parent; parent = nodes[parent].parentIndex }
            if (ancestors.any { i -> val a = nodes[i]
                a.className !in containers || !a.visible || !a.enabled || a.clickable || a.longClickable || a.scrollable ||
                    !ordinary(a) || !a.bounds.contains(n.bounds)
            }) return@filter false
            nodes.indices.none { i -> i != index && i !in ancestors && nodes[i].visible &&
                (!nodes[i].bounds.valid || nodes[i].bounds.overlaps(n.bounds)) }
        }
    }
}
