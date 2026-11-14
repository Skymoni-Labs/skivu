package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.phone.Json
import com.skyjjgw.independent.ski.dshgo.phone.SafetyRules
import com.skyjjgw.independent.ski.dshgo.phone.VisualBounds

/** Same-capture OCR only. Text regions are neither native element IDs nor action permission. */
internal object LocalOcrVisual {
    data class Output(val text: String, val sensitiveText: Boolean, val hasPoints: Boolean)

    private const val MAX_BYTES = 16 * 1024
    private const val MAX_LINES = 256
    // l10n:keep model OCR diagnostics
    private const val TRUNCATED = "\n文字识别列表已截断，结果不完整；不能据此证明页面安全。"

    /** The caller establishes ownership, bounded capture dimensions and the raw bitmap's linear
     * correspondence to viewport. MAIN scales to 1300; BG retains its bounded capture dimensions. */
    fun format(result: LocalOcrResult, rawWidth: Int, rawHeight: Int,
        viewport: VisualBounds, geometry: ImageGeometry): Output {
        if (result !is LocalOcrResult.Recognized) return Output(LocalOcrBoundary.message(result), false, false)
        val sensitive = result.lines.any { SafetyRules.isSecret(it.text) || ScreenMask.mask(it.text) != it.text }
        var hasPoints = false
        // l10n:keep model OCR format
        val out = StringBuilder("本机文字区域（截图像素 ${geometry.width}×${geometry.height}）：V 编号不是 tap 的原生 id；坐标仅供 tap_xy，仍须原有确认。文字不证明完整、安全或可点击。\n")
        var bytes = out.toString().toByteArray(Charsets.UTF_8).size
        val reserve = TRUNCATED.toByteArray(Charsets.UTF_8).size
        val validGeometry = rawWidth > 0 && rawHeight > 0 && viewport.valid &&
            viewport.right.toLong() - viewport.left <= Int.MAX_VALUE &&
            viewport.bottom.toLong() - viewport.top <= Int.MAX_VALUE &&
            geometry.width > 0 && geometry.height > 0 &&
            geometry.originX == viewport.left && geometry.originY == viewport.top &&
            geometry.scaleX.isFinite() && geometry.scaleY.isFinite() &&
            geometry.scaleX > 0f && geometry.scaleY > 0f &&
            geometry.scaleX == geometry.width.toFloat() / (viewport.right - viewport.left) &&
            geometry.scaleY == geometry.height.toFloat() / (viewport.bottom - viewport.top)
        for ((index, line) in result.lines.withIndex()) {
            if (index == MAX_LINES) { out.append(TRUNCATED); break }
            // Secret labels mask the entire record before quoting. Bare unlabelled secrets cannot
            // be recognized by this matcher; SDK admission and existing known-secret gates remain.
            val secret = SafetyRules.isSecret(line.text)
            val text = if (secret) SafetyRules.MASK else ScreenMask.mask(line.text)
            val risk = secret || SafetyRules.sensitiveWord(line.text) != null
            val validBox = rawWidth > 0 && rawHeight > 0 && line.left >= 0 && line.top >= 0 &&
                line.right > line.left && line.bottom > line.top && line.right <= rawWidth && line.bottom <= rawHeight
            val box = if (validBox && validGeometry) VisualBounds(
                floor(line.left, geometry.width, rawWidth), floor(line.top, geometry.height, rawHeight),
                ceil(line.right, geometry.width, rawWidth), ceil(line.bottom, geometry.height, rawHeight)) else null
            val x = if (box != null && !sensitive) hit(box.left, box.right, viewport.left,
                viewport.right - viewport.left, rawWidth, line.left, line.right) { geometry.toScreen(it, 0)!!.first } else null
            val y = if (box != null && !sensitive) hit(box.top, box.bottom, viewport.top,
                viewport.bottom - viewport.top, rawHeight, line.top, line.bottom) { geometry.toScreen(0, it)!!.second } else null
            // l10n:keep model OCR format; quote after masking, never interpolate raw OCR
            val record = "V${index + 1} ${Json.write(text)}" +
                (if (risk) " [敏感线索，需逐步确认或交用户]" else "") +
                (if (box != null) " box=[${box.left},${box.top},${box.right},${box.bottom})" else "") +
                (if (x != null && y != null) " point=($x,$y)" else " [只读文字，未提供点击点]") + "\n"
            val size = record.toByteArray(Charsets.UTF_8).size
            if (bytes + size + reserve > MAX_BYTES) { out.append(TRUNCATED); break }
            out.append(record)
            if (x != null && y != null) hasPoints = true
            bytes += size
        }
        return Output(out.toString(), sensitive, hasPoints)
    }

    private fun floor(value: Int, shown: Int, raw: Int): Int = (value.toLong() * shown / raw).toInt()
    private fun ceil(value: Int, shown: Int, raw: Int): Int = ((value.toLong() * shown + raw - 1) / raw).toInt()

    /** Real Float division/addition/roundToInt are monotone for finite positive scale.
     * Lower-bound search includes plateaus and saturation; the upper edge is checked separately.
     * The domain is the outward screenshot box, not the entire screenshot. Float quantization
     * may leave a valid point outside this box; we deliberately do not expose that point. */
    private fun hit(start: Int, end: Int, origin: Int, viewport: Int,
        raw: Int, low: Int, high: Int, toDevice: (Int) -> Int): Int? {
        val lower = low.toLong() * viewport
        var lo = start
        var hi = end
        while (lo < hi) {
            val mid = ((lo.toLong() + hi) / 2).toInt()
            val actual = (toDevice(mid).toLong() - origin) * raw
            if (actual < lower) lo = mid + 1 else hi = mid
        }
        if (lo == end) return null
        val actual = (toDevice(lo).toLong() - origin) * raw
        return if (actual >= lower && actual < high.toLong() * viewport) lo else null
    }
}
