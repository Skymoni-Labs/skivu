// ImageGeometry extracted from ScreenShooter.kt; its existing Phase attribution is retained.
// Portions derived from Phase (https://github.com/CikeSeven/phase), used with the author's permission. See THIRD_PARTY_NOTICES.md.
// Local changes: value equality for viewport checks, local change summary and monotonic expiry.

package com.skyjjgw.independent.ski.dshgo.phone.a11y

import kotlin.math.abs
import kotlin.math.roundToInt

/** Coordinates refer to the captured viewport, which may be a window rather than the display. */
internal data class ImageGeometry(val originX: Int, val originY: Int, val scaleX: Float, val scaleY: Float, val width: Int, val height: Int) {
    fun toScreen(x: Int, y: Int): Pair<Int, Int>? {
        if (x < 0 || y < 0 || x >= width || y >= height) return null
        return (originX + x / scaleX).roundToInt() to (originY + y / scaleY).roundToInt()
    }
}

/** A local change summary, computed before masking/numbering or JPEG encoding. Not a target match. */
internal class VisualFrame private constructor(
    private val width: Int,
    private val height: Int,
    private val samples: IntArray,
) {
    enum class Change { CHANGED, UNCHANGED, UNAVAILABLE }

    /** Small animation/caret changes do not establish a visible page change or task success. */
    fun changeFrom(other: VisualFrame): Change {
        if (width != other.width || height != other.height) return Change.UNAVAILABLE
        val changed = samples.indices.count { abs(samples[it] - other.samples[it]) >= 16 }
        return if (changed * 100 >= samples.size) Change.CHANGED else Change.UNCHANGED
    }

    companion object {
        private const val GRID = 48

        /** Reads at most GRID rows and retains only luminance samples, never a complete bitmap. */
        fun capture(width: Int, height: Int, readRow: (Int, IntArray) -> Unit): VisualFrame {
            val row = IntArray(width)
            val samples = IntArray(GRID * GRID)
            var lastY = -1
            for (sampleY in 0 until GRID) {
                val y = sampleY * height / GRID
                if (y != lastY) { readRow(y, row); lastY = y }
                for (x in 0 until GRID) {
                    val pixel = row[x * width / GRID]
                    samples[sampleY * GRID + x] = ((pixel ushr 16 and 255) * 77 +
                        (pixel ushr 8 and 255) * 150 + (pixel and 255) * 29) shr 8
                }
            }
            return VisualFrame(width, height, samples)
        }
    }
}

internal class ImageObservation(val geometry: ImageGeometry, val capturedUptimeMs: Long, val frame: VisualFrame) {
    fun isFresh(nowUptimeMs: Long): Boolean = nowUptimeMs - capturedUptimeMs in 0..TTL_MS

    /** Time and viewport only. The caller separately checks the existing tree/window context. */
    fun sameViewportAs(current: ImageObservation, nowUptimeMs: Long): Boolean =
        isFresh(nowUptimeMs) && current.isFresh(nowUptimeMs) &&
            current.capturedUptimeMs >= capturedUptimeMs && geometry == current.geometry

    fun changeFrom(previous: ImageObservation): VisualFrame.Change =
        if (geometry == previous.geometry) frame.changeFrom(previous.frame) else VisualFrame.Change.UNAVAILABLE

    companion object { const val TTL_MS = 30_000L }
}
