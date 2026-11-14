// Self-ADB (wireless debugging) path to a shell-uid process, the Shizuku-free way; ADB protocol,
// TLS pairing and mDNS come from libadb-android. This side adds discovery, key storage, the
// pairing flow and the app_process launch.
package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.i18n.AppStrings
import com.skyjjgw.independent.ski.R
import android.content.Context
import android.net.InetAddresses
import android.os.Build
import android.provider.Settings
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import io.github.muntashirakon.adb.android.AdbMdns
import java.io.File
import java.net.InetAddress
import java.security.PrivateKey
import java.security.cert.Certificate
import java.util.concurrent.TimeUnit

/** wirelessDebugging / paired / connected for the status Map. */
data class AdbStatus(
    val wirelessDebugging: Boolean?,
    val paired: Boolean,
    val connected: Boolean,
) {
    fun map(): Map<String, Any?> =
        mapOf("wirelessDebugging" to wirelessDebugging, "paired" to paired, "connected" to connected)
}

class AdbStarter(private val context: Context, private val onChanged: () -> Unit) {

    private val keys = AdbKeyStore(context)
    private val pairedFlag = File(File(context.filesDir, "phone-adb"), "paired").apply { parentFile?.mkdirs() }

    private val manager = object : AbsAdbConnectionManager() {
        init {
            setApi(Build.VERSION.SDK_INT)
            setTimeout(8, TimeUnit.SECONDS)
        }
        override fun getPrivateKey(): PrivateKey = keys.privateKey()
        override fun getCertificate(): Certificate = keys.certificate()
        override fun getDeviceName(): String = "dsh-app"
    }

    @Volatile private var pairingMdns: AdbMdns? = null
    @Volatile private var connectMdns: AdbMdns? = null
    private val pairDiscovery = AdbDiscoverySlot()
    private val connectDiscovery = AdbDiscoverySlot()
    @Volatile private var channel: AdbChannel? = null
    private val guard = Any()
    private class Operation(val mayStart: () -> Boolean, val worker: Thread?) {
        var valid = true
        var candidate: AdbChannel? = null
        var published = false
        var whenAvailable: (() -> Unit)? = null
    }
    // The slot is held until the last manager call (including cleanup) has returned.
    private var operation: Operation? = null

    fun status(): AdbStatus = AdbStatus(wirelessDebugging(), pairedFlag.exists(), channel?.alive() == true)

    fun reason(): String? = when {
        channel?.alive() == true -> null
        !pairedFlag.exists() -> AppStrings.get(context, R.string.background_adb_not_paired)
        else -> AppStrings.get(context, R.string.background_adb_disconnected)
    }

    private fun wirelessDebugging(): Boolean? = runCatching {
        // Reported as unknown from API 36 (Android 16) on. AOSP 17 redacts `adb_enabled` to 0 for
        // third-party apps; `adb_wifi_enabled` is still readable there, so this cutoff is conservative.
        if (Build.VERSION.SDK_INT >= 36) return@runCatching null
        Settings.Global.getInt(context.contentResolver, "adb_wifi_enabled", 0) == 1
    }.getOrDefault(null)

    /** Begins mDNS discovery of the pairing service so [pair] can target the live port. */
    fun startPairing(): Map<String, Any?> {
        stopMdns()
        val pairTicket = pairDiscovery.begin()
        val connectTicket = connectDiscovery.begin()
        pairingMdns = AdbMdns(context, AdbMdns.SERVICE_TYPE_TLS_PAIRING) { address, port ->
            if (pairDiscovery.publish(pairTicket, address, port)) onChanged()
        }.also { it.start() }
        connectMdns = AdbMdns(context, AdbMdns.SERVICE_TYPE_TLS_CONNECT) { address, port ->
            if (connectDiscovery.publish(connectTicket, address, port)) onChanged()
        }.also { it.start() }
        return mapOf("ok" to true)
    }

    /** Pairs with the 6-digit code. [port] overrides mDNS (for the App's manual fallback dialog). */
    fun pair(code: String, port: Int?): Map<String, Any?> {
        if (!code.matches(Regex("\\d{6}"))) return fail(AppStrings.get(context, R.string.pairing_invalid_code))
        val discovered = pairDiscovery.current()
        val host = if (port != null) loopback() else discovered?.address ?: loopback()
        val target = port ?: discovered?.port ?: return fail(AppStrings.get(context, R.string.pairing_port_missing))
        if (target !in 1..65535) return fail(AppStrings.get(context, R.string.background_adb_invalid_port))
        return try {
            val ok = manager.pair(host.hostAddress ?: "127.0.0.1", target, code)
            if (ok) { pairedFlag.writeText("ok"); onChanged() }
            mapOf("ok" to ok, "reason" to if (ok) null else AppStrings.get(context, R.string.pairing_failed))
        } catch (e: Exception) {
            fail(AppStrings.get(context, R.string.pairing_error, e.javaClass.simpleName))
        } finally {
            pairDiscovery.retire()
            runCatching { pairingMdns?.stop() }; pairingMdns = null
        }
    }

