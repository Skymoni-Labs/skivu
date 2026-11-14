package com.skyjjgw.independent.ski.dshgo.phone.background

import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import org.junit.Assert.*
import org.junit.Test

/** Real production cleanup FutureTask; controlled UI queue/zero-budget await, no Android stubs. */
class ProbeCleanupTest {
    private fun cleanup(action: () -> Unit) = ProbeCleanup(
        await = { it.get(0, TimeUnit.MILLISECONDS); Unit }, cleanup = action,
    )

    @Test fun repeatedCloseBeforeUiRunsStillTimesOutAndPostsOnlyOnce() {
        var dismissed = 0
        val pending = mutableListOf<Runnable>()
        val state = cleanup { dismissed++ }
        repeat(2) {
            assertThrows(TimeoutException::class.java) {
                state.close(false) { assertTrue(state.isSealed); pending += it; true }
            }
        }
        assertTrue(state.isSealed)
        assertEquals(1, pending.size)
        assertEquals(0, dismissed)
    }

    @Test fun lateUiCompletionIsTheOnlySuccessfulRetryAndNeverDismissesTwice() {
        var dismissed = 0
        val pending = mutableListOf<Runnable>()
        val state = cleanup { dismissed++ }
        assertThrows(TimeoutException::class.java) { state.close(false) { pending += it; true } }
        pending.single().run()
        repeat(2) { state.close(false) { error("must not post another job") } }
        assertEquals(1, dismissed)
    }

    @Test fun mainThreadReentryRunsTheOriginalQueuedJobWithoutDeadlockingItsOwnQueue() {
        var dismissed = 0
        val pending = mutableListOf<Runnable>()
        val state = cleanup { dismissed++ }
        assertThrows(TimeoutException::class.java) { state.close(false) { pending += it; true } }
        state.close(true) { error("UI must execute the original job directly") }
        pending.single().run()
        state.close(true) { error("already complete") }
        assertEquals(1, dismissed)
    }

    @Test fun failedDismissRemainsFailedOnEveryCloseWithoutRepeatingTheEffect() {
        var attempts = 0
        val cause = IllegalStateException("synthetic dismiss failure")
        val state = cleanup { attempts++; throw cause }
        repeat(2) {
            val failure = assertThrows(ExecutionException::class.java) { state.close(true) { error("unused") } }
            assertSame(cause, failure.cause)
        }
        assertEquals(1, attempts)
        assertTrue(state.isSealed)
    }

    @Test fun rejectedUiPostNeverTurnsIntoSuccessOnSecondClose() {
        var posts = 0
        var dismissed = 0
        val state = cleanup { dismissed++ }
        repeat(2) {
            assertThrows(ExecutionException::class.java) { state.close(false) { posts++; false } }
        }
        assertThrows(ExecutionException::class.java) { state.close(true) { error("unused") } }
        assertEquals(1, posts)
        assertEquals(0, dismissed)
    }

    @Test fun dispatchExceptionIsRetainedForTheSameJob() {
        val cause = IllegalStateException("synthetic dispatch failure")
        val state = cleanup { error("must not run") }
        repeat(2) {
            val failure = assertThrows(ExecutionException::class.java) { state.close(false) { throw cause } }
            assertSame(cause, failure.cause)
        }
    }

    @Test fun interruptedWaitDoesNotCancelOrReplaceTheUiJob() {
        var interruptedOnce = false
        var dismissed = 0
        val pending = mutableListOf<Runnable>()
        val state = ProbeCleanup(await = {
            if (!interruptedOnce) { interruptedOnce = true; throw InterruptedException("synthetic interrupt") }
            it.get(0, TimeUnit.MILLISECONDS)
            Unit
        }) { dismissed++ }
        assertThrows(InterruptedException::class.java) { state.close(false) { pending += it; true } }
        assertTrue(state.isSealed)
        pending.single().run()
        state.close(false) { error("must retain the first job") }
        assertEquals(1, dismissed)
    }
}
