package com.skyjjgw.independent.ski.dshgo.phone.shell

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Launch returns ownership immediately; prepare performs any bounded pre-exec handshake. */
internal interface ShellOwnedProcess {
    val stdout: InputStream
    val stderr: InputStream
    fun prepare(): Boolean = true
    fun waitFor(): Int
    fun terminate()
    fun close()
}

/** Short start/poll/cancel calls. No command or output is logged or persisted. */
internal class ShellJobCore(private val launch: (String, Long) -> ShellOwnedProcess) {
    private val guard = Any()
    private var closed = false
    private var current: Job? = null
    private val retired = LinkedHashSet<String>()
    private val timer = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "dsh-shell-deadline").apply { isDaemon = true }
    }

    private class Job(val id: String) {
        val stdout = ByteArrayOutputStream()
        val stderr = ByteArrayOutputStream()
        var process: ShellOwnedProcess? = null
        var deadline: ScheduledFuture<*>? = null
        var started = false
        var done = false
        var exitCode: Int? = null
        var timedOut = false
        var cancelled = false
        var truncated = false
        var error: String? = null
        var bytes = 0
    }

    fun start(id: String, command: String, timeoutMs: Long): Map<String, Any?> = synchronized(guard) {
        if (closed) return ShellProtocol.failure("notConnected")
        if (!validJobId(id)) return ShellProtocol.failure("invalidArguments")
        ShellProtocol.commandError(command)?.let { return ShellProtocol.failure(it) }
        ShellProtocol.timeoutError(timeoutMs)?.let { return ShellProtocol.failure(it) }
        current?.let {
            if (it.id == id) return snapshot(it).map() // A lost start reply is never a replay.
            if (!it.done) return ShellProtocol.failure("busy")
        }
        if (id in retired) return ShellProtocol.failure("cancelled")
        current?.let { remember(it.id) }
        val job = Job(id)
        current = job
        job.deadline = timer.schedule({ stop(job, timedOut = true) }, timeoutMs, TimeUnit.MILLISECONDS)
        Thread({ run(job, command, timeoutMs) }, "dsh-shell-job").apply { isDaemon = true; start() }
        snapshot(job).map()
    }

    fun poll(id: String): Map<String, Any?> = synchronized(guard) {
        current?.takeIf { it.id == id }?.let { snapshot(it).map() }
            ?: ShellProtocol.failure(if (id in retired) "cancelled" else "jobNotFound")
    }

    fun cancel(id: String): Map<String, Any?> {
        val job = synchronized(guard) {
            if (!validJobId(id)) return ShellProtocol.failure("invalidArguments")
            remember(id) // Also prevents a delayed START from racing ahead of cancellation.
            current?.takeIf { it.id == id }
        }
        if (job != null) stop(job, timedOut = false)
        return mapOf("ok" to true)
    }

    fun destroy() {
        val job = synchronized(guard) { closed = true; current }
        if (job != null) stop(job, timedOut = false)
        timer.shutdownNow()
    }

    private fun stop(job: Job, timedOut: Boolean) {
        val process = synchronized(guard) {
            if (job.done) return
            if (timedOut) {
                job.timedOut = true
                job.error = "timeout"
            } else {
                job.cancelled = true
                if (!job.timedOut) job.error = "cancelled"
            }
            job.process
        }
        // Never hold the state lock while killing processes or touching streams.
        runCatching { process?.terminate() }
    }

    private fun run(job: Job, command: String, timeoutMs: Long) {
        var process: ShellOwnedProcess? = null
        val readers = mutableListOf<Thread>()
        try {
            if (synchronized(guard) { job.cancelled || job.timedOut || closed }) return
            val child = launch(command, timeoutMs)
            process = child
            val wanted = synchronized(guard) {
                job.process = child
                !job.cancelled && !job.timedOut && !closed
            }
            readers += drain(job, child.stderr, false)
            if (!wanted || !child.prepare()) {
                child.terminate()
                synchronized(guard) { if (job.error == null) job.error = "identityChanged" }
            } else {
                synchronized(guard) { job.started = true }
                readers += drain(job, child.stdout, true)
            }
            val exit = child.waitFor()
            synchronized(guard) { job.exitCode = exit }
        } catch (_: Exception) {
            synchronized(guard) { if (job.error == null) job.error = "executionFailed" }
        } finally {
            // A script cannot leave persistent work in its owned process group, even on normal exit.
            runCatching { process?.terminate() }.onFailure {
                synchronized(guard) { job.error = "cleanupFailed" }
            }
            readers.forEach { reader -> runCatching { reader.join(500) } }
            val incomplete = readers.any { it.isAlive }
            // Some escaped daemon may retain a pipe. Closing must not make the RPC host hang.
            val closer = Thread({ runCatching { process?.close() } }, "dsh-shell-pipe-close").apply {
                isDaemon = true; start()
            }
            runCatching { closer.join(250) }
            readers.forEach { reader -> if (reader.isAlive) runCatching { reader.join(100) } }
            synchronized(guard) {
                if (incomplete) {
                    job.truncated = true
                    job.error = "outputIncomplete"
                    closed = true
                }
                job.deadline?.cancel(false)
                job.process = null
                job.done = true
            }
        }
    }

    private fun drain(job: Job, stream: InputStream, stdout: Boolean): Thread =
        Thread({
            val buffer = ByteArray(4096)
            try {
                while (true) {
                    val count = stream.read(buffer)
                    if (count < 0) break
                    synchronized(guard) {
                        if (job.done) return@Thread
                        val keep = minOf(count, ShellProtocol.MAX_OUTPUT_BYTES - job.bytes)
                        if (keep > 0) {
                            (if (stdout) job.stdout else job.stderr).write(buffer, 0, keep)
                            job.bytes += keep
                        }
                        if (keep < count) job.truncated = true
                    }
                    // Continue draining both pipes after the shared capture budget is exhausted.
                }
            } catch (_: Exception) {
                // Closing owned pipes after cancellation/exit is expected.
            }
        }, if (stdout) "dsh-shell-out" else "dsh-shell-err").apply { isDaemon = true; start() }

    private fun snapshot(job: Job) = ShellSnapshot(
        job.id, job.started, job.done, decode(job.stdout), decode(job.stderr),
        job.exitCode, job.timedOut, job.cancelled, job.truncated, job.error,
    )

    private fun decode(bytes: ByteArrayOutputStream): String = Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPLACE).onUnmappableCharacter(CodingErrorAction.REPLACE)
        .replaceWith("?").decode(ByteBuffer.wrap(bytes.toByteArray())).toString()

    private fun remember(id: String) {
        retired.add(id)
        if (retired.size > 64) retired.remove(retired.first())
    }

    private fun validJobId(id: String): Boolean = id.matches(Regex("[a-zA-Z0-9-]{1,64}"))
}
