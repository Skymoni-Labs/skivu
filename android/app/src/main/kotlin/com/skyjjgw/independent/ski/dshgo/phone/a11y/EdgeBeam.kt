// Portions derived from Libraries.dev Border beam (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.content.Context
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.ColorMatrixColorFilter
import android.graphics.ComposeShader
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.PorterDuff
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.SweepGradient
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.Choreographer
import android.view.Gravity
import android.view.RoundedCorner
import android.view.View
import android.view.WindowManager
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * A beam of light round the screen's edge while DSH operates the phone: the Border beam `md`
 * type (docs/design/phone-overlay.md §12) on the display's own outline. Its own full-screen
 * TYPE_ACCESSIBILITY_OVERLAY window, never touchable or focusable, over the bars and the cutout,
 * added under the control's windows. [ControlOverlay] says when it is on, paused or hidden (every
 * screenshot and injected gesture); this class fades it, moves it and draws it.
 *
 * Drawn with android.graphics, every layer as one shader on one path: the inner glow is the blob
 * stack (RadialGradients, composed source-over) masked by the travelling conic window
 * (SweepGradient) and the 28 dp edge fade, the inset shadow a blurred path under the same masks,
 * the ring a stroked rounded path with the colours, the white highlight and the bloom. Per frame
 * only the sweeps' local matrix and the paints' alphas change.
 */
internal class EdgeBeam(private val context: Context, private val wm: WindowManager) {
    private val view = BeamView(context)
    private var clock = EdgeBeamClock(motion = true)
    private var scheduled = false
    private var drawnAt = 0L
    private var removeWhenGone = false

    val root: View get() = view
    val attached: Boolean get() = view.isAttachedToWindow

    private val params = WindowManager.LayoutParams(
        WindowManager.LayoutParams.MATCH_PARENT,
        WindowManager.LayoutParams.MATCH_PARENT,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        if (Build.VERSION.SDK_INT >= 28) {
            layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= 30) WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            else WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        if (Build.VERSION.SDK_INT >= 30) setFitInsetsTypes(0)
    }

    private val frame = Choreographer.FrameCallback { onFrame() }

    /** Adds the window, faded out, for a [dark] or light screen and the app's accent [seed]; false when refused. */
    fun attach(title: CharSequence, dark: Boolean, seed: Int, hidden: Boolean): Boolean {
        view.setLook(dark, seed)
        if (attached) return true
        clock = EdgeBeamClock(OverlayMotion.on())
        removeWhenGone = false
        view.show(0f, 1f, 0.0)
        view.visibility = if (hidden) View.INVISIBLE else View.VISIBLE
        params.title = title
        fitScreen()
        return try {
            wm.addView(view, params)
            true
        } catch (e: Exception) {
            Log.w(TAG, "edge beam addView failed", e)
            false
        }
    }

    /** [on]: a task's control shows; [paused]: the beam settles into its still outline. */
    fun set(on: Boolean, paused: Boolean) {
        if (!attached) return
        // A new task's control while the last one's beam was still fading out: it stays.
        if (on) removeWhenGone = false
        val now = SystemClock.uptimeMillis()
        clock.show(on, now)
        clock.pause(paused, now)
        schedule()
    }

    /** Not drawn at all (a screenshot or an injected gesture is under way). */
    fun setHidden(hidden: Boolean) {
        if (!attached) return
        val v = if (hidden) View.INVISIBLE else View.VISIBLE
        if (view.visibility == v) return
        view.visibility = v
        schedule()
    }

    /** Goes: faded out first when [animated], the window removed once it is. */
    fun detach(animated: Boolean) {
        if (!attached) return
        if (!animated) { remove(); return }
        clock.show(false, SystemClock.uptimeMillis())
        removeWhenGone = true
        schedule()
    }

    /** A rotation or a new display size. */
    fun relayout() {
        if (!attached) return
        fitScreen()
        try { wm.updateViewLayout(view, params) } catch (e: Exception) { Log.w(TAG, "edge beam update failed", e) }
    }

