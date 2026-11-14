package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

/** Stop-time facts, independent of whether a ticker delivered an active sample. */
class PhoneTasksInterruptedTest {
    @Test fun activeStopReportsInterruptionEvenWhenTheLastDeliveredStateWasCold() {
        val tasks = PhoneTasks(clock = { 1_000L })
        val delivered = tasks.snapshot().toMap()
        tasks.begin()
        tasks.stop("screen off")
        assertEquals(false, delivered["active"])
        val stopped = tasks.snapshot()
        assertFalse(stopped.active)
        assertTrue(stopped.stopped)
        assertTrue(stopped.interrupted)
        assertEquals(true, stopped.toMap()["interrupted"])
    }

    @Test fun coldAndIdleExplicitStopsHaveAHoldButDidNotInterruptATask() {
        var time = 0L
        val tasks = PhoneTasks(clock = { time }, idleMs = 10)
        tasks.stop("cold explicit stop")
        assertTrue(tasks.snapshot().stopped)
        assertFalse(tasks.snapshot().interrupted)
        tasks.clearStop()
        tasks.begin()
        time = 11
        assertTrue(tasks.isActive) // Internal lifetime has not expired yet.
        assertFalse(tasks.snapshot().active)
        tasks.stop("idle explicit stop")
        assertTrue(tasks.snapshot().stopped)
        assertFalse(tasks.snapshot().interrupted)
        assertEquals(false, tasks.snapshot().toMap()["interrupted"])
    }

    @Test fun normalFinishThenImmediateStopDoesNotAdoptTheLastDeliveredActiveSample() {
        val tasks = PhoneTasks(clock = { 1_000L })
        tasks.begin()
        val delivered = tasks.snapshot()
        assertTrue(tasks.finish(delivered.id))
        tasks.stop("screen off after normal finish")
        assertTrue(delivered.active)
        assertTrue(tasks.snapshot().stopped)
        assertFalse(tasks.snapshot().interrupted)
    }

    @Test fun repeatedStopsKeepTrueOnlyWithinTheCurrentHold() {
        var time = 0L
        val tasks = PhoneTasks(clock = { time }, stopHoldMs = 10)
        tasks.begin()
        tasks.stop("first")
        time = 9
        tasks.stop("repeated explicit stop") // Extends the existing hold to 19.
        assertTrue(tasks.snapshot().interrupted)
        val ambient = tasks.stopActiveDeferred("second screen receiver")
        assertTrue(ambient.snapshot.interrupted) // Ambient repeat does not extend it.
        time = 18
        assertTrue(tasks.snapshot().interrupted)
        time = 19
        assertFalse(tasks.snapshot().stopped)
        assertFalse(tasks.snapshot().interrupted)
    }

    @Test fun anExpiredHoldCannotDonateTrueToANewColdStopWithoutAnIntermediateSnapshot() {
        var time = 0L
        val tasks = PhoneTasks(clock = { time }, stopHoldMs = 10)
        tasks.begin()
        tasks.stop("running")
        time = 10 // No snapshot, ticker, begin or explicit clear since the stop.
        tasks.stop("later cold stop")
        assertTrue(tasks.snapshot().stopped)
        assertFalse(tasks.snapshot().interrupted)
    }

    @Test fun refusedRetryRetainsInterruptionWhileRenewingTheSameHold() {
        var time = 0L
        val tasks = PhoneTasks(clock = { time }, stopHoldMs = 10)
        tasks.begin()
        tasks.stop("stop")
        time = 9
        assertTrue(tasks.begin() is PhoneTasks.Begin.Refused)
        time = 18
        assertTrue(tasks.snapshot().stopped)
        assertTrue(tasks.snapshot().interrupted)
        time = 19
        assertFalse(tasks.snapshot().interrupted)
    }

    @Test fun newTaskAndEveryExplicitHoldClearStartWithFalse() {
        for (clear in listOf<(PhoneTasks) -> Unit>(
            { it.clearStop() },
            { assertNotNull(it.resumeForSnapshot(it.snapshot())) },
            { assertTrue(it.finish()) },
        )) {
            val tasks = PhoneTasks(clock = { 1_000L })
            val first = (tasks.begin() as PhoneTasks.Begin.Go).taskId
            tasks.stop("stop")
            assertTrue(tasks.snapshot().interrupted)
            clear(tasks)
            assertFalse(tasks.snapshot().interrupted)
            val next = tasks.begin() as PhoneTasks.Begin.Go
            assertNotEquals(first, next.taskId)
            assertFalse(tasks.snapshot().interrupted)
        }
        var time = 0L
        val tasks = PhoneTasks(clock = { time }, stopHoldMs = 10)
        tasks.begin(); tasks.stop("stop")
        time = 10
        assertTrue(tasks.begin() is PhoneTasks.Begin.Go)
        assertFalse(tasks.snapshot().interrupted)
    }

    @Test fun pausedAndInFlightTasksRemainPubliclyActivePastTheIdleDeadline() {
        var time = 0L
        val paused = PhoneTasks(clock = { time }, idleMs = 10)
        paused.begin(); paused.setPaused(true)
        val running = PhoneTasks(clock = { time }, idleMs = 10)
        val owner = (running.begin() as PhoneTasks.Begin.Go).owner
        running.callStarted()
        time = 11
        assertTrue(paused.snapshot().active)
        assertTrue(running.snapshot().active)
        paused.stop("stop paused")
        running.stop("stop running")
        assertTrue(paused.snapshot().interrupted)
        assertTrue(running.snapshot().interrupted)
        running.callEnded(owner)
    }

    @Test fun ambientDecisionAndInterruptionUseOneClockSampleAtTheIdleBoundary() {
        var next = 0L
        val tasks = PhoneTasks(clock = { next++ }, idleMs = 2, stopHoldMs = 10)
        tasks.begin() // begin=0; its listener snapshot=1.
        val stopped = tasks.stopActiveDeferred("screen off") // exact decision time=2, still active.
        assertTrue(stopped.snapshot.stopped)
        assertTrue(stopped.snapshot.interrupted)
    }

    @Test fun oldCapturedStopIsHistoricalAndCannotChangeANewTasksCurrentBit() {
        val tasks = PhoneTasks(clock = { 1_000L })
        val old = (tasks.begin() as PhoneTasks.Begin.Go).owner
        val captured = tasks.stopForOwner(old, "stop")!!
        tasks.clearStop()
        val next = (tasks.begin() as PhoneTasks.Begin.Go).owner
        tasks.publish(captured)
        assertTrue(captured.snapshot.interrupted)
        assertFalse(tasks.snapshot().interrupted)
        assertTrue(tasks.isCurrent(next))
        assertFalse(tasks.isCurrent(old))
    }
}
