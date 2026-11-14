package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.phone.PhoneDisplaySelection
import com.skyjjgw.independent.ski.dshgo.phone.PhoneTasks
import org.junit.Assert.*
import org.junit.Test

/** Actual selection -> posted status cleanup -> fold lifecycle; no Android window is simulated. */
class RepeatedStatusOwnershipTest {
    private var now = 0L
    private val selection = PhoneDisplaySelection()
    private val shown = StatusOwnership()
    private val fold = FoldClock().apply { setAutoFold(true, now) }
    private val stop = { task: PhoneTasks, owner: PhoneTasks.Owner, reason: String -> task.stopIfCurrent(owner, reason) }

    private fun task() = PhoneTasks(clock = { now })

    private fun select(task: PhoneTasks): PhoneDisplaySelection.Ticket =
        selection.select(task, (task.begin() as PhoneTasks.Begin.Go).owner)!!

    private fun publish(ticket: PhoneDisplaySelection.Ticket) {
        val guard = selection.guard(ticket)
        selection.status("reading", guard)
        assertTrue(shown.publish(guard) { selection.controls(stop) })
        fold.start(now) // Idempotent while ControlOverlay's existing pill remains attached.
    }

    private fun postedClear(): Boolean {
        val removed = shown.takeStale()
        if (removed) fold.reset() // ControlOverlay.clearStatus -> removePill.
        return removed
    }

    @Test fun repeatedReadsDoNotRecreateThePillOrPostponeItsIdleFold() {
        val task = task()
        val first = select(task)
        publish(first)
        var removed = 0
        for (i in 1..9) {
            now = i * 350L
            val next = select(task)
            assertNotSame(first, next)
            assertNotSame(first.owner, next.owner)
            if (postedClear()) removed++
            publish(next)
            assertFalse(selection.status("late first read", selection.guard(first)))
        }
        assertEquals("same owner calls removed=$removed foldAt=${fold.foldAt}", 0, removed)
        assertEquals(3_500L, fold.foldAt)
        now = 3_500
        assertEquals(FoldClock.Tick.FOLD, fold.tick(now))
        val next = select(task)
        assertFalse(postedClear())
        publish(next)
        assertEquals(FoldClock.Form.BALL, fold.form)
    }

    @Test fun aManualFoldSurvivesTheNextExecutionOfThatOwner() {
        val task = task()
        val first = select(task)
        publish(first)
        assertTrue(fold.foldByHand(100))
        now = 350
        val next = select(task)
        assertFalse(postedClear())
        publish(next)
        assertEquals(FoldClock.Form.BALL, fold.form)
        assertTrue(fold.byHand)
        assertFalse(shown.publish(selection.guard(first)) { selection.controls(stop) })
    }

    @Test fun sameOwnerExecutionKeepsTheEditorsOriginalControls() {
        val task = task()
        val first = select(task)
        publish(first)
        assertTrue(shown.beginEditing())
        val editor = shown.editingControls
        val next = select(task)
        assertFalse(postedClear())
        publish(next)
        assertSame(editor, shown.editingControls)
        assertTrue(editor!!.interject("synthetic note"))
        assertEquals(listOf("synthetic note"), task.drainInterjections())
        assertFalse(selection.status("late first execution", selection.guard(first)))
    }

    @Test fun leavingAndReturningToTheSameOwnerCannotReviveItsOldDisplayedPill() {
        val a = task(); val b = task()
        val first = select(a)
        publish(first)
        selection.select(b, (b.begin() as PhoneTasks.Begin.Go).owner) // apps-only B publishes nothing.
        val third = select(a)
        assertEquals(first.owner.taskId, third.owner.taskId)
        assertEquals(first.owner.lifecycle, third.owner.lifecycle)
        assertTrue(postedClear()) // The queued B cleanup only now reaches the UI.
        assertFalse(fold.running)
        assertFalse(shown.publish(selection.guard(first)) { selection.controls(stop) })
        publish(third)
        assertFalse(postedClear())
        assertTrue(fold.running)
    }

    @Test fun differentTaskObjectsWithTheSameNumericOwnerMustStillRetire() {
        val a = task(); val b = task()
        val first = select(a)
        publish(first)
        val second = select(b)
        assertEquals(first.owner.taskId, second.owner.taskId)
        assertEquals(first.owner.lifecycle, second.owner.lifecycle)
        assertTrue(postedClear())
        assertFalse(fold.running)
        assertSame(b, selection.view()!!.task)
    }

    @Test fun pauseKeepsTheOwnerButStopEndsTheDisplayedLifetime() {
        val task = task()
        publish(select(task))
        assertTrue(shown.controls!!.setPaused(true))
        val next = select(task)
        assertFalse(postedClear())
        publish(next)
        assertTrue(shown.controls!!.isPaused())
        task.stop("synthetic stop")
        assertTrue(postedClear())
        assertFalse(fold.running)
    }

    @Test fun lifecycleReplacementAndSelectionClearBreakDisplayContinuity() {
        val task = task()
        val first = select(task)
        publish(first)
        task.invalidateOwners()
        val replacement = select(task)
        assertEquals(first.owner.taskId, replacement.owner.taskId)
        assertNotEquals(first.owner.lifecycle, replacement.owner.lifecycle)
        assertTrue(postedClear())
        publish(replacement)
        selection.clear()
        val afterClear = select(task)
        assertTrue(postedClear())
        assertFalse(shown.publish(selection.guard(replacement)) { selection.controls(stop) })
        publish(afterClear)
        assertFalse(postedClear())
    }

    @Test fun aStatusWithoutNativeControlsStillExpiresWithItsExecutionGuard() {
        val task = task()
        val first = select(task)
        assertTrue(shown.publish(selection.guard(first)))
        fold.start(now)
        select(task)
        assertTrue(postedClear())
        assertFalse(fold.running)
    }

    @Test fun finishingTheOwnerRetiresItsDisplayBeforeTheNextTask() {
        val task = task()
        val first = select(task)
        publish(first)
        assertTrue(task.finish(first.owner.taskId))
        assertTrue(postedClear())
        assertFalse(fold.running)
        val next = select(task)
        assertNotEquals(first.owner.taskId, next.owner.taskId)
        assertFalse(shown.publish(selection.guard(first)) { selection.controls(stop) })
        publish(next)
        assertFalse(postedClear())
    }
}
