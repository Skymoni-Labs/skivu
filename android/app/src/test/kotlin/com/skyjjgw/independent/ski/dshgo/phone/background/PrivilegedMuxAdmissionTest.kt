package com.skyjjgw.independent.ski.dshgo.phone.background

import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

class PrivilegedMuxAdmissionTest {
    private fun await(latch: CountDownLatch) { assertTrue(latch.await(3, TimeUnit.SECONDS)) }
    private fun waiting(thread: Thread) {
        val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (thread.state != Thread.State.WAITING && System.nanoTime() < until) Thread.yield()
        assertEquals(Thread.State.WAITING, thread.state)
    }

    @Test fun threeBodiesAndGlobalBarrierExcludeLaterAdmissionUntilItsReply() {
        val calls = PrivilegedCalls(3); val pool = Executors.newFixedThreadPool(3)
        val entered = CountDownLatch(3); val release = CountDownLatch(1)
        val globalEntered = CountDownLatch(1); val globalReply = CountDownLatch(1)
        val globalDone = CountDownLatch(1); val later = AtomicBoolean(false)
        val global = Thread {
            calls.execute(global = true) { globalEntered.countDown(); globalReply.await(); false }
            globalDone.countDown()
        }
        val next = Thread { calls.execute { later.set(true) } }
        try {
            val bodies = (1..3).map { pool.submit { calls.execute { entered.countDown(); release.await() } } }
            await(entered); assertNull(calls.tryPreview { "frame" })
            global.start(); waiting(global); next.start(); waiting(next)
            release.countDown(); await(globalEntered)
            assertFalse(later.get()); assertNull(calls.tryPreview { "frame" })
            globalReply.countDown(); await(globalDone); next.join(3000)
            assertTrue(later.get()); bodies.forEach { it.get(3, TimeUnit.SECONDS) }
        } finally { release.countDown(); globalReply.countDown(); calls.retire(); pool.shutdownNow(); global.join(3000); next.join(3000) }
    }

    @Test fun successfulDestroyNeverPinsAFirstRequestWaitingOutsideTheGate() {
        for (success in listOf(true, false)) {
            val calls = PrivilegedCalls(3); val io = BackgroundDisplayIo<Any>(); val peer = Any()
            val entered = CountDownLatch(1); val response = CountDownLatch(1); val requestEntered = CountDownLatch(1)
            val destroyed = Thread { calls.execute<Boolean>(global = true, terminal = { it }) { entered.countDown(); response.await(); success } }
            val pool = Executors.newSingleThreadExecutor()
            try {
                destroyed.start(); await(entered)
                val first = pool.submit<Boolean> {
                    try {
                        io.call { io.startResource(peer, { commit ->
                            requestEntered.countDown()
                            calls.execute(beforeSend = commit) { true }
                        }) { true } }
                        true
                    } catch (_: IOException) { false }
                }
                await(requestEntered); assertNull(io.peer())
                response.countDown(); destroyed.join(3000)
                assertEquals(!success, first.get(3, TimeUnit.SECONDS))
                if (success) {
                    assertNull(io.peer()); var sentRelease = false
                    assertTrue(io.release { sentRelease = true; true }); assertFalse(sentRelease)
                } else {
                    assertSame(peer, io.peer()); assertTrue(io.release { assertSame(peer, it); true })
                }
            } finally { response.countDown(); calls.retire(); io.seal(); pool.shutdownNow(); destroyed.join(3000) }
        }
    }

    @Test fun callbackFailureDoesNotSendAndDoesNotPoisonOtherOwners() {
        val calls = PrivilegedCalls(3); var sent = false
        try { calls.execute(beforeSend = { throw IllegalStateException("sealed") }) { sent = true }; fail() }
        catch (_: IllegalStateException) { }
        assertFalse(sent); assertEquals("next", calls.execute { "next" })
    }

    @Test fun retireWakesQueuedAdmissionWithoutCallingItsPinCallback() {
        val calls = PrivilegedCalls(); val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2); val pinned = AtomicBoolean(false)
        val queued = CountDownLatch(1); val waiterThread = AtomicReference<Thread>()
        try {
            val active = pool.submit { calls.execute { entered.countDown(); release.await() } }; await(entered)
            val waiter = pool.submit<Boolean> {
                waiterThread.set(Thread.currentThread()); queued.countDown()
                try { calls.execute(beforeSend = { pinned.set(true) }) { Unit }; false } catch (_: IOException) { true }
            }
            await(queued); waiting(waiterThread.get())
            calls.retire(); assertTrue(waiter.get(3, TimeUnit.SECONDS)); assertFalse(pinned.get())
            release.countDown(); active.get(3, TimeUnit.SECONDS)
        } finally { release.countDown(); calls.retire(); pool.shutdownNow() }
    }
}
