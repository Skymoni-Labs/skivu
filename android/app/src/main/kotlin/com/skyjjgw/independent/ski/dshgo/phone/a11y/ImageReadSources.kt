package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.view.accessibility.AccessibilityWindowInfo

/** Known sources for the actual image scope, not an attestation of every captured pixel. */
internal object ImageReadSources {
    fun knownPackages(cap: Capture, shot: Shot, ownPackage: String): Set<String> {
        if (shot.bytes == null) return emptySet()
        val windowId = shot.capturedWindowId
        return buildSet {
            if (windowId != null) {
                // Use the actual window API target, never the SDK level or the top package.
                cap.imageWindows.filter { it.id == windowId }.forEach { window ->
                    window.packageName?.takeIf { it.isNotBlank() }?.let { add(it) }
                }
                cap.windows.filter { it.id == windowId }.forEach { window ->
                    window.packageName?.takeIf { it.isNotBlank() }?.let { add(it) }
                }
            } else {
                for (window in cap.imageWindows) {
                    val pkg = window.packageName?.takeIf { it.isNotBlank() } ?: continue
                    val hiddenControl = window.type == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY &&
                        pkg == ownPackage && window.id in shot.hiddenOverlayWindowIds
                    if (!hiddenControl) add(pkg)
                }
                // The same capture may have learned a package while reading its content root
                // after a metadata lookup failed. Content windows are APP/SYSTEM, not our overlay.
                cap.windows.forEach { window ->
                    window.packageName?.takeIf { it.isNotBlank() }?.let { add(it) }
                }
            }
        }
    }
}