    /** The display's full size, bars and cutout included. */
    private fun fitScreen() {
        if (Build.VERSION.SDK_INT >= 30) {
            val b = wm.currentWindowMetrics.bounds
            params.width = b.width()
            params.height = b.height()
            if (Build.VERSION.SDK_INT >= 31) {
                val insets = wm.currentWindowMetrics.windowInsets
                fun r(pos: Int) = insets.getRoundedCorner(pos)?.radius
                view.corners = intArrayOf(
                    r(RoundedCorner.POSITION_TOP_LEFT) ?: 0, r(RoundedCorner.POSITION_TOP_RIGHT) ?: 0,
                    r(RoundedCorner.POSITION_BOTTOM_RIGHT) ?: 0, r(RoundedCorner.POSITION_BOTTOM_LEFT) ?: 0,
                )
            }
        } else {
            params.width = WindowManager.LayoutParams.MATCH_PARENT
            params.height = WindowManager.LayoutParams.MATCH_PARENT
        }
    }

    private fun remove() {
        if (scheduled) Choreographer.getInstance().removeFrameCallback(frame)
        scheduled = false
        removeWhenGone = false
        try { wm.removeView(view) } catch (_: Exception) {}
    }

    private fun schedule() {
        if (scheduled || !attached) return
        scheduled = true
        Choreographer.getInstance().postFrameCallback(frame)
    }

    private fun onFrame() {
        scheduled = false
        if (!attached) return
        val now = SystemClock.uptimeMillis()
        if (removeWhenGone && clock.gone(now)) { remove(); return }
        val animating = clock.animating(now)
        // 60 fps is plenty for a slow beam, also on a 120 Hz screen.
        if (!animating || now - drawnAt >= EdgeBeamSpec.FRAME_MS) {
            clock.frame(now)
            view.show(clock.fadeNow, clock.stillNow, clock.phase)
            drawnAt = now
        }
        if (animating) schedule() else clock.rest()
    }

    /** The beam itself; every shader is built once per size and look. */
    private class BeamView(context: Context) : View(context) {
        private var dark = true
        private var seed = 0
        private var looked = false
        private var fade = 0f
        private var still = 1f
        private var phase = 0.0
        private var lap = 8.0

        /** Display corner radii in px (TL, TR, BR, BL); 0 means not reported. */
        var corners = IntArray(4)
            set(value) {
                if (value.contentEquals(field)) return
                field = value
                if (width > 0) build(width, height)
            }

        /** Android 8.x draws composed shaders badly: the ring and its highlight only. */
        private val simple = Build.VERSION.SDK_INT < 28

        private val rotation = Matrix()
        private val band = Path()
        private val ring = Path()
        private val shadowPath = Path()
        private val innerPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val ringPaint = stroke()
        private val highlightPaint = stroke()
        private val bloomPaint = stroke()
        private val outlinePaint = stroke()
        private var sweeps: List<SweepGradient> = emptyList()
        private var hueFilters: Array<ColorMatrixColorFilter> = emptyArray()
        private var bloomFilter: ColorMatrixColorFilter? = null

        init {
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }

        private fun stroke() = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }

        fun setLook(dark: Boolean, seed: Int) {
            if (looked && dark == this.dark && seed == this.seed) return
            looked = true
            this.dark = dark
            this.seed = seed
            val p = EdgeBeamSpec.preset(dark)
            val range = EdgeBeamSpec.HUE_RANGE
            hueFilters = Array(2 * range + 1) { i ->
                ColorMatrixColorFilter(BeamMath.filterMatrix((i - range).toDouble(), p.brightness.toDouble(), p.saturation.toDouble()))
            }
            bloomFilter = ColorMatrixColorFilter(BeamMath.filterMatrix(0.0, p.brightness.toDouble(), p.saturation.toDouble()))
            if (width > 0) build(width, height)
            invalidate()
        }

        fun show(fade: Float, still: Float, phase: Double) {
            this.fade = fade
            this.still = still
            this.phase = phase
            invalidate()
        }

