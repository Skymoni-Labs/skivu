package com.skyjjgw.independent.ski.dshgo.phone.background

import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** The stream entry's real bounded body/reply dispatcher; no owner or resource state is duplicated. */
internal class FramedMuxServer<Q, R>(
    private val input: InputStream, private val output: OutputStream,
    private val decode: (ByteArray) -> Request<Q>, private val handle: (Q) -> R,
    private val encode: (Long, R) -> ByteArray, private val terminal: (Q, R) -> Boolean,
    private val abort: () -> Unit,
) {
    data class Request<Q>(val id: Long, val body: Q, val global: Boolean)
    private val gate = PrivilegedCalls(3)
    private val failed = AtomicBoolean(false)
    private val workers = ThreadPoolExecutor(3, 3, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(3),
        { job -> Thread(job, "dsh-mux-body").apply { isDaemon = true } })

    fun run() {
        try {
            while (!failed.get()) {
                val request = decode(Frames.read(input) ?: return)
                gate.enter(request.global) {}
                if (request.global) {
                    if (respond(request)) return
                } else try {
                    workers.execute { respond(request) }
                } catch (error: Throwable) { fail(); throw error }
            }
        } finally { gate.retire(); workers.shutdown() }
    }

    private fun respond(request: Request<Q>): Boolean {
        var ended = false
        try {
            if (failed.get()) return false
            val response = handle(request.body)
            synchronized(output) { Frames.write(output, encode(request.id, response)) }
            ended = request.global && terminal(request.body, response)
            return ended
        } catch (_: Throwable) { fail(); return false }
        finally { gate.leave(request.global, ended) }
    }

    private fun fail() {
        if (!failed.compareAndSet(false, true)) return
        gate.retire()
        workers.shutdown()
        abort() // A worker failure must terminate the real stream even while its reader is blocked.
    }
}
