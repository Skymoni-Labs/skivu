package com.skyjjgw.independent.ski.dshgo.phone.background

import java.util.concurrent.TimeoutException
import org.junit.Assert.*
import org.junit.Test

class ProbeActivitySessionTest {
    @Test fun neverStartedCanCloseButCannotLaunchAfterSealing() {
        val session = ProbeActivitySession()
        session.close(0)
        assertTrue(session.isSealed)
        assertThrows(IllegalStateException::class.java) { session.starting() }
    }

    @Test fun definiteLaunchRejectionDoesNotNeedAnActivityReceipt() {
        val session = ProbeActivitySession()
        session.starting()
        session.rejected()
        session.close(0)
    }

    @Test fun createdButUnarmedActivityStillHasAFinishEndpoint() {
        val session = ProbeActivitySession()
        session.starting()
        var finishes = 0
        assertTrue(session.connected { finishes++; session.detached() })
        repeat(2) { session.close(0) }
        assertEquals(1, finishes)
    }

    @Test fun finishRequestIsNotAWindowRemovalAcknowledgement() {
        val session = ProbeActivitySession()
        session.starting()
        var finishes = 0
        session.connected { finishes++ }
        repeat(2) { assertThrows(TimeoutException::class.java) { session.close(0) } }
        assertEquals(1, finishes)
        session.detached()
        repeat(2) { session.close(0) }
        assertEquals(1, finishes)
    }

    @Test fun lateCreatedAfterTimeoutFinishesOriginalActivityAndRetainsItsReceipt() {
        val session = ProbeActivitySession()
        session.starting()
        assertThrows(TimeoutException::class.java) { session.close(0) }
        var finishes = 0
        assertTrue(session.connected { finishes++ })
        assertThrows(TimeoutException::class.java) { session.close(0) }
        assertEquals(1, finishes)
        session.detached()
        session.close(0)
    }

    @Test fun detachedWithoutOriginalCreatedCannotAcknowledgeAnUncertainLaunch() {
        val session = ProbeActivitySession()
        session.starting()
        session.detached()
        assertThrows(TimeoutException::class.java) { session.close(0) }
    }

    @Test fun duplicateCreatedCannotReplaceOriginalCleanupEndpoint() {
        val session = ProbeActivitySession()
        session.starting()
        var finishes = 0
        assertTrue(session.connected { finishes++; session.detached() })
        assertFalse(session.connected { error("must retain the original instance") })
        session.close(0)
        assertEquals(1, finishes)
    }

    @Test fun interruptedWaitDoesNotDiscardLateRemovalReceipt() {
        val session = ProbeActivitySession()
        session.starting()
        session.connected { }
        Thread.currentThread().interrupt()
        try { assertThrows(InterruptedException::class.java) { session.close(0) } }
        finally { Thread.interrupted() }
        session.detached()
        session.close(0)
    }

    @Test fun duplicateReadyCannotRetargetAnInFlightGesture() {
        val probe = InputProbe(11)
        val original = InputProbe.Target(11, 100, 200)
        probe.ready(original)
        probe.ready(InputProbe.Target(11, 300, 400))
        probe.verify({ 123L }, { target, time ->
            assertEquals(original, target)
            probe.accept(11, time, 0, 100f, 200f)
            probe.accept(11, time, 1, 100f, 200f)
        }, 0, 0)
    }

    @Test fun lifecycleFailureDuringSendCannotTurnItsWakeupIntoSuccess() {
        val probe = InputProbe(11)
        probe.ready(InputProbe.Target(11, 100, 200))
        var sends = 0
        val failure = assertThrows(InputProbe.Failure::class.java) {
            probe.verify({ 123L }, { target, time ->
                sends++
                probe.fail(IllegalStateException())
                probe.accept(11, time, 0, target.x.toFloat(), target.y.toFloat())
                probe.accept(11, time, 1, target.x.toFloat(), target.y.toFloat())
            }, 0, 0)
        }
        assertEquals("inputWindowNotReady", failure.code)
        assertEquals(1, sends)
    }

    @Test fun failedBeforeArmedNeverInjectsEvenIfLateReadyArrives() {
        val probe = InputProbe(11)
        probe.fail(IllegalStateException())
        probe.ready(InputProbe.Target(11, 100, 200))
        assertThrows(InputProbe.Failure::class.java) {
            probe.verify({ 123L }, { _, _ -> error("must not inject") }, 0, 0)
        }
    }
}
