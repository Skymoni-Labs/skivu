// Portions derived from Libraries.dev Border beam (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

package com.skyjjgw.independent.ski.dshgo.phone.a11y

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

// The screen-edge beam's pure half (EdgeBeamModelTest): the Border beam `md` type (the Dart port
// is app/lib/ui/fx/beam) with its numbers, scaled from a card to the whole screen. EdgeBeam.kt
// draws what these decide.

/** The `md` type's tables and presets (styles.ts), and how they scale to a screen. */
internal object EdgeBeamSpec {
    /** `colorPalettes[*].border`: x and y as fractions of the box, radii in dp. */
    val BLOBS = arrayOf(
        floatArrayOf(0.33f, -0.074f, 70f, 40f),
        floatArrayOf(0.12f, -0.05f, 60f, 35f),
        floatArrayOf(0.021f, 0.683f, 40f, 70f),
        floatArrayOf(0.021f, 0.683f, 20f, 35f),
        floatArrayOf(0.744f, 1f, 180f, 32f),
        floatArrayOf(0.55f, 1f, 85f, 26f),
        floatArrayOf(0.939f, 0f, 74f, 32f),
        floatArrayOf(1f, 0.271f, 26f, 42f),
        floatArrayOf(1f, 0.271f, 52f, 48f),
    )

    /** The inner glow's blobs: the border's at 90 % size (rounded) and a flat alpha. */
    const val INNER_SIZE = 0.9f
    const val INNER_ALPHA = 0.45f

    /** Conic stops: positions (fractions of a turn from the beam angle) and alphas. */
    val WINDOW_POS = floatArrayOf(0f, 0.30f, 0.36f, 0.44f, 0.52f, 0.80f, 0.86f, 0.92f, 0.95f, 1f)
    val WINDOW_ALPHA = floatArrayOf(0f, 0f, 0.1f, 0.35f, 1f, 1f, 0.35f, 0.1f, 0f, 0f)
    val WHITE_POS = floatArrayOf(0f, 0.54f, 0.57f, 0.60f, 0.63f, 0.66f, 0.69f, 0.72f, 0.75f, 0.78f, 1f)
    val WHITE_ALPHA_DARK = floatArrayOf(0f, 0f, 0.1f, 0.3f, 0.6f, 0.75f, 0.6f, 0.3f, 0.1f, 0f, 0f)
    val WHITE_ALPHA_LIGHT = floatArrayOf(0f, 0f, 0.08f, 0.2f, 0.4f, 0.55f, 0.4f, 0.2f, 0.08f, 0f, 0f)
    val BLOOM_POS = floatArrayOf(0f, 0.58f, 0.62f, 0.65f, 0.67f, 0.69f, 0.70f, 0.705f, 0.715f, 0.73f, 0.75f, 0.78f, 0.82f, 1f)
    val BLOOM_ALPHA_DARK = floatArrayOf(0f, 0f, 0.03f, 0.08f, 0.2f, 0.45f, 0.85f, 0.85f, 0.45f, 0.2f, 0.08f, 0.03f, 0f, 0f)
    val BLOOM_ALPHA_LIGHT = floatArrayOf(0f, 0f, 0.02f, 0.08f, 0.2f, 0.4f, 0.6f, 0.6f, 0.4f, 0.2f, 0.08f, 0.02f, 0f, 0f)

    /** `sizeThemePresets.md`: layer opacities, the inset shadow, the filter. */
    class Preset(val stroke: Float, val inner: Float, val bloom: Float, val shadow: Int, val saturation: Float, val brightness: Float = 1.3f)

    val DARK = Preset(stroke = 0.26f, inner = 0.42f, bloom = 0.24f, shadow = 0x45FFFFFF, saturation = 1.2f)
    val LIGHT = Preset(stroke = 0.12f, inner = 0.26f, bloom = 0.34f, shadow = 0x24000000, saturation = 1.5f)

