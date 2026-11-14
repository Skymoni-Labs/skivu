package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.SerialWorker
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

/** Real production resource I/O gate + SerialWorker; no Android Bundle stubs are executed. */
class BackgroundDisplayIoTest {
    private fun await(latch: CountDownLatch) = assertTrue(latch.await(5, TimeUnit.SECONDS))
    private fun join(thread: Thread) { thread.join(5_000); assertFalse(thread.isAlive) }

    @Test fun previewOnlyReservesAnIdlePinnedResource() {
        val scope = BackgroundDisplayIo<Any>(); val peer = Any()
        val entered = CountDownLatch(1); val answer = CountDownLatch(1)
        val previews = AtomicInteger()
        assertNull(scope.tryPreview { previews.incrementAndGet() })
        val agent = Thread { scope.call { scope.startResource(peer, { beforeSend -> beforeSend(); entered.countDown(); answer.await() }) { true } } }.apply { start() }
        try {
            await(entered)
            assertNull(scope.tryPreview { previews.incrementAndGet() })
            answer.countDown(); join(agent)
            assertEquals(7, scope.tryPreview { assertSame(peer, it); previews.incrementAndGet(); 7 })
            scope.seal()
            assertNull(scope.tryPreview { previews.incrementAndGet() })
            assertEquals(1, previews.get())
            assertTrue(scope.release { true })
        } finally { answer.countDown(); join(agent) }
    }

    @Test fun strictCleanupWaitsForTheSamePhysicalPreviewReply() {
        val scope = BackgroundDisplayIo<Any>(); val peer = Any()
        scope.call { scope.startResource(peer, { beforeSend -> beforeSend(); Unit }) { true } }
        val entered = CountDownLatch(1); val answer = CountDownLatch(1)
        val replied = AtomicBoolean(); val releases = AtomicInteger()
        val ioInterrupted = AtomicBoolean(); val previewInterrupted = AtomicBoolean(); val cleanupInterrupted = AtomicBoolean()
        val preview = Thread {
            assertEquals(7, scope.tryPreview {
                assertSame(peer, it); entered.countDown(); answer.await()
                ioInterrupted.set(Thread.currentThread().isInterrupted); replied.set(true); 7
            })
            previewInterrupted.set(Thread.currentThread().isInterrupted)
        }.apply { start() }
        var cleanup: Thread? = null
        try {
            await(entered)
            cleanup = Thread {
                assertTrue(scope.release {
                    assertSame(peer, it); assertTrue(replied.get()); releases.incrementAndGet(); true
                })
                cleanupInterrupted.set(Thread.currentThread().isInterrupted)
            }.apply { start() }
            val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (!scope.previewClosed() && System.nanoTime() < until) Thread.yield()
            assertTrue(scope.previewClosed())
            assertEquals(0, releases.get())
            preview.interrupt(); cleanup.interrupt()
            answer.countDown(); join(preview); join(cleanup)
            assertFalse(ioInterrupted.get()); assertTrue(previewInterrupted.get()); assertTrue(cleanupInterrupted.get())
            assertEquals(1, releases.get())
            assertNull(scope.tryPreview { error("retired preview cannot reach its peer") })
            assertTrue(scope.release { error("the exact release was already acknowledged") })
        } finally { answer.countDown(); join(preview); cleanup?.let(::join) }
    }

    @Test fun anAgentWaitingAfterOnePreviewBlocksTheNextOptionalPoll() {
        val scope = BackgroundDisplayIo<Any>(); val peer = Any()
        scope.call { scope.startResource(peer, { beforeSend -> beforeSend(); Unit }) { true } }
        val previewEntered = CountDownLatch(1); val previewAnswer = CountDownLatch(1)
        val agentEntered = CountDownLatch(1); val agentAnswer = CountDownLatch(1)
        val sequence = java.util.Collections.synchronizedList(mutableListOf<String>())
        val preview = Thread { scope.tryPreview { sequence.add("preview"); previewEntered.countDown(); previewAnswer.await() } }.apply { start() }
        var agent: Thread? = null
        try {
            await(previewEntered)
            agent = Thread { scope.call { sequence.add("agent"); agentEntered.countDown(); agentAnswer.await() } }.apply { start() }
            previewAnswer.countDown(); await(agentEntered)
            assertNull(scope.tryPreview { sequence.add("late-preview") })
            agentAnswer.countDown(); join(agent); join(preview)
            assertEquals(listOf("preview", "agent"), sequence)
            assertTrue(scope.release { true })
        } finally { previewAnswer.countDown(); agentAnswer.countDown(); join(preview); agent?.let(::join) }
    }

