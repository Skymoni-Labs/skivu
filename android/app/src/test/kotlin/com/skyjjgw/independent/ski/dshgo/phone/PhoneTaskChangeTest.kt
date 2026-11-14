package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

/** Actual Tasks lifecycle receipts. Registry integration races live in PhoneTaskSessionsTest. */
class PhoneTaskChangeTest {
    @Test fun deferredStopPublishesOriginalSnapshotNotWhateverScopeExistsLater() {
        val tasks = PhoneTasks()
        val owner = (tasks.begin() as PhoneTasks.Begin.Go).owner
        val seen = mutableListOf<PhoneTasks.Snapshot>()
        tasks.addListener { seen += it }
        val change = tasks.stopForOwner(owner, "stop")!!
        assertTrue(seen.isEmpty()) // No listener under a caller's registry lock.
        tasks.clearStop()
        val next = (tasks.begin() as PhoneTasks.Begin.Go).owner
        seen.clear()
        tasks.publish(change)
        assertEquals(listOf(change.snapshot), seen)
        assertNotEquals(next.taskId, seen.single().id)
        var cancelledNewScope = false
        tasks.runIfInactive(seen.single()) { cancelledNewScope = true }
        assertFalse(cancelledNewScope)
        assertTrue(tasks.isCurrent(next))
    }

    @Test fun conditionalGateStopInvalidatesPreviouslyAdmittedLegacyCall() {
        var time = 0L
        val tasks = PhoneTasks(clock = { time }, stopHoldMs = 10)
        val owner = (tasks.begin() as PhoneTasks.Begin.Go).owner
        val queuedEpoch = tasks.admissionEpoch()
        assertTrue(tasks.stopIfCurrent(owner, "SafetyGate stop"))
        time = 11 // Beyond the hold; the old admission still must not start a new task.
        assertTrue(tasks.begin(queuedEpoch) is PhoneTasks.Begin.Refused)
        assertFalse(tasks.isActive)
        assertTrue(tasks.begin(tasks.admissionEpoch()) is PhoneTasks.Begin.Go)
    }

    @Test fun staleStopAndResumeCannotMutateAReplacementLifetime() {
        val tasks = PhoneTasks()
        val old = (tasks.begin() as PhoneTasks.Begin.Go).owner
        val oldSnapshot = tasks.snapshot()
        tasks.stop("first stop")
        val stopped = tasks.snapshot()
        tasks.stop("second stop")
        assertNull(tasks.resumeForSnapshot(stopped))
        assertTrue(tasks.isStopped())
        tasks.clearStop()
        val current = (tasks.begin() as PhoneTasks.Begin.Go).owner
        val epoch = tasks.admissionEpoch()
        assertNull(tasks.stopForOwner(old, "late"))
        assertNull(tasks.stopForSnapshot(oldSnapshot, "late"))
        assertEquals(epoch, tasks.admissionEpoch())
        assertTrue(tasks.isCurrent(current))
    }

    @Test fun noopResumeKeepsActiveOwnerAndDeferredResumeNotifiesOnlyWhenPublished() {
        val tasks = PhoneTasks()
        val owner = (tasks.begin() as PhoneTasks.Begin.Go).owner
        val noop = tasks.resumeForSnapshot(tasks.snapshot())!!
        assertTrue(tasks.isCurrent(owner))
        assertEquals(owner.lifecycle, noop.snapshot.lifecycle)
        tasks.stop("stop")
        var calls = 0
        tasks.addListener { calls++ }
        val resumed = tasks.resumeForSnapshot(tasks.snapshot())!!
        assertEquals(0, calls)
        assertFalse(tasks.isStopped())
        tasks.publish(resumed)
        assertEquals(1, calls)
    }

    @Test fun coldAndIdleSnapshotsCanBeStoppedWithoutGuessingActiveProjection() {
        var time = 0L
        val tasks = PhoneTasks(clock = { time }, idleMs = 10)
        val cold = tasks.stopForSnapshot(tasks.snapshot(), "cold")!!
        assertTrue(cold.snapshot.stopped)
        tasks.clearStop()
        tasks.begin()
        time = 11
        val idle = tasks.snapshot()
        assertFalse(idle.active)
        val stopped = tasks.stopForSnapshot(idle, "idle")!!
        assertEquals(idle.id, stopped.snapshot.id)
        assertTrue(stopped.snapshot.stopped)
    }
}
