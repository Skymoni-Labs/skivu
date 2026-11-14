package com.skyjjgw.independent.ski.dshgo.phone.a11y

/** Distinguishes an empty layout shell from a text-poor but usable view. */
internal object WindowContent {
    enum class RootGap { FRONT, PARTIAL }

    /** A missing lower root must not hide an already readable dialog. */
    fun rootGap(readableWindows: List<UiWindow>): RootGap =
        if (readableWindows.isEmpty()) RootGap.FRONT else RootGap.PARTIAL

    fun unavailable(hidden: Boolean, unreadable: Boolean, windows: List<UiWindow>): Boolean =
        hidden || unreadable || windows.isEmpty()

    fun usable(root: UiNode?): Boolean {
        if (root == null) return false
        if (root.bounds.isEmpty) return root.children.any(::usable)
        if (!root.text.isNullOrBlank() || !root.desc.isNullOrBlank() || !root.hint.isNullOrBlank() ||
            root.clickable || root.longClickable || root.editable || root.scrollable || root.checkable ||
            root.rangeCurrent != null
        ) return true
        if (root.children.any(::usable)) return true
        // SurfaceView / TextureView and custom canvas leaves can still be used through an image.
        // Generic View and layout leaves alone are what filtered subtrees leave behind.
        val cls = root.className.substringAfterLast('.')
        if (root.children.isNotEmpty() || cls.isEmpty() || cls == "View" || cls == "ViewGroup" ||
            cls == "DecorView" || cls == "ComposeView" || cls == "AndroidComposeView" || cls.endsWith("Layout")
        ) return false
        if (cls.endsWith("SurfaceView") || cls == "TextureView" || cls.endsWith("WebView") || cls == "ImageView") return true
        return !root.className.startsWith("android.") && !root.className.startsWith("androidx.") &&
            !root.className.startsWith("com.android.")
    }

    /** Absence of the IME is only known after a successful, nonempty window enumeration. */
    fun keyboardShown(windowTypes: List<Int>?, inputMethodType: Int): Boolean? =
        windowTypes?.takeIf { it.isNotEmpty() }?.any { it == inputMethodType }
}

internal object ScreenshotClock {
    /** Android ScreenshotResult.timestamp and uptimeMillis share the millisecond uptime clock. */
    fun wallTime(timestamp: Long, uptimeMillis: Long, wallTimeMillis: Long): Long =
        wallTimeMillis - (uptimeMillis - timestamp)
}
