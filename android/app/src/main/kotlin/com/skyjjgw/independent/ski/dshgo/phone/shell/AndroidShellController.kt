package com.skyjjgw.independent.ski.dshgo.phone.shell

import android.content.Context
import com.skyjjgw.independent.ski.dshgo.phone.Decision
import com.skyjjgw.independent.ski.dshgo.phone.PhoneAndroidShell
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Opt-in shell capability, independent of screen-control configuration and confirmation modes. */
class AndroidShellController(context: Context, private val onChanged: () -> Unit = {}) {
    private val context = context.applicationContext
    private val preferences = this.context.getSharedPreferences("android-shell-v1", Context.MODE_PRIVATE)
    private val guard = Any()
    private var enabled = preferences.getBoolean("enabled", false)
    private var backend = preferences.getString("backend", "shizuku").takeIf { it == "adb" || it == "shizuku" } ?: "shizuku"
    private var generation = 0L
    private var setupBusy = false
    private var active: Lease? = null
    @Volatile private var readyLink: ShellLink? = null
    private val adb = ShellAdbBackend(this.context, onChanged)
    private val shizuku = ShellShizukuBackend(this.context, onChanged)

    private class Lease(val ownerId: Long, val generation: Long, val backend: String) {
        val id = UUID.randomUUID().toString()
        @Volatile var cancelled = false
        @Volatile var link: ShellLink? = null
        var sent = false
    }

    fun status(): Map<String, Any?> {
        val config = synchronized(guard) { enabled to backend }
        val shizukuStatus = shizuku.status()
        val adbStatus = adb.status()
        val link = readyLink?.takeIf { it.backend == config.second && it.alive() &&
            (config.second != "shizuku" || shizukuStatus["granted"] == true) }
        val reason = when {
            !config.first -> "disabled"
            link != null -> null
            config.second == "shizuku" && shizukuStatus["installed"] != true -> "shizukuMissing"
            config.second == "shizuku" && shizukuStatus["running"] != true -> "shizukuStopped"
            config.second == "shizuku" && shizukuStatus["granted"] != true -> "permissionRequired"
            config.second == "adb" && adbStatus["paired"] != true -> "adbNotPaired"
            else -> "notConnected"
        }
        return mapOf(
            "v" to 1, "enabled" to config.first, "backend" to config.second,
            "ready" to (config.first && link != null), "uid" to link?.uid,
            "reasonCode" to reason, "shizuku" to shizukuStatus, "adb" to adbStatus,
            "limits" to mapOf("defaultTimeoutMs" to ShellProtocol.DEFAULT_TIMEOUT_MS,
                "maxTimeoutMs" to ShellProtocol.MAX_TIMEOUT_MS, "maxOutputBytes" to ShellProtocol.MAX_OUTPUT_BYTES,
                "maxCommandBytes" to ShellProtocol.MAX_COMMAND_BYTES),
        )
    }

    fun configure(enabled: Boolean, backend: String): Map<String, Any?> {
        if (backend != "shizuku" && backend != "adb") return mapOf("ok" to false, "errorCode" to "invalidArguments")
        val changed = synchronized(guard) {
            if (this.enabled == enabled && this.backend == backend) false else {
                this.enabled = enabled; this.backend = backend; ++generation
                active?.cancelled = true
                readyLink = null
                preferences.edit().putBoolean("enabled", enabled).putString("backend", backend).apply()
                true
            }
        }
        if (changed) { adb.disconnect(); shizuku.disconnect(); onChanged() }
        return status() + mapOf("ok" to true, "errorCode" to null)
    }

    fun requestShizukuPermission(): Boolean = shizuku.requestPermission()
    fun startAdbPairing(): Map<String, Any?> = adb.startPairing()

    fun pairAdb(code: String, port: Int?): Map<String, Any?> {
        val ticket = synchronized(guard) {
            if (setupBusy || active != null) return mapOf("ok" to false, "errorCode" to "busy")
            setupBusy = true; generation
        }
        return try { adb.pair(code, port) { synchronized(guard) { generation == ticket } } }
        finally { synchronized(guard) { setupBusy = false }; onChanged() }
    }

    /** Explicit setup only. status/configure never start a privileged process. */
    fun connect(port: Int? = null): Map<String, Any?> {
        val selection = synchronized(guard) {
            if (!enabled) return mapOf("ok" to false, "errorCode" to "disabled")
            if (setupBusy || active != null) return mapOf("ok" to false, "errorCode" to "busy")
            setupBusy = true; generation to backend
        }
        val wanted = { synchronized(guard) { enabled && generation == selection.first && backend == selection.second } }
        return try {
            val connection = connection(selection.second, port, wanted)
            val link = connection.link ?: return mapOf("ok" to false, "errorCode" to connection.errorCode)
            if (!wanted()) { link.close(); return mapOf("ok" to false, "errorCode" to "cancelled") }
            readyLink = link
            status() + mapOf("ok" to true, "errorCode" to null)
        } finally { synchronized(guard) { setupBusy = false }; onChanged() }
    }

