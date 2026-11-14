package com.skyjjgw.independent.ski.dshgo.phone.background

import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** One probe's actual cleanup job. Sealing new work is not an acknowledgement of UI cleanup. */
internal class ProbeCleanup(
    private val await: (FutureTask<Unit>) -> Unit = { it.get(2_000, TimeUnit.MILLISECONDS); Unit },
    cleanup: () -> Unit,
) {
    private val sealedForWork = AtomicBoolean(false)
    private val job = object : FutureTask<Unit>({ cleanup() }) {
        fun rejected(error: Exception) = setException(error)
    }
    val isSealed: Boolean get() = sealedForWork.get()

    fun close(onUiThread: Boolean, post: (Runnable) -> Boolean) {
        if (sealedForWork.compareAndSet(false, true)) {
            try {
                if (onUiThread) job.run()
                else if (!post(job)) job.rejected(IllegalStateException("Probe cleanup dispatch rejected"))
            } catch (e: Exception) {
                job.rejected(e)
            }
        } else if (onUiThread) {
            // A worker may already have queued this very job. Run it here instead of waiting
            // on our own looper; FutureTask makes the later queued run a no-op.
            job.run()
        }
        // Timeout/interruption never cancels the UI job. Reentry observes its actual result.
        await(job)
    }
}
