package com.skyjjgw.independent.ski.dshgo.phone.shell

import android.content.Context
import android.os.Build
import com.skyjjgw.independent.ski.dshgo.phone.background.AdbKeyStore
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import io.github.muntashirakon.adb.android.AdbMdns
import java.io.File
import java.net.InetAddress
import java.net.NetworkInterface
import java.security.PrivateKey
import java.security.cert.Certificate
import java.util.concurrent.TimeUnit

/** Discovery supplies only ports: all pairing and connect sockets target 127.0.0.1. */
internal class ShellAdbBackend(private val context: Context, private val onChanged: () -> Unit) {
    private val keys = AdbKeyStore(context)
    private val paired = File(context.filesDir, "phone-adb/paired")
    private val manager = object : AbsAdbConnectionManager() {
        init { setApi(Build.VERSION.SDK_INT); setTimeout(8, TimeUnit.SECONDS) }
        override fun getPrivateKey(): PrivateKey = keys.privateKey()
        override fun getCertificate(): Certificate = keys.certificate()
        override fun getDeviceName(): String = "dsh-app"
    }
    private val guard = Object()
    private var generation = 0L
    private var busy = false
    private var cleanup = false
    private var discoveryGeneration = 0L
    private var pairPort: Int? = null
    private var connectPort: Int? = null
    private var pairMdns: AdbMdns? = null
    private var connectMdns: AdbMdns? = null
    @Volatile private var channel: ShellLink? = null

    fun status(): Map<String, Any?> = mapOf("paired" to paired.isFile, "connected" to (channel?.alive() == true))

    fun startPairing(): Map<String, Any?> = try {
        discover(pairing = true)
        mapOf("ok" to true, "errorCode" to null)
    } catch (_: Exception) { mapOf("ok" to false, "errorCode" to "connectFailed") }

    private fun discover(pairing: Boolean) {
        synchronized(guard) {
            if (connectMdns != null && (!pairing || pairMdns != null)) return
            val ticket = ++discoveryGeneration
            runCatching { pairMdns?.stop() }; runCatching { connectMdns?.stop() }
            pairPort = null; connectPort = null
            if (pairing) pairMdns = AdbMdns(context, AdbMdns.SERVICE_TYPE_TLS_PAIRING) { address, port ->
                publish(ticket, true, address, port)
            }.also { it.start() }
            connectMdns = AdbMdns(context, AdbMdns.SERVICE_TYPE_TLS_CONNECT) { address, port ->
                publish(ticket, false, address, port)
            }.also { it.start() }
        }
    }

    private fun publish(ticket: Long, pairing: Boolean, address: InetAddress?, port: Int) {
        // Ignore neighboring devices, including a remote mDNS record with an otherwise valid port.
        if (address == null || !(address.isLoopbackAddress || runCatching { NetworkInterface.getByInetAddress(address) != null }.getOrDefault(false))) return
        synchronized(guard) {
            if (ticket != discoveryGeneration) return
            if (pairing) pairPort = port.takeIf { it in 1..65535 } else connectPort = port.takeIf { it in 1..65535 }
            guard.notifyAll()
        }
        onChanged()
    }

