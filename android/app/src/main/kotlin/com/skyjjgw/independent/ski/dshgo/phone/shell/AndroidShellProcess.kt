package com.skyjjgw.independent.ski.dshgo.phone.shell

import android.os.Process
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileDescriptor
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.system.exitProcess

internal class AndroidShellProcess(command: String, timeoutMs: Long, classpath: String) : ShellOwnedProcess {
    private val process = ProcessBuilder(
        "/system/bin/app_process", "/system/bin", AndroidShellJobMain::class.java.name,
        timeoutMs.toString(), command,
    ).apply {
        environment().clear()
        environment().putAll(shellHelperEnvironment(classpath))
    }.start()
    override val stdout = process.inputStream
    override val stderr = process.errorStream
    private val stopped = AtomicBoolean(false)
    private val permitGuard = Any()
    @Volatile private var group: Int? = null

    override fun prepare(): Boolean {
        // Only the trusted helper runs before this bounded header; user code has not started.
        val header = StringBuilder()
        while (header.length < 96) {
            val value = stdout.read()
            if (value < 0) return false
            if (value == 10) break
            if (value !in 32..126) return false
            header.append(value.toChar())
        }
        val pid = header.toString().removePrefix("DSH_SHELL_JOB ").toIntOrNull() ?: return false
        if (!header.startsWith("DSH_SHELL_JOB ") || pid <= 1) return false
        // Verify the actual helper, not a pid printed by a user command, before releasing stdin.
        val stat = File("/proc/$pid/stat").readText()
        val fields = stat.substringAfterLast(") ").split(' ')
        val realUid = File("/proc/$pid/status").useLines { lines ->
            lines.firstOrNull { it.startsWith("Uid:") }?.substringAfter(':')?.trim()?.split(Regex("\\s+"))?.firstOrNull()?.toIntOrNull()
        }
        if (fields.size < 4 || fields[1].toIntOrNull() != Process.myPid() ||
            fields[2].toIntOrNull() != pid || fields[3].toIntOrNull() != pid || realUid != Process.myUid()) return false
        synchronized(permitGuard) {
            group = pid
            if (stopped.get()) { killGroup(); return false }
            process.outputStream.write(1)
            process.outputStream.flush()
        }
        return true
    }

    override fun waitFor(): Int = process.waitFor()

    override fun terminate() {
        synchronized(permitGuard) {
            stopped.set(true)
            try { killGroup() } finally {
                runCatching { process.destroyForcibly() }
                runCatching { process.outputStream.close() }
            }
        }
    }

    private fun killGroup() {
        group?.let { pid ->
            // The group is created by our child and never inferred from a caller-supplied PID.
            try { Os.kill(-pid, OsConstants.SIGKILL) }
            catch (error: android.system.ErrnoException) { if (error.errno != OsConstants.ESRCH) throw error }
            group = null
        }
    }

    override fun close() {
        runCatching { process.inputStream.close() }
        runCatching { process.errorStream.close() }
        runCatching { process.outputStream.close() }
    }
}

/** Internal child entry: a separate session, same real UID, never su. */
@androidx.annotation.Keep
object AndroidShellJobMain {
    @JvmStatic
    fun main(args: Array<String>) {
        if (args.size != 2) exitProcess(125)
        val timeout = args[0].toLongOrNull() ?: exitProcess(125)
        if (ShellProtocol.timeoutError(timeout) != null || ShellProtocol.commandError(args[1]) != null) exitProcess(125)
        val pid = Process.myPid()
        Os.setsid()
        val output = FileOutputStream(FileDescriptor.out)
        output.write("DSH_SHELL_JOB $pid\n".toByteArray(Charsets.US_ASCII))
        output.flush()
        fun killOwnedGroup() { runCatching { Os.kill(-pid, OsConstants.SIGKILL) }; exitProcess(125) }
        Thread({
            try { Thread.sleep(timeout); killOwnedGroup() } catch (_: InterruptedException) { }
        }, "dsh-shell-child-deadline").apply { isDaemon = true; start() }
        if (System.`in`.read() != 1) exitProcess(125)
        // EOF on the ownership pipe also cancels if the privileged host is killed unexpectedly.
        Thread({
            runCatching { while (System.`in`.read() >= 0) { } }
            killOwnedGroup()
        }, "dsh-shell-parent-watch").apply { isDaemon = true; start() }
        val child = ProcessBuilder("/system/bin/sh", "-c", args[1]).apply {
            environment().clear()
            environment().putAll(shellEnvironment())
        }
            .redirectInput(File("/dev/null"))
            .redirectOutput(ProcessBuilder.Redirect.INHERIT)
            .redirectError(ProcessBuilder.Redirect.INHERIT)
            .start()
        exitProcess(child.waitFor())
    }
}
