package com.skyjjgw.independent.ski.dshgo.phone

import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** One bridge call's native reply commit; a timed-out body still owns its original drain. */
class PhoneCallWork(
    private val invoke: () -> String,
    private val remainingMs: (() -> Long)? = null,
    private val expiredReply: (() -> String)? = null,
    private val nativeReplyCommit: PhoneReplyCommit? = null,
) {
    private val lock = Any()
    private var committed = false
    private var timer: ScheduledFuture<*>? = null

    fun run(): String? {
        val reply = invoke()
        return synchronized(lock) {
            if (committed) null else {
                committed = true
                timer?.cancel(false)
                if (remainingMs != null && remainingMs.invoke() <= 0) checkNotNull(expiredReply).invoke() else {
                    nativeReplyCommit?.commitIfEncoded()
                    reply
                }
            }
        }
    }

    /** May be called before the body starts. Never executes device cleanup or socket IO. */
    internal fun expire(): String? = synchronized(lock) {
        if (committed || remainingMs == null || remainingMs.invoke() > 0) null else {
            committed = true
            timer?.cancel(false)
            checkNotNull(expiredReply).invoke()
        }
    }

    internal fun schedule(executor: ScheduledExecutorService, deliver: (String) -> Unit) {
        synchronized(lock) {
            if (committed || remainingMs == null) return
            timer = executor.schedule({
                val reply = expire()
                if (reply != null) deliver(reply)
                else schedule(executor, deliver) // A wakeup never grants an earlier deadline.
            }, remainingMs.invoke().coerceAtLeast(0), TimeUnit.MILLISECONDS)
        }
    }
}
