package com.skyjjgw.independent.ski.dshgo.phone

import java.util.concurrent.CountDownLatch
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class PhoneCallWorkTest {
    @Test fun successfulCommitPreventsALaterTimeoutAndEarlyWakeupDoesNotExpire() {
        var remaining = 10L
        var expirations = 0
        val work = PhoneCallWork({ "success" }, { remaining }, { expirations++; "timeout" })
        assertNull(work.expire())
        assertEquals("success", work.run())
        remaining = 0L
        assertNull(work.expire())
        assertEquals(0, expirations)
    }

    @Test fun actualSchedulerPublishesAnAlreadyDueReplyAndRetainsTheBodyForDrain() {
        val executor = ScheduledThreadPoolExecutor(1).apply { removeOnCancelPolicy = true }
        val delivered = CountDownLatch(1)
        val reply = java.util.concurrent.atomic.AtomicReference<String>()
        var bodies = 0
        val work = PhoneCallWork({ bodies++; "late" }, { 0L }, { "timeout" })
        try {
            work.schedule(executor) { reply.set(it); delivered.countDown() }
            assertTrue(delivered.await(5, TimeUnit.SECONDS))
            assertEquals("timeout", reply.get())
            assertEquals(0, bodies)
            assertNull(work.run())
            assertEquals(1, bodies)
        } finally { executor.shutdownNow() }
    }

    @Test fun successfulReplyRemovesItsPendingTimerWithoutWaitingForTheDeadline() {
        val executor = ScheduledThreadPoolExecutor(1).apply { removeOnCancelPolicy = true }
        val work = PhoneCallWork({ "success" }, { PhoneCore.MAX_TOTAL_MS }, { "timeout" })
        try {
            work.schedule(executor) { error("unexpected timeout") }
            assertEquals(1, executor.queue.size)
            assertEquals("success", work.run())
            assertTrue(executor.queue.isEmpty())
        } finally { executor.shutdownNow() }
    }

}
