package com.skyjjgw.independent.ski.dshgo.phone.background

import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class ShizukuCleanupTest {
    @Test fun fixedTagIsReusableOnlyAfterBothUnbindStepsSucceed() {
        val steps = mutableListOf<String>()
        val failure = shizukuUnbind(
            detach = { steps += "detach" },
            remove = { steps += "remove" },
        )
        assertNull(failure)
        assertEquals(listOf("detach", "remove"), steps)
    }

    @Test fun detachFailureStillAttemptsRemovalButDoesNotReleaseTag() {
        var removed = false
        val failure = shizukuUnbind(
            detach = { throw IllegalStateException("detach") },
            remove = { removed = true },
        )
        assertTrue(removed)
        assertEquals("unbindFailed", failure)
    }

    @Test fun removalFailureDoesNotReleaseTagDespiteSuccessfulDetach() {
        val failure = shizukuUnbind(
            detach = {},
            remove = { throw IllegalStateException("remove") },
        )
        assertEquals("unbindFailed", failure)
    }

    @Test fun failedRemovalCanBeRetriedAfterTheLocalCallbackWasDetached() {
        val callbacks = mutableMapOf("tag" to Any())
        var detachCalls = 0
        var removeCalls = 0
        val detach = {
            detachCalls++
            // API 13.1.5 get(args) creates an empty connection when the cache entry is absent.
            callbacks.getOrPut("tag") { Any() }
            callbacks.clear()
        }
        val remove = {
            removeCalls++
            if (removeCalls == 1) throw IllegalStateException("remove")
        }
        assertEquals("unbindFailed", shizukuUnbind(detach, remove))
        assertTrue(callbacks.isEmpty())
        assertNull(shizukuUnbind(detach, remove))
        assertEquals(2, detachCalls)
        assertEquals(2, removeCalls)
    }

    @Test fun completedCleanupDoesNotRequireAnAvailabilityCallback() {
        val cleanup = ShizukuCleanup()
        cleanup.complete(null)
        assertNull(cleanup.await(0, TimeUnit.MILLISECONDS))
    }

    @Test fun failedCleanupWakesWaiterWithStableReason() {
        val cleanup = ShizukuCleanup()
        cleanup.complete("unbindFailed")
        assertEquals("unbindFailed", cleanup.await(0, TimeUnit.MILLISECONDS))
    }

    @Test fun timeoutDoesNotCompleteOrReplaceTheOldCleanup() {
        val cleanup = ShizukuCleanup()
        assertEquals("unbindTimeout", cleanup.await(0, TimeUnit.MILLISECONDS))
        assertEquals("unbindTimeout", cleanup.await(0, TimeUnit.MILLISECONDS))
        cleanup.complete(null)
        assertNull(cleanup.await(0, TimeUnit.MILLISECONDS))
    }

    @Test fun aLaterCleanupAttemptCannotCompleteTheOldAttempt() {
        val old = ShizukuCleanup()
        val current = ShizukuCleanup()
        old.complete("unbindFailed")
        assertEquals("unbindTimeout", current.await(0, TimeUnit.MILLISECONDS))
        current.complete(null)
        assertEquals("unbindFailed", old.await(0, TimeUnit.MILLISECONDS))
        assertNull(current.await(0, TimeUnit.MILLISECONDS))
    }
}
