package com.skyjjgw.independent.ski.dshgo.phone.background

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/** One disposable display, one gesture. Only a matching DOWN/UP receipt proves delivery. */
internal class InputProbe(
    private val displayId: Int,
    private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    class Failure(val code: String, val observation: InputProbeDiagnostics.Observation? = null) : Exception(code)
    private val startedAt = clock()
    private var stage = InputProbeDiagnostics.Stage.PRECONDITION

    // show/setContentView may synchronously deliver a later callback; never move observation back.
    @Synchronized fun entered(next: InputProbeDiagnostics.Stage) {
        if (next.ordinal > stage.ordinal) stage = next
    }

    @Synchronized fun observation(error: Throwable?): InputProbeDiagnostics.Observation =
        (error as? Failure)?.observation ?: InputProbeDiagnostics.observe(stage, error, clock() - startedAt)

    fun failure(code: String, cause: Throwable? = null): Failure =
        Failure(code, observation(cause)).also { if (cause != null) it.initCause(cause) }
    data class Target(val displayId: Int, val x: Int, val y: Int)

    private val ready = CountDownLatch(1)
    private val received = CountDownLatch(1)
    @Volatile private var target: Target? = null
    @Volatile private var failure: Throwable? = null
    private var downTime: Long? = null
    private var down = false

    @Synchronized fun ready(target: Target) {
        if (this.target != null || failure != null) return
        this.target = target
        ready.countDown()
    }

    /** Receiver setup failed before injection; even SecurityException is a window failure here. */
    @Synchronized fun fail(error: Throwable) {
        failure = failure("inputWindowNotReady", error)
        ready.countDown()
        received.countDown()
    }

    fun verify(
        now: () -> Long,
        send: (Target, Long) -> Unit,
        readyTimeoutMs: Long = 3000,
        receiptTimeoutMs: Long = 1000,
    ) {
        if (!ready.await(readyTimeoutMs, TimeUnit.MILLISECONDS))
            throw failure("inputWindowNotReady", java.util.concurrent.TimeoutException())
        failure?.let { throw it }
        entered(InputProbeDiagnostics.Stage.TARGET_VALIDATE)
        val point = target ?: throw failure("inputWindowNotReady")
        if (displayId <= 0 || point.displayId != displayId || point.x <= 0 || point.y <= 0)
            throw failure("inputWindowNotReady")
        if (Thread.currentThread().isInterrupted) throw InterruptedException()
        val time = now()
        synchronized(this) { downTime = time }
        entered(InputProbeDiagnostics.Stage.INPUT_SEND)
        send(point, time) // Async injection, never replayed; its boolean is not a receipt.
        entered(InputProbeDiagnostics.Stage.RECEIPT_WAIT)
        if (!received.await(receiptTimeoutMs, TimeUnit.MILLISECONDS))
            throw failure("inputUnconfirmed", java.util.concurrent.TimeoutException())
        failure?.let { throw it }
    }

    @Synchronized fun accept(id: Int, time: Long, action: Int, x: Float, y: Float) {
        val point = target ?: return
        if (failure != null || id != displayId || downTime != time || !x.isFinite() || !y.isFinite() ||
            abs(x - point.x) > 2 || abs(y - point.y) > 2) return
        when (action) {
            0 -> down = true // ACTION_DOWN
            1 -> if (down) { down = false; received.countDown() } // ACTION_UP
            3 -> down = false // ACTION_CANCEL
        }
    }
}
