package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.SensitiveWords
import com.skyjjgw.independent.ski.dshgo.phone.a11y.ImageObservation
import com.skyjjgw.independent.ski.dshgo.phone.a11y.VisualFrame

/** One local, privacy-qualified frame. Never serialized or used to authorize an input action. */
internal class BackgroundVisualObservation private constructor(
    private val scope: Scope,
    private val image: ImageObservation,
) {
    data class Window(val id: Int, val left: Int, val top: Int, val right: Int, val bottom: Int)
    // display is the actual VirtualDisplay instance, not a reusable numeric display id.
    data class Scope(val display: Any, val owner: String, val pkg: String, val window: Window)

    fun changeFrom(previous: BackgroundVisualObservation?, now: Long): String {
        if (previous == null || scope != previous.scope || !previous.image.sameViewportAs(image, now)) return "unavailable"
        return when (image.changeFrom(previous.image)) {
            VisualFrame.Change.CHANGED -> "changed"
            VisualFrame.Change.UNCHANGED -> "unchanged"
            VisualFrame.Change.UNAVAILABLE -> "unavailable"
        }
    }

    companion object {
        fun create(scope: Scope?, image: ImageObservation?, complete: Boolean,
            hasSecrets: Boolean, hasSensitive: Boolean, now: Long): BackgroundVisualObservation? {
            if (scope == null || image == null || !complete || hasSecrets || hasSensitive || !image.isFresh(now)) return null
            val window = scope.window
            if (window.id < 0 || window.right <= window.left || window.bottom <= window.top) return null
            return BackgroundVisualObservation(scope, image)
        }
    }
}

/** Only fixed peer values become agent text; an unknown/missing field preserves the old reply. */
internal fun backgroundVisualNote(value: Any?): String = when (value) {
    // l10n:keep agent action protocol
    "changed" -> "；与最近观察相比，画面有明显变化（不表示操作成功）"
    // l10n:keep agent action protocol
    "unchanged" -> "；与最近观察相比，未检测到明显画面变化（不表示操作失败，请勿据此重试）"
    // l10n:keep agent action protocol
    "unavailable" -> "；无法与最近观察比较画面（不表示操作失败，请勿据此重试）"
    else -> ""
}

/** Bound additional privacy work; an oversized field is unknown, never a truncated safe prefix. */
internal fun backgroundVisualSensitive(text: CharSequence?, description: CharSequence?, hint: CharSequence?, viewId: String?): Boolean {
    if (listOf(text, description, hint, viewId).any { (it?.length ?: 0) > 4096 }) return true
    return SensitiveWords.confirmHit(text?.toString(), viewId) != null ||
        SensitiveWords.confirmHit(description?.toString(), null) != null ||
        SensitiveWords.confirmHit(hint?.toString(), null) != null
}
