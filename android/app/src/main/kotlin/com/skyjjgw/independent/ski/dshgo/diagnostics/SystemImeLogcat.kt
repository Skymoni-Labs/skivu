package com.skyjjgw.independent.ski.dshgo.diagnostics

import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Runs only in the existing privileged core. stdout is parsed here, never relayed or logged. */
object SystemImeLogcat {
    data class Capture(val code: String, val capturedAt: Long, val events: List<SystemImeEvent> = emptyList())
    private val busy = AtomicBoolean(false)
    private val timer = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "dsh-ime-deadline").apply { isDaemon = true }
    }

    fun collect(appPid: Int): Capture {
        val at = System.currentTimeMillis()
        if (appPid <= 0) return Capture("failed", at)
        if (!busy.compareAndSet(false, true)) return Capture("busy", at)
        try {
            val process = try { ProcessBuilder(SystemImeEvidence.command).redirectErrorStream(true).start() }
                catch (_: Exception) { return Capture("unavailable", at) }
            return read(process, appPid, at)
        } finally { busy.set(false) }
    }

    internal fun read(process: Process, appPid: Int, at: Long): Capture {
        val expired = AtomicBoolean(false)
        val deadline = timer.schedule({
            expired.set(true)
            process.destroyForcibly()
        }, SystemImeEvidence.RUNTIME_MS, TimeUnit.MILLISECONDS)
        try {
            val events = ArrayList<SystemImeEvent>()
            val line = ByteArrayOutputStream()
            var bytes = 0
            var oversized = false
            process.inputStream.use { input ->
                while (true) {
                    if (Thread.currentThread().isInterrupted) return Capture("cancelled", at)
                    val byte = input.read()
                    if (expired.get()) return Capture("timeout", at)
                    if (byte == -1) break
                    if (++bytes > SystemImeEvidence.MAX_BYTES) return Capture("limitExceeded", at)
                    if (byte == 10) {
                        if (!oversized) SystemImeEvidence.parse(line.toString("UTF-8"), appPid, at)?.let {
                            if (events.size >= SystemImeEvidence.MAX_EVENTS) return Capture("limitExceeded", at)
                            events.add(it)
                        }
                        line.reset()
                        oversized = false
                    } else if (line.size() < SystemImeEvidence.MAX_LINE_BYTES) {
                        line.write(byte)
                    } else oversized = true
                }
            }
            // Ignore an incomplete final line. A hung logcat is still killed after EOF.
            if (!process.waitFor(SystemImeEvidence.RUNTIME_MS, TimeUnit.MILLISECONDS) || expired.get())
                return Capture("timeout", at)
            if (process.exitValue() != 0) return Capture("unavailable", at)
            return Capture(if (events.isEmpty()) "noEvents" else "ok", at, events)
        } catch (_: Exception) {
            return Capture(if (expired.get()) "timeout" else "failed", at)
        } finally {
            deadline.cancel(false)
            process.destroyForcibly()
            runCatching { process.inputStream.close() }
            runCatching { process.errorStream.close() }
            runCatching { process.outputStream.close() }
        }
    }
}
