package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.VisualBounds
import com.skyjjgw.independent.ski.dshgo.phone.VisualScope

import com.skyjjgw.independent.ski.dshgo.phone.PhoneAppIdentity
import com.skyjjgw.independent.ski.dshgo.phone.a11y.ImageGeometry
import com.skyjjgw.independent.ski.dshgo.phone.a11y.ImageObservation
import com.skyjjgw.independent.ski.dshgo.phone.a11y.VisualFrame

/** The private coordinate operation accepts only this fixed grammar, never a display or script. */
internal data class BackgroundCoordinateRequest(
    val nonce: String, val gesture: String, val x: Int, val y: Int,
    val x2: Int? = null, val y2: Int? = null, val durationMs: Int = 400,
) {
    fun fits(width: Int, height: Int): Boolean = x in 0 until width && y in 0 until height &&
        (gesture != "swipe" || x2 != null && y2 != null && x2 in 0 until width && y2 in 0 until height)

    companion object {
        private val common = setOf(Proto.OP, Proto.OWNER, Proto.TARGET_IDENTITY_VERSION, Proto.PKG, Proto.TARGET_UID,
            Proto.BACKGROUND_COORDINATES, Proto.COORDINATE_OBSERVATION, Proto.GESTURE, Proto.X, Proto.Y)
        private val swipe = setOf(Proto.X2, Proto.Y2, Proto.DURATION_MS)
        fun parse(keys: Set<String>, value: (String) -> Any?): BackgroundCoordinateRequest? {
            if (value(Proto.OP) != Proto.OP_COORDINATE || value(Proto.BACKGROUND_COORDINATES) !is Int ||
                value(Proto.BACKGROUND_COORDINATES) != 1) return null
            val gesture = value(Proto.GESTURE) as? String ?: return null
            if (gesture !in setOf("tap", "long", "swipe") || !keys.containsAll(common) ||
                keys.any { it !in common && it != Proto.AFTER_LOCAL_VISUAL && (gesture != "swipe" || it !in swipe) }) return null
            if (!BackgroundAfterVisual.validRequest(Proto.OP_COORDINATE, Proto.AFTER_LOCAL_VISUAL in keys,
                    value(Proto.AFTER_LOCAL_VISUAL))) return null
            val nonce = (value(Proto.COORDINATE_OBSERVATION) as? String)?.takeIf { it.isNotEmpty() && it.length <= 128 } ?: return null
            val x = value(Proto.X) as? Int ?: return null
            val y = value(Proto.Y) as? Int ?: return null
            if (x < 0 || y < 0) return null
            if (gesture != "swipe") return BackgroundCoordinateRequest(nonce, gesture, x, y)
            val x2 = value(Proto.X2) as? Int ?: return null
            val y2 = value(Proto.Y2) as? Int ?: return null
            val duration = if (Proto.DURATION_MS in keys) value(Proto.DURATION_MS) as? Int ?: return null else 400
            if (x2 < 0 || y2 < 0 || duration !in 100..2000) return null
            return BackgroundCoordinateRequest(nonce, gesture, x, y, x2, y2, duration)
        }
    }
}

/** Independent from postverify's observation: this exact explicit image may authorize one action. */
internal class BackgroundCoordinateObservation private constructor(
    val nonce: String, val scope: Scope, val window: BackgroundVisualObservation.Window,
    val context: String, val image: ImageObservation,
) {
    data class Scope(val display: Any, val owner: String, val target: PhoneAppIdentity)
    private fun sameScope(current: Scope?): Boolean = current != null && scope.display === current.display &&
        scope.owner == current.owner && scope.target == current.target
    fun matches(current: Scope, window: BackgroundVisualObservation.Window?, context: String?,
                geometry: ImageGeometry, now: Long): Boolean =
        sameScope(current) && this.window == window && this.context == context &&
            image.geometry == geometry && image.isFresh(now)

    fun change(current: Scope?, window: BackgroundVisualObservation.Window?, after: ImageObservation?,
               safe: Boolean, now: Long): String {
        if (!safe || !sameScope(current) || this.window != window || after == null || !image.sameViewportAs(after, now)) return "unavailable"
        return when (after.changeFrom(image)) {
            VisualFrame.Change.CHANGED -> "changed"
            VisualFrame.Change.UNCHANGED -> "unchanged"
            VisualFrame.Change.UNAVAILABLE -> "unavailable"
        }
    }

    companion object {
        fun create(nonce: String, scope: Scope?, window: BackgroundVisualObservation.Window?, context: String?,
                   image: ImageObservation?, complete: Boolean, hasSecrets: Boolean, hasSensitive: Boolean,
                   now: Long): BackgroundCoordinateObservation? {
            if (scope == null || window == null || context == null || image == null ||
                !complete || hasSecrets || hasSensitive || !image.isFresh(now)) return null
            if (window.id < 0 || window.left < 0 || window.top < 0 || window.right <= window.left ||
                window.bottom <= window.top || window.right > image.geometry.width || window.bottom > image.geometry.height) return null
            return BackgroundCoordinateObservation(nonce, scope, window, context, image)
        }
    }
}

