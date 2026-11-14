package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** The gate now waits for a receiver instead of replaying taps on an empty display (#362). */
class BackgroundGateRetryTest {
    private val point = InputProbe.Target(11, 180, 400)
    private fun ready() = InputProbe(11).also { it.ready(point) }
    private fun verify(probe: InputProbe, send: (InputProbe.Target, Long) -> Unit) =
        probe.verify({ 100L }, send, readyTimeoutMs = 0, receiptTimeoutMs = 0)

    private fun gesture(probe: InputProbe, point: InputProbe.Target, time: Long) {
        probe.accept(point.displayId, time, 0, point.x.toFloat(), point.y.toFloat())
        probe.accept(point.displayId, time, 1, point.x.toFloat(), point.y.toFloat())
    }

    @Test fun aMatchingReceiptPassesWithExactlyOneGesture() {
        val probe = ready()
        var sends = 0
        verify(probe) { target, time -> sends++; gesture(probe, target, time) }
        assertEquals(1, sends)
    }

    @Test fun readinessAndReceiptCanArriveFromAnotherThread() {
        val probe = InputProbe(11)
        val started = CountDownLatch(1)
        val sent = CountDownLatch(1)
        val task = FutureTask<Unit> {
            started.countDown()
            probe.verify({ 100L }, { _, _ -> sent.countDown() })
        }
        val worker = Thread(task, "probe-test")
        worker.start()
        try {
            assertTrue(started.await(1, TimeUnit.SECONDS))
            assertFalse(task.isDone)
            assertEquals(1L, sent.count)
            probe.ready(point)
            assertTrue(sent.await(1, TimeUnit.SECONDS))
            assertFalse(task.isDone) // Injection alone cannot complete the probe.
            gesture(probe, point, 100L)
            task.get(1, TimeUnit.SECONDS)
        } finally {
            worker.interrupt()
            worker.join(1000)
        }
    }

    @Test fun anInjectionWithoutAReceiptFailsAndIsNeverRepeated() {
        var sends = 0
        val error = assertThrows(InputProbe.Failure::class.java) { verify(ready()) { _, _ -> sends++ } }
        assertEquals("inputUnconfirmed", error.code)
        assertEquals(1, sends)
    }

    @Test fun aMissingWindowNeverReceivesATap() {
        var sends = 0
        val error = assertThrows(InputProbe.Failure::class.java) { verify(InputProbe(11)) { _, _ -> sends++ } }
        assertEquals("inputWindowNotReady", error.code)
        assertEquals(0, sends)
    }

    @Test fun aWindowFailureIsNotCalledAnInjectionFailure() {
        for (cause in listOf(SecurityException("window denied"), IllegalStateException("window unavailable"))) {
            val probe = InputProbe(11).also { it.fail(cause) }
            var sends = 0
            val failure = assertThrows(InputProbe.Failure::class.java) {
                verify(probe) { _, _ -> sends++ }
            }
            assertEquals("inputWindowNotReady", failure.code)
            assertSame(cause, failure.cause)
            assertEquals(0, sends)
        }
    }

    @Test fun theMainScreenWrongDisplayAndInvalidCoordinatesNeverReceiveATap() {
        for (target in listOf(point.copy(displayId = 0), point.copy(displayId = -1),
            point.copy(displayId = 12), point.copy(x = 0), point.copy(y = -1))) {
            val probe = InputProbe(11).also { it.ready(target) }
            val error = assertThrows(InputProbe.Failure::class.java) {
                verify(probe) { _, _ -> throw AssertionError("must not inject") }
            }
            assertEquals("inputWindowNotReady", error.code)
        }
    }

    @Test fun aSendFailurePropagatesWithoutReplay() {
        val denied = SecurityException("denied")
        var sends = 0
        assertSame(denied, assertThrows(SecurityException::class.java) {
            verify(ready()) { _, _ -> sends++; throw denied }
        })
        assertEquals(1, sends)
    }

    @Test fun anUpWithoutDownDoesNotPass() {
        val probe = ready()
        assertUnconfirmed(probe) { target, time ->
            probe.accept(target.displayId, time, 1, 180f, 400f)
        }
    }

    @Test fun aDownWithoutUpDoesNotPass() {
        val probe = ready()
        assertUnconfirmed(probe) { target, time ->
            probe.accept(target.displayId, time, 0, 180f, 400f)
        }
    }

    @Test fun aReceiptMustMatchBothEdgesDisplayTimeAndPosition() {
        val wrong = listOf<(InputProbe, InputProbe.Target, Long) -> Unit>(
            { p, t, time -> gesture(p, t.copy(displayId = 0), time) },
            { p, t, time -> gesture(p, t, time - 1) },
            { p, t, time -> gesture(p, t.copy(x = 1), time) },
            { p, t, time ->
                p.accept(t.displayId, time, 0, 180f, 400f)
                p.accept(t.displayId, time - 1, 1, 180f, 400f)
            },
            { p, t, time ->
                p.accept(t.displayId, time, 0, 180f, 400f)
                p.accept(t.displayId, time, 1, Float.NaN, 400f)
            },
        )
        for (receipt in wrong) {
            val probe = ready()
            assertUnconfirmed(probe) { target, time -> receipt(probe, target, time) }
        }
    }

    @Test fun aReceiptFromBeforeTheAttemptDoesNotPass() {
        val probe = ready()
        gesture(probe, point, 100L)
        assertUnconfirmed(probe) { _, _ -> }
    }

    @Test fun cancelInvalidatesThePendingDown() {
        val probe = ready()
        assertUnconfirmed(probe) { target, time ->
            probe.accept(target.displayId, time, 0, 180f, 400f)
            probe.accept(target.displayId, time, 3, 180f, 400f)
            probe.accept(target.displayId, time, 1, 180f, 400f)
        }
    }

    @Test fun anInterruptedProbeNeverSendsATap() {
        Thread.currentThread().interrupt()
        try {
            assertThrows(InterruptedException::class.java) {
                verify(ready()) { _, _ -> throw AssertionError("must not inject") }
            }
        } finally { Thread.interrupted() }
    }

    private fun assertUnconfirmed(probe: InputProbe, send: (InputProbe.Target, Long) -> Unit) {
        assertEquals("inputUnconfirmed", assertThrows(InputProbe.Failure::class.java) { verify(probe, send) }.code)
    }
}
