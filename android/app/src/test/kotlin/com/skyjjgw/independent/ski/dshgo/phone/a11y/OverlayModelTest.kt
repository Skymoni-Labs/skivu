package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.phone.a11y.HoldToStop.Release
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OverlayModelTest {
    // The core's own formats (values-zh/i18n_strings.xml, values/i18n_strings.xml).
    private val zh = StatusLines("免确认 · %1\$s", "DSH 正在操作 · %1\$s")
    private val en = StatusLines("No approval needed · %1\$s", "DSH is acting · %1\$s")

    // ---- 状态行：胶囊只说正在做的事 ------------------------------------------------------------------

    @Test fun theCapsuleShowsTheActionWithoutTheCoresPrefixes() {
        assertEquals(StatusLine("点「发送」", waived = false, acting = true), zh.parse("DSH 正在操作 · 点「发送」"))
        assertEquals(StatusLine("点「发送」", waived = true, acting = true), zh.parse("免确认 · DSH 正在操作 · 点「发送」"))
        // Keys come through the same prefix (phone_status_press).
        assertEquals("按返回", zh.parse("DSH 正在操作 · 按返回").text)
        assertEquals(StatusLine("Tap “Send”", waived = true, acting = true), en.parse("No approval needed · DSH is acting · Tap “Send”"))
    }

    @Test fun readingTheScreenStaysAsItIsAndIsNotAStep() {
        assertEquals(StatusLine("DSH 正在看屏幕", waived = false, acting = false), zh.parse("DSH 正在看屏幕"))
        assertEquals(StatusLine("DSH 正在看屏幕", waived = true, acting = false), zh.parse("免确认 · DSH 正在看屏幕"))
    }

    @Test fun aLineThatIsOnlyAPrefixKeepsItsWords() {
        assertEquals("DSH 正在操作 ·", zh.parse("DSH 正在操作 · ").text)
        assertEquals("", StatusLines("", "").parse("").text)
    }

    @Test fun prefixesComeFromOneArgumentFormatsOnly() {
        assertEquals("免确认 · ", StatusLines.prefixOf("免确认 · %1\$s"))
        assertEquals("A ", StatusLines.prefixOf("A %s"))
        assertNull(StatusLines.prefixOf("%1\$s · B"))
        assertNull(StatusLines.prefixOf("%1\$s"))
        // A broken translation takes nothing off rather than the wrong thing.
        assertEquals("DSH 正在操作 · 点「发送」", StatusLines("x", "y").parse("DSH 正在操作 · 点「发送」").text)
    }

    // ---- 最近几步 ------------------------------------------------------------------------------------

    @Test fun theCardListsTheActionsBeforeTheLineNewestFirst() {
        val h = StepHistory()
        val lines = listOf("DSH 正在看屏幕", "DSH 正在操作 · 点「搜索」", "DSH 正在看屏幕", "DSH 正在操作 · 输入「张三」", "DSH 正在看屏幕")
        lines.forEach { h.add(zh.parse(it)) }
        // The header reads the screen: both actions are behind it.
        assertEquals(listOf("输入「张三」", "点「搜索」"), h.before(zh.parse("DSH 正在看屏幕"), 3))
        // The header is the newest action: it isn't listed twice.
        val now = zh.parse("DSH 正在操作 · 点「张三」")
        h.add(now)
        assertEquals(listOf("输入「张三」", "点「搜索」"), h.before(now, 3))
        assertEquals(listOf("输入「张三」"), h.before(now, 1))
    }

    @Test fun repeatsAndOverflowAreDropped() {
        val h = StepHistory()
        repeat(3) { h.add(zh.parse("DSH 正在操作 · 滚动")) }
        assertEquals(listOf("滚动"), h.before(null, 3))
        for (i in 1..10) h.add(zh.parse("DSH 正在操作 · 点「$i」"))
        assertEquals(listOf("点「10」", "点「9」", "点「8」"), h.before(null, 3))
        assertEquals(listOf("点「9」", "点「8」", "点「7」"), h.before(zh.parse("DSH 正在操作 · 点「10」"), 3))
        h.clear()
        assertEquals(emptyList<String>(), h.before(null, 3))
    }

    // ---- 头部：停止永远在同一个位置，一步可达 ---------------------------------------------------------

    @Test fun stopIsAlwaysTheLastKeyWithPauseBesideIt() {
        val running = CapsuleMetrics.slots(stopped = false)
        assertEquals(listOf(Slot.MARK, Slot.LINE, Slot.PAUSE, Slot.STOP), running)
        // 停止 at the right end: the same place in the capsule and the card, never behind a menu.
        assertEquals(Slot.STOP, running.last())
        // Once stopped there is nothing left to stop.
        assertFalse(Slot.STOP in CapsuleMetrics.slots(stopped = true))
    }

    @Test fun everyKeyIsABigEnoughTarget() {
        assertTrue(CapsuleMetrics.KEY_DP >= 48)
        assertTrue(CapsuleMetrics.HEIGHT_DP >= CapsuleMetrics.KEY_DP)
        // The disc sits concentric with the capsule's round end.
        assertEquals(CapsuleMetrics.HEIGHT_DP - CapsuleMetrics.DISC_DP, CapsuleMetrics.KEY_DP - CapsuleMetrics.DISC_DP)
        assertTrue(CapsuleMetrics.KEY_GAP_DP > 0)
    }

    // ---- 宽度：跟着这行字，长了立刻长，短了过一会儿再缩 ------------------------------------------------

    private val d = 2.625f
    private val screen = 1080

    @Test fun widthsAreWholeStepsWithinTheRange() {
        val w = CapsuleMetrics.widthPx(CapsuleMetrics.contentDp(57f, lock = false, stopped = false) * d, screen, d)
        assertEquals(0, Math.round(w / d) % CapsuleMetrics.STEP_DP)
        // A one-glyph-longer line keeps the same width.
        val w2 = CapsuleMetrics.widthPx(CapsuleMetrics.contentDp(58f, lock = false, stopped = false) * d, screen, d)
        assertEquals(w, w2)
        // Never past the screen's sides less the gap, nor the cap.
        val huge = CapsuleMetrics.widthPx(10_000f, screen, d)
        assertEquals(screen - Math.round(2 * CapsuleMetrics.EDGE_DP * d), huge)
        val tablet = CapsuleMetrics.widthPx(10_000f, 2560, 2f)
        assertEquals(CapsuleMetrics.MAX_DP * 2, tablet)
        // A stopped capsule (no keys) can be small, but not a sliver.
        assertEquals(Math.round(CapsuleMetrics.MIN_DP * d), CapsuleMetrics.widthPx(10f, screen, d))
    }

    @Test fun theLockAndTheKeysTakeTheirRoom() {
        val plain = CapsuleMetrics.contentDp(100f, lock = false, stopped = false)
        val locked = CapsuleMetrics.contentDp(100f, lock = true, stopped = false)
        val stopped = CapsuleMetrics.contentDp(100f, lock = false, stopped = true)
        assertEquals((CapsuleMetrics.LOCK_DP + CapsuleMetrics.LOCK_GAP_DP).toFloat(), locked - plain)
        assertTrue(stopped < plain - 2 * CapsuleMetrics.KEY_DP)
    }

    @Test fun aLongLineGrowsTheCapsuleAtOnce() {
        val w = CapsuleWidth(slack = 60)
        assertTrue(w.offer(600, 0))
        assertTrue(w.offer(800, 10))
        assertEquals(800, w.width)
        assertNull(w.shrinkAt)
    }

    @Test fun aShortLineShrinksItOnlyAfterAWhile() {
        val w = CapsuleWidth(slack = 60)
        w.offer(800, 0)
        assertFalse(w.offer(500, 1_000))
        assertEquals(800, w.width)
        assertEquals(1_000 + CapsuleWidth.SHRINK_AFTER_MS, w.shrinkAt)
        // The agent alternates lines: still the widest since they got narrower.
        assertFalse(w.offer(600, 1_500))
        assertFalse(w.offer(500, 2_000))
        assertTrue(w.offer(500, 1_000 + CapsuleWidth.SHRINK_AFTER_MS))
        assertEquals(600, w.width)
    }

    @Test fun theAlternatingLinesKeepItSteady() {
        val w = CapsuleWidth(slack = 60)
        w.offer(800, 0)
        // 「正在看屏幕」, 「点「…」」, every second: a wide line back in time keeps the width.
        var t = 0L
        repeat(10) {
            t += 500
            assertFalse(w.offer(500, t))
            t += 500
            assertFalse(w.offer(800, t))
        }
        assertEquals(800, w.width)
    }

    @Test fun nearlyAsWideIsLeftAlone() {
        val w = CapsuleWidth(slack = 60)
        w.offer(800, 0)
        assertFalse(w.offer(760, 100))
        assertNull(w.shrinkAt)
        assertFalse(w.offer(760, 100_000))
        assertEquals(800, w.width)
    }

    @Test fun aStateChangeResizesAtOnce() {
        val w = CapsuleWidth(slack = 60)
        w.offer(800, 0)
        w.offer(300, 10)
        assertTrue(w.force(300))
        assertEquals(300, w.width)
        assertNull(w.shrinkAt)
        w.reset()
        assertEquals(0, w.width)
    }

    // ---- 按住小球停止 ---------------------------------------------------------------------------------

    private val arm = HoldToStop.ARM_MS
    private val full = HoldToStop.ARM_MS + HoldToStop.FILL_MS

    @Test fun aTapOpensTheCapsule() {
        val h = HoldToStop()
        h.down(0)
        assertFalse(h.tick(100))
        assertEquals(0f, h.progress(100))
        assertEquals(Release.TAP, h.up(arm - 1))
    }

    @Test fun holdingStillForASecondStops() {
        assertEquals(1_000L, full)
        val h = HoldToStop()
        h.down(0)
        assertEquals(arm, h.nextAt())
        assertFalse(h.tick(arm))
        assertEquals(HoldToStop.State.FILLING, h.state)
        assertEquals(0.5f, h.progress(arm + HoldToStop.FILL_MS / 2), 0.01f)
        assertFalse(h.tick(full - 1))
        assertTrue("stops exactly once", h.tick(full))
        assertFalse(h.tick(full + 100))
        assertEquals(1f, h.progress(full + 100))
        assertEquals(Release.STOPPED, h.up(full + 200))
        assertEquals(HoldToStop.State.IDLE, h.state)
    }

    @Test fun lettingGoWhileItFillsCancels() {
        val h = HoldToStop()
        h.down(0)
        h.tick(arm + 10)
        // Neither a stop nor a tap.
        assertEquals(Release.CANCELLED, h.up(full - 100))
    }

    @Test fun aReleaseAfterTheSecondStillCounts() {
        // The frame that would have fired never came (a busy main thread): the release stops it.
        val h = HoldToStop()
        h.down(0)
        assertEquals(Release.STOP, h.up(full + 5))
    }

    @Test fun aDragIsNeverAStop() {
        val h = HoldToStop()
        h.down(0)
        h.tick(arm + 100)
        h.moved()
        assertEquals(HoldToStop.State.DRAGGING, h.state)
        assertFalse(h.tick(10 * full))
        assertEquals(0f, h.progress(10 * full))
        assertNull(h.nextAt())
        assertEquals(Release.DRAG, h.up(10 * full))
    }

    @Test fun aCancelledGestureDoesNothing() {
        val h = HoldToStop()
        h.down(0)
        h.cancel()
        assertFalse(h.tick(10 * full))
        assertEquals(Release.NONE, h.up(10 * full))
    }

    // ---- 卡片列几步 -----------------------------------------------------------------------------------

    @Test fun aShortScreenListsOneStep() {
        assertEquals(1, CapsuleMetrics.steps(411f))
        assertEquals(3, CapsuleMetrics.steps(914f))
    }

    // ---- 确认卡 / 交还卡的窗口宽度 ---------------------------------------------------------------------

    @Test fun theCardsFitTheScreenAndStopAtTheCap() {
        val density = 2.525f
        // 472 dp would be 1192 px here: the 1080 px display decides (the cold-start bug took 1192).
        assertEquals(1050, CardMetrics.windowWidthPx(1080, density, CardMetrics.CONFIRM_DP))
        // A wide screen leaves the cap in charge; the handoff card at the top has its own.
        assertEquals(1192, CardMetrics.windowWidthPx(2207, density, CardMetrics.CONFIRM_DP))
        assertEquals(1242, CardMetrics.windowWidthPx(2207, density, CardMetrics.HANDOFF_DP))
        // A tablet at 2x density: still the cap.
        assertEquals(944, CardMetrics.windowWidthPx(2560, 2f, CardMetrics.CONFIRM_DP))
    }
}
