package com.skyjjgw.independent.ski.dshgo.phone.shell

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import com.skyjjgw.independent.ski.dshgo.phone.background.ShizukuCleanup
import com.skyjjgw.independent.ski.dshgo.phone.background.shizukuUnbind
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import rikka.shizuku.Shizuku
import rikka.sui.Sui

internal class ShellShizukuBackend(private val context: Context, private val onChanged: () -> Unit) {
    private val guard = Any()
    private val main = Handler(Looper.getMainLooper())
    // Replacing the APK must also replace the service that captured its child-process classpath.
    @Suppress("DEPRECATION")
    private val serviceVersion = context.packageManager.getPackageInfo(context.packageName, 0).versionCode
    private var current: Binding? = null
    @Volatile private var channel: ShellLink? = null

    private class Binding(val wanted: () -> Boolean, val args: Shizuku.UserServiceArgs) {
        val latch = CountDownLatch(1)
        var valid = true
        var worker = true
        var bound = false
        var cleaning = false
        var cleanup: ShizukuCleanup? = null
        var binder: IBinder? = null
        lateinit var listener: ServiceConnection
    }

    init {
        runCatching {
            Shizuku.addBinderDeadListener { disconnect(); onChanged() }
            Shizuku.addBinderReceivedListener { onChanged() }
            Shizuku.addRequestPermissionResultListener { code, _ ->
                if (code == REQUEST_CODE) { if (!granted()) disconnect(); onChanged() }
            }
        }
    }

    fun status(): Map<String, Any?> = mapOf(
        "installed" to (runCatching { context.packageManager.getApplicationInfo("moe.shizuku.privileged.api", 0); true }.getOrDefault(false) || Sui.isSui()),
        "running" to running(), "granted" to granted(),
    )
    private fun running(): Boolean = Shizuku.getBinder()?.isBinderAlive == true
    private fun granted(): Boolean = runCatching {
        running() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    }.getOrDefault(false)

    fun requestPermission(): Boolean = running() && runCatching {
        main.post { runCatching { Shizuku.requestPermission(REQUEST_CODE) } }
        true
    }.getOrDefault(false)

    fun connect(wanted: () -> Boolean): ShellConnection {
        if (!granted()) return ShellConnection(errorCode = when {
            status()["installed"] != true -> "shizukuMissing"
            !running() -> "shizukuStopped"
            else -> "permissionRequired"
        })
        val previous = synchronized(guard) {
            if (!wanted()) return ShellConnection(errorCode = "cancelled")
            channel?.takeIf { it.alive() }?.let { return ShellConnection(it) }
            // Main must remain free to run the old unbind and the new bind.
            if (Looper.myLooper() == main.looper) return ShellConnection(errorCode = "connectFailed")
            current?.let {
                if (it.worker) return ShellConnection(errorCode = "busy")
                retire(it)
                it.cleanup
            }
        }
        try {
            previous?.await(15, TimeUnit.SECONDS)?.let { return ShellConnection(errorCode = "cleanupFailed") }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return ShellConnection(errorCode = "cancelled")
        }
        val binding = synchronized(guard) {
            if (!wanted()) return ShellConnection(errorCode = "cancelled")
            channel?.takeIf { it.alive() }?.let { return ShellConnection(it) }
            // A concurrent caller may have acquired the fixed tag while we waited.
            if (current != null) return ShellConnection(errorCode = "busy")
            Binding(wanted, Shizuku.UserServiceArgs(ComponentName(context, AndroidShellService::class.java))
                .tag(ShellProtocol.TAG).processNameSuffix("android_shell").version(serviceVersion).daemon(false)).also { current = it }
        }
        binding.listener = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                synchronized(guard) {
                    if (current !== binding || !binding.valid) return
                    binding.binder = binder; binding.latch.countDown()
                }
            }
            override fun onServiceDisconnected(name: ComponentName?) {
                synchronized(guard) { if (current === binding) retire(binding) }
                onChanged()
            }
        }
        var candidate: ShellLink? = null
        return try {
            if (!main.post {
                synchronized(guard) {
                    if (!binding.valid || !binding.wanted()) { binding.latch.countDown(); return@post }
                    binding.bound = true
                }
                runCatching { Shizuku.bindUserService(binding.args, binding.listener) }
                    .onFailure { binding.latch.countDown() }
            }) return ShellConnection(errorCode = "connectFailed")
            if (!binding.latch.await(15, TimeUnit.SECONDS)) return ShellConnection(errorCode = "connectFailed")
            val binder = synchronized(guard) {
                if (!binding.valid || !wanted()) return ShellConnection(errorCode = "cancelled")
                binding.binder ?: return ShellConnection(errorCode = "connectFailed")
            }
            val remote = IAndroidShell.remote(binder)
            candidate = ShellLink("shizuku", { remote.execute(it) }, { binder.isBinderAlive }, {
                synchronized(guard) { if (current === binding) retire(binding) }
            })
            if (!candidate.probe()) return ShellConnection(errorCode = "identityChanged")
            synchronized(guard) {
                if (!binding.valid || !wanted()) return ShellConnection(errorCode = "cancelled")
                channel = candidate
                ShellConnection(candidate)
            }
        } catch (error: Exception) {
            if (error is InterruptedException) Thread.currentThread().interrupt()
            ShellConnection(errorCode = if (error is InterruptedException) "cancelled" else "connectFailed")
        }
        finally {
            synchronized(guard) {
                binding.worker = false
                if (channel !== candidate || !binding.valid || candidate == null) { candidate?.close(); retire(binding) }
            }
            onChanged()
        }
    }

    fun disconnect() { synchronized(guard) { current?.let { retire(it) } } }

    private fun retire(binding: Binding) {
        binding.valid = false
        binding.latch.countDown()
        channel?.close(); channel = null
        if (binding.worker || binding.cleaning) return
        binding.cleaning = true
        val cleanup = ShizukuCleanup().also { binding.cleanup = it }
        if (!main.post {
            // Detach the API callback cache, then remove the service before reusing its tag.
            val failure = if (binding.bound) shizukuUnbind(
                detach = { Shizuku.unbindUserService(binding.args, binding.listener, false) },
                remove = { Shizuku.unbindUserService(binding.args, binding.listener, true) },
            ) else null
            synchronized(guard) {
                if (failure == null && current === binding) current = null
                else binding.cleaning = false // a later explicit connect may retry teardown
                cleanup.complete(failure)
            }
            onChanged()
        }) {
            binding.cleaning = false
            cleanup.complete("unbindDispatchFailed")
        }
    }

    private companion object { const val REQUEST_CODE = 4611 }
}
