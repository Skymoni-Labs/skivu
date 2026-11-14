package com.skyjjgw.independent.ski.dshgo.phone

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

/** Exercise the real Callable boundary with a controllable clock, not a copied state machine. */
class SerialWorkerAdmissionTest {
    @Test fun queuedDeadlineWinningBeforeBodyClaimPreventsLateExecution() {
        val time = AtomicLong(1_000)
        val atClock = CountDownLatch(1)
        val clockReply = CountDownLatch(1)
        val clockCalls = AtomicInteger()
        val bodyCalls = AtomicInteger()
        val worker = SerialWorker("admission-clock", {
            if (Thread.currentThread().name.startsWith("admission-clock-") && clockCalls.getAndIncrement() == 0) {
                atClock.countDown()
                check(clockReply.await(5, TimeUnit.SECONDS))
            }
            time.get()
        }) { false }
        val caller = Executors.newSingleThreadExecutor()
        try {
            val result = caller.submit<SerialWorker.Outcome<Int>> { worker.run(10_000, 100, Any()) { bodyCalls.incrementAndGet() } }
            assertTrue(atClock.await(5, TimeUnit.SECONDS))
            time.addAndGet(1_000)
            val timeout = result.get(5, TimeUnit.SECONDS)
            assertTrue(timeout is SerialWorker.Outcome.TimedOut && timeout.queued)
            assertEquals(0, bodyCalls.get())
            clockReply.countDown()
            // This real next call must pass the old Callable in the same executor queue.
            val next = worker.run(10_000, 10_000) { 23 }
            assertTrue(next is SerialWorker.Outcome.Done && next.value == 23)
            assertEquals("the cancelled pre-claim body must never run later", 0, bodyCalls.get())
        } finally { clockReply.countDown(); caller.shutdownNow(); worker.shutdown() }
    }

    @Test fun claimedBodyAtZeroClockIsNeverReportedAsQueuedAndRetainsPhysicalDrain() {
        val time = AtomicLong(0) // Zero is a valid starting timestamp, not a QUEUED sentinel.
        val entered = CountDownLatch(1)
        val bodyReply = CountDownLatch(1)
        val drained = CountDownLatch(1)
        val owner = Any()
        val worker = SerialWorker("admission-running", time::get) { false }
        val caller = Executors.newSingleThreadExecutor()
        try {
            val result = caller.submit<SerialWorker.Outcome<Int>> {
                worker.run(10_000, 100, owner) {
                    entered.countDown()
                    // Simulates a platform body which still owns physical work after cancellation.
                    while (true) {
                        try { if (bodyReply.await(5, TimeUnit.SECONDS)) break else error("test reply missing") }
                        catch (_: InterruptedException) { }
                    }
                    42
                }
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            time.addAndGet(1_000)
            val timeout = result.get(5, TimeUnit.SECONDS)
            assertTrue(timeout is SerialWorker.Outcome.TimedOut && !timeout.queued)
            worker.afterDrained(owner) { drained.countDown() }
            assertEquals(1L, drained.count)
            bodyReply.countDown()
            assertTrue(drained.await(5, TimeUnit.SECONDS))
        } finally { bodyReply.countDown(); caller.shutdownNow(); worker.shutdown() }
    }

    @Test fun retiredBodyCannotDeliverSuccessAfterConsumingItsInterrupt() {
        val worker = SerialWorker("retire-delivery")
        val caller = Executors.newSingleThreadExecutor()
        val entered = CountDownLatch(1); val interrupted = CountDownLatch(1)
        val release = CountDownLatch(1); val drained = CountDownLatch(1)
        val owner = Any()
        try {
            val result = caller.submit<SerialWorker.Outcome<Int>> {
                worker.run(10_000, 10_000, owner) {
                    entered.countDown()
                    awaitIgnoringInterrupt(release, interrupted)
                    assertFalse(Thread.currentThread().isInterrupted)
                    42
                }
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            worker.retire()
            assertTrue(interrupted.await(5, TimeUnit.SECONDS))
            worker.afterDrained(owner) { drained.countDown() }
            assertEquals("retirement is not physical completion", 1L, drained.count)
            assertFalse(result.isDone)
            release.countDown()
            assertSame("old-epoch value must not leave the worker", SerialWorker.Outcome.Interrupted,
                result.get(5, TimeUnit.SECONDS))
            assertTrue(drained.await(5, TimeUnit.SECONDS))
            val next = worker.run(10_000, 10_000) { 23 }
            assertTrue(next is SerialWorker.Outcome.Done && next.value == 23)
        } finally { release.countDown(); caller.shutdownNow(); worker.shutdown() }
    }

    @Test fun retirementAfterBodyReturnStillRejectsTheNotYetDeliveredValue() {
        val worker = SerialWorker("retire-after-return")
        val caller = Executors.newSingleThreadExecutor()
        val entered = CountDownLatch(1); val finishBody = CountDownLatch(1)
        val atObserver = CountDownLatch(1); val finishObserver = CountDownLatch(1)
        val observerFailure = AtomicReference<Throwable?>()
        val owner = Any()
        try {
            val result = caller.submit<SerialWorker.Outcome<Int>> {
                worker.run(10_000, 10_000, owner) {
                    entered.countDown()
                    check(finishBody.await(5, TimeUnit.SECONDS))
                    42
                }
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            // Existing production drain callback: job() has returned, current is cleared,
            // but Callable/Future delivery still waits for this observer. No new worker hook.
            worker.afterDrained(owner) {
                atObserver.countDown()
                try { check(finishObserver.await(5, TimeUnit.SECONDS)) }
                catch (error: Throwable) { observerFailure.set(error) }
            }
            finishBody.countDown()
            assertTrue(atObserver.await(5, TimeUnit.SECONDS))
            worker.retire() // No running thread remains in current to carry an interrupt.
            finishObserver.countDown()
            assertSame(SerialWorker.Outcome.Interrupted, result.get(5, TimeUnit.SECONDS))
            assertNull("drain observer must complete without a hidden failure", observerFailure.get())
            val next = worker.run(10_000, 10_000) { 23 }
            assertTrue(next is SerialWorker.Outcome.Done && next.value == 23)
        } finally {
            finishBody.countDown(); finishObserver.countDown()
            caller.shutdownNow(); worker.shutdown()
        }
    }

    private fun awaitIgnoringInterrupt(release: CountDownLatch, interrupted: CountDownLatch) {
        while (true) try { check(release.await(5, TimeUnit.SECONDS)); return }
        catch (_: InterruptedException) { interrupted.countDown() }
    }

}
