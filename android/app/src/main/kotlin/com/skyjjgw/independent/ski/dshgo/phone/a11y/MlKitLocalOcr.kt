package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import java.util.concurrent.Executors

/** Process owner. Construction/settings never enter ML Kit; only an admitted recognize does. */
internal class MlKitLocalOcr private constructor(context: Context) : LocalOcr {
    private val app = context.applicationContext
    private val gate = Object()
    private var switchedOn = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY, true)
    private var epoch = 0L
    private var generation: Generation? = null
    private var active: Job? = null
    // Never shut down on driver retirement or OFF: the original SDK Task may finish later.
    private val cleanup = Executors.newSingleThreadExecutor { work ->
        Thread(work, "dsh-local-ocr-close").apply { isDaemon = true }
    }

    private class Generation {
        var session: MlKitSession? = null
        var retired = false
        var closing = false
        var failed = false
    }
    private class Job(val generation: Generation, val epoch: Long, val deadline: Long) {
        var copy: Bitmap? = null
        var accepting = true
        var submitted = false
        var terminalClaimed = false
        var result: LocalOcrResult? = null
    }

    val enabled: Boolean get() = synchronized(gate) { switchedOn }
    /** Snapshot for the caller's same-observation read/format boundary; ON does not revive an old epoch. */
    internal fun enabledEpoch(): Long? = synchronized(gate) { if (switchedOn) epoch else null }
    override val unavailableReason: LocalOcrResult.Reason?
        get() = if (enabled) null else LocalOcrResult.Reason.DISABLED

    /** Memory publication only. The settings owner separately orders and checks persistence. */
    fun setEnabled(value: Boolean) {
        val closing = synchronized(gate) {
            if (switchedOn == value) return
            switchedOn = value
            epoch++
            if (!value) {
                generation?.retired = true
                active?.accepting = false
            }
            val next = claimCloseLocked()
            gate.notifyAll()
            next
        }
        closeLater(closing)
    }

    override fun recognize(bitmap: Bitmap, deadlineUptimeMs: Long, cancelled: () -> Boolean): LocalOcrResult {
        var admitted: Job? = null
        try {
            while (admitted == null) {
                failure(null, deadlineUptimeMs, cancelled)?.let { return it }
                synchronized(gate) {
                    if (!switchedOn) return unavailable(LocalOcrResult.Reason.DISABLED)
                    val current = generation
                    if (current?.failed == true) return engineFailure()
                    if (active == null && (current == null || !current.retired && !current.closing)) {
                        val next = current ?: Generation().also { generation = it }
                        admitted = Job(next, epoch, deadlineUptimeMs).also { active = it }
                    } else waitLocked(deadlineUptimeMs)
                }
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return unavailable(LocalOcrResult.Reason.CANCELLED)
        }
        val job = checkNotNull(admitted)
        try {
            failure(job, deadlineUptimeMs, cancelled)?.let { return finishBeforeSubmit(job, it) }
            val width = bitmap.width
            val height = bitmap.height
            // Int dimensions cannot overflow this Long product; compare before multiplying by 4.
            if (!acceptsCopyDimensions(width, height))
                return finishBeforeSubmit(job, LocalOcrResult.Failed(LocalOcrResult.Failure.RESULT_LIMIT))
            if (bitmap.isRecycled)
                return finishBeforeSubmit(job, LocalOcrResult.Failed(LocalOcrResult.Failure.INVALID_RESULT))
            val owned = bitmap.copy(Bitmap.Config.ARGB_8888, false)
                ?: return finishBeforeSubmit(job, engineFailure())
            job.copy = owned
            if (owned.allocationByteCount.toLong() > MAX_COPY_BYTES)
                return finishBeforeSubmit(job, LocalOcrResult.Failed(LocalOcrResult.Failure.RESULT_LIMIT))
            failure(job, deadlineUptimeMs, cancelled)?.let { return finishBeforeSubmit(job, it) }
            // Entry admission, not a claim that OFF can stop an already admitted factory call.
            val entering = synchronized(gate) { acceptingLocked(job) }
            if (!entering) return finishBeforeSubmit(job, resultWhenRevoked(job))
            val session = job.generation.session ?: MlKitSession.create(app).also {
                // Retain even if OFF happened inside initialize/getClient, so it can be closed.
                synchronized(gate) { job.generation.session = it }
            }
            failure(job, deadlineUptimeMs, cancelled)?.let { return finishBeforeSubmit(job, it) }
            // Prepare InputImage synchronously before claiming process admission. Registration
            // may invoke completion inline; no job state is installed after start returns.
            val started = session.start(owned,
                beforeProcess = {
                    synchronized(gate) {
                        if (!acceptingLocked(job)) false else { job.submitted = true; true }
                    }
                },
                accepting = { accepting(job) },
                complete = { result -> finish(job, result) })
            if (!started) return finishBeforeSubmit(job, resultWhenRevoked(job))
            while (true) {
                failure(job, deadlineUptimeMs, cancelled)?.let { stopped ->
                    synchronized(gate) { job.accepting = false; job.result = null }
                    return stopped
                }
                synchronized(gate) {
                    if (!switchedOn) { job.accepting = false; job.result = null; return unavailable(LocalOcrResult.Reason.DISABLED) }
                    if (epoch != job.epoch || job.generation.retired) {
                        job.accepting = false
                        job.result = null
                        return unavailable(LocalOcrResult.Reason.CANCELLED)
                    }
                    job.result?.let {
                        job.result = null
                        if (SystemClock.uptimeMillis() >= deadlineUptimeMs)
                            return unavailable(LocalOcrResult.Reason.DEADLINE)
                        return it
                    }
                    waitLocked(deadlineUptimeMs)
                }
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            val result = unavailable(LocalOcrResult.Reason.CANCELLED)
            abandonOrFinish(job, result, uncertain = false)
            return result
        } catch (_: Exception) {
            val result = engineFailure()
            abandonOrFinish(job, result)
            return result
        } catch (error: Error) {
            abandonOrFinish(job, engineFailure())
            throw error
        }
    }

    private fun failure(job: Job?, deadline: Long, cancelled: () -> Boolean): LocalOcrResult? {
        // Caller code runs outside our gate and is never retained by an SDK callback.
        val stopped = Thread.currentThread().isInterrupted || cancelled()
        val expired = SystemClock.uptimeMillis() >= deadline
        return synchronized(gate) {
            when {
                !switchedOn -> unavailable(LocalOcrResult.Reason.DISABLED)
                job != null && (epoch != job.epoch || job.generation.retired || !job.accepting) ->
                    unavailable(LocalOcrResult.Reason.CANCELLED)
                stopped -> unavailable(LocalOcrResult.Reason.CANCELLED)
                expired -> unavailable(LocalOcrResult.Reason.DEADLINE)
                else -> null
            }
        }
    }

    private fun acceptingLocked(job: Job): Boolean = switchedOn && epoch == job.epoch &&
        !job.generation.retired && job.accepting && SystemClock.uptimeMillis() < job.deadline
    private fun accepting(job: Job): Boolean = synchronized(gate) { acceptingLocked(job) }
    private fun resultWhenRevoked(job: Job): LocalOcrResult = synchronized(gate) {
        unavailable(when {
            !switchedOn -> LocalOcrResult.Reason.DISABLED
            SystemClock.uptimeMillis() >= job.deadline -> LocalOcrResult.Reason.DEADLINE
            else -> LocalOcrResult.Reason.CANCELLED
        })
    }
    private fun waitLocked(deadline: Long) {
        val remaining = deadline - SystemClock.uptimeMillis()
        if (remaining > 0) gate.wait(minOf(remaining, 50L))
    }

    private fun finishBeforeSubmit(job: Job, result: LocalOcrResult): LocalOcrResult {
        finish(job, result)
        return synchronized(gate) { (job.result ?: engineFailure()).also { job.result = null } }
    }

    private fun abandonOrFinish(job: Job, result: LocalOcrResult, uncertain: Boolean = true) {
        val submitted = synchronized(gate) {
            job.accepting = false
            job.result = null
            if (job.terminalClaimed) return
            if (job.submitted) {
                // process or listener registration may have taken ownership without returning.
                // Keep the one slot/copy until a real completion, never invent a release proof.
                if (uncertain) job.generation.failed = true
                job.result = result
                gate.notifyAll()
            }
            job.submitted
        }
        if (!submitted) finish(job, result)
    }

    /** Called only before process or from its original Task's terminal callback. */
    private fun finish(job: Job, result: LocalOcrResult) {
        synchronized(gate) {
            if (job.terminalClaimed) return
            job.terminalClaimed = true
            // A real terminal callback resolves previously unknown submission ownership.
            if (job.submitted) job.generation.failed = false
        }
        try {
            job.copy?.recycle()
            job.copy = null
        } catch (error: Throwable) {
            synchronized(gate) {
                job.generation.failed = true
                job.result = engineFailure()
                gate.notifyAll()
            }
            throw error
        }
        val closing = synchronized(gate) {
            check(active === job)
            job.result = when {
                !switchedOn -> unavailable(LocalOcrResult.Reason.DISABLED)
                epoch != job.epoch || job.generation.retired || job.submitted && !job.accepting -> unavailable(LocalOcrResult.Reason.CANCELLED)
                SystemClock.uptimeMillis() >= job.deadline -> unavailable(LocalOcrResult.Reason.DEADLINE)
                else -> result
            }
            active = null
            val next = claimCloseLocked()
            gate.notifyAll()
            next
        }
        closeLater(closing)
    }

    private fun claimCloseLocked(): Generation? {
        val old = generation ?: return null
        if (!old.retired || old.closing || active != null || old.failed) return null
        if (old.session == null) { generation = null; return null }
        old.closing = true
        return old
    }

    private fun closeLater(old: Generation?) {
        if (old == null) return
        try {
            cleanup.execute {
                val closed = try { checkNotNull(old.session).close(); true } catch (_: Exception) { false }
                synchronized(gate) {
                    if (closed) { old.session = null; check(generation === old); generation = null }
                    else old.failed = true
                    gate.notifyAll()
                }
            }
        } catch (_: Exception) {
            synchronized(gate) { old.failed = true; gate.notifyAll() }
        }
    }

    companion object {
        internal const val PREFS = "dsh_phone_local_ocr"
        internal const val KEY = "enabled"
        private const val MAX_COPY_BYTES = 32L * 1024 * 1024
        private const val MAX_PIXELS = MAX_COPY_BYTES / 4
        internal fun acceptsCopyDimensions(width: Int, height: Int): Boolean =
            width > 0 && height > 0 && width.toLong() * height.toLong() <= MAX_PIXELS
        @Volatile private var instance: MlKitLocalOcr? = null
        fun get(context: Context): MlKitLocalOcr = instance ?: synchronized(this) {
            instance ?: MlKitLocalOcr(context).also { instance = it }
        }
        private fun unavailable(reason: LocalOcrResult.Reason) = LocalOcrResult.Unavailable(reason)
        private fun engineFailure() = LocalOcrResult.Failed(LocalOcrResult.Failure.ENGINE)
    }
}
