// Portions derived from Phase (https://github.com/CikeSeven/phase), used with the author's permission. See THIRD_PARTY_NOTICES.md.
// Shizuku binding, permission and status, through the Shizuku API (dev.rikka.shizuku).
package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.i18n.AppStrings
import com.skyjjgw.independent.ski.R
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import rikka.shizuku.Shizuku
import rikka.sui.Sui

class ShizukuStarter(
    private val context: Context,
    private val onAccessChanged: () -> Unit,
    private val onChanged: () -> Unit,
) {
    companion object {
        const val PACKAGE = "moe.shizuku.privileged.api"
        private const val PERMISSION_REQUEST_CODE = 4601

        /** 自动恢复无障碍's request, told apart from 不打扰模式's. */
        private const val GRANT_REQUEST_CODE = 4602
    }

    private val main = Handler(Looper.getMainLooper())
    @Volatile private var channel: ShizukuChannel? = null
    /** Stable failure stage for the latest connect attempt; null after a successful connect. */
    @Volatile var connectReasonCode: String? = null
        private set
    private val guard = Any()
    private class Binding(val mayStart: () -> Boolean, val args: Shizuku.UserServiceArgs) {
        val latch = CountDownLatch(1)
        var worker: Thread? = Thread.currentThread()
        var valid = true
        var bound = false // main-thread bind was issued, even if the remote call failed
        var cleaning = false
        var cleanup: ShizukuCleanup? = null
        var bindFailure: String? = null
        var whenAvailable: (() -> Unit)? = null
        var binder: IBinder? = null
        lateinit var listener: ServiceConnection
    }
    private var binding: Binding? = null
    @Volatile private var listenersAdded = false

    // Refresh the service for every installed APK, not only manually remembered protocol bumps.
    @Suppress("DEPRECATION")
    private val serviceVersion = context.packageManager.getPackageInfo(context.packageName, 0).versionCode
    private val args0: Shizuku.UserServiceArgs
        get() = Shizuku.UserServiceArgs(ComponentName(context, PrivilegedDisplayService::class.java))
            .tag("dsh.vdisplay").processNameSuffix("vdisplay").version(serviceVersion).daemon(false)

    private fun appInstalled(): Boolean =
        runCatching { context.packageManager.getApplicationInfo(PACKAGE, 0); true }.getOrDefault(false)

    fun running(): Boolean = runCatching { Shizuku.pingBinder() }.getOrDefault(false)

    fun granted(): Boolean = runCatching {
        running() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    }.getOrDefault(false)

    // ShizukuProvider has already run Sui.init() before the Activity; isSui() only reads its result.
    fun status(): ShizukuStatus = ShizukuStatus.fromFacts(appInstalled(), Sui.isSui(), running(), granted())

    fun uid(): Int = runCatching { Shizuku.getUid() }.getOrDefault(-1)

    /** A one-line reason when not ready, else null. */
    fun reason(): String? {
        val status = status()
        val sui = status.provider == ShizukuStatus.SUI
        return when {
            !status.installed -> AppStrings.get(context, R.string.background_shizuku_missing)
            !status.running -> AppStrings.get(context,
                if (sui) R.string.background_sui_stopped else R.string.background_shizuku_stopped)
            !status.granted -> AppStrings.get(context,
                if (sui) R.string.background_sui_permission else R.string.background_shizuku_permission)
            else -> null
        }
    }

    fun ensureListeners() {
        if (listenersAdded) return
        listenersAdded = true
        runCatching {
            // An already-present binder is only an initial status refresh, not a
            // new access generation that could retire the first pending probe.
            Shizuku.addBinderReceivedListener { onAccessChanged(); onChanged() }
            Shizuku.addBinderDeadListener { disconnect(); onAccessChanged(); onChanged() }
            Shizuku.addRequestPermissionResultListener { _, _ -> onAccessChanged(); onChanged() }
            onChanged()
        }
    }

    fun requestPermission(): Boolean {
        if (!running()) return false
        return runCatching { Shizuku.requestPermission(PERMISSION_REQUEST_CODE); true }.getOrDefault(false)
    }

    /** Asks for the permission; [then] runs (main thread) once the person allows it. */
    fun requestPermission(then: () -> Unit): Boolean {
        if (!running()) return false
        val listener = object : Shizuku.OnRequestPermissionResultListener {
            override fun onRequestPermissionResult(requestCode: Int, grantResult: Int) {
                if (requestCode != GRANT_REQUEST_CODE) return
                Shizuku.removeRequestPermissionResultListener(this)
                onChanged()
                if (grantResult == PackageManager.PERMISSION_GRANTED) then()
            }
        }
        return runCatching {
            Shizuku.addRequestPermissionResultListener(listener)
            Shizuku.requestPermission(GRANT_REQUEST_CODE)
            true
        }.getOrElse {
            Shizuku.removeRequestPermissionResultListener(listener)
            false
        }
    }

    /** Short ownership read; never reconnects, probes, or waits for transport work. */
    internal fun isPublished(expected: PrivilegedChannel): Boolean = synchronized(guard) {
        channel === expected && binding?.let { it.valid && !it.cleaning && it.worker == null } == true
    }

    private fun connectFailed(reasonCode: String): PrivilegedChannel? {
        connectReasonCode = reasonCode
        return null
    }

    /** Cleanup and bind waits are bounded; Binder PROBE and physical teardown are not cancelled by a timeout. */
    fun connect(whenAvailable: (() -> Unit)? = null, mayStart: () -> Boolean = { true }): PrivilegedChannel? {
        if (!running()) return connectFailed("serviceUnavailable")
        if (!granted()) return connectFailed("permissionDenied")
        val previous = synchronized(guard) {
            if (!mayStart()) return connectFailed("cancelled")
            channel?.takeIf { it.alive() }?.let { connectReasonCode = null; return it }
            // Waiting here on main would prevent both unbind and bind from running.
            if (Looper.myLooper() == main.looper) return connectFailed("mainThread")
            binding?.let {
                if (it.worker != null) {
                    if (whenAvailable != null) it.whenAvailable = whenAvailable
                    return connectFailed("bindingBusy")
                }
                retire(it)
                it.cleanup
            }
        }
        try {
            previous?.await(15, TimeUnit.SECONDS)?.let { return connectFailed(it) }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return connectFailed("interrupted")
        }
        val owner = synchronized(guard) {
            if (!mayStart()) return connectFailed("cancelled")
            channel?.takeIf { it.alive() }?.let { connectReasonCode = null; return it }
            // Another caller may have acquired the tag while this caller waited. No second bind.
            binding?.let {
                if (whenAvailable != null) it.whenAvailable = whenAvailable
                return connectFailed("bindingBusy")
            }
            Binding(mayStart, args0).also { binding = it }
        }
        owner.listener = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                synchronized(guard) {
                    if (binding !== owner || !owner.valid) return
                    owner.binder = binder
                    owner.latch.countDown()
                }
            }
            override fun onServiceDisconnected(name: ComponentName?) {
                synchronized(guard) { if (binding === owner) retire(owner) }
                onChanged()
            }
        }
        var failureStage = "bindFailed"
        try {
            if (!main.post {
                val bind = synchronized(guard) {
                    if (!owner.valid || !owner.mayStart()) { owner.bindFailure = "cancelled"; false }
                    else { owner.bound = true; true }
                }
                if (bind) runCatching { Shizuku.bindUserService(owner.args, owner.listener) }
                    .onFailure {
                        synchronized(guard) { owner.bindFailure = "bindFailed" }
                        owner.latch.countDown()
                    }
                else owner.latch.countDown()
            }) return connectFailed("bindDispatchFailed")
            if (!owner.latch.await(15, TimeUnit.SECONDS)) return connectFailed("bindTimeout")
            val binder = synchronized(guard) {
                if (!owner.valid || !owner.mayStart()) return connectFailed("cancelled")
                owner.bindFailure?.let { return connectFailed(it) }
                owner.binder
            }
            val remote = IPrivilegedDisplay.Stub.asInterface(binder) ?: return connectFailed("noBinder")
            failureStage = "probeFailed"
            val probe = remote.execute(android.os.Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) })
            if (!probe.getBoolean(Proto.OK)) return connectFailed("probeRejected")
            if (probe.getString("revision") != Proto.REVISION) return connectFailed("protocolMismatch")
            failureStage = "muxFailed"
            val peer = MuxProtocol.peer(probe)
            peer?.let { MuxProtocol.acknowledge(remote.execute(MuxProtocol.optIn(it)), it) }
            val candidate = ShizukuChannel(remote, peer, backgroundRequestLimit(probe.get(Proto.OK), peer != null))
            return synchronized(guard) {
                if (!owner.valid || !owner.mayStart()) { candidate.close(); return connectFailed("cancelled") }
                connectReasonCode = null
                candidate.also { channel = it }
            }
        } catch (e: Exception) {
            if (e is InterruptedException) Thread.currentThread().interrupt()
            return connectFailed(if (e is InterruptedException) "interrupted" else failureStage)
        } finally {
            val available = synchronized(guard) {
                owner.worker = null
                if (!owner.valid || channel == null) { retire(owner); null }
                else owner.whenAvailable.also { owner.whenAvailable = null }
            }
            available?.invoke()
            onChanged()
        }
    }

    fun cancelUnwantedPending() {
        synchronized(guard) {
            val owner = binding ?: return
            if (channel == null && !owner.mayStart()) retire(owner)
        }
    }

    fun disconnectIfCurrent(expected: PrivilegedChannel?) {
        if (expected == null) return
        synchronized(guard) {
            if (channel === expected) binding?.let { retire(it) }
        }
    }

    fun disconnect() {
        synchronized(guard) { binding?.let { retire(it) } }
    }

    // Caller holds guard. A pending Binder operation must finish before its tag may be reused.
    private fun retire(owner: Binding) {
        owner.valid = false
        channel?.close() // Memory-only admission retirement; physical unbind remains below.
        channel = null
        owner.latch.countDown()
        owner.worker?.interrupt()
        if (owner.worker != null || owner.cleaning) return
        owner.cleaning = true
        val cleanup = ShizukuCleanup().also { owner.cleanup = it }
        if (!main.post {
            // API 13.1.5 remove=true leaves its local callback cache until a death callback.
            // Detach that cache first; both unbind calls must return before reusing the tag.
            val failure = if (owner.bound) shizukuUnbind(
                detach = { Shizuku.unbindUserService(owner.args, owner.listener, false) },
                remove = { Shizuku.unbindUserService(owner.args, owner.listener, true) },
            ) else null
            val available = synchronized(guard) {
                val callback = if (failure == null) {
                    binding = null
                    owner.whenAvailable.also { owner.whenAvailable = null }
                } else {
                    owner.cleaning = false // a later explicit connect may attempt teardown again
                    null
                }
                cleanup.complete(failure) // signal only after the old tag is released (or retained on failure)
                callback
            }
            available?.invoke()
            onChanged()
        }) {
            owner.cleaning = false
            cleanup.complete("unbindDispatchFailed")
        }
    }
}

/** Completion belongs to one cleanup attempt, never to a later bind using the same tag. */
internal class ShizukuCleanup {
    private val done = CountDownLatch(1)
    private var failure: String? = null

    fun complete(reasonCode: String?) {
        failure = reasonCode
        done.countDown()
    }

    fun await(timeout: Long, unit: TimeUnit): String? =
        if (done.await(timeout, unit)) failure else "unbindTimeout"
}

internal fun shizukuUnbind(detach: () -> Unit, remove: () -> Unit): String? {
    // API 13.1.5 recreates a missing local connection on detach; failed removal remains retryable.
    val detached = runCatching(detach).isSuccess
    val removed = runCatching(remove).isSuccess
    return if (detached && removed) null else "unbindFailed"
}
