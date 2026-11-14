package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.phone.PhoneTasks
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class CoordinateDispatchTest {
    @Test fun queuedTimeoutSealsTheOriginalTicketAgainstLateMainAndThreadReuse() {
        val sent = AtomicInteger()
        val ticket = CoordinateDispatch(Thread.currentThread(), { true }, { it() }) { sent.incrementAndGet(); true }
        assertFalse(ticket.awaitStart(0))
        ticket.run(); ticket.run()
        assertEquals(0, sent.get())
    }

    @Test fun originalCallerInterruptionAndChangedPublishedDriverBothRefuseMainStart() {
        val hold = Any(); val ready = CountDownLatch(1)
        val caller = Thread {
            Thread.currentThread().interrupt(); ready.countDown()
            synchronized(hold) { } // Alive and interrupted until the test completes the main start.
        }
        var sent = 0
        synchronized(hold) {
            caller.start(); assertTrue(ready.await(5, TimeUnit.SECONDS))
            val interrupted = CoordinateDispatch(caller, { true }, { it() }) { sent++; true }
            assertFalse(Thread.currentThread().isInterrupted) // Main's interrupt bit is unrelated.
            interrupted.run(); assertFalse(interrupted.awaitStart(0))
        }
        caller.join(5_000)
        val replaced = CoordinateDispatch(Thread.currentThread(), { false }, { it() }) { sent++; true }
        replaced.run(); assertFalse(replaced.awaitStart(0)); assertEquals(0, sent)
    }

    @Test fun interruptedWaitSealsBeforeClearingTheWorkerFlagAndLateMainCannotSend() {
        val value = AtomicReference<CoordinateDispatch>(); val restored = AtomicBoolean()
        val sent = AtomicInteger(); val pool = Executors.newSingleThreadExecutor()
        try {
            pool.submit {
                val ticket = CoordinateDispatch(Thread.currentThread(), { true }, { it() }) { sent.incrementAndGet(); true }
                value.set(ticket)
                Thread.currentThread().interrupt()
                assertFalse(ticket.awaitStart(10_000))
                restored.set(Thread.currentThread().isInterrupted)
                Thread.interrupted() // Reuse the same caller after its completed invocation.
            }.get(5, TimeUnit.SECONDS)
            assertTrue(restored.get())
            value.get().run(); assertEquals(0, sent.get())
        } finally { pool.shutdownNow() }
    }

    @Test fun claimBeforeCancellationDrainsTheSameStartAndPreservesOriginalInterrupt() {
        val ready = CountDownLatch(1); val entered = CountDownLatch(1); val finish = CountDownLatch(1)
        val returned = CountDownLatch(1); val ticket = AtomicReference<CoordinateDispatch>()
        val sent = AtomicInteger(); val restored = AtomicBoolean(); val actualReply = AtomicBoolean()
        val caller = Thread {
            val value = CoordinateDispatch(Thread.currentThread(), { true }, { it() }) {
                sent.incrementAndGet(); entered.countDown(); check(finish.await(5, TimeUnit.SECONDS)); actualReply.set(true); true
            }
            ticket.set(value); ready.countDown()
            try { assertTrue(value.awaitStart(10_000)); assertTrue(actualReply.get()); restored.set(Thread.currentThread().isInterrupted) }
            finally { returned.countDown() }
        }
        val main = Executors.newSingleThreadExecutor()
        try {
            caller.start(); assertTrue(ready.await(5, TimeUnit.SECONDS))
            val job = main.submit { ticket.get().run() }
            assertTrue(entered.await(5, TimeUnit.SECONDS)); caller.interrupt()
            assertEquals(1L, returned.count) // No completion before original dispatch body returned.
            finish.countDown(); job.get(5, TimeUnit.SECONDS)
            assertTrue(returned.await(5, TimeUnit.SECONDS)); assertTrue(restored.get()); assertEquals(1, sent.get())
            ticket.get().run(); assertEquals(1, sent.get())
        } finally { finish.countDown(); caller.join(5_000); main.shutdownNow() }
    }

    @Test fun originalTasksCommitRejectsStopAndNeverHoldsTasksLockAcrossDispatch() {
        val tasks = PhoneTasks(); val owner = (tasks.begin() as PhoneTasks.Begin.Go).owner
        fun admit(claim: () -> Boolean): Boolean {
            var ok = false
            tasks.runIfCurrent(owner) { if (!tasks.isPaused) ok = claim() }
            return ok
        }
        val pool = Executors.newSingleThreadExecutor()
        try {
            var sent = 0
            val first = CoordinateDispatch(Thread.currentThread(), { true }, ::admit) {
                // If dispatch inherited Tasks.lock this other thread would block here.
                pool.submit { tasks.stop("during actual start") }.get(5, TimeUnit.SECONDS)
                sent++; true
            }
            first.run(); assertTrue(first.awaitStart(0)); assertEquals(1, sent)
            tasks.clearStop(); tasks.begin()
            val stale = CoordinateDispatch(Thread.currentThread(), { true }, ::admit) { sent++; true }
            stale.run(); assertFalse(stale.awaitStart(0)); assertEquals(1, sent)
        } finally { pool.shutdownNow() }
    }

    @Test fun windowTransitionAfterVerificationRefusesTheQueuedStartForKnownAndUnknownScopes() {
        val state = MainVisualState(Any())
        for ((window, pkg) in listOf(7 to "example.app", null to null)) {
            state.observed(window, pkg); state.publish("s1") // The screenshot the model saw.
            val transitions = state.transitions() // tapXY samples this before verifying.
            state.observed(window, pkg) // Verification capture: still the same window.
            val scope = state.scope("s1")
            var sent = 0
            fun start() = CoordinateDispatch(Thread.currentThread(), { state.isCurrent(scope, transitions) }, { it() }) { sent++; true }
            val unchanged = start(); unchanged.run(); assertTrue(unchanged.awaitStart(0))
            val queued = start()
            state.windowChanged() // The event is handled on main before the queued start runs.
            assertSame(scope, state.scope("s1")) // No capture ran: the cached scope alone would still pass.
            queued.run(); assertFalse(queued.awaitStart(0)); assertEquals(1, sent)
        }
    }

    @Test fun dispatchExceptionCompletesItsOneStartWithoutReplayOrCrashingMain() {
        var sent = 0
        val ticket = CoordinateDispatch(Thread.currentThread(), { true }, { it() }) { sent++; error("unknown dispatch result") }
        ticket.run(); assertFalse(ticket.awaitStart(0)); ticket.run(); assertEquals(1, sent)
    }
}
