package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/** The screen-edge beam's numbers: the Border beam `md` type scaled to a phone (411 × 914 dp). */
class EdgeBeamModelTest {
    private val phoneW = 1080 / 2.625f
    private val phoneH = 2400 / 2.625f

    // ---- 尺度：整块屏幕 ---------------------------------------------------------------------------

    @Test fun aLapRoundAPhoneIsCalm() {
        // 1.96 s round a 350 × 140 card, perimeter for perimeter, half again slower.
        val lap = EdgeBeamSpec.lapSeconds(phoneW, phoneH)
        assertEquals(1.96 * 2 * (phoneW + phoneH) / 980.0 * 1.5, lap, 1e-6)
        assertTrue(lap in 7.0..9.0)
        // Never frantic on a small screen, never sluggish on a tablet.
        assertEquals(EdgeBeamSpec.LAP_MIN_S, EdgeBeamSpec.lapSeconds(200f, 300f), 0.0)
        assertEquals(EdgeBeamSpec.LAP_MAX_S, EdgeBeamSpec.lapSeconds(1600f, 2400f), 0.0)
    }

    @Test fun theBlobsScaleToTheScreenAsTheAuthorScalesPulseOutside() {
        val (sx, sy) = EdgeBeamSpec.blobScale(phoneW, phoneH)
        assertEquals(1.176f, sx, 0f)
        assertEquals(EdgeBeamSpec.SCALE_MAX, sy, 0f) // 914 / 140 clamps at 4
        assertEquals(EdgeBeamSpec.SCALE_MIN, EdgeBeamSpec.blobScale(50f, 30f).first, 0f)
    }

    @Test fun theDisplaysCornerRadiusWinsOverTheFallback() {
        assertEquals(120f, EdgeBeamSpec.cornerPx(120, 2.625f), 0f)
        assertEquals(28 * 2.625f, EdgeBeamSpec.cornerPx(null, 2.625f), 0.001f)
        assertEquals(28 * 2.625f, EdgeBeamSpec.cornerPx(0, 2.625f), 0.001f)
    }

    @Test fun thePresetsAreTheAuthorsMd() {
        assertEquals(0.26f, EdgeBeamSpec.DARK.stroke, 0f)
        assertEquals(0.42f, EdgeBeamSpec.DARK.inner, 0f)
        assertEquals(0.24f, EdgeBeamSpec.DARK.bloom, 0f)
        assertEquals(0.12f, EdgeBeamSpec.LIGHT.stroke, 0f)
        assertEquals(1.5f, EdgeBeamSpec.LIGHT.saturation, 0f)
        // rgba(255,255,255,0.27) and rgba(0,0,0,0.14).
        assertEquals(69, EdgeBeamSpec.DARK.shadow ushr 24)
        assertEquals(36, EdgeBeamSpec.LIGHT.shadow ushr 24)
        assertEquals(EdgeBeamSpec.WINDOW_POS.size, EdgeBeamSpec.WINDOW_ALPHA.size)
        assertEquals(EdgeBeamSpec.WHITE_POS.size, EdgeBeamSpec.WHITE_ALPHA_DARK.size)
        assertEquals(EdgeBeamSpec.BLOOM_POS.size, EdgeBeamSpec.BLOOM_ALPHA_LIGHT.size)
        for (stops in listOf(EdgeBeamSpec.WINDOW_POS, EdgeBeamSpec.WHITE_POS, EdgeBeamSpec.BLOOM_POS)) {
            assertTrue(stops.toList().zipWithNext().all { (a, b) -> a <= b })
        }
    }

    // ---- 配色：跟 App 的主色 ------------------------------------------------------------------------

    @Test fun thePaletteIsTheDartPortsThemePalette() {
        // BeamPalette.fromSeed for 雾蓝 (#4B67B4), as Flutter's HSLColor rounds it.
        val p = EdgeBeamPalette.fromSeed(0xFF4B67B4.toInt())
        assertEquals(9, p.size)
        assertEquals(0xFF778CC5.toInt(), p[0])
        assertEquals(0xFF89B3C8.toInt(), p[1])
        assertEquals(0xFF8B7EC8.toInt(), p[8])
    }

    @Test fun thePaletteStaysNearTheAccentHueAndCalm() {
        for (seed in intArrayOf(0xFF4B67B4.toInt(), 0xFF236185.toInt(), 0xFFD0453B.toInt(), 0xFF808080.toInt())) {
            val (hue, _, _) = EdgeBeamPalette.hsl(seed)
            for (c in EdgeBeamPalette.fromSeed(seed)) {
                val (h, s, l) = EdgeBeamPalette.hsl(c)
                val d = abs(((h - hue + 540f) % 360f) - 180f)
                assertTrue("hue $h vs $hue", d <= 36.5f)
                assertTrue("saturation $s", s in 0.33f..0.67f)
                assertTrue("lightness $l", l in 0.57f..0.71f)
            }
        }
    }

