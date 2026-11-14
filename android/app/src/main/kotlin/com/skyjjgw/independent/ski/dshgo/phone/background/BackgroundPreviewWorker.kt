package com.skyjjgw.independent.ski.dshgo.phone.background

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Core serializes access. Shutdown retains the original encoder until it really terminates. */
internal class BackgroundPreviewWorker {
    private var worker: ExecutorService? = null
    fun acquire(): ExecutorService? {
        val old = worker
        if (old != null && !old.isTerminated) return old.takeUnless { it.isShutdown }
        return Executors.newSingleThreadExecutor { job -> Thread(job, "dsh-preview").apply { isDaemon = true } }
            .also { worker = it }
    }
    /** Release receipts observe the encoder's real termination, not just a queued shutdown. */
    fun stop() {
        val old = worker ?: return
        old.shutdown()
        awaitQuietly(old, STOP_TIMEOUT_MS)
    }

    fun drained(): Boolean {
        val old = worker ?: return true
        if (!old.isTerminated && old.isShutdown) awaitQuietly(old, DRAIN_TIMEOUT_MS)
        if (!old.isTerminated) return false
        worker = null
        return true
    }

    /** A short, bounded wait: the caller's own interrupt must survive the best-effort drain. */
    private fun awaitQuietly(old: ExecutorService, timeoutMs: Long) {
        try { old.awaitTermination(timeoutMs, TimeUnit.MILLISECONDS) }
        catch (_: InterruptedException) { Thread.currentThread().interrupt() }
    }

    private companion object {
        const val STOP_TIMEOUT_MS = 1_000L
        const val DRAIN_TIMEOUT_MS = 250L
    }
}
