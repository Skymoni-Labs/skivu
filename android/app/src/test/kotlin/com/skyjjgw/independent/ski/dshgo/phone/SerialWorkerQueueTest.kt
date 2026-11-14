package com.skyjjgw.independent.ski.dshgo.phone

import java.util.concurrent.Callable
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class SerialWorkerQueueTest {
    @Test fun shutdownCompletesEveryRemovedFutureWithoutRunningItsBody() {
        val worker = SerialWorker("queue-close-test")
        // Observe the real owned executor; do not replace it or change the worker's clock.
        val executor = SerialWorker::class.java.getDeclaredField("executor").apply {
            isAccessible = true
        }.get(worker) as ExecutorService
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val ran = AtomicInteger()
        try {
            executor.submit {
                entered.countDown()
                release.await()
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            // submit has returned for both Futures while the sole worker is still held.
            val queued = List(2) { executor.submit(Callable { ran.incrementAndGet() }) }
            assertTrue(queued.all { !it.isDone })

            worker.shutdown()
            worker.shutdown()

            for (future in queued) {
                assertTrue("a removed task must complete its Future", future.isDone)
                assertTrue(future.isCancelled)
                try {
                    future.get(0, TimeUnit.MILLISECONDS)
                    fail("the removed body must not produce a value")
                } catch (_: CancellationException) {
                }
            }
            assertEquals(0, ran.get())
        } finally {
            release.countDown()
            worker.shutdown()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
        }
    }
}