    /** The ring (`padding: 1px`), the inner glow's edge fade, the inset shadow, the bloom's blur, in dp. */
    const val RING_DP = 1f
    const val EDGE_FADE_DP = 28f
    const val SHADOW_BLUR_DP = 9f
    const val SHADOW_SPREAD_DP = 1f
    const val BLOOM_BLUR_DP = 8f

    /**
     * The bloom is the conic ring pattern blurred, then cut to the 1 px ring at the box's edge,
     * where the blur has half the pattern (transparent outside the box).
     */
    const val BLOOM_EDGE = 0.5f

    /** Fade in 0.6 s, out 0.5 s, CSS `ease`. */
    const val FADE_IN_MS = 600L
    const val FADE_OUT_MS = 500L

    /** Paused, or 移除动画: the beam settles into a still, faint outline, over this long. */
    const val STILL_MS = 500L

    /** The still outline: the ring's colours all round, at this share of the stroke's opacity. */
    const val OUTLINE = 0.6f

    /** ± degrees of hue drift over a 12 s ease-in-out ping-pong. */
    const val HUE_RANGE = 30
    const val HUE_PERIOD_S = 12.0

    /**
     * The author's beam rounds a 350×140 card in 1.96 s. A screen takes as much longer as its
     * perimeter is, and half again: a whole screen edge moving fast reads as an alarm.
     */
    const val CARD_LAP_S = 1.96
    const val CARD_PERIMETER_DP = 2 * (350f + 140f)
    const val CALM = 1.5
    const val LAP_MIN_S = 6.0
    const val LAP_MAX_S = 12.0

    /** The blobs are authored for a 350×140 element and scaled per axis (the author's pulse-outside rule). */
    const val REF_W_DP = 350f
    const val REF_H_DP = 140f
    const val SCALE_MIN = 0.35f
    const val SCALE_MAX = 4f

    /** Corner radius when the display does not report one (before Android 12). */
    const val CORNER_FALLBACK_DP = 28f

    /** One beam frame at most every this many ms: 60 fps on a 120 Hz screen. */
    const val FRAME_MS = 15L

    fun preset(dark: Boolean) = if (dark) DARK else LIGHT

    /** Seconds per lap round a screen [wDp] × [hDp]. */
    fun lapSeconds(wDp: Float, hDp: Float): Double =
        (CARD_LAP_S * (2 * (wDp + hDp)) / CARD_PERIMETER_DP * CALM).coerceIn(LAP_MIN_S, LAP_MAX_S)

    /** The blobs' scale on a screen [wDp] × [hDp], per axis, rounded to 3 decimals. */
    fun blobScale(wDp: Float, hDp: Float): Pair<Float, Float> {
        fun s(v: Float) = (v.coerceIn(SCALE_MIN, SCALE_MAX) * 1000).roundToInt() / 1000f
        return s(wDp / REF_W_DP) to s(hDp / REF_H_DP)
    }

    /** The display's corner radius in px, or the fallback. */
    fun cornerPx(reported: Int?, density: Float): Float =
        reported?.takeIf { it > 0 }?.toFloat() ?: (CORNER_FALLBACK_DP * density)
}

/** The theme palette: nine soft tones round the app's accent hue (BeamPalette.fromSeed in the Dart port). */
internal object EdgeBeamPalette {
    /** ARGB of the nine border colours for the accent [seed] (ARGB). */
    fun fromSeed(seed: Int): IntArray {
        val (hue, s, _) = hsl(seed)
        val sat = (s * 0.85f).coerceIn(0.4f, 0.6f)
        fun tone(shift: Float, s: Float, l: Float) = fromHsl(((hue + shift) % 360f + 360f) % 360f, s.coerceIn(0f, 1f), l)
        return intArrayOf(
            tone(0f, sat, 0.62f),
            tone(-24f, sat * 0.9f, 0.66f),
            tone(18f, sat, 0.6f),
            tone(-10f, sat * 1.1f, 0.58f),
            tone(32f, sat * 0.85f, 0.66f),
            tone(-36f, sat, 0.62f),
            tone(8f, sat * 0.9f, 0.7f),
            tone(-16f, sat, 0.6f),
            tone(26f, sat, 0.64f),
        )
    }

