package com.skyjjgw.independent.ski.dshgo.phone.shell

import android.os.Bundle
import com.skyjjgw.independent.ski.dshgo.phone.background.Bundles
import io.github.muntashirakon.adb.AdbStream
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal data class ShellConnection(val link: ShellLink? = null, val errorCode: String? = null)

/** A timed-out exchange always retires the link; its response can never become a later reply. */
internal class ShellLink(
    val backend: String,
    private val exchange: (Bundle) -> Bundle,
    private val transportAlive: () -> Boolean,
    private val retire: () -> Unit,
) {
    private val closed = AtomicBoolean(false)
    private val serial = Any()
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "dsh-shell-rpc").apply { isDaemon = true }
    }
    @Volatile var uid: Int = -1
        private set
    @Volatile private var instance: String? = null

    fun probe(): Boolean {
        val response = call(mapOf("op" to "probe"))
        val actualUid = response["uid"] as? Int ?: return false
        val peer = response["instance"] as? String ?: return false
        if (response["ok"] != true || response["revision"] != ShellProtocol.REVISION ||
            !ShellProtocol.validUid(backend, actualUid) || peer.isBlank()) return false
        uid = actualUid
        instance = peer
        return true
    }

    fun call(values: Map<String, Any?>, beforeSend: () -> Boolean = { true }): Map<String, Any?> = synchronized(serial) {
        if (!alive()) throw IOException("transportLost")
        val body = values + mapOf("revision" to ShellProtocol.REVISION, "instance" to instance)
        val future = worker.submit<Bundle> {
            if (!beforeSend()) shellBundle(ShellProtocol.failure("cancelled")) else exchange(shellBundle(body))
        }
        try {
            future.get(ShellProtocol.RPC_TIMEOUT_MS, TimeUnit.MILLISECONDS).shellMap()
        } catch (error: Exception) {
            future.cancel(true)
            close()
            if (error is InterruptedException) Thread.currentThread().interrupt()
            throw IOException("transportLost")
        }
    }

    fun alive(): Boolean = !closed.get() && transportAlive()

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        worker.shutdownNow()
        Thread({ runCatching { retire() } }, "dsh-shell-retire").apply { isDaemon = true; start() }
    }

    companion object {
        fun adb(stream: AdbStream): ShellLink {
            var synced = false
            val input = stream.openInputStream()
            val output = stream.openOutputStream()
            return ShellLink("adb", { request ->
                if (!synced) { ShellWire.sync(input); synced = true }
                ShellWire.write(output, Bundles.marshal(request))
                Bundles.unmarshal(ShellWire.read(input) ?: throw IOException("transportLost"))
            }, { !stream.isClosed }, { stream.close() })
        }
    }
}
