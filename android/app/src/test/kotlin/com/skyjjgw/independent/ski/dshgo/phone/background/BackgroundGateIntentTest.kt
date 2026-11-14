package com.skyjjgw.independent.ski.dshgo.phone.background

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

/** Exercises the production gate's actual intent/begin/admit lock, with no device substitute. */
class BackgroundGateIntentTest {
    @Test fun lateBeginCannotFitBetweenRevocationAndTheRealTicketChange() {
        val state = BackgroundGateState()
        val wanted = AtomicBoolean(true)
        val inside = CountDownLatch(1); val change = CountDownLatch(1); val trying = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        try {
            val mutation = pool.submit { state.changeIntent {
                inside.countDown(); check(change.await(5, TimeUnit.SECONDS)); wanted.set(false)
            } }
            assertTrue(inside.await(5, TimeUnit.SECONDS))
            val begin = pool.submit<BackgroundGateState.Probe?> {
                trying.countDown(); state.begin { wanted.get() }
            }
            assertTrue(trying.await(5, TimeUnit.SECONDS)); assertFalse(begin.isDone)
            change.countDown(); mutation.get(5, TimeUnit.SECONDS)
            assertNull(begin.get(5, TimeUnit.SECONDS))
        } finally { change.countDown(); pool.shutdownNow() }
    }

    @Test fun existingProbeCannotCommitAfterItsTicketChanged() {
        val state = BackgroundGateState(); val wanted = AtomicBoolean(true)
        val probe = state.begin { wanted.get() }!!
        state.changeIntent { wanted.set(false) }
        var committed = false
        assertFalse(state.admit(probe) { committed = true })
        assertFalse(committed)
    }

    @Test fun DetachingAnUnrelatedAttachmentDoesNotRevokeTheCurrentProbe() {
        val state = BackgroundGateState()
        val oldAttached = AtomicBoolean(true); val currentAttached = AtomicBoolean(true)
        val probe = state.begin { currentAttached.get() }!!
        state.changeIntent { oldAttached.set(false) }
        var committed = false
        assertTrue(state.admit(probe) { committed = true })
        assertTrue(committed); assertFalse(oldAttached.get())
    }
}