/** App-side candidate becomes actionable only when Core retains its image after final filtering. */
internal class BackgroundCoordinateImage {
    data class Receipt(val nonce: String, val width: Int, val height: Int) {
        companion object {
            fun parse(version: Any?, nonce: Any?, width: Any?, height: Any?): Receipt? {
                if (version !is Int || version != 1 || nonce !is String || nonce.isEmpty() || nonce.length > 128 ||
                    width !is Int || height !is Int || width <= 0 || height <= 0) return null
                return Receipt(nonce, width, height)
            }
        }
    }
    data class Result(val ok: Boolean, val attempted: Boolean, val change: String) {
        companion object {
            fun parse(expected: Receipt, target: PhoneAppIdentity, value: (String) -> Any?): Result? {
                if (Receipt.parse(value(Proto.BACKGROUND_COORDINATES), value(Proto.COORDINATE_OBSERVATION),
                        value(Proto.COORDINATE_WIDTH), value(Proto.COORDINATE_HEIGHT)) != expected) return null
                val attempted = value(Proto.ACTION_ATTEMPTED) as? Boolean ?: return null
                val ok = value(Proto.OK) as? Boolean ?: return null
                val identity = TargetIdentity.receipt(target, value(Proto.TARGET_IDENTITY_VERSION), value(Proto.PKG), value(Proto.TARGET_UID))
                if (ok && !attempted || !identity && !attempted) return null
                val change = (value(Proto.VISUAL_CHANGE) as? String)?.takeIf {
                    it in setOf("changed", "unchanged", "unavailable")
                } ?: "unavailable"
                // An already-attempted action cannot be erased by failed identity/postread evidence.
                return Result(ok && identity, attempted, if (ok && identity) change else "unavailable")
            }
        }
    }
    private var scopeScreen: String? = null
    private var scope: VisualScope.Background? = null
    private var targets: Map<Int, VisualBounds> = emptyMap()

    @Synchronized fun publishScope(screenId: String, known: Boolean, owner: String, target: PhoneAppIdentity?) {
        scopeScreen = screenId
        scope = if (!known || target == null) null else (scope?.takeIf { it.resourceOwner == owner && it.target == target }
            ?: VisualScope.Background(owner, target, Any()))
    }
    @Synchronized fun scope(screenId: String): VisualScope? = scope.takeIf { scopeScreen == screenId }
    @Synchronized fun invalidateScope() { scopeScreen = null; scope = null }
    @Synchronized fun targetAt(screenId: String, x: Int, y: Int): Int? =
        if (accepted && screen == screenId && scopeScreen == screenId && scope != null)
            targets.entries.singleOrNull { it.value.contains(x, y) }?.key else null

    companion object {
        fun targets(version: Any?, indices: Any?, bounds: Any?, count: Int, width: Int, height: Int): Map<Int, VisualBounds> {
            if (version !is Int || version != 1 || indices !is IntArray || bounds !is IntArray ||
                indices.size > 120 || bounds.size != indices.size * 4) return emptyMap()
            val viewport = VisualBounds(0, 0, width, height)
            val result = linkedMapOf<Int, VisualBounds>()
            for (i in indices.indices) {
                val id = indices[i]
                val box = VisualBounds(bounds[i * 4], bounds[i * 4 + 1], bounds[i * 4 + 2], bounds[i * 4 + 3])
                if (id !in 1..count || (i > 0 && id <= indices[i - 1]) || !viewport.contains(box) ||
                    result.values.any { it.overlaps(box) }) return emptyMap()
                result[id] = box
            }
            return result
        }
    }
    private var screen: String? = null
    private var receipt: Receipt? = null
    private var accepted = false
    @Synchronized fun candidate(screenId: String, value: Receipt?, eligible: Map<Int, VisualBounds> = emptyMap()) {
        screen = screenId; receipt = value; accepted = false; targets = eligible.toMap()
    }
    @Synchronized fun accept(screenId: String) { if (screen == screenId && receipt != null) accepted = true }
    @Synchronized fun take(screenId: String): Receipt? {
        val result = receipt.takeIf { accepted && screen == screenId }
        clear()
        return result
    }
    @Synchronized fun clear() { screen = null; receipt = null; accepted = false; targets = emptyMap() }
}
