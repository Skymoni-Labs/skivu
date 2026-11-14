package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** A pause holds the task: the idle limit never ends it, so DSH can't go on by itself. */
class PhoneTasksPauseTest {
    @Volatile private var now = 1_000L
    private fun tasks() = PhoneTasks(clock = { now })

    /** A call blocked in [PhoneTasks.awaitResume] on its own thread, as the phone worker waits. */
    private class Waiter(t: PhoneTasks) {
        val result = AtomicReference<Boolean?>(null)
        private val done = CountDownLatch(1)
        private val thread = Thread {
            result.set(t.awaitResume(WAIT_MS))
            done.countDown()
        }.apply { isDaemon = true; start() }

        fun returnedWithin(ms: Long): Boolean = done.await(ms, TimeUnit.MILLISECONDS)
        fun interrupt() = thread.interrupt()
    }

    @Test fun aPauseOutlastingTheIdleLimitStaysPausedAndKeepsTheWaiver() {
        val t = tasks()
        val seen = mutableListOf<PhoneTasks.Snapshot>()
        t.callStarted()
        val first = t.begin() as PhoneTasks.Begin.Go
        t.waive()
        t.approve("com.example")
        t.callEnded(t.activeOwner())
        t.setPaused(true)
        t.addListener { seen += it }

        now += t.idleMs * 4
        assertFalse(t.expireIdle())
        val s = t.snapshot()
        assertTrue(s.active)
        assertTrue(s.paused)
        assertTrue(s.waived)
        assertTrue(t.isPaused)
        assertTrue(t.isWaived)
        assertTrue(t.isApproved("com.example"))
        // Nobody heard the task end.
        assertTrue(seen.none { !it.active })
        // A call arriving now waits on the same task instead of starting a fresh one.
        t.callStarted()
        val next = t.begin() as PhoneTasks.Begin.Go
        assertFalse(next.newTask)
        assertEquals(first.taskId, next.taskId)
        assertFalse(t.awaitResume(0))
        t.callEnded(t.activeOwner())
    }

    @Test fun aCallWaitingOutThePauseDoesNotGoOnByItself() {
        val t = tasks()
        t.callStarted()
        t.begin()
        t.waive()
        t.setPaused(true)
        val waiter = Waiter(t)
        try {
            now += t.idleMs + 1
            assertFalse(t.expireIdle())
            now += t.idleMs * 3
            assertFalse(t.expireIdle())
            // Still waiting for the person: the expiry did not clear the pause under it.
            assertFalse(waiter.returnedWithin(300))
            assertTrue(t.isPaused)
            assertTrue(t.isWaived)
            // 继续 on the pill is what lets it go on.
            t.setPaused(false)
            assertTrue(waiter.returnedWithin(5_000))
            assertEquals(true, waiter.result.get())
            assertTrue(t.isWaived)
        } finally {
            waiter.interrupt()
            t.callEnded(t.activeOwner())
        }
    }

    @Test fun theIdleClockRestartsOnResume() {
        val t = tasks()
        t.begin()
        t.setPaused(true)
        now += t.idleMs * 2
        t.setPaused(false)
        now += t.idleMs
        assertFalse(t.expireIdle())
        assertTrue(t.snapshot().active)
        now += 1
        assertTrue(t.expireIdle())
        assertFalse(t.snapshot().active)
    }

    @Test fun aRunningCallIsNeverIdle() {
        val t = tasks()
        t.callStarted()
        t.begin()
        now += t.idleMs * 2
        assertFalse(t.expireIdle())
        assertTrue(t.snapshot().active)
        // The clock starts when the result went back.
        t.callEnded(t.activeOwner())
        now += t.idleMs
        assertFalse(t.expireIdle())
        now += 1
        assertTrue(t.expireIdle())
    }

    @Test fun aStopWhileWaitingIsNoResume() {
        val t = tasks()
        t.callStarted()
        t.begin()
        t.setPaused(true)
        val waiter = Waiter(t)
        try {
            assertFalse(waiter.returnedWithin(200))
            t.stop("stopped on the pill")
            assertTrue(waiter.returnedWithin(5_000))
            assertEquals(false, waiter.result.get())
        } finally {
            waiter.interrupt()
            t.callEnded(t.activeOwner())
        }
    }

    @Test fun theTaskEndingUnderTheWaitIsNoResume() {
        val t = tasks()
        t.callStarted()
        t.begin()
        t.setPaused(true)
        val waiter = Waiter(t)
        try {
            assertFalse(waiter.returnedWithin(200))
            // The engine went away: the pause clears with the task, but the call must not act.
            t.endTask()
            assertTrue(waiter.returnedWithin(5_000))
            assertEquals(false, waiter.result.get())
            assertFalse(t.isActive)
        } finally {
            waiter.interrupt()
            t.callEnded(t.activeOwner())
        }
    }

    @Test fun anUnpausedIdleTaskStillEnds() {
        val t = tasks()
        t.begin()
        t.waive()
        now += t.idleMs + 1
        assertFalse(t.snapshot().active)
        assertTrue(t.expireIdle())
        assertFalse(t.isWaived)
        val next = t.begin() as PhoneTasks.Begin.Go
        assertTrue(next.newTask)
    }

    private companion object {
        /** Longer than any clock jump here, so only a resume, stop or end lets a waiter return. */
        const val WAIT_MS = 3_600_000L
    }
}
