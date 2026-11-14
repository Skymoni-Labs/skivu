package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.accessibilityservice.AccessibilityService
import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction
import android.view.accessibility.AccessibilityWindowInfo

/** Package metadata from the same enumeration, independent of the formatted tree subset. */
internal data class CapturedImageWindow(val id: Int, val type: Int, val packageName: String?)

/**
 * One read of the windows on the main display: plain [UiWindow]s for ScreenFormat plus
 * the native nodes they index ([UiNode.ref]), which the Actuator acts on. Drop with
 * [recycle] once a newer capture replaces it.
 */
internal class Capture(
    /** Top-most first; the last is the main window. Empty when nothing readable is in front. */
    val windows: List<UiWindow>,
    val natives: List<AccessibilityNodeInfo>,
    /** Null when the system did not give us a window enumeration. */
    val keyboardShown: Boolean?,
    val screen: Box,
    /** Package of the top-most readable window (what the person is looking at). */
    val packageName: String?,
    /** DSH itself is in front. Read anyway (the 「读一下当前屏幕」 check shows it); the core's
     *  SafetyGate.filterScreen hides it from the model and the driver never acts on it. */
    val ownAppInFront: Boolean,
    /** A system window (notification shade, quick settings) covers the screen. */
    val systemInFront: Boolean,
    /** Hit a window, node, depth or time limit: the tree may be incomplete. */
    val truncated: Boolean,
    /** A declared tree part could not be read; the available content is retained. */
    val partial: Boolean = false,
    /**
     * Title of a front window whose root the system won't give us. This can happen with
     * accessibilityDataSensitive pages or a transition; conservatively forwarded as secure.
     */
    val hiddenWindowTitle: String? = null,
    /**
     * Title of the front window that is there but gives us only empty layout shells.
     * Android 14+ hides views marked accessibilityDataSensitive from non-tool
     * services this way (GitHub, banking and password pages), so the root survives while the
     * content subtree does not. Only a hint: report 「可能受敏感视图策略限制」, never assert
     * that the app is a sensitive page (a fresh, still-drawing app looks the same for a moment).
     */
    val unreadableWindowTitle: String? = null,
    val takenAt: Long = SystemClock.uptimeMillis(),
    /** Whole enumeration, before the formatting loop can stop at an opaque window. */
    val visualWindowId: Int? = null,
    val visualComplete: Boolean = false,
    val visualOcclusions: List<Box> = emptyList(),
    val imageWindows: List<CapturedImageWindow> = emptyList(),
    /** Same read counter; consumers must still compare current transitions after their own work. */
    val typedTransitions: Long? = null,
    /** Delivered events for the same read; independent of the window-transition counter. */
    val typedEvents: Long? = null,
) {
    fun native(ref: Int): AccessibilityNodeInfo? = natives.getOrNull(ref)

    fun windowBounds(id: Int): Box? = windows.firstOrNull { it.id == id }?.bounds

    @Suppress("DEPRECATION")
    fun recycle() {
        if (Build.VERSION.SDK_INT < 33) natives.forEach { runCatching { it.recycle() } }
    }
}

internal object TreeCapture {
    private const val MAX_NODES = 2000
    private const val MAX_DEPTH = 80
    private const val MAX_WINDOWS = 4

    private val scrollIds by lazy {
        mapOf(
            AccessibilityAction.ACTION_SCROLL_FORWARD.id to Scroll.FORWARD,
            AccessibilityAction.ACTION_SCROLL_BACKWARD.id to Scroll.BACKWARD,
            AccessibilityAction.ACTION_SCROLL_UP.id to Scroll.UP,
            AccessibilityAction.ACTION_SCROLL_DOWN.id to Scroll.DOWN,
            AccessibilityAction.ACTION_SCROLL_LEFT.id to Scroll.LEFT,
            AccessibilityAction.ACTION_SCROLL_RIGHT.id to Scroll.RIGHT,
        )
    }

