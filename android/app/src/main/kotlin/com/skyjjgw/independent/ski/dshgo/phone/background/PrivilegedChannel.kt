package com.skyjjgw.independent.ski.dshgo.phone.background

import android.os.Bundle
import io.github.muntashirakon.adb.AdbStream

/**
 * One live link to the privileged engine. Three implementations, one contract: the driver
 * sends a request Bundle and gets a response Bundle, never caring whether the engine is
 * reached over a Shizuku binder or an adb stream. Agent calls have priority over optional
 * preview polls on each live channel; [execute] blocks, [tryExecute] skips a busy channel.
 */
interface PrivilegedChannel {
    /** Slots this live link carries ([backgroundRequestLimit]); 0 once it is closed. No IPC here. */
    val backgroundLimit: Int
    fun execute(request: Bundle): Bundle = execute(request) {}
    /** Actual admission commits the original resource pin before any transport write. */
    fun execute(request: Bundle, beforeSend: () -> Unit): Bundle
    fun tryExecute(request: Bundle): Bundle? = null
    fun alive(): Boolean
    fun close()
}

class ShizukuChannel(private val remote: IPrivilegedDisplay, private val peer: String?,
                     @Volatile private var supportedBackgroundLimit: Int) : PrivilegedChannel {
    private val calls = PrivilegedCalls(if (peer == null) 1 else 3)
    override val backgroundLimit: Int get() = if (calls.alive()) supportedBackgroundLimit else 0
    private val ids = java.util.concurrent.atomic.AtomicLong(1)
    override fun execute(request: Bundle, beforeSend: () -> Unit): Bundle =
        calls.execute(MuxProtocol.global(request), beforeSend, { MuxProtocol.destroyed(request, it) }) { exchange(request) }
    override fun tryExecute(request: Bundle): Bundle? = calls.tryPreview { exchange(request) }
    override fun alive(): Boolean = calls.alive() && runCatching { remote.asBinder().pingBinder() }.getOrDefault(false)
    override fun close() { calls.retire() }
    private fun exchange(request: Bundle): Bundle = try {
        val response = if (peer == null) remote.execute(request) else {
            val id = ids.getAndIncrement()
            if (id <= 0 || id == Long.MAX_VALUE) throw java.io.IOException("identityChanged")
            val response = MuxProtocol.unwrap(remote.execute(MuxProtocol.request(request, peer, id)), peer)
            if (response.id != id) throw java.io.IOException("identityChanged")
            response.value
        }
        if (request.get(Proto.OP) == Proto.OP_PROBE)
            supportedBackgroundLimit = backgroundRequestLimit(response.get(Proto.OK), peer != null)
        response
    } catch (error: Exception) { close(); throw error }
}

/** Same candidate owns its streams from plain PROBE through the complete mux handshake. */
class AdbChannel(private val stream: AdbStream) : PrivilegedChannel {
    private val setup = Any()
    @Volatile private var calls = PrivilegedCalls()
    @Volatile private var peer: String? = null
    private var closed = false
    @Volatile private var supportedBackgroundLimit = 0
    override val backgroundLimit: Int get() = if (calls.alive()) supportedBackgroundLimit else 0
    private val session = AdbFramedSession(stream.openInputStream(), stream.openOutputStream(),
        transportAlive = { !stream.isClosed }, closeTransport = { stream.close() })

    internal fun negotiate(probe: Bundle) {
        val expected = MuxProtocol.peer(probe)
        if (expected != null) {
            val ack = execute(MuxProtocol.optIn(expected))
            MuxProtocol.acknowledge(ack, expected)
        }
        val limit = backgroundRequestLimit(probe.get(Proto.OK), expected != null)
        synchronized(setup) {
            check(!closed)
            if (expected != null) {
                val admitted = PrivilegedCalls(3)
                calls = admitted
                peer = expected
                session.installMux(expected, admitted::retire)
            }
            supportedBackgroundLimit = limit
        }
    }
    override fun execute(request: Bundle, beforeSend: () -> Unit): Bundle =
        calls.execute(MuxProtocol.global(request), beforeSend, { MuxProtocol.destroyed(request, it) }) { exchange(request) }
    override fun tryExecute(request: Bundle): Bundle? = calls.tryPreview { exchange(request) }
    private fun exchange(request: Bundle): Bundle = try {
        val expected = peer
        val response = if (expected != null) session.exchangeMux(request, expected)
        else session.exchange(Bundles.marshal(request))?.let(Bundles::unmarshal) ?: throw java.io.IOException("deviceUnavailable")
        if (request.get(Proto.OP) == Proto.OP_PROBE)
            supportedBackgroundLimit = backgroundRequestLimit(response.get(Proto.OK), expected != null)
        response
    } catch (error: Exception) {
        close()
        Bundle().apply { putBoolean(Proto.OK, false); putString(Proto.ERROR, "deviceUnavailable") }
    }
    override fun alive(): Boolean = calls.alive() && session.alive()
    override fun close() {
        synchronized(setup) { if (closed) return; closed = true; calls.retire() }
        session.close()
    }
}

/**
 * Slots one connected link can carry: the multiplexed protocol carries three, a plain one one.
 * Optional PROBE fields never zero this: the service is this same APK (the starters refuse
 * another revision), and a device that cannot do something fails the real operation instead.
 */
internal fun backgroundRequestLimit(ok: Any?, multiplexed: Boolean): Int =
    if (ok != true) 0 else if (multiplexed) 3 else 1
