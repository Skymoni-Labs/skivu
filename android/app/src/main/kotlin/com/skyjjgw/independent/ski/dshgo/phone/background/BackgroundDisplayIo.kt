package com.skyjjgw.independent.ski.dshgo.phone.background

import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.Future

/** One resource's ordered physical I/O. Cancellation closes admission, never a half-read frame. */
internal class BackgroundDisplayIo<C : Any> {
    val owner: String = UUID.randomUUID().toString()
    private val lock = Any()
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-display-io").apply { isDaemon = true } }
    private var activeCalls = 0
    private var previewCalls = 0
    private var releaseStarted = false
    private var releasing = false
    private var completed = false
    private var pinned: C? = null
    private var firstRequest = false
    private var notAdmitted = false

    fun wasNotAdmitted(): Boolean = synchronized(lock) { notAdmitted }

    /** Called inside the admitted IO body. Only its own complete reply can prove no admission. */
    fun <R> startResource(peer: C, exchange: (beforeSend: () -> Unit) -> R, admission: (R) -> Boolean?): R {
        val reply = exchange {
            synchronized(lock) {
                check(!releaseStarted && activeCalls > 0 && !firstRequest && pinned == null)
                pinned = peer
                firstRequest = true // Only after actual channel admission, before any transport write.
            }
        }
        val accepted = admission(reply)
        synchronized(lock) {
            if (firstRequest) {
                check(pinned === peer)
                if (accepted == false) notAdmitted = true
            }
        }
        return reply
    }

    /** Actual channel beforeSend for a later business request, never for original cleanup. */
    fun checkDispatch() = synchronized(lock) {
        check(!releaseStarted && activeCalls > 0 && pinned != null && !notAdmitted) {
            "Background resource admission was stopped"
        }
    }

    fun peer(): C? = synchronized(lock) { pinned }

    fun previewAvailable(peer: C): Boolean = synchronized(lock) { !releaseStarted && pinned === peer }
    fun previewClosed(): Boolean = synchronized(lock) { releaseStarted }

    /** Bounded local identity only; no task callback, IPC, or resource acquisition. */
    fun existingResource(matches: (C) -> Boolean): Boolean = synchronized(lock) {
        val peer = pinned ?: return false
        !releaseStarted && !notAdmitted && matches(peer)
    }


    /** Only bounded local observation state may be committed here; never IPC or OCR work. */
    fun <T> commitObservation(block: () -> T): T = synchronized(lock) {
        check(!releaseStarted) { "Background resource admission was stopped" }
        block()
    }

    fun seal() = synchronized(lock) {
        releaseStarted = true
        finishUnused()
    }

    fun <T> call(block: () -> T): T {
        if (Thread.currentThread().isInterrupted) throw InterruptedException()
        synchronized(lock) {
            check(!releaseStarted) { "Background resource admission was stopped" }
            activeCalls++
        }
        try {
            return await(io.submit(Callable {
                synchronized(lock) { check(!releaseStarted) { "Background resource admission was stopped" } }
                block()
            }))
        } finally {
            synchronized(lock) { activeCalls--; finishUnused() }
        }
    }

    /** Optional work only reserves an idle, already-pinned resource; it never queues behind Agent work. */
    fun <T> tryPreview(block: (C) -> T?): T? {
        if (Thread.currentThread().isInterrupted) throw InterruptedException()
        val future = synchronized(lock) {
            if (releaseStarted || activeCalls != 0) return null
            val current = pinned ?: return null
            activeCalls++
            previewCalls++
            // Queue insertion is part of this short reservation. An Agent cannot submit in
            // the gap and leave this optional poll waiting behind a long device operation.
            io.submit(Callable {
                synchronized(lock) {
                    if (releaseStarted || activeCalls > previewCalls) return@Callable null
                }
                block(current)
            })
        }
        try {
            return await(future)
        } finally {
            synchronized(lock) { activeCalls--; previewCalls--; finishUnused() }
        }
    }

    /** Cleanup may enter with a cancelled caller, but uses the same protected worker and peer. */
    fun release(block: (C) -> Boolean): Boolean {
        val peer = synchronized(lock) {
            releaseStarted = true
            finishUnused()
            if (completed) return true
            // Agent bodies still own their outer drain fence. A preview has no outer worker:
            // cleanup queues on this SAME I/O lane, after its actual reply, without interrupting it.
            if (activeCalls > previewCalls || releasing) return false
            releasing = true
            checkNotNull(pinned)
        }
        try {
            val ok = await(io.submit(Callable { block(peer) }))
            synchronized(lock) {
                if (ok) { completed = true; io.shutdown() }
            }
            return ok
        } finally { synchronized(lock) { releasing = false } }
    }

    // Only called under lock. No pin means no CREATE/LAUNCH was committed to any peer.
    private fun finishUnused() {
        // A refused first request retires only after its actual exchange left the IO body.
        if (notAdmitted && activeCalls == 0) { releaseStarted = true; pinned = null }
        if (releaseStarted && activeCalls == 0 && pinned == null && !completed) {
            completed = true
            io.shutdown()
        }
    }

    private fun <T> await(future: Future<T>): T {
        var interrupted = false
        try {
            while (true) {
                try { return future.get() }
                catch (_: InterruptedException) { interrupted = true }
                catch (e: ExecutionException) { throw (e.cause ?: e) }
            }
        } finally { if (interrupted) Thread.currentThread().interrupt() }
    }
}
