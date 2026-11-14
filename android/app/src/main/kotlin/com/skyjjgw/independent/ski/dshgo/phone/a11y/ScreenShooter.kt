// Portions derived from Phase (https://github.com/CikeSeven/phase), used with the author's permission. See THIRD_PARTY_NOTICES.md.
// Local changes: blocking with a timeout; API 30–33 full-display capture with the overlay
// hidden; element numbers drawn on the image; near-black frames treated as secure; JPEG, long
// side ≤ 1300 px.

package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.accessibilityservice.AccessibilityService
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Build
import android.os.SystemClock
import android.view.Display
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.roundToInt

internal class Shot(
    val bytes: ByteArray?, val mime: String?, val geometry: ImageGeometry?, val secure: Boolean, val error: String?,
    /** When the system took the frame (device clock, ms), from [AccessibilityService.ScreenshotResult.getTimestamp]. */
    val takenAtMillis: Long? = null,
    val observation: ImageObservation? = null,
    val localText: LocalOcrResult = LocalOcrResult.Unavailable(LocalOcrResult.Reason.NO_FRAME),
    val rawWidth: Int = 0,
    val rawHeight: Int = 0,
    val viewport: com.skyjjgw.independent.ski.dshgo.phone.VisualBounds? = null,
    /** Actual window API target; null denotes the display API when a frame was returned. */
    val capturedWindowId: Int? = null,
    /** This capture's successful UI hide receipt; not a compositor/frame acknowledgement. */
    val hiddenOverlayWindowIds: Set<Int> = emptySet(),
) {
    /** Geometry and raw dimensions travel together even when no JPEG was requested. */
    fun visualText(): LocalOcrVisual.Output? {
        val imageGeometry = geometry ?: return null
        val rawViewport = viewport ?: return null
        return LocalOcrVisual.format(localText, rawWidth, rawHeight, rawViewport, imageGeometry)
    }
}

