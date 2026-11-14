// Root app_process path. Magisk/KernelSU/APatch command syntax checked against upstream
// source; authorization UI, SELinux and display behavior have NOT been verified on devices.
package com.skyjjgw.independent.ski.dshgo.phone.background

import android.content.Context
import android.os.Bundle
import android.os.Process
import java.io.IOException

/**
 * su runs only from [start]: behind an explicit user action, or, once the person turned on
 * keeping root, from the keeper. Tasks and [grantSecureSettings] only use what a start left alive.
 */
class RootStarter(private val context: Context, private val onChanged: () -> Unit) {
    private val guard = Any()
    private val startLock = Any()
    private val state = RootState()
    private var channel: RootChannel? = null
    private var pending: RootProcess? = null
    private var pendingAllowed: (() -> Boolean)? = null

    fun status(): RootStatus {
        discardDead()
        return synchronized(guard) { state.status() }
    }

    /** Short ownership read; never reconnects, probes, or waits for transport work. */
    internal fun isPublished(expected: PrivilegedChannel): Boolean = synchronized(guard) {
        channel === expected
    }

    fun connect(): PrivilegedChannel? {
        discardDead()
        return synchronized(guard) { channel }
    }

    /**
     * [mayStart] (a lock-free read of the caller's UI or explicit keep ticket) is checked under the guard [disconnect]
     * takes, so a cancel either comes first and nothing starts, or ends this start's ticket.
     */
    fun start(mayStart: () -> Boolean = { true }): PrivilegedChannel? = synchronized(startLock) start@{
        discardDead()
        val ticket = synchronized(guard) {
            channel?.let { return@start if (mayStart()) it else null }
            (state.beginIfAllowed(mayStart) ?: return@start null).also { pendingAllowed = mayStart }
        }
        onChanged()
        val stillAccepted = synchronized(guard) {
            if (!state.current(ticket) || !mayStart()) {
                if (state.current(ticket)) { pendingAllowed = null; state.disconnect() }
                false
            } else true
        }
        if (!stillAccepted) { onChanged(); return@start null }
        val info = context.applicationInfo
        val process = try {
            RootProcess.launch(RootCommands.appProcess(info.sourceDir, info.splitSourceDirs?.toList().orEmpty()))
        } catch (error: Exception) {
            synchronized(guard) { if (state.current(ticket)) { pendingAllowed = null; state.finish(ticket, reason(error)) } }
            onChanged()
            return@start null
        }
        // Registered, disconnect() closes it mid-authorization; already cancelled, it closes now.
        val registered = synchronized(guard) {
            if (state.current(ticket)) { pending = process; true } else false
        }
        if (!registered) process.close()
        val deadline = System.nanoTime() + java.util.concurrent.TimeUnit.MILLISECONDS.toNanos(START_TIMEOUT_MS)
        fun remaining(): Long = java.util.concurrent.TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime()).also {
            if (it <= 0) throw IOException("rootTimeout")
        }
        var negotiated: String? = null
        var backgroundLimit = 0
        val failure = try {
            val probe = Bundles.unmarshal(process.exchange(Bundles.marshal(Bundle().apply {
                putString(Proto.OP, Proto.OP_PROBE)
            }), remaining()))
            when {
                !probe.getBoolean(Proto.OK) -> "rootStartFailed"
                !RootProbe.accepted(true, probe.getInt(Proto.UID, -1), probe.getString("revision"), Proto.REVISION) -> "rootIdentityMismatch"
                else -> {
                    negotiated = MuxProtocol.peer(probe)
                    negotiated?.let { peer ->
                        val ack = Bundles.unmarshal(process.exchange(Bundles.marshal(MuxProtocol.optIn(peer)), remaining()))
                        MuxProtocol.acknowledge(ack, peer)
                    }
                    backgroundLimit = backgroundRequestLimit(probe.get(Proto.OK), negotiated != null)
                    null
                }
            }
        } catch (error: Exception) {
            reason(error)
        }
        val candidate = if (failure == null) try {
            RootChannel(process, negotiated, backgroundLimit) { channelFailed(process, it) }
        } catch (_: Exception) { process.close(); null } else null
        val result = synchronized(guard) {
            if (state.current(ticket) && !mayStart()) state.disconnect()
            pending = null
            pendingAllowed = null
            if (state.finish(ticket, failure ?: if (candidate == null) "rootStartFailed" else null) && candidate != null) {
                candidate.also { channel = it }
            } else null
        }
        if (result == null) process.close()
        onChanged()
        result
    }

    /** The fixed grant uses the connected root process; it never starts or retries su. */
    fun grantSecureSettings(): Boolean {
        val current = connect() ?: return false
        val ok = current.execute(Bundle().apply {
            putString(Proto.OP, Proto.OP_GRANT_SECURE_SETTINGS)
            putInt(Proto.USER, Process.myUid() / 100000)
        }).getBoolean(Proto.OK)
        if (!ok) synchronized(guard) {
            if (channel === current) state.note("rootGrantFailed")
        }
        onChanged()
        return ok
    }

    /** Revokes only a still-pending attempt whose own caller no longer wants it. */
    fun cancelUnwantedPending() {
        var closing: RootProcess? = null
        val cancelled = synchronized(guard) {
            val allowed = pendingAllowed
            if (allowed == null || allowed()) false else {
                state.disconnect(); pendingAllowed = null
                closing = pending; pending = null
                true
            }
        }
        closing?.close()
        if (cancelled) onChanged()
    }

    fun disconnect() {
        val closing = synchronized(guard) {
            state.disconnect(); pendingAllowed = null
            (pending to channel).also { pending = null; channel = null }
        }
        closing.first?.close(); closing.second?.close()
        onChanged()
    }

    /** Ends this exact process (its displays go with it); a newer connection is left alone. */
    fun disconnectIfCurrent(expected: PrivilegedChannel) {
        val closing = synchronized(guard) {
            if (channel !== expected) return
            state.disconnect()
            channel.also { channel = null }
        }
        closing?.close()
        onChanged()
    }

    private fun discardDead() {
        val dead = synchronized(guard) {
            channel?.takeIf { !it.alive() }?.also { channel = null; state.disconnect() }
        }
        dead?.close()
    }

    private fun channelFailed(process: RootProcess, failure: String) {
        synchronized(guard) {
            if (channel?.process !== process) return
            channel = null
            state.disconnect()
            state.note(failure)
        }
        onChanged()
    }

    companion object {
        // App policy, not the managers' own authorization timeouts.
        const val START_TIMEOUT_MS = 30_000L
        private fun reason(error: Exception): String =
            error.message.takeIf { error is IOException && it in setOf("rootTimeout", "rootCancelled") } ?: "rootStartFailed"
    }
}

