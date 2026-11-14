package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class BackgroundPreviewWorkerTest {
    @Test fun stopObservesRealTerminationOfAShortEncoderTask() {
        val worker = BackgroundPreviewWorker(); val original = checkNotNull(worker.acquire())
        original.execute { Thread.sleep(100) }
        worker.stop()
        assertTrue(original.isTerminated)
        assertTrue(worker.drained())
    }

    @Test fun shutdownDoesNotDiscardTheOriginalEncoderOrAllowAnotherBeforeTermination() {
        val worker = BackgroundPreviewWorker(); val original = checkNotNull(worker.acquire())
        val entered = CountDownLatch(1); val exit = CountDownLatch(1)
        original.execute { entered.countDown(); check(exit.await(5, TimeUnit.SECONDS)) }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            worker.stop(); assertFalse(worker.drained()); assertNull(worker.acquire())
            exit.countDown(); assertTrue(original.awaitTermination(5, TimeUnit.SECONDS))
            assertTrue(worker.drained())
            val next = checkNotNull(worker.acquire()); assertNotSame(original, next)
            worker.stop(); assertTrue(next.awaitTermination(5, TimeUnit.SECONDS)); assertTrue(worker.drained())
        } finally { exit.countDown(); worker.stop() }
    }
}