    private fun port(pairing: Boolean, manual: Int?, wanted: () -> Boolean): Int? {
        if (manual != null) return manual.takeIf { it in 1..65535 }
        discover(pairing)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8)
        synchronized(guard) {
            while (wanted()) {
                (if (pairing) pairPort else connectPort)?.let { return it }
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) return null
                TimeUnit.NANOSECONDS.timedWait(guard, minOf(remaining, TimeUnit.MILLISECONDS.toNanos(100)))
            }
        }
        return null
    }

    fun pair(code: String, manualPort: Int?, wanted: () -> Boolean): Map<String, Any?> {
        if (!code.matches(Regex("[0-9]{6}")) || manualPort != null && manualPort !in 1..65535)
            return mapOf("ok" to false, "errorCode" to "invalidArguments")
        val ticket = begin() ?: return mapOf("ok" to false, "errorCode" to "busy")
        return try {
            val target = port(true, manualPort) { valid(ticket) && wanted() }
                ?: return mapOf("ok" to false, "errorCode" to "connectFailed")
            if (!valid(ticket) || !wanted()) return mapOf("ok" to false, "errorCode" to "cancelled")
            val ok = manager.pair("127.0.0.1", target, code)
            if (!valid(ticket) || !wanted()) return mapOf("ok" to false, "errorCode" to "cancelled")
            if (ok) { paired.parentFile?.mkdirs(); paired.writeText("ok") }
            mapOf("ok" to ok, "errorCode" to if (ok) null else "connectFailed")
        } catch (_: Exception) { mapOf("ok" to false, "errorCode" to "connectFailed") }
        finally { finish(ticket); onChanged() }
    }

    fun connect(manualPort: Int?, wanted: () -> Boolean): ShellConnection {
        if (manualPort != null && manualPort !in 1..65535) return ShellConnection(errorCode = "invalidArguments")
        channel?.takeIf { it.alive() && wanted() }?.let { return ShellConnection(it) }
        val ticket = begin() ?: return ShellConnection(errorCode = "busy")
        var candidate: ShellLink? = null
        var published = false
        return try {
            val target = port(false, manualPort) { valid(ticket) && wanted() }
                ?: return ShellConnection(errorCode = if (paired.isFile) "connectFailed" else "adbNotPaired")
            if (!valid(ticket) || !wanted()) return ShellConnection(errorCode = "cancelled")
            channel?.close(); channel = null
            manager.disconnect()
            if (!manager.connect("127.0.0.1", target)) return ShellConnection(errorCode = "connectFailed")
            if (!valid(ticket) || !wanted()) return ShellConnection(errorCode = "cancelled")
            val info = context.applicationInfo
            val classpath = (listOf(info.sourceDir) + info.splitSourceDirs.orEmpty()).joinToString(":")
            require(classpath.isNotBlank() && '\u0000' !in classpath)
            val quoted = "'" + classpath.replace("'", "'\\''") + "'"
            candidate = ShellLink.adb(manager.openStream("shell:CLASSPATH=" + quoted +
                " exec /system/bin/app_process /system/bin " + AndroidShellMain::class.java.name))
            if (!candidate.probe()) return ShellConnection(errorCode = "identityChanged")
            synchronized(guard) {
                if (!valid(ticket) || !wanted()) return ShellConnection(errorCode = "cancelled")
                channel = candidate
                published = true
            }
            ShellConnection(candidate)
        } catch (_: Exception) {
            synchronized(guard) { connectPort = null }
            ShellConnection(errorCode = "connectFailed")
        } finally {
            if (!published) { candidate?.close(); runCatching { manager.disconnect() } }
            finish(ticket); onChanged()
        }
    }

    private fun begin(): Long? = synchronized(guard) {
        if (busy) null else { busy = true; generation }
    }
    private fun valid(ticket: Long): Boolean = synchronized(guard) { generation == ticket && !cleanup }
    private fun finish(ticket: Long) {
        synchronized(guard) {
            if (generation == ticket && !cleanup) { busy = false; guard.notifyAll(); return }
        }
        runCatching { manager.disconnect() }
        synchronized(guard) { busy = false; cleanup = false; guard.notifyAll() }
    }

    fun disconnect() {
        val shouldClean = synchronized(guard) {
            ++generation; cleanup = true
            ++discoveryGeneration
            runCatching { pairMdns?.stop() }; pairMdns = null
            runCatching { connectMdns?.stop() }; connectMdns = null
            pairPort = null; connectPort = null
            channel?.close(); channel = null
            guard.notifyAll()
            if (busy) false else { busy = true; true }
        }
        if (shouldClean) Thread({
            runCatching { manager.disconnect() }
            synchronized(guard) { busy = false; cleanup = false }
            onChanged()
        }, "dsh-shell-adb-stop").apply { isDaemon = true; start() }
    }
}
