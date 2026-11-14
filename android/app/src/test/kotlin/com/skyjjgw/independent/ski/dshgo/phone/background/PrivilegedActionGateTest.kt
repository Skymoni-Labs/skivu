package com.skyjjgw.independent.ski.dshgo.phone.background

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class PrivilegedActionGateTest {
    @Test fun cancelledRootIntentNeverRunsAfterAnOlderPhoneOperationUnblocks() {
        val gate = PrivilegedActionGate()
        val queue = Executors.newSingleThreadExecutor()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val starts = AtomicInteger()
        try {
            queue.submit { entered.countDown(); release.await(2, TimeUnit.SECONDS) }
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            val rootTicket = gate.select()
            val rootAction = queue.submit { if (gate.current(rootTicket)) starts.incrementAndGet() }
            gate.select() // off / master switch off / engine detach, on the UI thread
            release.countDown()
            rootAction.get(2, TimeUnit.SECONDS)
            assertEquals(0, starts.get())
        } finally { release.countDown(); queue.shutdownNow() }
    }

    @Test fun statusReadsDoNotInvalidateOrCreateAnIntent() {
        val gate = PrivilegedActionGate()
        val selected = gate.select()
        repeat(10) { assertEquals(selected, gate.snapshot()) }
        assertTrue(gate.current(selected))
        val replacement = gate.select()
        assertFalse(gate.current(selected))
        assertTrue(gate.current(replacement))
    }
}