    /** Short ownership read; never reconnects, probes, or waits for transport work. */
    internal fun isPublished(expected: PrivilegedChannel): Boolean = synchronized(guard) {
        channel === expected && operation == null
    }

    /** Connects to the local adbd. mayStart is a nonblocking lease, checked before publication. */
    fun connect(port: Int? = null, whenAvailable: (() -> Unit)? = null, mayStart: () -> Boolean = { true }): PrivilegedChannel? {
        if (port != null && port !in 1..65535) return null
        val op = synchronized(guard) {
            if (!mayStart()) return null
            channel?.takeIf { it.alive() }?.let { return it }
            operation?.let {
                if (whenAvailable != null) it.whenAvailable = whenAvailable
                return null
            }
            if (!pairedFlag.exists()) return null
            Operation(mayStart, Thread.currentThread()).also { operation = it }
        }
        val discovered = connectDiscovery.current()
        return try {
            channel?.close()
            channel = null
            manager.disconnect()
            if (!wanted(op)) return null
            val connected = if (port != null) {
                // The connect port on Wireless debugging's main page is different
                // from its short-lived pairing port. Manual input targets this device.
                manager.connect("127.0.0.1", port)
            } else if (discovered != null) {
                val cached = runCatching {
                    manager.connect(discovered.address.hostAddress ?: "127.0.0.1", discovered.port)
                }.getOrDefault(false)
                if (!wanted(op)) return null
                if (cached) true else {
                    // Toggling wireless debugging or changing networks rotates the port.
                    connectDiscovery.discard(discovered)
                    manager.disconnect()
                    if (!wanted(op)) return null
                    manager.autoConnect(context, TimeUnit.SECONDS.toMillis(8))
                }
            } else {
                manager.autoConnect(context, TimeUnit.SECONDS.toMillis(8))
            }
            if (!wanted(op) || (!connected && !manager.isConnected)) return null
            val info = context.applicationInfo
            val stream = manager.openStream("shell:" + PrivilegedCommands.appProcess(info.sourceDir, info.splitSourceDirs?.toList().orEmpty()))
            val value = AdbChannel(stream)
            synchronized(guard) { op.candidate = value }
            if (!wanted(op)) return null
            val probe = value.execute(android.os.Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) })
            if (!probe.getBoolean(Proto.OK) || probe.getString("revision") != Proto.REVISION) return null
            value.negotiate(probe)
            synchronized(guard) {
                if (!op.valid || !op.mayStart()) return null
                channel = value
                op.published = true
                value
            }
        } catch (e: Exception) {
            if (e is InterruptedException) Thread.currentThread().interrupt()
            connectDiscovery.discard(discovered)
            null
        } finally {
            finish(op, preserve = op.published)
            onChanged()
        }
    }

    private fun wanted(op: Operation): Boolean = synchronized(guard) { op.valid && op.mayStart() }

    private fun finish(op: Operation, preserve: Boolean) {
        // Clearing the slot and deciding whether cleanup is needed are one handoff. A disconnect
        // after this handoff claims its own cleanup slot; before it, this worker owns cleanup.
        var available: (() -> Unit)? = null
        val cleanup = synchronized(guard) {
            if (preserve && op.valid) {
                operation = null
                available = op.whenAvailable
                false
            } else true
        }
        if (cleanup) {
            op.candidate?.close()
            runCatching { manager.disconnect() }
            synchronized(guard) { operation = null; available = op.whenAvailable }
        }
        // Only a connect rejected by this slot registered a waiter. Its captured keep ticket
        // decides whether it is still wanted; ordinary failures do not schedule their own retry.
        available?.invoke()
    }

    fun cancelUnwantedPending() {
        val candidate = synchronized(guard) {
            val op = operation ?: return
            if (op.published || op.mayStart()) return
            op.valid = false
            op.worker?.interrupt()
            op.candidate
        }
        candidate?.close()
    }

    fun disconnectIfCurrent(expected: PrivilegedChannel?) {
        if (expected == null) return
        retire(expected)
    }

    fun disconnect() {
        retire(null)
        stopMdns()
        onChanged()
    }

    private fun retire(expected: PrivilegedChannel?) {
        var published: PrivilegedChannel? = null
        var candidate: PrivilegedChannel? = null
        val cleanup = synchronized(guard) {
            if (expected != null && channel !== expected) return
            published = channel; channel = null
            val pending = operation
            if (pending != null) {
                pending.valid = false
                pending.worker?.interrupt()
                candidate = pending.candidate
                null
            } else {
                Operation({ false }, null).also { it.valid = false; operation = it }
            }
        }
        published?.close(); candidate?.close()
        if (cleanup != null) Thread({ finish(cleanup, preserve = false); onChanged() }, "dsh-adb-disconnect").apply {
            isDaemon = true
            start()
        }
    }

    private fun stopMdns() {
        pairDiscovery.retire()
        connectDiscovery.retire()
        runCatching { pairingMdns?.stop() }; pairingMdns = null
        runCatching { connectMdns?.stop() }; connectMdns = null
    }

    private fun loopback(): InetAddress = InetAddresses.parseNumericAddress("127.0.0.1")
    private fun fail(reason: String): Map<String, Any?> = mapOf("ok" to false, "reason" to reason)
}