    @Test fun hslRoundTrips() {
        val (h, s, l) = EdgeBeamPalette.hsl(0xFF778CC5.toInt())
        assertEquals(0xFF778CC5.toInt(), EdgeBeamPalette.fromHsl(h, s, l))
    }

    // ---- CSS 的时间与滤镜 ---------------------------------------------------------------------------

    @Test fun cssCurves() {
        assertEquals(0.8024, BeamMath.ease(0.5), 1e-4)
        assertEquals(0.5, BeamMath.easeInOut(0.5), 1e-9)
        assertEquals(0.0, BeamMath.ease(0.0), 0.0)
        assertEquals(1.0, BeamMath.ease(1.0), 0.0)
    }

    @Test fun theHueDriftsMinusToPlusAndBack() {
        assertEquals(-30.0, BeamMath.hueDrift(0.0, 30.0, 12.0), 1e-9)
        assertEquals(0.0, BeamMath.hueDrift(3.0, 30.0, 12.0), 1e-6)
        assertEquals(30.0, BeamMath.hueDrift(6.0, 30.0, 12.0), 1e-9)
        assertEquals(0.0, BeamMath.hueDrift(9.0, 30.0, 12.0), 1e-6)
        assertEquals(-30.0, BeamMath.hueDrift(12.0, 30.0, 12.0), 1e-9)
    }

    @Test fun theFilterMatrixIsTheW3cChain() {
        val identity = floatArrayOf(1f, 0f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 0f, 1f, 0f)
        assertArrayEquals(identity, BeamMath.filterMatrix(0.0, 1.0, 1.0), 1e-6f)
        assertArrayEquals(identity, BeamMath.filterMatrix(360.0, 1.0, 1.0), 1e-6f)
        assertEquals(1.3f, BeamMath.filterMatrix(0.0, 1.3, 1.0)[0], 1e-6f)
        val grey = BeamMath.filterMatrix(0.0, 1.0, 0.0)
        for (row in intArrayOf(0, 5, 10)) assertArrayEquals(floatArrayOf(0.213f, 0.715f, 0.072f), grey.copyOfRange(row, row + 3), 1e-6f)
    }

    // ---- 渐入渐出、暂停、移除动画 -----------------------------------------------------------------------

    @Test fun itFadesInOverSixTenthsAndOutOverHalfASecond() {
        val c = EdgeBeamClock(motion = true)
        c.show(true, 1_000)
        c.frame(1_000)
        assertEquals(0f, c.fadeNow, 0f)
        c.frame(1_300)
        assertEquals(BeamMath.ease(0.5).toFloat(), c.fadeNow, 1e-4f)
        c.frame(1_600)
        assertEquals(1f, c.fadeNow, 0f)
        assertTrue(c.animating(1_600)) // on and travelling
        c.show(false, 2_000)
        assertFalse(c.gone(2_400))
        assertTrue(c.gone(2_500))
    }

    @Test fun switchingBackMidFadeCarriesOnFromWhereItIs() {
        val c = EdgeBeamClock(motion = true)
        c.show(true, 0)
        c.show(false, 300)
        c.frame(300)
        val at = c.fadeNow
        assertTrue(at in 0.1f..0.95f)
        c.frame(301)
        assertEquals(at, c.fadeNow, 0.01f)
    }

    @Test fun pausedItSettlesStillAndStopsAskingForFrames() {
        val c = EdgeBeamClock(motion = true)
        c.show(true, 0)
        for (t in 0L..1_000L step 50) c.frame(t)
        assertEquals(1.0, c.phase, 1e-9)
        c.pause(true, 1_000)
        for (t in 1_050L..1_500L step 50) c.frame(t)
        assertEquals(1f, c.stillNow, 0f)
        val stopped = c.phase
        assertTrue(stopped in 1.0..1.5) // it slowed to a stop rather than halting
        c.frame(2_500)
        assertEquals(stopped, c.phase, 0.0) // no travel once still
        assertFalse(c.animating(2_500))
        c.pause(false, 3_000)
        assertTrue(c.animating(3_000))
    }

    @Test fun withoutAnimationsItIsAStillOutlineAtOnce() {
        val c = EdgeBeamClock(motion = false)
        c.show(true, 0)
        c.frame(0)
        assertEquals(1f, c.fadeNow, 0f)
        assertEquals(1f, c.stillNow, 0f)
        assertFalse(c.animating(0))
        c.pause(false, 10) // resuming changes nothing: still is all there is
        c.frame(20)
        assertEquals(1f, c.stillNow, 0f)
        c.show(false, 30)
        assertTrue(c.gone(30))
    }
}