    /** Hue (0–360), saturation and lightness of an ARGB colour (Flutter's HSLColor.fromColor). */
    fun hsl(argb: Int): Triple<Float, Float, Float> {
        val r = (argb shr 16 and 0xFF) / 255f
        val g = (argb shr 8 and 0xFF) / 255f
        val b = (argb and 0xFF) / 255f
        val max = maxOf(r, g, b)
        val min = minOf(r, g, b)
        val delta = max - min
        val hue = when {
            max == 0f || delta == 0f -> 0f
            max == r -> 60f * ((((g - b) / delta) % 6f + 6f) % 6f)
            max == g -> 60f * ((b - r) / delta + 2f)
            else -> 60f * ((r - g) / delta + 4f)
        }
        val l = (max + min) / 2f
        val s = if (l == 1f) 0f else (delta / (1f - abs(2f * l - 1f))).coerceIn(0f, 1f)
        return Triple(hue, s, l)
    }

    /** Opaque ARGB from hue, saturation, lightness (Flutter's HSLColor.toColor). */
    fun fromHsl(hue: Float, s: Float, l: Float): Int {
        val chroma = (1f - abs(2f * l - 1f)) * s
        val secondary = chroma * (1f - abs((hue / 60f) % 2f - 1f))
        val match = l - chroma / 2f
        val (r, g, b) = when {
            hue < 60f -> Triple(chroma, secondary, 0f)
            hue < 120f -> Triple(secondary, chroma, 0f)
            hue < 180f -> Triple(0f, chroma, secondary)
            hue < 240f -> Triple(0f, secondary, chroma)
            hue < 300f -> Triple(secondary, 0f, chroma)
            else -> Triple(chroma, 0f, secondary)
        }
        fun ch(v: Float) = ((v + match) * 255f).roundToInt().coerceIn(0, 255)
        return (0xFF shl 24) or (ch(r) shl 16) or (ch(g) shl 8) or ch(b)
    }
}

/** CSS timing and filter maths shared by the beam. */
internal object BeamMath {
    /** y at progress [x] on a CSS cubic-bezier curve. */
    fun cubicBezier(x1: Double, y1: Double, x2: Double, y2: Double, x: Double): Double {
        if (x <= 0) return 0.0
        if (x >= 1) return 1.0
        var lo = 0.0
        var hi = 1.0
        var t = x
        repeat(30) {
            val mt = 1 - t
            val bx = 3 * mt * mt * t * x1 + 3 * mt * t * t * x2 + t * t * t
            if (bx < x) lo = t else hi = t
            t = (lo + hi) / 2
        }
        val mt = 1 - t
        return 3 * mt * mt * t * y1 + 3 * mt * t * t * y2 + t * t * t
    }

    fun ease(x: Double) = cubicBezier(0.25, 0.1, 0.25, 1.0, x)
    fun easeInOut(x: Double) = cubicBezier(0.42, 0.0, 0.58, 1.0, x)

    /** The ± [range] hue drift at [t] s: −r → +r → −r over [period], ease-in-out each half. */
    fun hueDrift(t: Double, range: Double, period: Double): Double {
        val p = ((t / period) % 1.0 + 1.0) % 1.0
        return if (p < 0.5) -range + 2 * range * easeInOut(p * 2) else range - 2 * range * easeInOut(p * 2 - 1)
    }

