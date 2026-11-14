package com.skyjjgw.independent.ski.dshgo.phone.a11y

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.LockSupport

/** The actual one-shot coordinate start posted to main. Never waits or calls Binder under its lock. */
internal class CoordinateDispatch(
    private val caller: Thread,
    private val current: () -> Boolean,
    private val admission: ((() -> Boolean) -> Boolean),
    private val dispatch: () -> Boolean,
) : Runnable {
    private enum class Phase { QUEUED, CLAIMED, CANCELLED, FINISHED }
    private val lock = Any()
    private var phase = Phase.QUEUED
    private val done = CountDownLatch(1)
    @Volatile private var sent = false

    override fun run() {
        // admission owns the original Tasks lock; claim only reads memory and owns this ticket.
        val claimed = try { admission {
            synchronized(lock) {
                if (phase != Phase.QUEUED || caller.isInterrupted || !current()) false
                else { phase = Phase.CLAIMED; true }
            }
        }
        } catch (_: Throwable) { cancelQueued(); return }
        if (!claimed) { cancelQueued(); return }
        try { sent = dispatch() } catch (_: Throwable) { sent = false }
        finally { synchronized(lock) { phase = Phase.FINISHED }; done.countDown(); LockSupport.unpark(caller) }
    }

    fun cancelQueued(): Boolean = synchronized(lock) {
        if (phase != Phase.QUEUED) return false
        phase = Phase.CANCELLED; done.countDown(); LockSupport.unpark(caller); true
    }

    /** Once claimed, drain this same start body; interruption never re-posts or cancels half a start. */
    fun awaitStart(timeoutMs: Long): Boolean {
        var interrupted = false
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        try {
            while (done.count != 0L) {
                if (Thread.currentThread().isInterrupted) {
                    // park does NOT clear the interrupt bit. First seal QUEUED under the
                    // same lock as claim, then clear it only to drain an already-claimed body.
                    cancelQueued()
                    interrupted = true
                    Thread.interrupted()
                }
                if (done.count == 0L) break
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0L) {
                    cancelQueued()
                    if (done.count != 0L) LockSupport.park(this) // CLAIMED: the original body must finish.
                } else LockSupport.parkNanos(this, remaining)
            }
            return sent
        } finally {
            cancelQueued() // A reused worker cannot reactivate a late queued Runnable.
            if (interrupted) Thread.currentThread().interrupt()
        }
    }
}