    @Test fun releaseDuringFirstProbeSealsTheDriverBeforeAnyPeerCanBePinned() {
        val scope = BackgroundDisplayIo<Any>(); val peer = Any()
        val probe = CountDownLatch(1); val answer = CountDownLatch(1)
        val sent = AtomicInteger(); val failure = AtomicReference<Throwable?>()
        val caller = Thread {
            try { scope.call { probe.countDown(); answer.await(); scope.startResource(peer, { beforeSend -> beforeSend(); sent.incrementAndGet() }) { true } } }
            catch (error: Throwable) { failure.set(error) }
        }.apply { start() }
        try {
            await(probe)
            assertFalse(scope.release { error("an active probe is not a released display") })
            answer.countDown(); join(caller)
            assertTrue(failure.get() is IllegalStateException); assertEquals(0, sent.get()); assertNull(scope.peer())
            assertTrue(scope.release { error("nothing was ever dispatched to a peer") })
            assertThrows(IllegalStateException::class.java) { scope.call { sent.incrementAndGet() } }
        } finally { answer.countDown(); join(caller) }
    }

    @Test fun outerTimeoutDoesNotInterruptIoOrDrainTheOriginalWorkerBodyEarly() {
        val scope = BackgroundDisplayIo<Any>(); val peer = Any(); val owner = Any()
        val clock = AtomicLong(1_000); val worker = SerialWorker("shield-test", clock::get) { false }
        val pool = Executors.newSingleThreadExecutor()
        val entered = CountDownLatch(1); val reply = CountDownLatch(1); val drained = CountDownLatch(1)
        val ioInterrupted = AtomicBoolean(); val callerInterrupted = AtomicBoolean(); val laterDispatch = AtomicInteger()
        val result = pool.submit<SerialWorker.Outcome<Int>> {
            worker.run(100, 10_000, owner) {
                val value = scope.call {
                    scope.startResource(peer, { beforeSend -> beforeSend(); entered.countDown(); reply.await()
                        ioInterrupted.set(Thread.currentThread().isInterrupted); 7 }) { true }
                }
                callerInterrupted.set(Thread.currentThread().isInterrupted)
                try { scope.call { laterDispatch.incrementAndGet() } } catch (_: InterruptedException) { }
                value
            }
        }
        try {
            await(entered); clock.addAndGet(1_000)
            assertTrue(result.get(5, TimeUnit.SECONDS) is SerialWorker.Outcome.TimedOut)
            worker.afterDrained(owner) { drained.countDown() }
            assertEquals(1L, drained.count)
            assertFalse(scope.release { true })
            reply.countDown(); await(drained)
            assertFalse(ioInterrupted.get()); assertTrue(callerInterrupted.get()); assertEquals(0, laterDispatch.get())
            assertSame(peer, scope.peer())
            assertFalse(scope.release { false }) // a real unconfirmed result retains the same peer
            assertTrue(scope.release { assertSame(peer, it); true })
        } finally { reply.countDown(); pool.shutdownNow(); worker.shutdown() }
    }

    @Test fun interruptingCleanupWaiterStillDrainsTheSameReleaseFuture() {
        val scope = BackgroundDisplayIo<Any>(); val peer = Any()
        scope.call { scope.startResource(peer, { beforeSend -> beforeSend(); Unit }) { true } }
        val entered = CountDownLatch(1); val reply = CountDownLatch(1)
        val restored = AtomicBoolean(); val interruptedIo = AtomicBoolean(); val calls = AtomicInteger()
        val caller = Thread {
            assertTrue(scope.release {
                calls.incrementAndGet(); entered.countDown(); reply.await()
                interruptedIo.set(Thread.currentThread().isInterrupted); true
            })
            restored.set(Thread.currentThread().isInterrupted)
        }.apply { start() }
        try {
            await(entered); caller.interrupt()
            assertTrue(caller.isAlive); assertFalse(scope.release { error("a second release must not overtake the first") })
            reply.countDown(); join(caller)
            assertTrue(restored.get()); assertFalse(interruptedIo.get()); assertEquals(1, calls.get())
            assertTrue(scope.release { error("a confirmed resource is already closed") })
        } finally { reply.countDown(); join(caller) }
    }

