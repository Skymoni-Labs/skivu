package com.skyjjgw.independent.ski.dshgo.phone

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class SystemDispatchTest {
    private fun tasks() = PhoneTasks(clock = { 1_000L }).apply { begin() }

    @Test fun stopDuringPreparationRefusesTheOriginalOwner() {
        val tasks = tasks()
        val dispatch = tasks.systemDispatch(tasks.activeOwner()!!)
        val preparing = CountDownLatch(1)
        val prepared = CountDownLatch(1)
        val calls = AtomicInteger()
        val worker = Executors.newSingleThreadExecutor()
        try {
            val result = worker.submit<Boolean> {
                preparing.countDown()
                assertTrue(prepared.await(5, TimeUnit.SECONDS))
                dispatch.commitStart().also { if (it) calls.incrementAndGet() }
            }
            assertTrue(preparing.await(5, TimeUnit.SECONDS))
            tasks.stop("stop during package lookup")
            tasks.clearStop()
            tasks.begin()
            prepared.countDown()
            assertFalse(result.get(5, TimeUnit.SECONDS))
            assertEquals(0, calls.get())
            assertTrue(tasks.systemDispatch(tasks.activeOwner()!!).commitStart())
        } finally { prepared.countDown(); worker.shutdownNow() }
    }

    @Test fun committedActionMayRunAfterStopReturnsButCannotCommitAgain() {
        val tasks = tasks()
        val dispatch = tasks.systemDispatch(tasks.activeOwner()!!)
        val committed = CountDownLatch(1)
        val perform = CountDownLatch(1)
        val calls = AtomicInteger()
        val worker = Executors.newSingleThreadExecutor()
        try {
            val result = worker.submit<Boolean> {
                assertTrue(dispatch.commitStart())
                committed.countDown()
                assertTrue(perform.await(5, TimeUnit.SECONDS))
                calls.incrementAndGet()
                dispatch.commitStart()
            }
            assertTrue(committed.await(5, TimeUnit.SECONDS))
            // No action is running under the task lock: stop finishes before perform is released.
            tasks.stop("already committed")
            assertEquals(0, calls.get())
            perform.countDown()
            assertFalse(result.get(5, TimeUnit.SECONDS))
            assertEquals(1, calls.get())
            assertFalse(dispatch.commitNotice())
        } finally { perform.countDown(); worker.shutdownNow() }
    }

    @Test fun noticeRequiresStartAndItsOwnSingleCurrentCommit() {
        val tasks = tasks()
        val dispatch = tasks.systemDispatch(tasks.activeOwner()!!)
        assertFalse(dispatch.commitNotice())
        assertTrue(dispatch.commitStart())
        assertFalse(dispatch.commitStart())
        assertTrue(dispatch.commitNotice())
        assertFalse(dispatch.commitNotice())
        val cancelled = tasks.systemDispatch(tasks.activeOwner()!!)
        assertTrue(cancelled.commitStart())
        tasks.invalidateOwners()
        assertFalse(cancelled.commitNotice())
    }

    @Test fun observedInterruptRefusesBothCommitsWithoutClearingTheFlag() {
        val tasks = tasks()
        val dispatch = tasks.systemDispatch(tasks.activeOwner()!!)
        Thread.currentThread().interrupt()
        try {
            assertFalse(dispatch.commitStart())
            assertTrue(Thread.currentThread().isInterrupted)
        } finally { Thread.interrupted() }
        assertTrue(dispatch.commitStart())
        Thread.currentThread().interrupt()
        try {
            assertFalse(dispatch.commitNotice())
            assertTrue(Thread.currentThread().isInterrupted)
        } finally { Thread.interrupted() }
    }

    @Test fun inactiveOwnerCannotDispatchAndLateResultCannotRenameSuccessor() {
        val tasks = tasks()
        val old = tasks.activeOwner()!!
        assertTrue(tasks.setAppIfCurrent(old, "old"))
        tasks.endTask()
        val inactive = tasks.beforeTaskOwner()!!
        assertFalse(tasks.systemDispatch(inactive).commitStart())
        tasks.begin()
        val next = tasks.activeOwner()!!
        assertTrue(tasks.setAppIfCurrent(next, "new"))
        assertFalse(tasks.setAppIfCurrent(old, "late old"))
        assertEquals("new", tasks.snapshot().app)
    }
    @Test fun appChangeListenersRunOutsideTheTaskLock() {
        val tasks = tasks()
        val owner = tasks.activeOwner()!!
        val reader = Executors.newSingleThreadExecutor()
        var observed: String? = null
        tasks.addListener {
            // fire catches listener exceptions, so assert the completed value afterwards too.
            observed = reader.submit<String?> { tasks.snapshot().app }.get(5, TimeUnit.SECONDS)
        }
        try {
            assertTrue(tasks.setAppIfCurrent(owner, "current"))
            assertEquals("current", observed)
        } finally { reader.shutdownNow() }
    }

    @Test fun appLabelNotificationMayRetireOwnerBeforeSetterReturns() {
        val tasks = tasks()
        val original = tasks.activeOwner()!!
        var armed = true
        tasks.addListener { snapshot ->
            if (armed && snapshot.app == "old result") {
                armed = false
                tasks.endTask()
                tasks.begin()
                tasks.setApp("successor")
            }
        }
        // Publication was valid; the listener can retire it before this method returns.
        assertTrue(tasks.setAppIfCurrent(original, "old result"))
        assertFalse(tasks.isCurrent(original))
        assertFalse(tasks.systemDispatch(original).commitStart())
        assertEquals("successor", tasks.snapshot().app)
    }

}
