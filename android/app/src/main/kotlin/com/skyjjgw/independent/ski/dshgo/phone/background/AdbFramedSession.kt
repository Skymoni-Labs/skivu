package com.skyjjgw.independent.ski.dshgo.phone.background

import android.os.Bundle
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One request/response stream. After an interrupted or incomplete exchange its position is
 * unknowable: a later response may belong to the abandoned request, so this session is retired.
 * Closing never waits for the exchange lock or another protocol response.
 */
class AdbFramedSession(
    private val input: InputStream,
    private val output: OutputStream,
    private val transportAlive: () -> Boolean,
    private val closeTransport: () -> Unit,
) {
    private val lock = Any()
    private val closed = AtomicBoolean(false)
    private var synced = false
    private val muxGuard = Any()
    @Volatile private var mux: FramedMuxSession<Bundle>? = null

    internal fun installMux(peer: String, retired: () -> Unit, deadlineMs: Long = FramedMuxSession.REQUEST_DEADLINE_MS) =
        synchronized(muxGuard) {
            check(!closed.get() && synced && mux == null)
            FramedMuxSession(input, output, { MuxProtocol.unwrap(Bundles.unmarshal(it), peer) },
                { retired(); close() }, deadlineMs).also { mux = it; it.start() }
        }

    internal fun exchangeMux(request: Bundle, peer: String): Bundle =
        checkNotNull(mux).exchange { id -> Bundles.marshal(MuxProtocol.request(request, peer, id)) }

    fun alive(): Boolean = !closed.get() && transportAlive()

    fun exchange(request: ByteArray): ByteArray? = synchronized(lock) {
        if (!alive()) {
            close()
            return@synchronized null
        }
        try {
            if (!synced) {
                if (!Frames.syncToMagic(input)) {
                    close()
                    return@synchronized null
                }
                synced = true
            }
            Frames.write(output, request)
            val response = Frames.read(input)
            if (response == null) close()
            if (closed.get()) null else response
        } catch (error: Exception) {
            // libadb 3.1.1 wraps wait() interruption as IOException(cause=InterruptedException).
            close()
            if (error is InterruptedException || error.cause is InterruptedException) {
                Thread.currentThread().interrupt()
            }
            throw error
        }
    }

    fun close() {
        val current = synchronized(muxGuard) {
            if (!closed.compareAndSet(false, true)) return
            mux
        }
        current?.close()
        // libadb.close first wakes readers, then writes CLSE; a blocked transport write must not
        // hold the caller or delay the logical invalidation above. No DESTROY exchange is sent.
        Thread({ runCatching { closeTransport() } }, "dsh-adb-close").apply {
            isDaemon = true
            start()
        }
    }
}
