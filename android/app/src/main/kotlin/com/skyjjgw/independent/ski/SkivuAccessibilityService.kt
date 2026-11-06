package com.skyjjgw.independent.ski

import android.accessibilityservice.AccessibilityService
import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.util.UUID

/** Built-in observation/input backend. Never exposes the controller's own UI. */
class SkivuAccessibilityService : AccessibilityService() {
    companion object { @Volatile var connected: SkivuAccessibilityService? = null }
    private val nodes = mutableMapOf<String, AccessibilityNodeInfo>()
    private var observation = ""
    private var observedPackage = ""
    private var observedWindow = -1
    private var observedAt = 0L

    override fun onServiceConnected() { connected = this }
    override fun onInterrupt() { clearObservation() }
    override fun onDestroy() {
        if (connected === this) connected = null
        clearObservation()
        super.onDestroy()
    }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            event.packageName?.toString() != observedPackage) clearObservation()
    }

    private fun clearObservation() {
        nodes.values.forEach { @Suppress("DEPRECATION") it.recycle() }
        nodes.clear()
        observation = ""
    }

    private fun current(allowed: Set<String>): AccessibilityNodeInfo {
        val root = rootInActiveWindow ?: error("当前没有可观察的界面。")
        val target = root.packageName?.toString().orEmpty()
        require(target != packageName && target in allowed) { "当前软件不在授权范围内。" }
        return root
    }

    fun observe(allowed: Set<String>): Map<String, Any?> {
        clearObservation()
        val root = current(allowed)
        observedPackage = root.packageName.toString()
        observedWindow = root.windowId
        observedAt = SystemClock.uptimeMillis()
        observation = UUID.randomUUID().toString()
        val rows = mutableListOf<Map<String, Any?>>()
        fun walk(node: AccessibilityNodeInfo, parent: String?, depth: Int) {
            if (rows.size >= 160 || depth > 24 || !node.isVisibleToUser) return
            val id = "n_${rows.size}"
            val bounds = Rect().also { node.getBoundsInScreen(it) }
            val secret = node.isPassword
            @Suppress("DEPRECATION")
            nodes[id] = AccessibilityNodeInfo.obtain(node)
            rows += mapOf(
                "id" to id, "parentId" to parent,
                "text" to if (secret) "" else node.text?.toString()?.take(500).orEmpty(),
                "description" to if (secret) "" else node.contentDescription?.toString()?.take(300).orEmpty(),
                "viewId" to node.viewIdResourceName.orEmpty(),
                "class" to node.className?.toString().orEmpty(),
                "password" to secret, "editable" to node.isEditable,
                "enabled" to node.isEnabled, "checkable" to node.isCheckable,
                "checked" to node.isChecked, "selected" to node.isSelected,
                "clickable" to node.isClickable, "scrollable" to node.isScrollable,
                "bounds" to listOf(bounds.left, bounds.top, bounds.right, bounds.bottom)
            )
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                walk(child, id, depth + 1)
                @Suppress("DEPRECATION") child.recycle()
            }
        }
        walk(root, null, 0)
        @Suppress("DEPRECATION") root.recycle()
        return mapOf("observationId" to observation, "package" to observedPackage,
            "windowId" to observedWindow, "elements" to rows)
    }

    fun act(tool: String, args: Map<String, Any?>, allowed: Set<String>, beforeDispatch: () -> Unit): Boolean {
        val root = current(allowed)
        val matches = root.packageName?.toString() == observedPackage && root.windowId == observedWindow
        @Suppress("DEPRECATION") root.recycle()
        if (tool == "ui.back" || tool == "ui.home") {
            require(args.isEmpty()) { "界面动作参数无效。" }
            clearObservation()
            beforeDispatch()
            return performGlobalAction(if (tool == "ui.back") GLOBAL_ACTION_BACK else GLOBAL_ACTION_HOME)
        }
        require(observation.isNotEmpty() && args["observationId"] == observation && matches &&
            SystemClock.uptimeMillis() - observedAt < 60_000) { "界面观察已过期，请重新观察。" }
        val node = nodes[args["elementId"]] ?: error("当前观察中没有这个控件。")
        require(node.refresh() && node.isVisibleToUser && !node.isPassword) { "控件已变化或是密码字段，请重新观察。" }
        val keys = when (tool) {
            "ui.input" -> setOf("observationId", "elementId", "text")
            "ui.scroll" -> setOf("observationId", "elementId", "direction")
            else -> setOf("observationId", "elementId")
        }
        require(args.keys == keys) { "界面动作参数无效。" }
        // Android permission management is always a host/user authorization flow.
        require(observedPackage !in setOf("com.android.settings", "com.android.permissioncontroller", "com.google.android.permissioncontroller")) {
            "系统权限管理页面由用户操作；请使用明确的系统接口修改设置。"
        }
        val result = when (tool) {
            "ui.tap" -> { beforeDispatch(); node.performAction(AccessibilityNodeInfo.ACTION_CLICK) }
            "ui.input" -> {
                val text = args["text"] as? String ?: error("缺少输入文字。")
                require(text.length <= 12000 && !text.contains('\u0000') && node.isEditable)
                beforeDispatch()
                node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                })
            }
            "ui.scroll" -> {
                require(args["direction"] in listOf("forward", "backward"))
                beforeDispatch()
                node.performAction(if (args["direction"] == "forward") AccessibilityNodeInfo.ACTION_SCROLL_FORWARD else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
            }
            else -> error("不支持的界面操作。")
        }
        clearObservation()
        return result
    }
}