    /**
     * `hue-rotate(h) brightness(b) saturate(s)` as one 4×5 colour matrix (W3C feColorMatrix
     * maths, row-major, as android.graphics.ColorMatrix takes it).
     */
    fun filterMatrix(hueDegrees: Double, brightness: Double, saturation: Double): FloatArray {
        val rad = Math.toRadians(hueDegrees)
        val c = cos(rad)
        val s = sin(rad)
        val hue = doubleArrayOf(
            0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928,
            0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283,
            0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072,
        )
        val v = saturation
        val sat = doubleArrayOf(
            0.213 + 0.787 * v, 0.715 - 0.715 * v, 0.072 - 0.072 * v,
            0.213 - 0.213 * v, 0.715 + 0.285 * v, 0.072 - 0.072 * v,
            0.213 - 0.213 * v, 0.715 - 0.715 * v, 0.072 + 0.928 * v,
        )
        val m = FloatArray(20)
        for (row in 0 until 3) for (col in 0 until 3) {
            var sum = 0.0
            for (k in 0 until 3) sum += sat[row * 3 + k] * hue[k * 3 + col]
            m[row * 5 + col] = (sum * brightness).toFloat()
        }
        m[18] = 1f
        return m
    }
}

/** A value easing from [from] to [to] over [ms] from [start] (uptime ms), CSS `ease`. */
internal class BeamRamp(val from: Float, val to: Float, val start: Long, val ms: Long) {
    fun at(now: Long): Float {
        if (ms <= 0) return to
        val p = ((now - start).toDouble() / ms).coerceIn(0.0, 1.0)
        return (from + (to - from) * BeamMath.ease(p)).toFloat()
    }

    fun done(now: Long) = now - start >= ms

    companion object {
        fun still(v: Float) = BeamRamp(v, v, 0L, 0L)
    }
}

/**
 * What the beam shows from moment to moment: [fade] (0 off … 1 on, 0.6 s in, 0.5 s out),
 * [still] (0 the travelling beam … 1 the still outline, while paused or with 移除动画) and the
 * travelled [phase] in seconds, which slows to a stop as the beam goes still. Main thread, times
 * in uptime ms.
 */
internal class EdgeBeamClock(private val motion: Boolean) {
    private var fade = BeamRamp.still(0f)
    private var still = BeamRamp.still(if (motion) 0f else 1f)
    private var last = -1L

    var phase = 0.0
        private set

    /** Wanted on (a task's control shows) or off. */
    fun show(on: Boolean, now: Long) {
        val target = if (on) 1f else 0f
        if (fade.to == target) return
        fade = BeamRamp(fade.at(now), target, now, if (!motion) 0 else if (on) EdgeBeamSpec.FADE_IN_MS else EdgeBeamSpec.FADE_OUT_MS)
    }

    /** Paused: the beam settles into the outline; resumed: it travels again. */
    fun pause(paused: Boolean, now: Long) {
        val target = if (paused || !motion) 1f else 0f
        if (still.to == target) return
        still = BeamRamp(still.at(now), target, now, if (motion) EdgeBeamSpec.STILL_MS else 0)
    }

    /** The fade and the stillness at the last [frame]. */
    var fadeNow = 0f
        private set
    var stillNow = if (motion) 0f else 1f
        private set

    /** Advances to [now]: [fadeNow], [stillNow], and [phase] on by the time the beam was travelling. */
    fun frame(now: Long) {
        stillNow = still.at(now)
        fadeNow = fade.at(now)
        if (last >= 0) phase += (now - last).coerceIn(0, 100) / 1000.0 * (1f - stillNow)
        last = now
    }

    /** A frame break (hidden, no frames asked for): the next frame doesn't count the gap. */
    fun rest() { last = -1L }

    /** Frames are needed: something ramps, or the beam is on and travelling. */
    fun animating(now: Long): Boolean =
        !fade.done(now) || !still.done(now) || (motion && fade.to > 0f && still.to < 1f)

    /** Faded out completely. */
    fun gone(now: Long): Boolean = fade.to == 0f && fade.done(now)
}
