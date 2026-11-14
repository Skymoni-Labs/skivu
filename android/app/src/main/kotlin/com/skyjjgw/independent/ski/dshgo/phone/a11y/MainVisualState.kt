package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.phone.VisualScope

/** Short memory only: neither this monitor nor its callers invoke Driver/Tasks/UI under it. */
internal class MainVisualState(private val driverEpoch: Any) {
    private var current: VisualScope.Main? = null
    private var published: Pair<String, VisualScope.Main?>? = null
    private var imageId: String? = null
    private var accepted = false
    /** Window transitions reported by accessibility events; no capture needed, known scope or not. */
    private var transitions = 0L

    @Synchronized fun observed(windowId: Int?, packageName: String?): VisualScope.Main? {
        if (windowId == null || windowId < 0 || packageName.isNullOrBlank()) current = null
        else if (current?.windowId != windowId || current?.packageName != packageName)
            current = VisualScope.Main(driverEpoch, Any(), windowId, packageName)
        return current
    }
    @Synchronized fun publish(id: String) {
        published = id to current
        imageId = null
        accepted = false
    }
    @Synchronized fun scope(id: String): VisualScope.Main? =
        published?.takeIf { it.first == id && it.second === current }?.second
    @Synchronized fun isCurrent(scope: VisualScope.Main?, transitions: Long): Boolean =
        current === scope && this.transitions == transitions
    @Synchronized fun transitions(): Long = transitions
    /**
     * Any window shown after a screenshot retires its coordinates: the agent must look again. The
     * scope (and so the per-app visual permission) survives; only a different observed window renews it.
     */
    @Synchronized fun windowChanged() { transitions++; imageId = null; accepted = false }
    @Synchronized fun candidate(id: String, capturedTransitions: Long): Boolean {
        if (published?.first != id || transitions != capturedTransitions) return false
        imageId = id
        accepted = false
        return true
    }
    @Synchronized fun accept(id: String) { if (imageId == id && published?.first == id) accepted = true }
    @Synchronized fun imageAccepted(id: String): Boolean = accepted && imageId == id && published?.first == id
    @Synchronized fun consume(id: String): Boolean {
        if (!imageAccepted(id)) return false
        imageId = null; accepted = false
        return true
    }
    @Synchronized fun invalidate() {
        current = null; published = null; imageId = null; accepted = false
    }
}
