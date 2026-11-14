package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.phone.a11y.FoldClock.Form
import com.skyjjgw.independent.ski.dshgo.phone.a11y.FoldClock.Hold
import com.skyjjgw.independent.ski.dshgo.phone.a11y.FoldClock.Tick
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FoldClockTest {
    private val dim = FoldClock.DIM_MS
    private val fold = FoldClock.FOLD_MS
    private val card = FoldClock.CARD_MS

    private fun open(now: Long = 0, auto: Boolean = false) = FoldClock().apply {
        setAutoFold(auto, now)
        start(now)
    }

    // ---- 胶囊：默认形态，闲置后变淡，一碰就恢复 --------------------------------------------------------

    @Test fun itStartsAsTheCapsuleAndFadesWhenLeftAlone() {
        val c = open(1_000)
        assertEquals(Form.CAPSULE, c.form)
        assertFalse(c.dimmed)
        assertEquals(1_000 + dim, c.nextAt)
        assertEquals(Tick.NONE, c.tick(1_000 + dim - 1))
        assertEquals(Tick.DIM, c.tick(1_000 + dim))
        assertTrue(c.dimmed)
        // Faded, it stays the capsule: without 自动收起 nothing more is due.
        assertNull(c.nextAt)
        assertEquals(Tick.NONE, c.tick(1_000 + 100 * dim))
        assertEquals(Form.CAPSULE, c.form)
        // A touch brings it to full and counts again.
        assertTrue(c.touch(500_000))
        assertFalse(c.dimmed)
        assertEquals(500_000 + dim, c.nextAt)
    }

    @Test fun theCardNeverFadesAndOpensAFadedCapsuleAtFull() {
        val c = open()
        c.tick(dim)
        assertTrue(c.dimmed)
        assertTrue(c.expand(dim + 1))
        assertFalse(c.dimmed)
        // Only the card's own count runs, and it goes back to a capsule at full.
        assertEquals(dim + 1 + card, c.nextAt)
        assertEquals(Tick.COLLAPSE, c.tick(dim + 1 + card))
        assertFalse(c.dimmed)
        assertEquals(dim + 1 + card + dim, c.nextAt)
    }

    @Test fun whatAsksThePersonBringsAFadedCapsuleToFull() {
        for (h in Hold.values()) {
            val c = open()
            c.tick(dim)
            c.hold(h, dim + 1)
            assertFalse("$h", c.dimmed)
            assertNull("$h", c.nextAt)
            c.release(h, 10_000)
            assertEquals("$h", 10_000 + dim, c.nextAt)
        }
    }

    @Test fun statusLinesAreNotTouches() {
        // Only touch() restarts a count: the agent working (new lines) lets an idle capsule fold.
        val c = open(auto = true)
        assertEquals(Tick.FOLD, c.tick(fold))
    }

    // ---- 卡片：从胶囊长出来，闲置后收回 -----------------------------------------------------------

    @Test fun theLineOpensTheCardAndItGoesBackWhenLeftAlone() {
        val c = open()
        assertTrue(c.expand(100))
        assertEquals(Form.CARD, c.form)
        assertTrue(c.expanded)
        assertEquals(100 + card, c.nextAt)
        // A touch on the card keeps it.
        c.touch(5_000)
        assertEquals(5_000 + card, c.nextAt)
        assertEquals(Tick.NONE, c.tick(5_000 + card - 1))
        assertEquals(Tick.COLLAPSE, c.tick(5_000 + card))
        assertEquals(Form.CAPSULE, c.form)
        // Back as the capsule, which fades when left alone.
        assertEquals(5_000 + card + dim, c.nextAt)
    }

    @Test fun theLineAgainClosesTheCard() {
        val c = open()
        c.expand(0)
        assertTrue(c.collapse(10))
        assertEquals(Form.CAPSULE, c.form)
        assertFalse(c.collapse(20))
        // The card only opens from the capsule.
        c.foldByHand(30)
        assertFalse(c.expand(40))
        assertEquals(Form.BALL, c.form)
    }

    @Test fun typingKeepsTheCardOpen() {
        val c = open()
        c.expand(0)
        assertFalse("typing doesn't fold the card", c.hold(Hold.EDITING, 10))
        assertEquals(Form.CARD, c.form)
        assertNull(c.nextAt)
        assertEquals(Tick.NONE, c.tick(10 * card))
        assertFalse("the line can't close it under the keyboard", c.collapse(20))
        c.release(Hold.EDITING, 1_000)
        assertEquals(1_000 + card, c.nextAt)
    }

    @Test fun aConfirmAStopOrAHandoffFoldTheCardBack() {
        for (h in FoldClock.COLLAPSING) {
            val c = open()
            c.expand(0)
            assertTrue("$h", c.hold(h, 10))
            assertEquals("$h", Form.CAPSULE, c.form)
            // And the card doesn't open under them.
            assertFalse("$h", c.expand(20))
            c.release(h, 30)
            assertTrue("$h", c.expand(40))
        }
    }

    // ---- 小球：手动收起，本任务里一直保持，直到点开 -------------------------------------------------

    @Test fun theMarkFoldsUntilTheBallIsTapped() {
        val c = open()
        assertTrue(c.foldByHand(500))
        assertTrue(c.folded)
        assertTrue(c.byHand)
        // The ball is at full when it appears, then fades.
        assertFalse(c.dimmed)
        assertEquals(500 + dim, c.nextAt)
        assertEquals(Tick.DIM, c.tick(500 + dim))
        assertTrue(c.dimmed)
        // Nothing opens it on its own, however long.
        assertEquals(Tick.NONE, c.tick(10 * 60_000))
        assertTrue(c.folded)
        // A touch on the ball (a drag) brings it to full, still folded.
        assertTrue(c.touch(700_000))
        assertTrue(c.folded)
        assertTrue(c.unfold(800_000))
        // A tap opens the capsule, never the card.
        assertEquals(Form.CAPSULE, c.form)
        assertFalse(c.byHand)
        // Folding twice is nothing.
        c.foldByHand(900_000)
        assertFalse(c.foldByHand(900_001))
    }

    @Test fun theCardFoldsStraightIntoTheBall() {
        val c = open()
        c.expand(0)
        assertTrue(c.foldByHand(10))
        assertEquals(Form.BALL, c.form)
        c.unfold(20)
        assertEquals(Form.CAPSULE, c.form)
    }

    @Test fun aFoldByHandStaysThroughCardsAndTyping() {
        val c = open()
        c.foldByHand(0)
        for (h in Hold.values()) {
            assertFalse("$h doesn't open a fold by hand", c.hold(h, 1))
            assertTrue(c.folded)
            c.release(h, 2)
        }
    }

    @Test fun theStoppedNoteCannotBeFoldedAway() {
        val c = open()
        c.hold(Hold.STOPPED, 0)
        assertFalse(c.foldByHand(1))
        assertEquals(Form.CAPSULE, c.form)
    }

    // ---- 自动收起 ---------------------------------------------------------------------------------

    @Test fun autoFoldFoldsAnIdleCapsule() {
        val c = open(auto = true)
        // The fold comes instead of the fade: the capsule goes at full.
        assertEquals(fold, c.nextAt)
        assertEquals(Tick.FOLD, c.tick(fold))
        assertTrue(c.folded)
        assertFalse(c.byHand)
        // Then the ball fades like any other.
        assertEquals(fold + dim, c.nextAt)
        assertEquals(Tick.DIM, c.tick(fold + dim))
    }

    @Test fun autoFoldWaitsForTheCardFirst() {
        val c = open(auto = true)
        c.expand(0)
        assertEquals(card, c.nextAt)
        assertEquals(Tick.COLLAPSE, c.tick(card))
        assertEquals(card + fold, c.nextAt)
        assertEquals(Tick.FOLD, c.tick(card + fold))
        assertEquals(Form.BALL, c.form)
    }

    @Test fun anAutomaticFoldOpensForWhatAsksThePerson() {
        for (h in FoldClock.OPENING) {
            val c = open(auto = true)
            c.tick(fold)
            assertTrue(c.folded)
            assertTrue("$h opens it", c.hold(h, fold + 1))
            assertEquals(Form.CAPSULE, c.form)
        }
        // The 已停止 note doesn't: it is gone in a moment anyway.
        val c = open(auto = true)
        c.tick(fold)
        assertFalse(c.hold(Hold.STOPPED, fold + 1))
        assertTrue(c.folded)
    }

    @Test fun switchingAutoFoldAppliesAtOnce() {
        val c = open()
        assertEquals(dim, c.nextAt)
        c.setAutoFold(true, 1_000)
        assertEquals(1_000 + fold, c.nextAt)
        c.setAutoFold(false, 2_000)
        assertEquals(2_000 + dim, c.nextAt)
    }

    // ---- 等待：确认、交还、插话、已停止时什么都不变 ----------------------------------------------------

    @Test fun holdsStopEveryCount() {
        for (h in Hold.values()) {
            val c = open(auto = true)
            c.foldByHand(0)
            c.tick(dim)
            assertTrue(c.dimmed)
            c.hold(h, dim + 1)
            assertFalse("$h brings the ball to full", c.dimmed)
            assertNull(c.nextAt)
            assertEquals(Tick.NONE, c.tick(100_000))
            c.release(h, 200_000)
            // A whole idle span from when the hold went.
            assertEquals(200_000 + dim, c.nextAt)
        }
    }

    @Test fun overlappingHoldsWaitForTheLast() {
        val c = open(auto = true)
        c.hold(Hold.EDITING, 100)
        c.hold(Hold.CONFIRM, 200)
        c.release(Hold.EDITING, 300)
        assertNull(c.nextAt)
        assertTrue(c.held)
        c.release(Hold.CONFIRM, 400)
        assertEquals(400 + fold, c.nextAt)
        // Releasing what isn't held changes nothing.
        c.release(Hold.HANDOFF, 900)
        assertEquals(400 + fold, c.nextAt)
    }

    @Test fun resetEndsItAll() {
        val c = open(auto = true)
        c.expand(0)
        c.reset()
        assertFalse(c.running)
        assertEquals(Form.CAPSULE, c.form)
        assertNull(c.nextAt)
        assertFalse(c.expand(1))
        assertFalse(c.foldByHand(1))
        assertEquals(Tick.NONE, c.tick(10 * card))
    }
}
