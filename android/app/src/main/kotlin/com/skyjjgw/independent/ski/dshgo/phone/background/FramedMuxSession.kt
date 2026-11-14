package com.skyjjgw.independent.ski.dshgo.phone.background

import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.atomic.AtomicBoolean

/** Actual Root/ADB reader and pending table. The codec marshals each request/response once. */
internal class FramedMuxSession<R>(
    private val input: InputStream,
    private val output: OutputStream,
    private val decode: (ByteArray) -> Reply<R>,
    private val onClosed: () -> Unit,
    private val deadlineMs: Long? = null,
) : Closeable {
    data class Reply<R>(val id: Long, val value: R)
    private val lock = Any()
    private val writer = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(3),
        { job -> Thread(job, "dsh-mux-writer").apply { isDaemon = true } })
    private val deadlines = deadlineMs?.let { ScheduledThreadPoolExecutor(1, { job ->
        Thread(job, "dsh-mux-deadline").apply { isDaemon = true }
    }).apply { removeOnCancelPolicy = true } }
    private val pending = mutableMapOf<Long, CompletableFuture<R>>()
    private var nextId = 1L
    private var closed = false
    private val reader = Thread({ readReplies() }, "dsh-mux-reader").apply { isDaemon = true }

    fun start() { reader.start() }
    fun alive(): Boolean = synchronized(lock) { !closed }

    fun exchange(encode: (Long) -> ByteArray): R {
        val future = CompletableFuture<R>()
        val timedOut = AtomicBoolean(false)
        val timer = try {
            synchronized(lock) {
                if (closed || nextId == Long.MAX_VALUE) throw IOException("deviceUnavailable")
                check(pending.size < 3)
                val id = nextId++
                pending[id] = future
                // Register and queue in one order. Caller interruption cannot break this writer.
                writer.execute {
                    try {
                        synchronized(lock) { if (closed) return@execute }
                        Frames.write(output, encode(id))
                    } catch (_: Throwable) { close() }
                }
                deadlines?.schedule({ retire(id) { timedOut.set(true) } }, checkNotNull(deadlineMs), TimeUnit.MILLISECONDS)
            }
        } catch (e: Throwable) { close(); throw e }
        var interrupted = false
        try {
            while (true) {
                try { return future.get() }
                catch (_: InterruptedException) { interrupted = true }
                catch (e: ExecutionException) {
                    throw IOException(if (timedOut.get()) "rootTimeout" else "deviceUnavailable", e.cause)
                }
            }
        } finally {
            timer?.cancel(false)
            if (interrupted) Thread.currentThread().interrupt()
        }
    }

    private fun readReplies() {
        try {
            while (true) {
                val reply = decode(Frames.read(input) ?: throw IOException("deviceUnavailable"))
                val future = synchronized(lock) {
                    if (closed) return
                    pending.remove(reply.id) ?: throw IOException("identityChanged")
                }
                future.complete(reply.value)
            }
        } catch (_: Throwable) { close() }
    }

    override fun close() = retire()

    private fun retire(expectedId: Long? = null, timedOut: () -> Unit = {}) {
        val abandoned = synchronized(lock) {
            if (closed || expectedId != null && expectedId !in pending) return
            closed = true
            timedOut()
            pending.values.toList().also { pending.clear() }
        }
        writer.shutdown()
        deadlines?.shutdownNow()
        abandoned.forEach { it.completeExceptionally(IOException("deviceUnavailable")) }
        onClosed() // Outside pending/writer locks; actual transport close wakes its sole reader.
    }

    companion object {
        /** Root and ADB alike: a reply that never comes retires the channel instead of holding its caller. */
        const val REQUEST_DEADLINE_MS = 30_000L
    }
}
