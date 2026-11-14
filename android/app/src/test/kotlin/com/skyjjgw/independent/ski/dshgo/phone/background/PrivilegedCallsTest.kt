package com.skyjjgw.independent.ski.dshgo.phone.background

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class PrivilegedCallsTest {
    @Test fun previewSkipsAnActiveAgentWithoutQueuingWork() {
        val calls = PrivilegedCalls()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val agent = executor.submit<String> {
                calls.execute { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)); "agent" }
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val previewRan = AtomicBoolean(false)
            assertNull(calls.tryPreview { previewRan.set(true); "frame" })
            release.countDown()
            assertEquals("agent", agent.get(5, TimeUnit.SECONDS))
            assertFalse(previewRan.get())
            assertEquals("frame", calls.tryPreview { "frame" })
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test fun cancelledWaitingAgentDoesNotDispatchOrRetireTheSentPreview() {
        val calls = PrivilegedCalls()
        val previewEntered = CountDownLatch(1)
        val releasePreview = CountDownLatch(1)
        val agentStarted = CountDownLatch(1)
        val agentFinished = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        val agentDispatched = AtomicBoolean(false)
        try {
            val preview = executor.submit<String?> {
                calls.tryPreview { previewEntered.countDown(); check(releasePreview.await(5, TimeUnit.SECONDS)); "complete response" }
            }
            assertTrue(previewEntered.await(5, TimeUnit.SECONDS))
            val agent = executor.submit {
                try {
                    agentStarted.countDown()
                    calls.execute { agentDispatched.set(true) }
                } finally { agentFinished.countDown() }
            }
            assertTrue(agentStarted.await(5, TimeUnit.SECONDS))
            assertTrue(agent.cancel(true))
            assertTrue(agentFinished.await(5, TimeUnit.SECONDS))
            releasePreview.countDown()
            assertEquals("complete response", preview.get(5, TimeUnit.SECONDS))
            assertFalse(agentDispatched.get())
            assertEquals("next", calls.execute { "next" })
        } finally {
            releasePreview.countDown()
            executor.shutdownNow()
        }
    }

    @Test fun failedPreviewReleasesAdmissionForTheNextAgent() {
        val calls = PrivilegedCalls()
        try {
            calls.tryPreview<Unit> { throw IllegalStateException("synthetic failure") }
            fail("expected failure")
        } catch (_: IllegalStateException) { }
        assertEquals("agent", calls.execute { "agent" })
    }

    @Test fun capacitySnapshotDoesNotWaitForAnAdmissionCallbackHoldingTheCallsLock() {
        val calls = PrivilegedCalls(3)
        val beforeSend = CountDownLatch(1)
        val release = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val actual = executor.submit<String> {
                calls.execute(beforeSend = {
                    beforeSend.countDown()
                    check(release.await(5, TimeUnit.SECONDS))
                }) { "reply" }
            }
            assertTrue(beforeSend.await(5, TimeUnit.SECONDS))
            // This reader represents the registry side of registry -> capacity. It must
            // complete while the actual admission callback still owns Calls.lock.
            assertTrue(executor.submit<Boolean> { calls.alive() }.get(1, TimeUnit.SECONDS))
            release.countDown()
            assertEquals("reply", actual.get(5, TimeUnit.SECONDS))
            calls.retire()
            assertFalse(calls.alive())
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test fun successfulTerminalReplyPublishesRetirementToTheSameSnapshot() {
        val calls = PrivilegedCalls(3)
        assertEquals("closed", calls.execute(global = true, terminal = { it == "closed" }) { "closed" })
        assertFalse(calls.alive())
        assertNull(calls.tryPreview { "must not run" })
    }

}