    @Test fun sealedQueuedCallsNeverReachThePhysicalPeer() {
        val scope = BackgroundDisplayIo<Any>(); val peer = Any()
        val entered = CountDownLatch(1); val reply = CountDownLatch(1); val sent = AtomicInteger()
        val first = Thread { scope.call { scope.startResource(peer, { beforeSend -> beforeSend(); entered.countDown(); reply.await() }) { true } } }.apply { start() }
        val secondFailure = AtomicReference<Throwable?>()
        var second: Thread? = null
        try {
            await(entered)
            second = Thread { try { scope.call { sent.incrementAndGet() } } catch (e: Throwable) { secondFailure.set(e) } }.apply { start() }
            val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (second.state != Thread.State.WAITING && System.nanoTime() < until) Thread.yield()
            assertEquals(Thread.State.WAITING, second.state)
            scope.seal(); reply.countDown(); join(first); join(second)
            assertEquals(0, sent.get()); assertTrue(secondFailure.get() is IllegalStateException)
            assertTrue(scope.release { true })
        } finally { reply.countDown(); join(first); second?.let(::join) }
    }

    @Test fun sealedOrReleasedObservationNeverExecutesItsCommitBody() {
        for (releaseFirst in listOf(false, true)) {
            val io = BackgroundDisplayIo<Any>(); val peer = Any()
            io.call { io.startResource(peer, { it(); Unit }) { true } }
            var commits = 0
            try {
                if (releaseFirst) assertTrue(io.release { assertSame(peer, it); true }) else io.seal()
                assertThrows(IllegalStateException::class.java) {
                    io.commitObservation { commits++; "old response" }
                }
                assertEquals(0, commits)
                assertTrue(io.release { assertSame(peer, it); true })
            } finally { assertTrue(io.release { assertSame(peer, it); true }) }
        }
    }


    @Test fun committedObservationFinishesBeforeSealAndLaterCommitsAreRejected() {
        val io = BackgroundDisplayIo<Any>()
        val entered = CountDownLatch(1); val finish = CountDownLatch(1)
        val sealStarted = CountDownLatch(1); val sealed = CountDownLatch(1)
        val value = AtomicReference<String?>(); val failure = AtomicReference<Throwable?>()
        val commit = Thread {
            try { value.set(io.commitObservation { entered.countDown(); finish.await(); "current response" }) }
            catch (e: Throwable) { failure.set(e) }
        }.apply { start() }
        var closer: Thread? = null
        try {
            await(entered)
            closer = Thread { sealStarted.countDown(); io.seal(); sealed.countDown() }.apply { start() }
            await(sealStarted)
            val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (closer.state != Thread.State.BLOCKED && sealed.count != 0L && System.nanoTime() < until) {
                Thread.yield()
            }
            assertEquals(Thread.State.BLOCKED, closer.state)
            assertEquals(1L, sealed.count)
            finish.countDown(); join(commit); join(closer)
            assertNull(failure.get()); assertEquals("current response", value.get())
            assertEquals(0L, sealed.count)
            var lateCommits = 0
            assertThrows(IllegalStateException::class.java) {
                io.commitObservation { lateCommits++; "late output" }
            }
            assertEquals(0, lateCommits)
            assertTrue(io.release { error("no peer was allocated") })
        } finally { finish.countDown(); join(commit); closer?.let(::join) }
    }

    @Test fun sealedPhysicalReplyDrainsOriginalPeerWithoutPublishingItsObservation() {
        val io = BackgroundDisplayIo<Any>(); val peer = Any()
        val entered = CountDownLatch(1); val reply = CountDownLatch(1)
        val published = AtomicInteger(); val releases = AtomicInteger()
        val failure = AtomicReference<Throwable?>()
        val caller = Thread {
            try {
                io.call {
                    io.startResource(peer, { beforeSend -> beforeSend(); entered.countDown(); reply.await() }) { true }
                    io.commitObservation { published.incrementAndGet() }
                }
            } catch (e: Throwable) { failure.set(e) }
        }.apply { start() }
        try {
            await(entered); io.seal()
            assertFalse(io.release { releases.incrementAndGet(); true })
            assertEquals(0, releases.get())
            reply.countDown(); join(caller)
            assertTrue(failure.get() is IllegalStateException); assertEquals(0, published.get())
            assertSame(peer, io.peer())
            assertTrue(io.release { assertSame(peer, it); releases.incrementAndGet(); true })
            assertEquals(1, releases.get())
            assertTrue(io.release { error("already released") })
        } finally {
            reply.countDown(); join(caller)
            assertTrue(io.release { assertSame(peer, it); true })
        }
    }
}
