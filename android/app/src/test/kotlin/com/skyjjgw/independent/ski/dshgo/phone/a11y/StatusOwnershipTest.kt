package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.phone.PhoneDisplaySelection
import com.skyjjgw.independent.ski.dshgo.phone.PhoneTasks
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.*
import org.junit.Test

class StatusOwnershipTest {
    @Test fun editorKeepsOriginalControlsAcrossSameOwnerStatusAndClearsOnAnotherTask() {
        val ids = AtomicLong()
        val a = PhoneTasks(idSource = ids::incrementAndGet)
        val b = PhoneTasks(idSource = ids::incrementAndGet)
        val selection = PhoneDisplaySelection()
        val shown = StatusOwnership()
        val stop = { task: PhoneTasks, owner: PhoneTasks.Owner, reason: String -> task.stopIfCurrent(owner, reason) }
        val oa = (a.begin() as PhoneTasks.Begin.Go).owner
        val ta = selection.select(a, oa)!!
        assertTrue(shown.publish(selection.guard(ta)) { selection.controls(stop) })
        assertTrue(shown.beginEditing())
        val editor = shown.editingControls!!
        assertTrue(shown.publish(selection.guard(ta)) { selection.controls(stop) })
        assertNotSame(editor, shown.controls) // Each publish allocates controls; identity is not ownership.
        assertSame(editor, shown.editingControls)
        assertTrue(editor.interject("for original A"))
        assertEquals(listOf("for original A"), a.drainInterjections())

        val ob = (b.begin() as PhoneTasks.Begin.Go).owner
        val tb = selection.select(b, ob)!!
        assertTrue(shown.publish(selection.guard(tb)) { selection.controls(stop) })
        assertNull(shown.editingControls)
        assertTrue(b.drainInterjections().isEmpty())
        assertTrue(shown.beginEditing())
        shown.clear()
        assertNull(shown.editingControls)
        assertFalse(shown.beginEditing())
    }

    @Test fun editorIsRevokedWhenTheSameTaskObjectHasANewOwner() {
        val task = PhoneTasks()
        val selection = PhoneDisplaySelection()
        val shown = StatusOwnership()
        val stop = { t: PhoneTasks, owner: PhoneTasks.Owner, reason: String -> t.stopIfCurrent(owner, reason) }
        val old = (task.begin() as PhoneTasks.Begin.Go).owner
        val ticket = selection.select(task, old)!!
        assertTrue(shown.publish(selection.guard(ticket)) { selection.controls(stop) })
        assertTrue(shown.beginEditing())
        val editor = shown.editingControls!!
        task.invalidateOwners()
        val next = task.activeOwner()!!
        assertEquals(old.taskId, next.taskId)
        assertNotEquals(old.lifecycle, next.lifecycle)
        val nextTicket = selection.select(task, next)!!
        assertTrue(shown.publish(selection.guard(nextTicket)) { selection.controls(stop) })
        assertNull(shown.editingControls)
        assertFalse(editor.interject("late"))
        assertTrue(task.drainInterjections().isEmpty())
    }

    @Test fun replacementInvalidatesCleanupTicketButDoesNotKeepTheOldDisplayedStatus() {
        val tasks = PhoneTasks()
        val shown = StatusOwnership()
        val a = (tasks.begin() as PhoneTasks.Begin.Go).owner
        assertTrue(shown.publish { update -> tasks.runIfCurrent(a, update) })
        tasks.stop("stop A")
        val cleanupA = tasks.snapshot()
        tasks.clearStop()
        tasks.begin() // B can be a pure apps read: it need not publish a status.
        var oldCleanupApplied = false
        tasks.runIfInactive(cleanupA) { oldCleanupApplied = true }
        assertFalse(oldCleanupApplied)
        assertTrue(shown.takeStale())
        assertFalse(shown.takeStale())
    }

    @Test fun cleanupForOldTaskPreservesTheNewDisplayedStatus() {
        val tasks = PhoneTasks()
        val shown = StatusOwnership()
        val a = (tasks.begin() as PhoneTasks.Begin.Go).owner
        assertTrue(shown.publish { update -> tasks.runIfCurrent(a, update) })
        tasks.stop("stop A")
        tasks.clearStop()
        val b = (tasks.begin() as PhoneTasks.Begin.Go).owner
        assertTrue(shown.publish { update -> tasks.runIfCurrent(b, update) })
        assertFalse(shown.takeStale())
        assertFalse(shown.publish { update -> tasks.runIfCurrent(a, update) })
        assertFalse(shown.takeStale()) // A's rejected late status did not replace B's ownership.
    }

    @Test fun removingOnlyAStatusCanPreserveCurrentPromptHoldsAcrossPillRecreation() {
        val fold = FoldClock()
        fold.start(0)
        fold.hold(FoldClock.Hold.CONFIRM, 1)
        fold.reset()
        fold.hold(FoldClock.Hold.CONFIRM, 2) // Current card survives removal of the old pill.
        fold.start(3)
        assertTrue(fold.isHeld(FoldClock.Hold.CONFIRM))
        assertNull(fold.nextAt)
        assertFalse(fold.expand(4))
        fold.release(FoldClock.Hold.CONFIRM, 5)
        assertFalse(fold.held)
    }
}