internal class ScreenShooter(private val service: AccessibilityService, private val overlay: ControlOverlay,
    private val localOcr: LocalOcr = NoLocalOcr) {
    /** Querying an absent backend must not capture a frame just to report its absence. */
    fun localTextWithoutFrame(): LocalOcrResult = LocalOcrResult.Unavailable(
        localOcr.unavailableReason ?: LocalOcrResult.Reason.NO_FRAME)
    private val captureLock = Any()
    private var closed = false
    private val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-a11y-shot") }
    private val callbackExecutor = Executor { callback ->
        try {
            executor.execute(callback)
        } catch (e: RejectedExecutionException) {
            if (!synchronized(captureLock) { closed }) throw e
            // The system still owns pending callbacks after close. They only release their
            // buffer now; rejecting them can also strand the framework's callback entry.
            callback.run()
        }
    }

    fun close() {
        synchronized(captureLock) { closed = true }
        executor.shutdown() // drain already queued callbacks so their buffers are closed
    }

    /**
     * Captures [window] with the API 34+ window API, or the display after the controls' hide
     * operation completes. UI completion is not a compositor ACK. Greys out [secrets] (see
     * [secretFieldBounds]) and draws [marks].
     */
    fun shoot(window: UiWindow?, screen: Box, marks: List<ScreenElement>, secrets: List<Box>, timeoutMs: Long, image: Boolean = true,
        readLocalText: Boolean = false, localTextPrivacyAllowed: Boolean = false,
        localTextCancelled: () -> Boolean = { false }): Shot {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        // l10n:keep agent screenshot result
        if (Build.VERSION.SDK_INT < 30) return Shot(null, null, null, false, "本机系统低于 Android 11，不支持无障碍截图")
        val useWindow = Build.VERSION.SDK_INT >= 34 && window != null
        var hiddenOverlayWindowIds: Set<Int> = emptySet()
        val raw = if (useWindow) capture(timeoutMs) { cb -> service.takeScreenshotOfWindow(window.id, callbackExecutor, cb) }
        else {
            try {
                hiddenOverlayWindowIds = overlay.hideForCaptureWithReceipt()
                    ?: return Shot(null, null, null, false, "截图前悬浮控件隐藏未完成，请稍后重新观察。") // l10n:keep agent screenshot result
                capture(timeoutMs) { cb -> service.takeScreenshot(Display.DEFAULT_DISPLAY, callbackExecutor, cb) }
            } finally { overlay.hideForCapture(false) }
        }
        // l10n:keep agent screenshot result
        if (raw.secure) return Shot(null, null, null, true, "此页面禁止截图（安全窗口）")
        // l10n:keep agent screenshot result
        val bitmap = raw.bitmap ?: return Shot(null, null, null, false, raw.error ?: "截图失败")
        try {
            // l10n:keep agent screenshot result
            if (looksBlack(bitmap)) return Shot(null, null, null, true, "截图全黑，可能是禁止截图的页面")
            val cancelled = { Thread.currentThread().isInterrupted || localTextCancelled() ||
                synchronized(captureLock) { closed } }
            val localText = LocalOcrBoundary.read(readLocalText, localTextPrivacyAllowed,
                bitmap.width, bitmap.height, deadline, SystemClock::uptimeMillis, cancelled) {
                localOcr.recognize(bitmap, deadline, cancelled)
            }
            val takenAt = raw.takenAtMillis
            val origin = if (useWindow) window.bounds else screen
            val frame = VisualFrame.capture(bitmap.width, bitmap.height) { y, row ->
                bitmap.getPixels(row, 0, bitmap.width, 0, y, bitmap.width, 1)
            }
            val factor = minOf(1f, 1300f / max(bitmap.width, bitmap.height))
            val w = (bitmap.width * factor).roundToInt().coerceAtLeast(1)
            val h = (bitmap.height * factor).roundToInt().coerceAtLeast(1)
            val sx = w.toFloat() / origin.width.coerceAtLeast(1)
            val sy = h.toFloat() / origin.height.coerceAtLeast(1)
            val geometry = ImageGeometry(origin.left, origin.top, sx, sy, w, h)
            val observation = ImageObservation(geometry, raw.capturedUptimeMs, frame)
            val viewport = com.skyjjgw.independent.ski.dshgo.phone.VisualBounds(origin.left, origin.top, origin.right, origin.bottom)
            if (!image) return Shot(null, null, geometry, false, null, takenAt, observation,
                localText, bitmap.width, bitmap.height, viewport,
                capturedWindowId = if (useWindow) window.id else null,
                hiddenOverlayWindowIds = hiddenOverlayWindowIds)
            var scaled = if (factor < 1f) Bitmap.createScaledBitmap(bitmap, w, h, true) else bitmap
            if (scaled === bitmap || !scaled.isMutable) {
                val mutable = scaled.copy(Bitmap.Config.ARGB_8888, true)
                if (scaled !== bitmap) scaled.recycle()
                scaled = mutable
            }
            try {
                draw(scaled, marks, secrets, origin, sx, sy)
                val out = ByteArrayOutputStream()
                scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
                return Shot(out.toByteArray(), "image/jpeg", geometry, false, null, takenAt,
                    observation, localText, bitmap.width, bitmap.height, viewport,
                    capturedWindowId = if (useWindow) window.id else null,
                    hiddenOverlayWindowIds = hiddenOverlayWindowIds)
            } finally { scaled.recycle() }
        } finally { bitmap.recycle() }
    }

    private class Raw(val bitmap: Bitmap?, val secure: Boolean, val error: String?, val takenAtMillis: Long? = null, val capturedUptimeMs: Long = 0)

    private fun capture(timeoutMs: Long, start: (AccessibilityService.TakeScreenshotCallback) -> Unit): Raw {
        if (Build.VERSION.SDK_INT < 30) return Raw(null, false, "unsupported")
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        repeat(2) { attempt ->
            val latch = CountDownLatch(1)
            var accepting = true
            var result: Raw? = null
            var tooSoon = false
            fun publish(next: Raw, retry: Boolean = false) {
                val accepted = synchronized(captureLock) {
                    if (accepting && !closed) {
                        result = next
                        tooSoon = retry
                        true
                    } else false
                }
                if (!accepted) next.bitmap?.recycle()
            }
            val callback = object : AccessibilityService.TakeScreenshotCallback {
                override fun onSuccess(screenshot: AccessibilityService.ScreenshotResult) {
                    val buffer = screenshot.hardwareBuffer
                    try {
                        if (!synchronized(captureLock) { accepting && !closed }) return
                        val next = try {
                            val hardware = Bitmap.wrapHardwareBuffer(buffer, screenshot.colorSpace)
                            val software = try { hardware?.copy(Bitmap.Config.ARGB_8888, false) }
                            finally { hardware?.recycle() }
                            // l10n:keep agent screenshot result
                            // ScreenshotResult.getTimestamp(): milliseconds on the uptime clock.
                            val wallClock = ScreenshotClock.wallTime(screenshot.timestamp, SystemClock.uptimeMillis(), System.currentTimeMillis())
                            Raw(software, false, if (software == null) "截图失败" else null, wallClock, screenshot.timestamp)
                        } catch (_: Throwable) {
                            // l10n:keep agent screenshot result
                            Raw(null, false, "截图失败")
                        }
                        publish(next)
                    } finally {
                        buffer.close()
                        latch.countDown()
                    }
                }

                override fun onFailure(errorCode: Int) {
                    val secure = Build.VERSION.SDK_INT >= 34 && errorCode == AccessibilityService.ERROR_TAKE_SCREENSHOT_SECURE_WINDOW
                    // l10n:keep agent screenshot result
                    publish(Raw(null, secure, "截图失败（错误 $errorCode）"), errorCode == AccessibilityService.ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT)
                    latch.countDown()
                }
            }
            var received: Raw? = null
            var retry = false
            try {
                // l10n:keep agent screenshot result
                if (synchronized(captureLock) { closed }) return Raw(null, false, "截图失败")
                if (Thread.currentThread().isInterrupted) throw InterruptedException()
                start(callback)
                // l10n:keep agent screenshot result
                val remaining = deadline - SystemClock.uptimeMillis()
                if (remaining <= 0 || !latch.await(remaining, TimeUnit.MILLISECONDS)) return Raw(null, false, "截图超时")
                synchronized(captureLock) {
                    if (!closed) {
                        received = result
                        result = null // the caller now owns this bitmap
                        retry = tooSoon
                    }
                }
            } finally {
                val abandoned = synchronized(captureLock) {
                    accepting = false
                    result.also { result = null }
                }
                abandoned?.bitmap?.recycle()
            }
            // l10n:keep agent screenshot result
            if (!retry || attempt == 1) return received ?: Raw(null, false, "截图失败")
            // The retry shares the original budget, including the system interval wait.
            if (deadline - SystemClock.uptimeMillis() <= 1_050) return received ?: Raw(null, false, "截图超时")
            Thread.sleep(1_050)
        }
        // l10n:keep agent screenshot result
        return Raw(null, false, "截图失败")
    }

    /** ≥ 97% of a 32×32 sample near-black: a FLAG_SECURE layer blanked out of a display capture. */
    private fun looksBlack(bitmap: Bitmap): Boolean {
        var dark = 0
        val n = 32
        for (i in 0 until n) for (j in 0 until n) {
            val c = bitmap.getPixel((bitmap.width - 1) * i / (n - 1), (bitmap.height - 1) * j / (n - 1))
            if (max(Color.red(c), max(Color.green(c), Color.blue(c))) < 12) dark++
        }
        return dark >= n * n * 97 / 100
    }

    private fun draw(bitmap: Bitmap, marks: List<ScreenElement>, secrets: List<Box>, origin: Box, sx: Float, sy: Float) {
        val canvas = Canvas(bitmap)
        val grey = Paint().apply { color = Color.rgb(128, 128, 128) }
        for (b in secrets) {
            canvas.drawRect((b.left - origin.left) * sx, (b.top - origin.top) * sy, (b.right - origin.left) * sx, (b.bottom - origin.top) * sy, grey)
        }
        val outline = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 2f; color = Color.argb(200, 61, 90, 152) }
        val tag = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(230, 33, 50, 98) }
        val halo = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 1.5f; color = Color.WHITE }
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; textSize = 18f; typeface = Typeface.DEFAULT_BOLD }
        val metrics = text.fontMetrics
        for (e in marks) {
            if (e.kind == ElementKind.LIST) continue
            val r = RectF((e.bounds.left - origin.left) * sx, (e.bounds.top - origin.top) * sy, (e.bounds.right - origin.left) * sx, (e.bounds.bottom - origin.top) * sy)
            if (r.right <= 0 || r.bottom <= 0 || r.left >= bitmap.width || r.top >= bitmap.height) continue
            canvas.drawRect(r, outline)
            val label = e.id.toString()
            val tw = text.measureText(label) + 8f
            val th = metrics.descent - metrics.ascent + 2f
            val left = r.left.coerceIn(0f, bitmap.width - tw)
            val top = r.top.coerceIn(0f, bitmap.height - th)
            val box = RectF(left, top, left + tw, top + th)
            canvas.drawRoundRect(box, 4f, 4f, tag)
            canvas.drawRoundRect(box, 4f, 4f, halo)
            canvas.drawText(label, left + 4f, top + 1f - metrics.ascent, text)
        }
    }

}