        override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
            if (w > 0 && h > 0) build(w, h)
        }

        private fun build(w: Int, h: Int) {
            val density = resources.displayMetrics.density
            val wDp = w / density
            val hDp = h / density
            lap = EdgeBeamSpec.lapSeconds(wDp, hDp)
            val (sx, sy) = EdgeBeamSpec.blobScale(wDp, hDp)
            val cx = w / 2f
            val cy = h / 2f
            val palette = EdgeBeamPalette.fromSeed(seed)

            // Outline paths on the display's own corners.
            val r = FloatArray(4) { EdgeBeamSpec.cornerPx(corners[it].takeIf { c -> c > 0 }, density) }
            val screen = RectF(0f, 0f, w.toFloat(), h.toFloat())
            val ringW = EdgeBeamSpec.RING_DP * density
            val fadeW = EdgeBeamSpec.EDGE_FADE_DP * density
            val spread = EdgeBeamSpec.SHADOW_SPREAD_DP * density
            val sigma = EdgeBeamSpec.SHADOW_BLUR_DP / 2f * density
            ring.reset()
            ring.addRoundRect(inset(screen, ringW / 2f), radii(r, ringW / 2f), Path.Direction.CW)
            band.reset()
            band.fillType = Path.FillType.EVEN_ODD
            band.addRoundRect(screen, radii(r, 0f), Path.Direction.CW)
            band.addRoundRect(inset(screen, fadeW), radii(r, fadeW), Path.Direction.CW)
            shadowPath.reset()
            shadowPath.fillType = Path.FillType.EVEN_ODD
            shadowPath.addRect(inset(screen, -4 * sigma), Path.Direction.CW)
            shadowPath.addRoundRect(inset(screen, spread), radii(r, spread), Path.Direction.CW)
            ringPaint.strokeWidth = ringW
            highlightPaint.strokeWidth = ringW
            bloomPaint.strokeWidth = ringW
            outlinePaint.strokeWidth = ringW

            val ink = if (dark) WHITE else BLACK
            val p = EdgeBeamSpec.preset(dark)
            val window = sweep(cx, cy, ink, EdgeBeamSpec.WINDOW_POS, EdgeBeamSpec.WINDOW_ALPHA, 1f)
            val highlight = sweep(cx, cy, ink, EdgeBeamSpec.WHITE_POS, if (dark) EdgeBeamSpec.WHITE_ALPHA_DARK else EdgeBeamSpec.WHITE_ALPHA_LIGHT, 1f)
            val bloom = sweep(cx, cy, ink, EdgeBeamSpec.BLOOM_POS, if (dark) EdgeBeamSpec.BLOOM_ALPHA_DARK else EdgeBeamSpec.BLOOM_ALPHA_LIGHT, 1f)
            highlightPaint.shader = highlight
            bloomPaint.shader = bloom
            if (simple) {
                ringPaint.shader = sweep(cx, cy, palette[0], EdgeBeamSpec.WINDOW_POS, EdgeBeamSpec.WINDOW_ALPHA, 1f)
                outlinePaint.shader = null
                outlinePaint.color = palette[0]
                sweeps = listOf(ringPaint.shader as SweepGradient, highlight, bloom)
                return
            }
            val shadowWindow = sweep(cx, cy, p.shadow, EdgeBeamSpec.WINDOW_POS, EdgeBeamSpec.WINDOW_ALPHA, (p.shadow ushr 24) / 255f)
            sweeps = listOf(window, highlight, bloom, shadowWindow)

            // The blob stacks, first blob on top (CSS backgrounds), each ellipse a stretched circle.
            fun stack(size: Float, alpha: Int?): Shader {
                var acc: Shader? = null
                for (i in EdgeBeamSpec.BLOBS.indices.reversed()) {
                    val (fx, fy, rxDp, ryDp) = EdgeBeamSpec.BLOBS[i]
                    val rx = (if (size == 1f) rxDp else (rxDp * size).roundToInt().toFloat()) * sx * density
                    val ry = (if (size == 1f) ryDp else (ryDp * size).roundToInt().toFloat()) * sy * density
                    val c = if (alpha == null) palette[i] else (palette[i] and 0xFFFFFF) or (alpha shl 24)
                    val bx = fx * w
                    val by = fy * h
                    val blob = RadialGradient(bx, by, rx, c, c and 0xFFFFFF, Shader.TileMode.CLAMP)
                    blob.setLocalMatrix(Matrix().apply { setScale(1f, ry / rx, bx, by) })
                    acc = if (acc == null) blob else ComposeShader(acc, blob, PorterDuff.Mode.SRC_OVER)
                }
                return acc!!
            }
            val ringColours = stack(1f, null)
            ringPaint.shader = ComposeShader(ringColours, window, PorterDuff.Mode.DST_IN)
            // CSS `mask-composite: add` of the two edge ramps is source-over of their alphas.
            fun edge(extent: Float, vertical: Boolean): Shader {
                val len = max(extent, fadeW)
                val stops = floatArrayOf(0f, fadeW / len, max(fadeW, extent - fadeW) / len, 1f)
                val colours = intArrayOf(WHITE, 0x00FFFFFF, 0x00FFFFFF, WHITE)
                return if (vertical) LinearGradient(0f, 0f, 0f, len, colours, stops, Shader.TileMode.CLAMP)
                else LinearGradient(0f, 0f, len, 0f, colours, stops, Shader.TileMode.CLAMP)
            }
            val edges = ComposeShader(edge(h.toFloat(), true), edge(w.toFloat(), false), PorterDuff.Mode.SRC_OVER)
            val innerColours = stack(EdgeBeamSpec.INNER_SIZE, (EdgeBeamSpec.INNER_ALPHA * 255).roundToInt())
            innerPaint.shader = ComposeShader(ComposeShader(innerColours, window, PorterDuff.Mode.DST_IN), edges, PorterDuff.Mode.DST_IN)
            shadowPaint.shader = ComposeShader(shadowWindow, edges, PorterDuff.Mode.DST_IN)
            // Android's blur radius → sigma is 0.57735 r + 0.5 (Skia's legacy conversion).
            shadowPaint.maskFilter = BlurMaskFilter(max(0.1f, (sigma - 0.5f) / 0.57735f), BlurMaskFilter.Blur.NORMAL)
            // The still outline: the ring's colours all round over the accent tone, so it has no gaps.
            outlinePaint.shader = ComposeShader(LinearGradient(0f, 0f, 1f, 0f, palette[0], palette[0], Shader.TileMode.CLAMP), ringColours, PorterDuff.Mode.SRC_OVER)
        }

        override fun onDraw(canvas: Canvas) {
            if (fade <= 0f || width == 0 || sweeps.isEmpty()) return
            val p = EdgeBeamSpec.preset(dark)
            val turn = (phase / lap) % 1.0
            val hue = BeamMath.hueDrift(phase, EdgeBeamSpec.HUE_RANGE.toDouble(), EdgeBeamSpec.HUE_PERIOD_S)
            val filter = hueFilters[(hue.roundToInt() + EdgeBeamSpec.HUE_RANGE).coerceIn(0, hueFilters.lastIndex)]
            // `conic-gradient(from <angle>)` starts at 12 o'clock, a sweep at 3. Squashed to a square
            // first, so the beam's pace round a tall screen stays even rather than racing the corners.
            rotation.setRotate((turn * 360.0 - 90.0).toFloat(), width / 2f, height / 2f)
            rotation.postScale(1f, height.toFloat() / width, width / 2f, height / 2f)
            for (s in sweeps) s.setLocalMatrix(rotation)

            val moving = fade * (1f - still)
            if (moving > ALPHA_FLOOR) {
                if (!simple) {
                    draw(canvas, band, innerPaint, p.inner * moving, filter)
                    draw(canvas, shadowPath, shadowPaint, p.inner * moving, filter)
                }
                draw(canvas, ring, ringPaint, p.stroke * moving, filter)
                draw(canvas, ring, highlightPaint, p.stroke * moving, filter)
                draw(canvas, ring, bloomPaint, p.bloom * EdgeBeamSpec.BLOOM_EDGE * moving, bloomFilter)
            }
            val outline = fade * still
            if (outline > ALPHA_FLOOR) draw(canvas, ring, outlinePaint, p.stroke * EdgeBeamSpec.OUTLINE * outline, filter)
        }

        private fun draw(canvas: Canvas, path: Path, paint: Paint, alpha: Float, filter: ColorMatrixColorFilter?) {
            paint.alpha = (alpha.coerceIn(0f, 1f) * 255).roundToInt()
            paint.colorFilter = filter
            canvas.drawPath(path, paint)
        }

        private fun sweep(cx: Float, cy: Float, rgb: Int, pos: FloatArray, alpha: FloatArray, scale: Float) =
            SweepGradient(cx, cy, IntArray(pos.size) { ((alpha[it] * scale * 255).roundToInt() shl 24) or (rgb and 0xFFFFFF) }, pos)

        private fun inset(r: RectF, by: Float) = RectF(r.left + by, r.top + by, r.right - by, r.bottom - by)

        /** Per-corner radii (TL, TR, BR, BL) less [by], as Path.addRoundRect takes them. */
        private fun radii(r: FloatArray, by: Float) = FloatArray(8) { max(0f, r[it / 2] - by) }
    }

    companion object {
        private const val TAG = "DshA11y"
        private const val WHITE = 0xFFFFFFFF.toInt()
        private const val BLACK = 0xFF000000.toInt()
        private const val ALPHA_FLOOR = 0.004f
    }
}
