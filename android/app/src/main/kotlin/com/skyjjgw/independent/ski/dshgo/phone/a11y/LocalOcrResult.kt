package com.skyjjgw.independent.ski.dshgo.phone.a11y

/** Internal-only text and raw-image pixel bounds. None of these lines enter ScreenSnapshot. */
internal sealed interface LocalOcrResult {
    data class Line(val text: String, val left: Int, val top: Int, val right: Int, val bottom: Int,
        val confidence: Float? = null)
    data class Recognized(val lines: List<Line>) : LocalOcrResult
    data class Unavailable(val reason: Reason) : LocalOcrResult
    data class Failed(val reason: Failure) : LocalOcrResult
    enum class Reason { DISABLED, NOT_REQUESTED, NOT_INSTALLED, NO_FRAME, PRIVACY_UNVERIFIED, CANCELLED, DEADLINE }
    enum class Failure { ENGINE, INVALID_RESULT, RESULT_LIMIT }
}

/** The production borrowed-frame boundary. Unknown/empty/failed OCR never supplies safety evidence. */
internal object LocalOcrBoundary {
    private const val MAX_LINES = 256
    private const val MAX_TEXT_BYTES = 16 * 1024

    fun read(requested: Boolean, privacyAllowed: Boolean, width: Int, height: Int,
        deadlineUptimeMs: Long, clock: () -> Long, cancelled: () -> Boolean,
        recognize: () -> LocalOcrResult): LocalOcrResult {
        if (!requested) return LocalOcrResult.Unavailable(LocalOcrResult.Reason.NOT_REQUESTED)
        if (!privacyAllowed) return LocalOcrResult.Unavailable(LocalOcrResult.Reason.PRIVACY_UNVERIFIED)
        if (cancelled()) return LocalOcrResult.Unavailable(LocalOcrResult.Reason.CANCELLED)
        if (clock() >= deadlineUptimeMs) return LocalOcrResult.Unavailable(LocalOcrResult.Reason.DEADLINE)
        val result = try { recognize() }
        catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return LocalOcrResult.Unavailable(LocalOcrResult.Reason.CANCELLED)
        } catch (_: Exception) { return LocalOcrResult.Failed(LocalOcrResult.Failure.ENGINE) }
        if (cancelled()) return LocalOcrResult.Unavailable(LocalOcrResult.Reason.CANCELLED)
        if (clock() >= deadlineUptimeMs) return LocalOcrResult.Unavailable(LocalOcrResult.Reason.DEADLINE)
        if (result !is LocalOcrResult.Recognized) return result
        if (result.lines.size > MAX_LINES) return LocalOcrResult.Failed(LocalOcrResult.Failure.RESULT_LIMIT)
        var bytes = 0
        for (line in result.lines) {
            if (line.left < 0 || line.top < 0 || line.right <= line.left || line.bottom <= line.top ||
                line.right > width || line.bottom > height ||
                line.confidence?.let { !it.isFinite() || it !in 0f..1f } == true)
                return LocalOcrResult.Failed(LocalOcrResult.Failure.INVALID_RESULT)
            // Bound allocation before UTF-8 conversion, including multi-byte Chinese/emoji text.
            if (line.text.length > MAX_TEXT_BYTES) return LocalOcrResult.Failed(LocalOcrResult.Failure.RESULT_LIMIT)
            bytes += line.text.toByteArray(Charsets.UTF_8).size
            if (bytes > MAX_TEXT_BYTES) return LocalOcrResult.Failed(LocalOcrResult.Failure.RESULT_LIMIT)
        }
        return LocalOcrResult.Recognized(result.lines.toList())
    }

    /** Only fixed diagnostics leave this process. Even successful empty OCR is not a safe page. */
    fun message(result: LocalOcrResult): String = when (result) {
        // l10n:keep agent local OCR status, never interpolate recognized text
        is LocalOcrResult.Recognized -> "本机识别结果仅留在本机，未提供视觉元素；不能据此猜坐标，请 handoff。"
        // l10n:keep agent local OCR status
        is LocalOcrResult.Failed -> "本机文字识别失败或结果不完整，未提供视觉元素；请 handoff。"
        is LocalOcrResult.Unavailable -> when (result.reason) {
            // l10n:keep agent local OCR status
            LocalOcrResult.Reason.DISABLED -> "本机文字识别已关闭"
            // l10n:keep agent local OCR status
            LocalOcrResult.Reason.NOT_INSTALLED -> "本机文字识别后端尚未安装，未提供视觉元素；不能据此猜坐标，请 handoff。"
            // l10n:keep agent local OCR status
            LocalOcrResult.Reason.PRIVACY_UNVERIFIED -> "无法确认本屏的本机识别隐私边界，未识别文字；请 handoff。"
            // l10n:keep agent local OCR status
            else -> "本次本机文字识别不可用，未提供视觉元素；请 handoff。"
        }
    }
}
