package com.skyjjgw.independent.ski.dshgo.phone

import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.FutureTask
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RunnableFuture
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

class SerialWorkerTimeoutOwnerTest {
    private fun await(latch: CountDownLatch) {
        assertTrue("controlled worker transition did not arrive", latch.await(5, TimeUnit.SECONDS))
    }

    /** Real single-thread execution; only the caller's first timed get is forced to time out. */
    private inner class ControlledExecutor(
        val clock: AtomicLong,
        val firstEntered: CountDownLatch,
        val secondSubmitted: CountDownLatch,
        val afterCancel: () -> Unit,
    ) : ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, LinkedBlockingQueue<Runnable>()) {
        private val submitted = AtomicInteger()
        override fun execute(command: Runnable) {
            super.execute(command)
            if (submitted.get() == 2) secondSubmitted.countDown()
        }
        override fun <T> newTaskFor(callable: Callable<T>): RunnableFuture<T> {
            val ordinal = submitted.incrementAndGet()
            return object : FutureTask<T>(callable) {
                private var firstPoll = true
                override fun get(timeout: Long, unit: TimeUnit): T {
                    if (ordinal == 1 && firstPoll) {
                        firstPoll = false
                        await(firstEntered)
                        await(secondSubmitted)
                        clock.set(2_000)
                        throw TimeoutException("controlled budget expiry")
                    }
                    // These gets await a latch-controlled result, never a real-time timeout.
                    return super.get()
                }
                override fun cancel(mayInterruptIfRunning: Boolean): Boolean {
                    val cancelled = super.cancel(mayInterruptIfRunning)
                    if (ordinal == 1 && cancelled) afterCancel()
                    return cancelled
                }
            }
        }
    }

    private fun install(worker: SerialWorker, executor: ExecutorService) {
        val field = SerialWorker::class.java.getDeclaredField("executor").apply { isAccessible = true }
        (field.get(worker) as ExecutorService).shutdownNow()
        field.set(worker, executor)
    }

    private fun executor(worker: SerialWorker): ExecutorService =
        SerialWorker::class.java.getDeclaredField("executor").apply { isAccessible = true }
            .get(worker) as ExecutorService

    @Test fun aFinishedTimedOutJobCannotRetireItsSuccessorOnTheSameThread() = successor(false)

    @Test fun completionAtTheGraceBoundaryCannotRetireItsSuccessor() = successor(true)

    private fun successor(finishDuringGrace: Boolean) {
        val clock = AtomicLong(1_000)
        val firstEntered = CountDownLatch(1)
        val secondSubmitted = CountDownLatch(1)
        val secondEntered = CountDownLatch(1)
        val firstRelease = CountDownLatch(1)
        val secondRelease = CountDownLatch(1)
        val firstDone = CountDownLatch(1)
        val secondDone = CountDownLatch(1)
        val firstThread = AtomicReference<Thread>()
        val secondThread = AtomicReference<Thread>()
        val firstResult = AtomicReference<SerialWorker.Outcome<String>>()
        val secondResult = AtomicReference<SerialWorker.Outcome<String>>()
        val worker = SerialWorker("timeout-owner", clock::get) {
            firstRelease.countDown()
            await(secondEntered)
            clock.set(4_000)
            false // The timeout boundary raced a completed job; the final check must see completion.
        }
        val original = ControlledExecutor(clock, firstEntered, secondSubmitted) {
            if (!finishDuringGrace) await(secondEntered)
        }
        install(worker, original)
        val firstCaller = Thread {
            try {
                firstResult.set(worker.run(10, 100_000) {
                    firstThread.set(Thread.currentThread())
                    firstEntered.countDown()
                    try { firstRelease.await() } catch (_: InterruptedException) {
                        if (finishDuringGrace) firstRelease.await()
                    }
                    "first"
                })
            } finally { firstDone.countDown() }
        }
        val secondCaller = Thread {
            try {
                secondResult.set(worker.run(100_000, 100_000) {
                    secondThread.set(Thread.currentThread())
                    secondEntered.countDown()
                    secondRelease.await()
                    "second"
                })
            } finally { secondDone.countDown() }
        }
        try {
            firstCaller.start()
            await(firstEntered)
            secondCaller.start()
            await(firstDone)
            assertSame("A and B must reuse the same executor thread", firstThread.get(), secondThread.get())
            assertSame("A's timeout must keep B's executor", original, executor(worker))
            assertFalse(original.isShutdown)
            val timedOut = firstResult.get() as SerialWorker.Outcome.TimedOut
            assertFalse(timedOut.queued)
            secondRelease.countDown()
            await(secondDone)
            assertEquals("second", (secondResult.get() as SerialWorker.Outcome.Done<*>).value)
        } finally {
            firstRelease.countDown(); secondRelease.countDown()
            worker.shutdown(); original.shutdownNow()
            firstCaller.join(5_000); secondCaller.join(5_000)
            assertFalse(firstCaller.isAlive); assertFalse(secondCaller.isAlive)
            assertTrue(original.awaitTermination(5, TimeUnit.SECONDS))
        }
    }

    @Test fun anUnfinishedJobStillRetiresItsExecutorAndCancelsOnlyQueuedJobs() {
        val clock = AtomicLong(1_000)
        val firstEntered = CountDownLatch(1)
        val secondSubmitted = CountDownLatch(1)
        val release = CountDownLatch(1)
        val firstDone = CountDownLatch(1)
        val secondDone = CountDownLatch(1)
        val ranSecond = AtomicInteger()
        val firstResult = AtomicReference<SerialWorker.Outcome<String>>()
        val secondResult = AtomicReference<SerialWorker.Outcome<String>>()
        val worker = SerialWorker("stuck-owner", clock::get) { clock.set(4_000); false }
        val original = ControlledExecutor(clock, firstEntered, secondSubmitted) {}
        install(worker, original)
        val firstCaller = Thread {
            try {
                firstResult.set(worker.run(10, 100_000) {
                    firstEntered.countDown()
                    while (release.count != 0L) {
                        try { release.await() } catch (_: InterruptedException) { /* deliberately stuck */ }
                    }
                    "first"
                })
            } finally { firstDone.countDown() }
        }
        val secondCaller = Thread {
            try {
                secondResult.set(worker.run(100_000, 100_000) { ranSecond.incrementAndGet(); "second" })
            } finally { secondDone.countDown() }
        }
        try {
            firstCaller.start(); await(firstEntered)
            secondCaller.start(); await(firstDone); await(secondDone)
            assertNotSame(original, executor(worker))
            assertTrue(original.isShutdown)
            assertFalse((firstResult.get() as SerialWorker.Outcome.TimedOut).queued)
            assertTrue((secondResult.get() as SerialWorker.Outcome.TimedOut).queued)
            assertEquals(0, ranSecond.get())
            assertEquals("new", (worker.run(100_000, 100_000) { "new" } as SerialWorker.Outcome.Done<*>).value)
        } finally {
            release.countDown()
            worker.shutdown(); original.shutdownNow()
            firstCaller.join(5_000); secondCaller.join(5_000)
            assertFalse(firstCaller.isAlive); assertFalse(secondCaller.isAlive)
            assertTrue(original.awaitTermination(5, TimeUnit.SECONDS))
        }
    }

    @Test fun interruptedGraceStillRetiresAStuckJobAndCancelsItsQueue() = interruptedGrace(false)

    @Test fun interruptedGraceDoesNotRetireAnAlreadyFinishedJobsSuccessor() = interruptedGrace(true)

    private fun interruptedGrace(finishBeforeInterrupt: Boolean) {
        val clock = AtomicLong(1_000)
        val firstEntered = CountDownLatch(1)
        val secondSubmitted = CountDownLatch(1)
        val secondEntered = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val releaseSecond = CountDownLatch(1)
        val firstDone = CountDownLatch(1)
        val secondDone = CountDownLatch(1)
        val firstResult = AtomicReference<SerialWorker.Outcome<String>>()
        val secondResult = AtomicReference<SerialWorker.Outcome<String>>()
        val escaped = AtomicReference<Throwable>()
        val callerInterrupted = AtomicBoolean()
        val worker = SerialWorker("grace-interrupt", clock::get) {
            if (finishBeforeInterrupt) {
                releaseFirst.countDown()
                await(secondEntered) // A's finally is complete; B reuses the original worker.
            }
            // A real interruptible latch wait clears the flag and throws; no elapsed-time wait.
            Thread.currentThread().interrupt()
            CountDownLatch(1).await()
            false
        }
        val original = ControlledExecutor(clock, firstEntered, secondSubmitted) {}
        install(worker, original)
        val firstCaller = Thread {
            try {
                firstResult.set(worker.run(10, 100_000) {
                    firstEntered.countDown()
                    while (releaseFirst.count != 0L) {
                        try { releaseFirst.await() } catch (_: InterruptedException) { /* hold A */ }
                    }
                    "first"
                })
                callerInterrupted.set(Thread.currentThread().isInterrupted)
            } catch (error: Throwable) { escaped.set(error) }
            finally { firstDone.countDown() }
        }
        val secondCaller = Thread {
            try {
                secondResult.set(worker.run(100_000, 100_000) {
                    secondEntered.countDown()
                    releaseSecond.await()
                    "second"
                })
            } finally { secondDone.countDown() }
        }
        try {
            firstCaller.start(); await(firstEntered)
            secondCaller.start(); await(firstDone)
            assertNull("grace interruption must be returned, not escape run", escaped.get())
            assertSame(SerialWorker.Outcome.Interrupted, firstResult.get())
            assertTrue("caller interruption must be restored", callerInterrupted.get())
            if (finishBeforeInterrupt) {
                assertSame(original, executor(worker))
                assertFalse(original.isShutdown)
                releaseSecond.countDown(); await(secondDone)
                assertEquals("second", (secondResult.get() as SerialWorker.Outcome.Done<*>).value)
            } else {
                assertNotSame(original, executor(worker))
                assertTrue(original.isShutdown)
                await(secondDone)
                assertTrue((secondResult.get() as SerialWorker.Outcome.TimedOut).queued)
                assertEquals(1L, secondEntered.count)
                assertEquals("new", (worker.run(100_000, 100_000) { "new" } as SerialWorker.Outcome.Done<*>).value)
            }
        } finally {
            releaseFirst.countDown(); releaseSecond.countDown()
            worker.shutdown(); original.shutdownNow()
            firstCaller.join(5_000); secondCaller.join(5_000)
            assertFalse(firstCaller.isAlive); assertFalse(secondCaller.isAlive)
            assertTrue(original.awaitTermination(5, TimeUnit.SECONDS))
        }
    }

}
