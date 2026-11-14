package com.skyjjgw.independent.ski.dshgo.phone

import java.util.concurrent.CopyOnWriteArrayList

/**
 * The current phone task: roughly one DSH turn. It starts with the first phone tool call,
 * and ends on stop (overlay, notification, Flutter, screen off), or after [idleMs] without calls.
 * A paused task is never idle, nor is one with a call still running: a pause holds the task — its
 * waiver included — until the person resumes or stops it, and the idle clock restarts on resume.
 * Holds the per-task app approvals and 本任务免确认 waiver, pause, and the person's interjections
 * for the agent.
 *
 * After a stop, calls are refused until [stopHoldMs] pass without any: the turn that was running
 * gets "已停止" on every retry, and the next turn starts a fresh task. Plain Kotlin (injected clock).
 */
class PhoneTasks(
    private val clock: () -> Long = System::currentTimeMillis,
    val idleMs: Long = 3 * 60_000L,
    val stopHoldMs: Long = 30_000L,
    private val idSource: (() -> Long)? = null,
) {
    enum class StopSource { USER, SCREEN_OFF, ENVIRONMENT }

    data class Snapshot(
        val id: Long,
        val active: Boolean,
        /** Label of the app the agent last operated in. */
        val app: String?,
        val paused: Boolean,
        /** Within the hold after a stop. */
        val stopped: Boolean,
        val stopReason: String?,
        /** 本任务免确认 granted for this task. */
        val waived: Boolean = false,
        /** Native-only lifetime; never inferred from a session id or a Flutter page. */
        internal val lifecycle: Long = 0,
        /** This stop hold interrupted a task whose public active projection was true. */
        val interrupted: Boolean = false,
        val stopSource: StopSource? = null,
    ) {
        fun toMap(): Map<String, Any?> =
            linkedMapOf("id" to id, "active" to active, "app" to app, "paused" to paused, "stopped" to stopped,
                "waived" to waived, "interrupted" to interrupted, "stopSource" to stopSource?.name)
    }

    sealed interface Begin {
        class Go(internal val owner: Owner, val newTask: Boolean) : Begin {
            val taskId: Long get() = owner.taskId
        }
        class Refused(val message: String) : Begin
    }

    private val lock = Object()
    private var nextId = 1L
    private var taskId = 0L
    private var lifecycle = 0L
    private var admissionEpoch = 0L
    private var active = false
    private var lastCallAt = 0L
    private var stoppedUntil = 0L
    private var stopReason: String? = null
    private var stopSource: StopSource? = null
    private var interrupted = false
    private val approved = LinkedHashSet<String>()
    private var waived = false
    private var visualLifecycle = -1L
    private val visualScopes = mutableMapOf<PhoneScreen, VisualScope>()
    private val visualGrants = mutableMapOf<PhoneScreen, VisualScope>()
    private val notified = HashSet<String>()
    private var app: String? = null
    private var paused = false
    private val interjections = ArrayList<String>()
    private var inFlight = 0
    private val listeners = CopyOnWriteArrayList<(Snapshot) -> Unit>()

    fun addListener(l: (Snapshot) -> Unit) {
        listeners += l
    }

    fun removeListener(l: (Snapshot) -> Unit) {
        listeners -= l
    }

    /** Called at the start of every phone tool call. */
    internal fun admissionEpoch(): Long = synchronized(lock) { admissionEpoch }

    fun begin(expectedEpoch: Long? = null): Begin {
        var started = false
        val result: Begin
        synchronized(lock) {
            if (expectedEpoch != null && expectedEpoch != admissionEpoch) return Begin.Refused(STOPPED_MESSAGE)
            val now = clock()
            if (now < stoppedUntil) {
                stoppedUntil = now + stopHoldMs
                return Begin.Refused(STOPPED_MESSAGE + (stopReason?.let { "（$it）" } ?: ""))
            }
            interrupted = false
            // This call is in flight already, so only the pause and the clock count here.
            if (active && !paused && now - lastCallAt > idleMs) endLocked()
            if (!active) {
                active = true
                taskId = idSource?.invoke() ?: nextId++
                lifecycle++
                stopReason = null
                started = true
            }
            lastCallAt = now
            result = Begin.Go(Owner(taskId, lifecycle, true), started)
        }
        if (started) fire()
        return result
    }

    /** Marks activity at the end of a call too (a long handoff must not count as idle). */
    fun touch(owner: Owner?) = synchronized(lock) {
        if (owner != null && currentLocked(owner)) lastCallAt = clock()
    }

    /** Ends an idle task; returns whether one ended. Run periodically so listeners hear it in time. */
    fun expireIdle(): Boolean {
        synchronized(lock) {
            if (!idleLocked(clock())) return false
            endLocked()
        }
        fire()
        return true
    }

    /** A committed lifecycle change. Publishing its captured snapshot is deliberately separate:
     * registry callers must release their admission lock before listeners/UI can run. */
    internal class Change internal constructor(val snapshot: Snapshot)

    internal fun stopForOwner(owner: Owner, reason: String): Change? = synchronized(lock) {
        if (!currentLocked(owner)) return null
        stopLocked(reason)
    }

    internal fun stopForSnapshot(expected: Snapshot, reason: String): Change? = synchronized(lock) {
        // Snapshot.active may be false because of idle projection while internal active is true.
        // The exact lifetime, rather than that projection, binds an explicit stop.
        if (taskId != expected.id || lifecycle != expected.lifecycle) return null
        stopLocked(reason)
    }

    private fun stopLocked(reason: String, now: Long = clock(), source: StopSource = StopSource.USER): Change {
        // Record the fact before endLocked clears active. Repeated stops in
        // this hold retain a prior interruption, but an expired hold cannot
        // donate that fact to a later cold/idle stop.
        interrupted = (now < stoppedUntil && interrupted) || (active && !idleLocked(now))
        admissionEpoch++
        if (active) endLocked() else lifecycle++
        stoppedUntil = now + stopHoldMs
        stopReason = reason
        stopSource = source
        paused = false
        lock.notifyAll()
        return Change(snapshotLocked(now))
    }

    internal fun resumeForSnapshot(expected: Snapshot): Change? = synchronized(lock) {
        if (taskId != expected.id || lifecycle != expected.lifecycle) return null
        if (clock() < stoppedUntil) {
            lifecycle++
            stoppedUntil = 0L
            stopReason = null
        }
        interrupted = false
        if (paused) {
            paused = false
            if (active) lastCallAt = clock()
        }
        lock.notifyAll()
        Change(snapshot())
    }

    internal fun publish(change: Change) = fire(change.snapshot)

    /** Commit a stop without listeners; callers publish only after their admission lock is released. */
    internal fun stopDeferred(reason: String, source: StopSource = StopSource.USER): Change = synchronized(lock) { stopLocked(reason, source = source) }

    /** Ambient stops fence queued calls/prompts, but only a live task starts a stop hold. */
    internal fun stopActiveDeferred(reason: String, source: StopSource = StopSource.ENVIRONMENT): Change = synchronized(lock) {
        val now = clock()
        if (active && !idleLocked(now)) return stopLocked(reason, now, source)
        // A later ambient boundary revokes screen-only recovery without extending the hold.
        if (now < stoppedUntil && source != StopSource.SCREEN_OFF) { stopSource = source }
        admissionEpoch++
        if (active) endLocked() else lifecycle++
        lock.notifyAll()
        Change(snapshotLocked(now))
    }

    fun stop(reason: String, source: StopSource = StopSource.USER) {
        publish(stopDeferred(reason, source))
    }

    /** Ends the task without a stop hold (the engine went away). */
    fun endTask() {
        synchronized(lock) {
            if (!active) return
            endLocked()
            lock.notifyAll()
        }
        fire()
    }

    /** A tool call came in; [callEnded] once its result goes back. */
    fun callStarted() = synchronized(lock) {
        inFlight++
    }

    fun callEnded(owner: Owner?) = synchronized(lock) {
        // Check before decrementing: this call may be what keeps a long-running task non-idle.
        if (owner != null && currentLocked(owner)) lastCallAt = clock()
        if (inFlight > 0) inFlight--
    }

    /** Tool calls between [callStarted] and [callEnded] right now. */
    val callsInFlight: Int get() = synchronized(lock) { inFlight }

    /**
     * The turn that drove the phone ended (Dart's `finishTask`): ends the task and drops a stop's
     * hold, since the turn it was refusing is over and the next one starts fresh. False when there
     * was nothing to end, the requested task changed, or a call is still running.
     */
    fun finish(expectedTaskId: Long? = null): Boolean = finishScope(expectedTaskId) != null

    /** The exact inactive lifetime produced by a successful finish, for delayed return UI. */
    fun finishScope(expectedTaskId: Long? = null): Owner? {
        val owner: Owner
        synchronized(lock) {
            if (expectedTaskId != null && expectedTaskId != taskId) return null
            if (inFlight > 0) return null
            val stopped = clock() < stoppedUntil
            if (!active && !stopped) return null
            if (active) endLocked() else lifecycle++
            stoppedUntil = 0L
            stopReason = null
            interrupted = false
            owner = Owner(taskId, lifecycle, false)
            lock.notifyAll()
        }
        fire()
        return owner
    }

    /** Opaque ownership: even stop → clearStop with the same id retires earlier questions. */
    class Owner internal constructor(val taskId: Long, internal val lifecycle: Long, internal val active: Boolean)

    fun activeOwner(expectedTaskId: Long? = null): Owner? = synchronized(lock) {
        if (!active || idleLocked(clock()) || clock() < stoppedUntil ||
            (expectedTaskId != null && expectedTaskId != taskId)) return null
        Owner(taskId, lifecycle, true)
    }

    /** Engine approval can precede the first native phone call; never adopt an active task. */
    fun beforeTaskOwner(): Owner? = synchronized(lock) {
        if (active || clock() < stoppedUntil) return null
        Owner(taskId, lifecycle, false)
    }

    fun isCurrent(owner: Owner): Boolean = synchronized(lock) { currentLocked(owner) }

    /** Result bookkeeping must not adopt the task that replaced its call. Keep [action] short. */
    fun runIfCurrent(owner: Owner, action: () -> Unit): Boolean = synchronized(lock) {
        if (!currentLocked(owner)) return false
        action()
        true
    }

    /** A single system start and its optional fallback notice, bound to the original call owner.
     * Task cancellation and each commitment share [lock]; platform work runs AFTER this lock.
     * Committed work may finish after stop returns. Thread interruption is only sampled here.
     * [allowed] is a memory-only last admission check: no IO or other registry locks.
     */
    inner class SystemDispatch internal constructor(private val owner: Owner, private val allowed: () -> Boolean) {
        private var startCommitted = false
        private var noticeCommitted = false

        fun commitStart(): Boolean = synchronized(lock) {
            if (startCommitted || !owner.active || !currentLocked(owner) || Thread.currentThread().isInterrupted) return false
            if (!allowed()) return false
            startCommitted = true
            true
        }

        fun commitNotice(): Boolean = synchronized(lock) {
            if (!startCommitted || noticeCommitted || !currentLocked(owner) || Thread.currentThread().isInterrupted) return false
            noticeCommitted = true
            true
        }
    }

    fun systemDispatch(owner: Owner, allowed: () -> Boolean = { true }): SystemDispatch = SystemDispatch(owner, allowed)

    private fun currentLocked(owner: Owner): Boolean =
        owner.taskId == taskId && owner.lifecycle == lifecycle && owner.active == active &&
            clock() >= stoppedUntil && (!active || !idleLocked(clock()))

    /** Engine/plugin shutdown also invalidates a prompt that predates any native task. */
    fun invalidateOwners() {
        synchronized(lock) { lifecycle++; admissionEpoch++ }
        fire()
    }

    /** Exact host run end wakes queued work without treating it as a new user stop/resume. */
    fun cancelPending() {
        synchronized(lock) { lifecycle++; admissionEpoch++; paused = false; lock.notifyAll() }
        fire()
    }

    /** Applying a late waiver and checking its owner are one operation. */
    fun confirmIfCurrent(owner: Owner, pkg: String? = null, waiveTask: Boolean = false): Boolean {
        var changed = false
        synchronized(lock) {
            if (!owner.active || !currentLocked(owner)) return false
            if (pkg != null) approved += pkg
            if (waiveTask && !waived) { waived = true; changed = true }
        }
        if (changed) fire()
        return true
    }

    /** All consumers hold the original owner; scope changes revoke rather than restore history. */
    fun syncVisualScope(owner: Owner, screen: PhoneScreen, scope: VisualScope?): Boolean = synchronized(lock) {
        if (!owner.active || !currentLocked(owner)) return false
        resetVisualLocked()
        val value = scope?.takeIf { it.screen == screen }
        if (visualScopes[screen] != value) visualGrants.remove(screen)
        if (value == null) visualScopes.remove(screen) else visualScopes[screen] = value
        true
    }

    fun hasVisualGrant(owner: Owner, scope: VisualScope): Boolean = synchronized(lock) {
        owner.active && currentLocked(owner) && visualLifecycle == lifecycle &&
            visualScopes[scope.screen] == scope && visualGrants[scope.screen] == scope
    }

    fun confirmVisualIfCurrent(owner: Owner, scope: VisualScope): Boolean = synchronized(lock) {
        if (!owner.active || !currentLocked(owner) || visualLifecycle != lifecycle || visualScopes[scope.screen] != scope) return false
        visualGrants[scope.screen] = scope
        true
    }

    private fun resetVisualLocked() {
        if (visualLifecycle != lifecycle) {
            visualScopes.clear(); visualGrants.clear(); visualLifecycle = lifecycle
        }
    }

    fun stopIfCurrent(owner: Owner, reason: String): Boolean {
        val change = stopForOwner(owner, reason) ?: return false
        publish(change)
        return true
    }

    /** Runs delayed UI cleanup only while the same task remains inactive. */
    fun runIfInactive(expectedTaskId: Long, action: () -> Unit): Boolean = synchronized(lock) {
        if (taskId != expectedTaskId || active) return false
        action()
        true
    }

    fun runIfInactive(snapshot: Snapshot, action: () -> Unit): Boolean = synchronized(lock) {
        if (taskId != snapshot.id || lifecycle != snapshot.lifecycle || active) return false
        action()
        true
    }

    /** Clears a stop early (e.g. the person turned phone control off and on again). */
    fun clearStop() {
        synchronized(lock) {
            lifecycle++
            stoppedUntil = 0L
            stopReason = null
            interrupted = false
        }
        fire()
    }

    fun setPaused(value: Boolean) {
        synchronized(lock) {
            if (paused == value) return
            paused = value
            // Resuming restarts the idle clock: the pause itself never counts as idle.
            if (!value && active) lastCallAt = clock()
            lock.notifyAll()
        }
        fire()
    }

    /** Display controls retain their captured scope; listeners still run outside the lock. */
    fun setPausedIfCurrent(owner: Owner, value: Boolean): Boolean {
        var changed = false
        synchronized(lock) {
            if (!owner.active || !currentLocked(owner)) return false
            if (paused != value) {
                paused = value
                if (!value) lastCallAt = clock()
                lock.notifyAll()
                changed = true
            }
        }
        if (changed) fire()
        return true
    }

    val isPaused: Boolean get() = synchronized(lock) { paused }

    /**
     * Blocks while paused, up to [timeoutMs]. True to go on — only when the person resumed the same
     * task; false when it was stopped or ended meanwhile, or the pause outlasted the timeout.
     * Throws InterruptedException when the worker is interrupted.
     */
    fun awaitResume(timeoutMs: Long): Boolean {
        val deadline = clock() + timeoutMs
        synchronized(lock) {
            val id = if (active) taskId else 0L
            while (paused) {
                val left = deadline - clock()
                if (left <= 0) return false
                lock.wait(minOf(left, 1000L))
            }
            // Ending a task clears its pause: that is no resume.
            if (id != 0L && (!active || taskId != id)) return false
            return clock() >= stoppedUntil
        }
    }

    /** A task is running (an idle one counts until [expireIdle] or the next call ends it). */
    val isActive: Boolean get() = synchronized(lock) { active }

    fun isStopped(): Boolean = synchronized(lock) { clock() < stoppedUntil }

    fun isApproved(pkg: String): Boolean = synchronized(lock) { pkg in approved }

    fun approve(pkg: String) = synchronized(lock) {
        approved += pkg
    }

    /** 本任务免确认 granted: the rest of this task asks nothing. Cleared when the task ends. */
    val isWaived: Boolean get() = synchronized(lock) { waived }

    fun waive() {
        synchronized(lock) {
            if (!active || waived) return
            waived = true
        }
        fire()
    }

    /** First time this task something was reported to the person (one fix-me notification per kind). */
    fun firstNotice(kind: String): Boolean = synchronized(lock) { notified.add(kind) }

    fun setApp(label: String?) {
        synchronized(lock) {
            if (label == null || app == label) return
            app = label
        }
        fire()
    }

    /** A completed system start must not rename a replacement task. Notify outside [lock]. */
    fun setAppIfCurrent(owner: Owner, label: String?): Boolean {
        var changed = false
        synchronized(lock) {
            if (!owner.active || !currentLocked(owner)) return false
            if (label != null && app != label) { app = label; changed = true }
        }
        if (changed) fire()
        return true
    }

    fun interject(text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
        synchronized(lock) {
            interjections += t
            while (interjections.size > 5) interjections.removeAt(0)
        }
    }

    fun interjectIfCurrent(owner: Owner, text: String): Boolean {
        val value = text.trim()
        if (value.isEmpty()) return false
        synchronized(lock) {
            if (!owner.active || !currentLocked(owner)) return false
            interjections += value
            while (interjections.size > 5) interjections.removeAt(0)
        }
        return true
    }

    fun drainInterjections(): List<String> = synchronized(lock) {
        val out = interjections.toList()
        interjections.clear()
        out
    }

    fun snapshot(): Snapshot = synchronized(lock) { snapshotLocked(clock()) }

    private fun snapshotLocked(now: Long): Snapshot {
        val idle = idleLocked(now)
        val stopped = now < stoppedUntil
        if (!stopped) interrupted = false
        return Snapshot(taskId, active && !idle, if (active && !idle) app else null, paused, stopped, stopReason,
            active && !idle && waived, lifecycle, interrupted, if (stopped) stopSource else null)
    }

    /** Idle: no call running, not paused, and nothing for [idleMs]. */
    private fun idleLocked(now: Long): Boolean = active && !paused && inFlight == 0 && now - lastCallAt > idleMs

    private fun endLocked() {
        lifecycle++
        active = false
        approved.clear()
        visualScopes.clear(); visualGrants.clear(); visualLifecycle = lifecycle
        waived = false
        notified.clear()
        interjections.clear()
        app = null
        paused = false
    }

    private fun fire(s: Snapshot = snapshot()) {
        for (l in listeners) {
            try {
                l(s)
            } catch (_: Exception) {
            }
        }
    }

    companion object {
        // l10n:keep agent stop protocol
        const val STOPPED_MESSAGE = "本轮手机操作已停止。不要重试本轮手机动作；与手机无关的工作可继续"
    }
}

/** What the agent did, without screen contents, for the person to review. Newest last; [toMaps] lists newest first. */
class ActionLog(private val capacity: Int = 300, private val clock: () -> Long = System::currentTimeMillis) {
    data class Entry(val time: Long, val tool: String, val app: String?, val summary: String, val decision: String)

    private val entries = ArrayDeque<Entry>()

    fun add(tool: String, app: String?, summary: String, decision: String) = synchronized(entries) {
        entries.addLast(Entry(clock(), tool, app, summary, decision))
        while (entries.size > capacity) entries.removeFirst()
    }

    fun toMaps(limit: Int): List<Map<String, Any?>> = synchronized(entries) {
        entries.reversed().take(limit.coerceIn(0, capacity)).map {
            linkedMapOf("time" to it.time, "tool" to it.tool, "app" to it.app, "summary" to it.summary, "decision" to it.decision)
        }
    }

    fun last(): Entry? = synchronized(entries) { entries.lastOrNull() }
}