    private class State(val deadline: Long, val typedTransitions: Long?, val typedEvents: Long?) {
        val natives = ArrayList<AccessibilityNodeInfo>(256)
        var count = 0
        var typedFresh = true
        var truncated = false
        var partial = false
        var visualComplete = true
        val rect = Rect()
    }

    fun capture(service: AccessibilityService, screen: Box, ownPackage: String, budgetMs: Long, typedTransitions: Long? = null, typedEvents: Long? = null): Capture {
        val st = State(SystemClock.uptimeMillis() + budgetMs, typedTransitions, typedEvents)
        val all = try { service.windows } catch (_: Throwable) { null }
        val sorted = all.orEmpty().sortedByDescending { it.layer }
        // Scan every window before the content loop can stop at an opaque app window.
        val keyboard = WindowContent.keyboardShown(all?.map { it.type }, AccessibilityWindowInfo.TYPE_INPUT_METHOD)
        // Conservative whole-window facts. Only our own confirmed overlay is ignored; small
        // system chrome is retained as an occluder, never silently treated as target-free space.
        val visual = runCatching {
            all ?: error("No window enumeration")
            val apps = mutableListOf<Int>()
            val occlusions = mutableListOf<Box>()
            var complete = true
            for (w in all) {
                w.getBoundsInScreen(st.rect)
                val box = Box(st.rect.left, st.rect.top, st.rect.right, st.rect.bottom).intersect(screen)
                if (box.isEmpty) continue
                when (w.type) {
                    AccessibilityWindowInfo.TYPE_APPLICATION -> apps += w.id
                    AccessibilityWindowInfo.TYPE_SYSTEM -> {
                        if (box.area.toDouble() / screen.area.coerceAtLeast(1) >= 0.5) complete = false
                        occlusions += box
                    }
                    AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY -> {
                        val root = w.root
                        try { refreshTyped(root, st); if (root?.packageName?.toString() != ownPackage) complete = false }
                        finally { root?.let(::release) }
                    }
                    else -> complete = false // IME, divider, magnifier or unknown overlay.
                }
            }
            Triple(apps.singleOrNull(), complete && apps.size == 1, occlusions.toList())
        }.getOrNull()
        val imageWindows = mutableListOf<CapturedImageWindow>()
        val chosen = mutableListOf<UiWindow>()
        var topPackage: String? = null
        var ownFront = false
        var systemFront = false
        var hidden: String? = null
        var unreadable: String? = null
        val screenArea = screen.area.coerceAtLeast(1)
        try {
            // Do not let the content loop's MAX_WINDOWS/opaque-front exits erase
            // known display-image sources. Only package metadata is read here.
            for (w in all.orEmpty()) {
                w.getBoundsInScreen(st.rect)
                val bounds = Box(st.rect.left, st.rect.top, st.rect.right, st.rect.bottom)
                if (bounds.intersect(screen).isEmpty) continue
                var pkg: String? = null
                if (!Thread.currentThread().isInterrupted && SystemClock.uptimeMillis() < st.deadline) {
                    try {
                        // API 33 permits no prefetch. Older getRoot may prefetch
                        // internally; this code never inspects child/text data.
                        val root = if (Build.VERSION.SDK_INT >= 33) w.getRoot(0) else w.root
                        try { refreshTyped(root, st); pkg = root?.packageName?.toString()?.takeIf { it.isNotBlank() } }
                        finally { root?.let(::release) }
                    } catch (_: Exception) {
                        // A failed root lookup establishes no package identity.
                    }
                }
                imageWindows += CapturedImageWindow(w.id, w.type, pkg)
            }
            for (w in sorted) {
                when (w.type) {
                    AccessibilityWindowInfo.TYPE_INPUT_METHOD -> continue
                    AccessibilityWindowInfo.TYPE_APPLICATION, AccessibilityWindowInfo.TYPE_SYSTEM -> {}
                    else -> continue // our overlay, other services' overlays, split-screen divider, magnifier
                }
                w.getBoundsInScreen(st.rect)
                val bounds = Box(st.rect.left, st.rect.top, st.rect.right, st.rect.bottom)
                val share = bounds.intersect(screen).area.toDouble() / screenArea
                if (share <= 0) continue
                // Status bar, navigation bar, a floating ball: small system windows are chrome, not content.
                if (w.type == AccessibilityWindowInfo.TYPE_SYSTEM && share < 0.5) continue
                if (chosen.size >= MAX_WINDOWS) { st.truncated = true; break }
                // Some windows answer getRoot() with null (seen on the API 35 emulator for a Settings
                // sub-page); the active window's root is still reachable through the service.
                val root = w.root ?: (if (w.isActive || w.isFocused) activeRoot(service, w.id) else null)
                if (root == null) {
                    // A dialog, split-screen pane or IME-resized app can be unreadable too.
                    if (w.type == AccessibilityWindowInfo.TYPE_APPLICATION) {
                        when (WindowContent.rootGap(chosen)) {
                            WindowContent.RootGap.FRONT -> hidden = (if (Build.VERSION.SDK_INT >= 24) w.title?.toString() else null) ?: ""
                            WindowContent.RootGap.PARTIAL -> st.partial = true
                        }
                        break
                    }
                    continue
                }
                refreshTyped(root, st)
                val pkg = root.packageName?.toString()
                if (chosen.isEmpty()) {
                    topPackage = pkg
                    ownFront = pkg == ownPackage
                    systemFront = w.type == AccessibilityWindowInfo.TYPE_SYSTEM
                }
                val title = if (Build.VERSION.SDK_INT >= 24) w.title?.toString() else null
                val node = convert(root, 0, st, refresh = false)
                // Inspect the whole subtree, not just the root's child count. A chain of empty
                // layouts is still unreadable; an unlabelled canvas is not evidence of filtering.
                val emptyFront = chosen.isEmpty() && w.type == AccessibilityWindowInfo.TYPE_APPLICATION &&
                    !st.truncated && !WindowContent.usable(node)
                if (emptyFront) unreadable = title ?: ""
                chosen += UiWindow(
                    w.id, if (w.type == AccessibilityWindowInfo.TYPE_SYSTEM) WindowKind.SYSTEM else WindowKind.APP,
                    pkg, title, bounds, node,
                )
                if (emptyFront || share >= 0.8) break // do not read through an unreadable front window
            }
        } finally {
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < 33) all.orEmpty().forEach { runCatching { it.recycle() } }
        }
        return Capture(
            windows = chosen,
            natives = st.natives,
            keyboardShown = keyboard,
            screen = screen,
            packageName = topPackage,
            ownAppInFront = ownFront,
            systemInFront = systemFront,
            truncated = st.truncated,
            partial = st.partial,
            hiddenWindowTitle = hidden,
            unreadableWindowTitle = unreadable,
            visualWindowId = visual?.first,
            visualComplete = visual?.second == true && st.visualComplete && !st.truncated && !st.partial &&
                hidden == null && unreadable == null && chosen.size == 1 && chosen.single().id == visual?.first,
            visualOcclusions = visual?.third.orEmpty(),
            imageWindows = imageWindows.toList(),
            typedTransitions = st.typedTransitions.takeIf { st.typedFresh },
            typedEvents = st.typedEvents.takeIf { st.typedFresh },
        )
    }

    /** Package of the top-most application / full-screen system window, without reading the tree. */
    fun foregroundPackage(service: AccessibilityService, screen: Box): String? {
        val all = try { service.windows } catch (_: Throwable) { return null }
        val rect = Rect()
        try {
            for (w in all.sortedByDescending { it.layer }) {
                if (w.type != AccessibilityWindowInfo.TYPE_APPLICATION && w.type != AccessibilityWindowInfo.TYPE_SYSTEM) continue
                w.getBoundsInScreen(rect)
                val share = Box(rect.left, rect.top, rect.right, rect.bottom).intersect(screen).area.toDouble() / screen.area.coerceAtLeast(1)
                if (w.type == AccessibilityWindowInfo.TYPE_SYSTEM && share < 0.5) continue
                val root = w.root ?: (if (w.isActive || w.isFocused) activeRoot(service, w.id) else null) ?: continue
                try { return root.packageName?.toString() } finally { release(root) }
            }
        } finally {
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < 33) all.forEach { runCatching { it.recycle() } }
        }
        return null
    }

    private fun activeRoot(service: AccessibilityService, windowId: Int): AccessibilityNodeInfo? {
        val root = try { service.rootInActiveWindow } catch (_: Throwable) { null } ?: return null
        if (root.windowId == windowId) return root
        release(root)
        return null
    }

    @Suppress("DEPRECATION")
    private fun release(node: AccessibilityNodeInfo) { if (Build.VERSION.SDK_INT < 33) runCatching { node.recycle() } }

    private fun refreshTyped(node: AccessibilityNodeInfo?, st: State) {
        if (st.typedTransitions == null) return
        if (node == null || Thread.currentThread().isInterrupted || SystemClock.uptimeMillis() > st.deadline) {
            st.typedFresh = false
            return
        }
        val refreshed = try { node.refresh() } catch (_: Exception) { false }
        if (!refreshed || Thread.currentThread().isInterrupted || SystemClock.uptimeMillis() > st.deadline)
            st.typedFresh = false
    }

    private fun convert(node: AccessibilityNodeInfo, depth: Int, st: State, refresh: Boolean = true): UiNode? {
        if (refresh) refreshTyped(node, st)
        if (!node.isVisibleToUser) { release(node); return null }
        node.getBoundsInScreen(st.rect)
        val bounds = Box(st.rect.left, st.rect.top, st.rect.right, st.rect.bottom)
        val ref = st.natives.size
        st.natives += node
        st.count++

        val rawChildren = node.childCount
        val children = ArrayList<UiNode>(rawChildren)
        if (depth < MAX_DEPTH) {
            for (i in 0 until rawChildren) {
                if (st.count >= MAX_NODES || SystemClock.uptimeMillis() > st.deadline) { st.truncated = true; break }
                val child = try { node.getChild(i) } catch (_: Throwable) { null }
                if (child == null) {
                    st.visualComplete = false
                    st.partial = true
                    continue
                }
                convert(child, depth + 1, st)?.let(children::add)
            }
        } else if (rawChildren > 0) st.truncated = true

        var scroll = 0
        if (node.isScrollable) for (action in node.actionList) scrollIds[action.id]?.let { scroll = scroll or it }
        val extras = try { node.extras } catch (_: Throwable) { null }
        val roleHint = (extras?.getCharSequence("AccessibilityNodeInfo.roleDescription")
            ?: extras?.getCharSequence("AccessibilityNodeInfo.chromeRole"))?.toString()?.lowercase()
        val range = node.rangeInfo
        return UiNode(
            ref = ref,
            className = node.className?.toString().orEmpty(),
            text = node.text?.toString(),
            desc = node.contentDescription?.toString(),
            hint = if (Build.VERSION.SDK_INT >= 26) node.hintText?.toString() else null,
            viewId = node.viewIdResourceName,
            bounds = bounds,
            clickable = node.isClickable,
            longClickable = node.isLongClickable,
            editable = node.isEditable,
            scrollable = node.isScrollable,
            checkable = node.isCheckable,
            checked = @Suppress("DEPRECATION") node.isChecked,
            selected = node.isSelected,
            focused = node.isFocused,
            enabled = node.isEnabled,
            password = node.isPassword,
            heading = Build.VERSION.SDK_INT >= 28 && node.isHeading,
            showingHint = Build.VERSION.SDK_INT >= 26 && node.isShowingHintText,
            scroll = scroll,
            roleHint = roleHint,
            stateDesc = if (Build.VERSION.SDK_INT >= 30) node.stateDescription?.toString() else null,
            rangeCurrent = range?.current,
            rangeMax = range?.max,
            children = children,
            rawChildCount = rawChildren,
            actionClick = node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK },
        )
    }
}