private class RootChannel(
    val process: RootProcess,
    private val peer: String?,
    @Volatile private var supportedBackgroundLimit: Int,
    private val onFailure: (String) -> Unit,
) : PrivilegedChannel {
    private val calls = PrivilegedCalls(if (peer == null) 1 else 3)
    init { peer?.let { process.installMux(it, calls::retire) } }
    override val backgroundLimit: Int get() = if (calls.alive()) supportedBackgroundLimit else 0
    override fun alive(): Boolean = calls.alive() && process.alive()
    override fun close() { calls.retire(); process.close() }
    override fun execute(request: Bundle, beforeSend: () -> Unit): Bundle =
        calls.execute(MuxProtocol.global(request), beforeSend, { MuxProtocol.destroyed(request, it) }) { exchange(request) }
    override fun tryExecute(request: Bundle): Bundle? = calls.tryPreview { exchange(request) }

    private fun exchange(request: Bundle): Bundle = try {
        val response = if (peer == null) Bundles.unmarshal(process.exchange(Bundles.marshal(request), 30_000))
        else process.exchangeMux(request, peer)
        if (request.get(Proto.OP) == Proto.OP_PROBE)
            supportedBackgroundLimit = backgroundRequestLimit(response.get(Proto.OK), peer != null)
        response
    } catch (error: Exception) {
        val timeout = error is IOException && error.message == "rootTimeout"
        close()
        onFailure(if (timeout) "rootTimeout" else "rootDisconnected")
        Bundle().apply {
            putBoolean(Proto.OK, false)
            putString(Proto.ERROR, if (timeout) "timeout" else "deviceUnavailable")
            if (!timeout) putString(Proto.ERROR_DETAIL, "root ${error.javaClass.simpleName}")
        }
    }
}