    fun execute(
        ownerId: Long,
        command: String,
        timeoutMs: Long,
        stillWanted: () -> Boolean,
        confirm: (backend: String, uid: Int) -> Decision,
    ): Map<String, Any?> {
        ShellProtocol.commandError(command)?.let { return ShellProtocol.failure(it) }
        ShellProtocol.timeoutError(timeoutMs)?.let { return ShellProtocol.failure(it) }
        val lease = synchronized(guard) {
            if (!enabled) return ShellProtocol.failure("disabled")
            if (setupBusy || active != null) return ShellProtocol.failure("busy")
            Lease(ownerId, generation, backend).also { active = it }
        }
        fun wanted(): Boolean = runCatching { stillWanted() }.getOrDefault(false) && synchronized(guard) {
            active === lease && !lease.cancelled && enabled && generation == lease.generation && backend == lease.backend
        }
        var restoreInterrupt = false
        try {
            if (!wanted()) return result(lease, ShellProtocol.failure("cancelled"))
            val connection = connection(lease.backend, null, ::wanted)
            val link = connection.link ?: return result(lease, ShellProtocol.failure(connection.errorCode ?: "connectFailed"))
            lease.link = link
            if (!wanted()) return result(lease, ShellProtocol.failure("cancelled"))
            // Read real UID on this very channel before every confirmation, not from provider status.
            if (!link.probe()) { link.close(); return result(lease, ShellProtocol.failure("identityChanged")) }
            readyLink = link
            val decision = confirm(lease.backend, link.uid)
            if (!wanted()) return result(lease, ShellProtocol.failure("cancelled"))
            PhoneAndroidShell.confirmationError(decision)?.let { return result(lease, ShellProtocol.failure(it)) }
            var response = link.call(mapOf("op" to "start", "jobId" to lease.id,
                "command" to command, "timeoutMs" to timeoutMs, "uid" to link.uid)) {
                wanted() && synchronized(guard) {
                    if (active !== lease || lease.cancelled || generation != lease.generation || !enabled) false
                    else { lease.sent = true; true }
                }
            }
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs + 2_000)
            var stopSent = false
            while (response["jobId"] == lease.id && response["done"] != true) {
                if (!wanted() && !stopSent) {
                    link.call(mapOf("op" to "cancel", "jobId" to lease.id))
                    stopSent = true
                }
                if (System.nanoTime() > deadline) {
                    runCatching { link.call(mapOf("op" to "cancel", "jobId" to lease.id)) }
                    link.close()
                    return result(lease, ShellProtocol.failure("cleanupFailed", started = true))
                }
                try { Thread.sleep(50) } catch (_: InterruptedException) {
                    restoreInterrupt = true; lease.cancelled = true
                }
                response = link.call(mapOf("op" to "poll", "jobId" to lease.id))
            }
            if (response["errorCode"] == "outputIncomplete") link.close()
            return result(lease, response)
        } catch (_: Exception) {
            val mayHaveStarted = synchronized(guard) { lease.cancelled = true; lease.sent }
            lease.link?.close()
            return result(lease, ShellProtocol.failure("transportLost", started = mayHaveStarted))
        } finally {
            synchronized(guard) { if (active === lease) active = null }
            if (restoreInterrupt) Thread.currentThread().interrupt()
            onChanged()
        }
    }

    private fun result(lease: Lease, values: Map<String, Any?>): Map<String, Any?> =
        values + mapOf("backend" to lease.backend, "uid" to lease.link?.uid?.takeIf { it >= 0 })

    private fun connection(backend: String, port: Int?, wanted: () -> Boolean): ShellConnection =
        if (backend == "adb") adb.connect(port, wanted) else shizuku.connect(wanted)

    fun cancel(ownerId: Long) {
        val lease = synchronized(guard) {
            active?.takeIf { it.ownerId == ownerId }?.also { it.cancelled = true }
        } ?: return
        if (lease.link == null) {
            if (lease.backend == "adb") adb.disconnect() else shizuku.disconnect()
        } else cancelRemote(lease)
    }

    fun cancelAll() {
        val lease = synchronized(guard) {
            ++generation
            readyLink = null
            active?.also { it.cancelled = true }
        }
        if (lease != null) cancelRemote(lease)
        adb.disconnect(); shizuku.disconnect(); onChanged()
    }

    private fun cancelRemote(lease: Lease) {
        val link = lease.link ?: return
        Thread({
            runCatching { link.call(mapOf("op" to "cancel", "jobId" to lease.id)) }
                .onFailure { link.close() }
        }, "dsh-shell-cancel").apply { isDaemon = true; start() }
    }
}
