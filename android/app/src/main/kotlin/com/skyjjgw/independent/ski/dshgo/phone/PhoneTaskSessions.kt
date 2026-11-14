package com.skyjjgw.independent.ski.dshgo.phone

import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillReplaySelections
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillOutcomes

/**
 * Per-launch session admission. The registry lock protects attribution, pending calls and screen/App
 * leases only. It is never held across driver work, UI waits, listeners or a worker join.
 * Lease waits happen before the selected screen worker, so a holder can continue and release.
 */
class PhoneTaskSessions(
    private val clock: () -> Long,
    private val idSource: () -> Long,
    private val create: (PhoneTasks, String?) -> PhoneCore,
    legacyTasks: PhoneTasks,
    legacyCore: PhoneCore,
    private val changed: () -> Unit = {},
    private val onSettled: (Task) -> Unit = {},
    private val maxRuns: Int = MAX_RUNS_PER_LAUNCH,
    private val settleResources: (Long) -> Unit = {},
    private val dispatchCleanup: (() -> Unit) -> Unit = { it() },
    // These leaf callbacks perform bounded trace/draft memory work only; never emit UI or perform IO.
    private val startSkillScope: (PhoneTasks.Owner) -> Long? = { null },
    private val completeSkillScope: (PhoneTasks.Owner, Long, String) -> Boolean = { _, _, _ -> false },
    // Runs outside registry/Tasks locks while this record cannot start or resume another scope.
    private val cancelScope: (Task, PhoneTasks.Snapshot) -> Unit = { task, state ->
        if (state.stopped) task.activeWorker?.interruptCurrent(task.tasks)
    },
    private val journal: PhoneTaskJournal? = null,
    private val createBackgroundWorker: () -> SerialWorker = { SerialWorker("dsh-phone-background") },
    // Pure in-memory capability/setting snapshot. Never probe a peer or read preferences here.
    private val backgroundCapacity: () -> Int = { 1 },
    private val screenRecoveryReady: () -> Boolean = { false },
    // Connection preparation precedes any new screen lease and runs outside registry/Tasks locks.
    private val prepareBackground: (Task, PhoneTasks.Owner) -> String? = { _, _ -> null },
) {
    internal class SkillScope(val owner: PhoneTasks.Owner, val draftEpoch: Long, val launchEpoch: Long) {
        var endOwner: PhoneTasks.Owner? = null
        var cancelled = false
        var settled = false
    }
    class Task internal constructor(val sessionId: String?, val runId: String?, val tasks: PhoneTasks, val core: PhoneCore) {
        internal var pending = 0
        internal var running = false
        @Volatile internal var activeWorker: SerialWorker? = null
        internal var backgroundWorker: SerialWorker? = null
        internal var closing = false
        internal var stopped = false
        internal var cancelling = false
        internal var cancelledLifecycle: Long? = null
        @Volatile internal var retired: PhoneTasks.Snapshot? = null
        @Volatile internal var resourcesReleased = true
        @Volatile internal var resourceTaskId = 0L
        internal var cleanupFailed = false
        internal var cleanupRetryTaskId: Long? = null
        // Full requested set while waiting; holders can change before this waiter wakes.
        internal var waitingScreens: List<PhoneScreen> = emptyList()
        internal var waitingApp: PhoneAppIdentity? = null
        internal var waitingUnknownApp = false
        internal var waitingSince: Long? = null
        internal var waitingOwner: PhoneTasks.Owner? = null
        internal val heldApps = linkedSetOf<PhoneAppIdentity>()
        internal var holdsUnknownApp = false
        internal var endRequested = false
        internal var ending = false
        internal var endSettled = false
        internal var finished: PhoneTasks.Owner? = null
        internal var pendingFinish: PhoneTasks.Owner? = null
        internal var returnClaimed = false
        internal var skillScope: SkillScope? = null
        internal var journalRecord: PhoneTaskJournal.Record? = null
        internal var journalMarked = false
        internal var journalEnded = false
        internal var journalFailed = false
        var completion: String = "unknown"
            internal set
    }
    class Admission internal constructor(internal val task: Task?, internal val epoch: Long, internal val refusal: String? = null,
        internal val scopeEpoch: Long? = task?.tasks?.admissionEpoch(), internal val startedAt: Long) {
        @Volatile internal var expired = false
        internal var runner: Thread? = null // Protected by this Admission, including interrupt and detach.
    }

    internal fun deadlineMs(a: Admission): Long = a.startedAt + PhoneCore.MAX_TOTAL_MS

    internal fun remainingMs(a: Admission): Long = if (a.expired) 0L else
        (PhoneCore.MAX_TOTAL_MS - (clock() - a.startedAt).coerceAtLeast(0)).coerceAtLeast(0)

    internal fun expire(a: Admission): ToolOutput {
        synchronized(a) {
            a.expired = true
            // Do not take a Thread out of this lock: it could return to the pool before interrupt.
            a.runner?.interrupt()
        }
        return deadlineOutput()
    }

    private fun deadlineOutput() = ToolOutput(
        "本次手机调用总期限已到，可能执行了也可能没有。不要自动重试同一个动作；待原操作结束后先查看屏幕。", // l10n:keep agent deadline result
        isError = true,
    )
    private val mainWorker = legacyCore.worker
    private val lock = Object()
    private var epoch = 0L
    private var callerLaunch = 0L
    private var modernCallerSeen = false

    /** Only the real runtime launch entry resets capability, never bridge retirement. */
    fun beginCallerLaunch() = synchronized(lock) {
        callerLaunch++
        modernCallerSeen = false
    }

    fun callerCapability(): Map<String, Any> = synchronized(lock) {
        mapOf("launch" to callerLaunch, "modernSeen" to modernCallerSeen)
    }

    private var resetting = false
    private val retiring = linkedSetOf<Task>()
    private data class Key(val sessionId: String?, val runId: String?)
    private var legacy = Task(null, null, legacyTasks, legacyCore)
    private val entries = linkedMapOf(Key(null, null) to legacy)
    private val stoppedSessions = HashSet<String?>()
    // Set only by the first screen-only fence; non-screen stops/resume/retire revoke it.
    private val screenStoppedSessions = HashSet<String>()
    private val endedRuns = HashMap<Key, String>()
    private val retainedRuns = HashSet<Key>()
    private val lastAdmitted = mutableMapOf<String?, Task>()
    private var mainHolder: Task? = null
    // Retired/paused/draining holders remain here until their original cleanup succeeds.
    private val backgroundHolders = linkedSetOf<Task>()

    fun backgroundHeldSlots(): Int = synchronized(lock) { backgroundHolders.size }

    /** Setter barrier: old acquisitions finish before it returns; waiters re-read the new limit. */
    fun backgroundCapacityChanged() {
        synchronized(lock) { lock.notifyAll() }
        changed()
    }
    // Includes retired records until their original physical cleanup succeeds.
    private val appHolders = linkedSetOf<Task>()
    class SelfCheckLease internal constructor(internal val epoch: Long) {
        internal var sealed = false
    }
    private var selfCheck: SelfCheckLease? = null

    /** Local diagnostic reservation, never a synthetic task or skill scope. */
    fun tryReserveSelfCheck(): SelfCheckLease? = synchronized(lock) {
        if (resetting || selfCheck != null || mainHolder != null || backgroundHolders.isNotEmpty() || appHolders.isNotEmpty() || retiring.isNotEmpty()) return null
        if (entries.values.any { it.pending > 0 || it.running || it.closing || it.cancelling ||
                it.cleanupFailed || it.ending || it.endRequested && !it.endSettled || it.tasks.isActive }) return null
        SelfCheckLease(epoch).also { selfCheck = it }
    }

    fun selfCheckCurrent(lease: SelfCheckLease): Boolean = synchronized(lock) {
        selfCheck === lease && !lease.sealed && lease.epoch == epoch && !resetting
    }

    fun sealSelfCheck(lease: SelfCheckLease) = synchronized(lock) {
        if (selfCheck === lease) lease.sealed = true
    }

    /** The original diagnostic owner returns this only after its physical work has drained/released. */
    fun releaseSelfCheck(lease: SelfCheckLease): Boolean = synchronized(lock) {
        if (selfCheck !== lease) false
        else { selfCheck = null; lock.notifyAll(); true }
    }

    /** Local on-device read, without a model task. Null means an existing owner is busy. */
    fun <T> readForSelfCheck(worker: SerialWorker, budgetMs: Long, maxTotalMs: Long, read: () -> T): SerialWorker.Outcome<T>? {
        val lease = tryReserveSelfCheck() ?: return null
        try {
            val result = worker.run(budgetMs, maxTotalMs, owner = lease) {
                if (!selfCheckCurrent(lease) || Thread.currentThread().isInterrupted) throw InterruptedException()
                read()
            }
            return if (selfCheckCurrent(lease)) result else SerialWorker.Outcome.Interrupted
        } finally {
            // Timeout/cancel may return before the original system read. Never release its
            // reservation until that exact body's finally has run, including across retire.
            worker.afterDrained(lease) { releaseSelfCheck(lease) }
        }
    }

    /** Called while PhoneBridge still holds its launch lock, before dispatch enters its pool. */
    fun admit(attribution: PhoneCaller?): Admission {
        val startedAt = clock()
        // Platform state reads may use Binder; bind their result to the current stop epoch.
        val readinessEpoch = synchronized(lock) { epoch }
        val screenReady = attribution?.runLifecycle == 1 && screenRecoveryReady()
        return synchronized(lock) {
            if (attribution?.runLifecycle == 1) modernCallerSeen = true
            // l10n:keep agent resource admission
            if (selfCheck != null) return Admission(null, epoch, "本地自检正在占用手机，请稍后重试。", startedAt = startedAt)
            if (resetting || retiring.any { it.cancelling }) return Admission(null, epoch, PhoneTasks.STOPPED_MESSAGE, startedAt = startedAt)
            // B1 attribution alone does not prove the client can deliver an exact run end.
            val caller = attribution?.takeIf { it.runLifecycle == 1 }
            val key = Key(caller?.sessionId, caller?.runId)
            if (caller != null) {
                if (key in endedRuns || entries[key]?.stopped == true) return Admission(null, epoch, PhoneTasks.STOPPED_MESSAGE, startedAt = startedAt)
                if (caller.sessionId in stoppedSessions && !recoverScreenStop(key, screenReady && readinessEpoch == epoch))
                    return Admission(null, epoch, PhoneTasks.STOPPED_MESSAGE, startedAt = startedAt)
                if (!reserve(key)) return Admission(null, epoch, CAPACITY_MESSAGE, startedAt = startedAt)
            }
            val task = entries.getOrPut(key) {
                val tasks = PhoneTasks(clock = clock, idleMs = Long.MAX_VALUE, idSource = idSource)
                Task(caller!!.sessionId, caller.runId, tasks, create(tasks, caller.sessionId))
            }
            if (!blocked(task) && !task.closing) lastAdmitted[task.sessionId] = task
            task.pending++
            Admission(task, epoch, startedAt = startedAt)
        }
    }

    // Registry lock held. Never clear a stopped Task or its old admission/owner fence.
    private fun recoverScreenStop(key: Key, screenReady: Boolean): Boolean {
        val sessionId = key.sessionId ?: return false
        if (key in entries || sessionId !in screenStoppedSessions || !screenReady) return false
        val records = (entries.values + retiring).filter { it.sessionId == sessionId }
        if (records.any { it.pending > 0 || it.running || it.closing || it.cancelling || it.cleanupFailed ||
                it.journalFailed || !it.resourcesReleased || it.skillScope?.settled == false ||
                it.journalRecord != null || it.ending || it.endRequested && !it.endSettled || it.tasks.isActive }) return false
        // Cold/queued records from before the stop are old runs too.
        records.forEach { it.stopped = true }
        stoppedSessions -= sessionId
        screenStoppedSessions -= sessionId
        return true
    }

    internal fun runReplay(admission: Admission, selection: PhoneSkillReplaySelections.Selection,
        selections: PhoneSkillReplaySelections, outcomes: PhoneSkillOutcomes): ToolOutput =
        run(admission, PhoneCore.REPLAY, emptyMap(), selection, selections, outcomes)

    fun run(admission: Admission, name: String, args: Map<String, Any?>): ToolOutput =
        run(admission, name, args, null, null, null)

    private fun run(admission: Admission, name: String, args: Map<String, Any?>,
        replay: PhoneSkillReplaySelections.Selection?, selections: PhoneSkillReplaySelections?,
        outcomes: PhoneSkillOutcomes?): ToolOutput {
        synchronized(admission) { admission.runner = Thread.currentThread() }
        try {
            return runAdmitted(admission, name, args, replay, selections, outcomes)
        } finally {
            synchronized(admission) {
                admission.runner = null
                if (admission.expired) Thread.interrupted()
            }
        }
    }

    private fun runAdmitted(admission: Admission, name: String, args: Map<String, Any?>,
        replay: PhoneSkillReplaySelections.Selection?, selections: PhoneSkillReplaySelections?,
        outcomes: PhoneSkillOutcomes?): ToolOutput {
        val task = admission.task ?: return ToolOutput(checkNotNull(admission.refusal), isError = true)
        var owner: PhoneTasks.Owner? = null
        var prepared: PhoneCore.PreparedCall? = null
        var running = false
        var executionWorker: SerialWorker? = null
        task.tasks.callStarted()
        try {
            if (replay != null && (task.sessionId != replay.request.session || task.runId != replay.run))
                return ToolOutput("路线调用身份与原准备不匹配，未执行。", isError = true) // l10n:keep replay result
            if (remainingMs(admission) <= 0) return deadlineOutput()
            journal?.refusal()?.let { return ToolOutput(it, isError = true) }
            if (replay == null) task.core.rejection(name)?.let { return it }
            synchronized(lock) {
                while (task.running && live(admission) && !blocked(task) && !task.closing) {
                    val left = remainingMs(admission)
                    if (left <= 0) return deadlineOutput()
                    lock.wait(minOf(left, 1_000))
                }
                if (remainingMs(admission) <= 0) return deadlineOutput()
                if (!live(admission) || blocked(task) || task.closing) return stopped()
                task.running = true
                running = true
            }
            // Legacy can start another logical task in this same record. Clean the prior
            // scope before beginning it, while this call exclusively owns the execution slot.
            if (task.sessionId == null && !task.tasks.isActive && !task.resourcesReleased) {
                try { releasePhysical(task, task.resourceTaskId) } catch (_: Exception) {
                    synchronized(lock) { task.cleanupFailed = true }
                    return stopped()
                }
            }
            if (remainingMs(admission) <= 0) return deadlineOutput()
            owner = when (val b = task.tasks.begin(admission.scopeEpoch)) {
                is PhoneTasks.Begin.Go -> {
                    if (b.newTask) {
                        // A legacy idle rollover can create a scope before its old inactive
                        // listener settles. Do not overwrite that old trace/resource identity.
                        val previous = synchronized(lock) { task.skillScope?.takeUnless { it.settled } }
                        if (previous != null) {
                            try {
                                if (!task.resourcesReleased) releasePhysical(task, task.resourceTaskId)
                                synchronized(lock) { settleSkill(task, null) }
                            } catch (_: Exception) {
                                synchronized(lock) { task.cleanupFailed = true }
                                task.tasks.stop("旧任务清理尚未确认", PhoneTasks.StopSource.ENVIRONMENT) // l10n:keep agent lifecycle result
                                return stopped()
                            }
                        }
                        synchronized(lock) {
                            if (live(admission) && !blocked(task)) task.tasks.runIfCurrent(b.owner) {
                                startSkillScope(b.owner)?.let { draftEpoch ->
                                    task.skillScope = SkillScope(b.owner, draftEpoch, admission.epoch)
                                }
                            }
                        }
                    }
                    b.owner
                }
                is PhoneTasks.Begin.Refused -> return ToolOutput(b.message, isError = true)
            }
            if (journal != null) {
                val previous = synchronized(lock) { task.journalRecord }
                if (previous != null && (previous.taskId != owner.taskId || previous.lifecycle != owner.lifecycle)) {
                    // A real owner replacement (including clearStop) cannot overwrite an old token.
                    try { if (!task.resourcesReleased) releasePhysical(task, task.resourceTaskId) }
                    catch (_: Exception) { synchronized(lock) { task.cleanupFailed = true }; return stopped() }
                    synchronized(lock) {
                        task.skillScope?.takeIf { it.owner.taskId == previous.taskId && it.owner.lifecycle == previous.lifecycle }
                            ?.let { settleSkill(task, null) }
                        task.journalEnded = true
                    }
                    if (!clearJournal(task)) return ToolOutput(PhoneTaskJournal.STORAGE_MESSAGE, isError = true)
                }
                val record = synchronized(lock) { task.journalRecord } ?: journal.record(owner)
                synchronized(lock) {
                    if (!live(admission) || blocked(task) || !task.tasks.isCurrent(owner)) return stopped()
                    task.journalRecord = record
                }
                if (!task.journalMarked) {
                    if (!journal.mark(record)) return ToolOutput(PhoneTaskJournal.STORAGE_MESSAGE, isError = true)
                    synchronized(lock) { task.journalMarked = true }
                }
                synchronized(lock) {
                    if (!live(admission) || blocked(task) || !task.tasks.isCurrent(owner)) return stopped()
                }
            }
            if (remainingMs(admission) <= 0) return deadlineOutput()
            if (task.tasks.isPaused && !task.tasks.awaitResume(minOf(PhoneCore.PAUSE_WAIT_MS, remainingMs(admission)))) {
                return if (remainingMs(admission) <= 0) deadlineOutput() else stopped()
            }
            if (remainingMs(admission) <= 0) return deadlineOutput()
            val preparation = if (replay == null) task.core.prepareCall(name, args, owner)
                else task.core.prepareReplayCall(replay, checkNotNull(selections), checkNotNull(outcomes), owner)
            val call = when (val result = preparation) {
                is Either.Left -> return result.value
                is Either.Right -> result.value
            }
            prepared = call
            if (remainingMs(admission) <= 0) return deadlineOutput()
            // Replay already froze an existing ready driver before acquiring its leases.
            // The ordinary path may bootstrap; replay must never restore/connect/open here.
            if (PhoneScreen.BACKGROUND in call.screens && replay == null) {
                prepareBackground(task, owner)?.let { return ToolOutput(it, isError = true) }
                if (remainingMs(admission) <= 0) return deadlineOutput()
            }
            val failure = awaitResources(admission, call)
            if (failure != null) return ToolOutput(failure, isError = true)
            val selected = synchronized(lock) {
                if (remainingMs(admission) <= 0) return deadlineOutput()
                if (!live(admission) || blocked(task) || !task.tasks.isCurrent(owner)) return stopped()
                val lane = if (PhoneScreen.BACKGROUND in call.screens) {
                    check(task in backgroundHolders)
                    task.backgroundWorker ?: createBackgroundWorker().also { task.backgroundWorker = it }
                } else mainWorker
                task.activeWorker = lane
                executionWorker = lane
                lane
            }
            return task.core.call(call, selected, { remainingMs(admission) })
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return stopped()
        } finally {
            task.tasks.callEnded(owner)
            synchronized(lock) { task.pending--; lock.notifyAll() }
            if (running) {
                // A timed-out Future can return before its device body. Keep the task's
                // execution slot and screen leases until that exact owner physically drains.
                val completedCall = prepared
                val drained = {
                    synchronized(lock) {
                        if (completedCall != null && completedCall.borrowedMainForBackgroundOpen &&
                            completedCall.backgroundOpenConfirmed && live(admission) && !blocked(task) &&
                            !task.closing && mainHolder === task) {
                            task.tasks.runIfCurrent(completedCall.owner) { mainHolder = null }
                        }
                        // Keep this execution slot until the exact original MAIN decision is committed.
                        task.activeWorker = null
                        task.running = false
                        clearWaiting(task)
                        lock.notifyAll()
                    }
                    settled(task)
                }
                val original = executionWorker
                if (original == null) drained() else original.afterDrained(task.tasks, drained)
            } else settled(task)
            changed()
        }
    }

    private fun settled(task: Task) {
        settleInactive(task)
        onSettled(task)
        changed()
    }

    private fun live(a: Admission) = a.epoch == epoch && a.task?.let { entries[Key(it.sessionId, it.runId)] === it } == true
    private fun blocked(task: Task) = task.journalFailed || task.cancelling || task.retired != null || task.cleanupFailed || task.endRequested || task.sessionId != null && (task.stopped || task.sessionId in stoppedSessions)
    private fun stopped() = ToolOutput(PhoneTasks.STOPPED_MESSAGE + "。", isError = true)

    private fun appBlockers(task: Task, known: PhoneAppIdentity?, unknown: Boolean): List<Task> =
        appHolders.filter { holder -> holder !== task && (unknown ||
            known != null && (holder.holdsUnknownApp || holder.heldApps.any {
                it.packageName == known.packageName || it.uid == known.uid
            })) }

    private fun mandatoryBlockers(task: Task, needed: List<PhoneScreen>, known: PhoneAppIdentity?, unknown: Boolean): Set<Task> =
        (listOfNotNull(mainHolder?.takeIf { PhoneScreen.MAIN in needed && it !== task }) +
            appBlockers(task, known, unknown)).toSet()

    private fun needsBackgroundSlot(task: Task, needed: List<PhoneScreen>): Boolean =
        PhoneScreen.BACKGROUND in needed && task !in backgroundHolders

    /** MAIN/App are mandatory; BG needs any one slot, not every current holder's release. Lock held. */
    private fun closedWaitSetContains(task: Task, limit: Int): Boolean {
        val remaining = entries.values.filterTo(linkedSetOf()) { candidate ->
            val owner = candidate.waitingOwner
            owner != null && candidate.waitingSince != null && candidate.running &&
                registered(candidate) && !blocked(candidate) && !candidate.closing && !candidate.ending &&
                (limit > 0 || !needsBackgroundSlot(candidate, candidate.waitingScreens)) &&
                candidate.tasks.isCurrent(owner)
        }
        while (remaining.isNotEmpty()) {
            val retainedBackground = backgroundHolders.count { it in remaining }
            val removable = remaining.filter { candidate ->
                mandatoryBlockers(candidate, candidate.waitingScreens, candidate.waitingApp,
                    candidate.waitingUnknownApp).none { it in remaining } &&
                    (!needsBackgroundSlot(candidate, candidate.waitingScreens) || limit > 0 && retainedBackground < limit)
            }
            if (removable.isEmpty()) break
            remaining.removeAll(removable.toSet())
        }
        return task in remaining
    }

    private fun clearWaiting(task: Task) {
        task.waitingScreens = emptyList()
        task.waitingApp = null
        task.waitingUnknownApp = false
        task.waitingSince = null
        task.waitingOwner = null
    }

    private fun awaitResources(a: Admission, call: PhoneCore.PreparedCall): String? {
        val needed = call.screens
        val known = call.knownApp
        val unknown = call.unknownApp
        if (needed.isEmpty() && known == null && !unknown) return null
        val started = clock()
        val until = started + 30_000
        val task = checkNotNull(a.task)
        fun current() = live(a) && !blocked(task) && task.tasks.isCurrent(call.owner)
        // Registry -> Admission; expiry never acquires registry. Claim and expiry are ordered
        // without holding either monitor across platform work.
        fun acquire(): String? = synchronized(a) {
            if (remainingMs(a) <= 0) return@synchronized deadlineOutput().text
            call.borrowedMainForBackgroundOpen = call.name == PhoneToolCatalog.OPEN &&
                call.args.bool("background") == true && PhoneScreen.MAIN in needed && mainHolder == null
            if (PhoneScreen.MAIN in needed) mainHolder = task
            if (PhoneScreen.BACKGROUND in needed) backgroundHolders += task
            if (known != null) task.heldApps += known
            if (unknown) task.holdsUnknownApp = true
            if (known != null || unknown) appHolders += task
            task.resourcesReleased = false
            task.resourceTaskId = call.owner.taskId
            null
        }
        synchronized(lock) {
            if (remainingMs(a) <= 0) return deadlineOutput().text
            if (!current()) return PhoneTasks.STOPPED_MESSAGE
            if (known != null && known !in task.heldApps && task.heldApps.size >= MAX_APPS_PER_SCOPE)
                return "本任务已保留 16 个应用身份，请结束并清理本任务后再打开其他应用。" // l10n:keep agent resource result
            val limit = backgroundCapacity()
            if (needsBackgroundSlot(task, needed) && limit == 0) return BACKGROUND_UNAVAILABLE
            if (mandatoryBlockers(task, needed, known, unknown).isEmpty() &&
                (!needsBackgroundSlot(task, needed) || backgroundHolders.size < limit)) return acquire()
            // Whole request, not the first blocker: another holder can appear before wakeup.
            task.waitingScreens = needed
            task.waitingApp = known
            task.waitingUnknownApp = unknown
            task.waitingSince = started
            task.waitingOwner = call.owner
        }
        changed()
        try {
            synchronized(lock) {
                while (true) {
                    if (remainingMs(a) <= 0) return deadlineOutput().text
                    if (!current()) return PhoneTasks.STOPPED_MESSAGE
                    val limit = backgroundCapacity()
                    if (needsBackgroundSlot(task, needed) && limit == 0) return BACKGROUND_UNAVAILABLE
                    if (mandatoryBlockers(task, needed, known, unknown).isEmpty() &&
                        (!needsBackgroundSlot(task, needed) || backgroundHolders.size < limit)) return acquire()
                    // Zero means unavailable for new slots, never a zero-threshold waiting cycle.
                    if (closedWaitSetContains(task, limit))
                        return "屏幕或应用资源形成等待环，本次没有操作。请结束或交还另一任务占用的资源后重试。" // l10n:keep agent resource result
                    val left = until - clock()
                    if (left <= 0) return "屏幕或应用资源正被另一个对话使用，已等待 30 秒，本次没有操作。请稍后再试或结束占用任务。" // l10n:keep agent resource result
                    lock.wait(minOf(left, remainingMs(a), 1_000).coerceAtLeast(1))
                }
            }
        } finally {
            synchronized(lock) { clearWaiting(task) }
            changed()
        }
    }

    fun task(taskId: Long): Task? = all().firstOrNull { it.tasks.snapshot().id == taskId }
    fun all(): List<Task> = synchronized(lock) { entries.values.toList() }
    fun isBusy(task: Task): Boolean = synchronized(lock) { task.pending > 0 || task.running || task.closing || task.cancelling || task.cleanupFailed }

    /** Policy validation and in-memory publication share admission's linearization point.
     * Callbacks must only read/publish memory; persistence and notifications belong outside. */
    fun updatePolicies(map: Map<*, *>?, current: () -> PhonePolicies, publish: (PhonePolicies) -> Unit): PhonePolicies? = synchronized(lock) {
        val next = PhonePolicies.update(map, current(), ::anyActive) ?: return@synchronized null
        publish(next)
        next
    }

    /** Any record, selected or not, that may still act: active, an admitted call, or a draining body. */
    fun anyActive(): Boolean = synchronized(lock) {
        (entries.values + retiring).any { it.pending > 0 || it.running || it.retired == null && it.tasks.snapshot().active }
    }

    /** End/stop/idle/retirement all keep physical leases until body AND resource cleanup drain. */
    fun settleInactive(task: Task) { settle(task, explicitFinish = false) }

    private fun settle(task: Task, explicitFinish: Boolean, retryTaskId: Long? = null, expected: PhoneTasks.Snapshot? = null): PhoneTasks.Owner? {
        val retry = retryTaskId != null
        val state: PhoneTasks.Snapshot
        val shouldFinish: Boolean
        val drainWorker: SerialWorker
        synchronized(lock) {
            if (retryTaskId != null) {
                if ((task.retired ?: task.tasks.snapshot()).id != retryTaskId) return null
                if (task.closing) {
                    // Journal-only closing has already released physical resources.
                    if (!task.resourcesReleased) task.cleanupRetryTaskId = retryTaskId
                    return null
                }
            }
            if (task.pending > 0 || task.running || task.closing || task.cancelling || task.ending || task.cleanupFailed && !retry || task.journalFailed) return null
            // Capture only after excluding a new registry run, in registry -> Tasks lock order.
            state = task.retired ?: task.tasks.snapshot()
            if (expected != null && (!registered(task) || state.id != expected.id || state.lifecycle != expected.lifecycle)) return null
            if (retry && !task.cleanupFailed) return null
            shouldFinish = task.retired == null && (explicitFinish || task.endRequested && !task.endSettled)
            if (!shouldFinish && task.retired == null && state.active) return null
            if (!shouldFinish && task.resourcesReleased && task.skillScope?.settled != false && task.journalRecord == null) { retiring.remove(task); return null }
            task.closing = true
            task.cleanupFailed = false
            drainWorker = task.activeWorker ?: task.backgroundWorker ?: mainWorker
        }
        changed()
        var result: PhoneTasks.Owner? = null
        drainWorker.afterDrained(task.tasks) {
            dispatchCleanup {
                try {
                    // finishScope fires listeners. closing prevents their reentrant cleanup/admission.
                    val ended = if (shouldFinish && task.retired == null) task.pendingFinish ?: task.tasks.finishScope(state.id) else null
                    synchronized(lock) { task.pendingFinish = ended }
                    if (!task.resourcesReleased) releasePhysical(task, task.resourceTaskId)
                    synchronized(lock) { task.journalEnded = true }
                    if (!clearJournal(task)) return@dispatchCleanup
                    synchronized(lock) {
                        task.resourcesReleased = true
                        if (task.endRequested) task.endSettled = true
                        // A concurrent old-scope cancellation may still be outside the lock.
                        // Its launch fence survives successful physical cleanup until it returns.
                        if (!task.cancelling) retiring.remove(task)
                        settleSkill(task, ended)
                        // A successful cleanup consumes this retry token; legacy reuses the Task record.
                        task.pendingFinish = null
                        if (task.retired == null && ended != null && task.tasks.isCurrent(ended)) {
                            task.finished = ended
                            if (task.sessionId == null) task.stopped = false
                            result = ended
                        }
                        lock.notifyAll()
                    }
                } catch (_: Exception) {
                    // A failed release does not prove the display/body is gone. Keep its physical fence.
                    synchronized(lock) { task.cleanupFailed = true }
                } finally {
                    val retryTaskId = synchronized(lock) {
                        task.closing = false
                        val requested = task.cleanupRetryTaskId
                        task.cleanupRetryTaskId = null
                        lock.notifyAll()
                        requested?.takeIf { task.cleanupFailed }
                    }
                    // Consume this explicit request once, before optional status observers.
                    // The original settle eligibility still protects an active failed handoff.
                    if (retryTaskId != null) retryCleanup(retryTaskId)
                    onSettled(task)
                    changed()
                }
            }
        }
        return result
    }
    private fun clearJournal(task: Task): Boolean {
        val record = synchronized(lock) { task.journalRecord } ?: return true
        val ok = checkNotNull(journal).clear(record) // Never called under registry/Tasks locks.
        synchronized(lock) {
            if (ok) { task.journalRecord = null; task.journalMarked = false; task.journalEnded = false }
            task.journalFailed = !ok
        }
        return ok
    }

    /** Plugin I/O consumer: only exact tokens whose body/physical cleanup already finished. */
    fun retryJournalStorage(): Boolean {
        val store = journal ?: return true
        if (!store.retryStorage()) { changed(); return false }
        val failed = synchronized(lock) { (entries.values + retiring).distinct().filter { it.journalFailed } }
        var ok = true
        for (task in failed) {
            val claimed = synchronized(lock) {
                if (!task.journalEnded || task.running || task.pending > 0 || task.closing || task.cancelling) false
                else { task.closing = true; true }
            }
            if (!claimed) { ok = false; continue }
            try { if (!clearJournal(task)) ok = false }
            finally { synchronized(lock) { task.closing = false; lock.notifyAll() } }
            settleInactive(task)
        }
        changed()
        return ok
    }

    /** Registry lock held; invoked only after the old body AND its resource cleanup completed. */
    private fun settleSkill(task: Task, finished: PhoneTasks.Owner?) {
        val skill = task.skillScope?.takeUnless { it.settled } ?: return
        val originalEnd = skill.endOwner
        val eligible = task.sessionId != null && task.endRequested && task.completion == "completed" &&
            !skill.cancelled && task.retired == null && skill.launchEpoch == epoch &&
            originalEnd != null && originalEnd.taskId == skill.owner.taskId && originalEnd.lifecycle == skill.owner.lifecycle
        if (eligible && finished != null && task.tasks.runIfCurrent(finished) {
                completeSkillScope(skill.owner, skill.draftEpoch, "completed")
                skill.settled = true
            }) return
        completeSkillScope(skill.owner, skill.draftEpoch, if (task.completion == "completed") "other" else task.completion)
        skill.settled = true
    }

    /** A user retry only repeats cleanup for the original physical task; it never resumes work. */
    fun retryCleanup(taskId: Long): Boolean {
        val task = synchronized(lock) {
            (entries.values + retiring).firstOrNull {
                (it.cleanupFailed || it.closing && !it.resourcesReleased) &&
                    (it.retired ?: it.tasks.snapshot()).id == taskId
            }
        } ?: return false
        settle(task, explicitFinish = false, retryTaskId = taskId)
        return synchronized(lock) { task.resourcesReleased && !task.cleanupFailed && !task.closing }
    }

    private fun releasePhysical(task: Task, taskId: Long) {
        settleResources(taskId) // Can block in platform IPC; neither registry nor worker lock is held.
        val retiredWorker = synchronized(lock) {
            task.resourcesReleased = true
            if (mainHolder === task) mainHolder = null
            backgroundHolders.remove(task)
            appHolders.remove(task)
            task.heldApps.clear()
            task.holdsUnknownApp = false
            val lane = task.backgroundWorker
            task.backgroundWorker = null
            lock.notifyAll()
            lane
        }
        // Both normal settlement and legacy scope rollover reach this successful cleanup.
        retiredWorker?.shutdown()
    }

    fun snapshot(): List<Map<String, Any?>> = synchronized(lock) { (entries.values + retiring).distinct() }.map { task ->
        val state = task.retired ?: task.tasks.snapshot()
        val at = clock()
        val extra = synchronized(lock) {
            val waitingApp = if (task.waitingSince == null || appBlockers(task, task.waitingApp, task.waitingUnknownApp).isEmpty()) null
                else if (task.waitingUnknownApp) mapOf("kind" to "unknown")
                else mapOf("kind" to "known", "packageName" to checkNotNull(task.waitingApp).packageName)
            mapOf("sessionId" to task.sessionId, "runId" to task.runId,
            "identity" to if (task.sessionId == null) "legacy" else "session",
            "backgroundSlot" to (task in backgroundHolders),
            "waitingForScreen" to task.waitingScreens.firstOrNull { screen ->
                when (screen) {
                    PhoneScreen.MAIN -> mainHolder != null && mainHolder !== task
                    PhoneScreen.BACKGROUND -> needsBackgroundSlot(task, task.waitingScreens) &&
                        backgroundHolders.size >= backgroundCapacity()
                }
            }?.name?.lowercase(), "waitingForApp" to waitingApp,
            "waitingForMs" to task.waitingSince?.let { (at - it).coerceAtLeast(0L) }, "pendingCalls" to task.pending,
            "retiring" to (task.retired != null), "settling" to task.closing, "cleanupFailed" to task.cleanupFailed,
            "finishing" to (task.closing || task.cleanupFailed || task.retired != null || task.endRequested && !task.endSettled), "draining" to (task.running && task.pending == 0),
            "stopped" to (task.retired != null || task.stopped || state.stopped || task.sessionId in stoppedSessions), "generation" to state.lifecycle,
            "completion" to task.completion, "endedRunId" to task.finished?.let { task.runId }, "endedGeneration" to task.finished?.lifecycle) }
        state.toMap() + extra + if (task.retired != null) mapOf("active" to false) else emptyMap()
    }

    /** Short registry -> Tasks commit; callbacks cannot cancel a successor in this record. */
    fun stop(task: Task, owner: PhoneTasks.Owner, reason: String): Boolean =
        stopCommitted(task) { task.tasks.stopForOwner(owner, reason) }

    fun stop(task: Task, expected: PhoneTasks.Snapshot, reason: String): Boolean =
        stopCommitted(task) { task.tasks.stopForSnapshot(expected, reason) }

    fun stop(task: Task, reason: String): Boolean = stop(task, task.tasks.snapshot(), reason)

    private fun stopCommitted(task: Task, commit: () -> PhoneTasks.Change?): Boolean {
        val change = synchronized(lock) {
            if (!registered(task) || task.cancelling) return false
            val committed = commit() ?: return false
            claimCancellation(task, committed.snapshot)
            committed
        }
        try {
            cancelScope(task, change.snapshot)
        } finally {
            try { task.tasks.publish(change) } finally { cancellationFinished(task) }
        }
        return true
    }

    /** An old listener snapshot may never interrupt or dismiss work in a later scope. */
    fun onInactive(task: Task, state: PhoneTasks.Snapshot): Boolean {
        if (state.active) return false
        val claimed = synchronized(lock) {
            if (!registered(task) || task.cancelling || task.cancelledLifecycle == state.lifecycle) return false
            // A registry run may already own the slot but not yet have called begin().
            // Non-stop idle/end notices cannot cancel that successor reservation. A real
            // stop advances admissionEpoch, so the reserved old call cannot begin afterward.
            if (!state.stopped && task.running) return false
            task.tasks.runIfInactive(state) { claimCancellation(task, state) }
        }
        if (!claimed) return false
        try { cancelScope(task, state) } finally { cancellationFinished(task) }
        return true
    }

    private fun registered(task: Task) = entries[Key(task.sessionId, task.runId)] === task && task.retired == null

    // Registry is held after an exact Tasks stop commit (epoch advanced) or inside its inactive guard. Memory only.
    private fun claimCancellation(task: Task, state: PhoneTasks.Snapshot) {
        task.cancelling = true
        task.cancelledLifecycle = state.lifecycle
        if (state.stopped) {
            task.skillScope?.cancelled = true
            if (task.sessionId != null) {
                if (state.stopSource != PhoneTasks.StopSource.SCREEN_OFF) screenStoppedSessions -= task.sessionId
                else if (task.sessionId !in stoppedSessions) screenStoppedSessions += task.sessionId
                task.stopped = true
                stoppedSessions += task.sessionId
            }
        }
        lock.notifyAll()
    }

    private fun cancellationFinished(task: Task) {
        synchronized(lock) { task.cancelling = false; lock.notifyAll() }
        settleInactive(task)
        changed()
    }

    fun resume(task: Task, expected: PhoneTasks.Snapshot = task.tasks.snapshot()): Boolean {
        val changes = synchronized(lock) {
            if (!registered(task) || retiring.any { it.cancelling }) return false
            val current = task.tasks.snapshot()
            if (current.id != expected.id || current.lifecycle != expected.lifecycle) return false
            val records = entries.values.filter { it.sessionId == task.sessionId }
            if (records.any { it.pending > 0 || it.running || it.closing || it.cancelling || it.cleanupFailed || !it.resourcesReleased || it.skillScope?.settled == false || it.journalRecord != null && !it.tasks.isActive }) return false
            // Commit clearStop/unpause while admission is still fenced. Publication is lock-free.
            val committed = records.map { record ->
                val expected = record.tasks.snapshot()
                val change = record.tasks.resumeForSnapshot(expected) ?: return false
                record to change
            }
            task.sessionId?.let { screenStoppedSessions -= it }
            stoppedSessions -= task.sessionId
            records.forEach { it.stopped = false }
            committed
        }
        changes.forEach { (record, change) -> record.tasks.publish(change) }
        changed()
        return true
    }
    fun finish(task: Task, expected: PhoneTasks.Snapshot = task.tasks.snapshot()): PhoneTasks.Owner? {
        if (task.sessionId != null) return null // Modern completion only accepts exact host run-end.
        val until = System.nanoTime() + 3_000_000_000L
        synchronized(lock) {
            while (task.closing) {
                val left = (until - System.nanoTime()) / 1_000_000
                if (left <= 0) return null
                lock.wait(minOf(left, 100))
            }
        }
        return settle(task, explicitFinish = true, expected = expected)
    }
    /** Actual host turn/end, not an inferred idle edge. Keep intent until native calls drain. */
    fun admitEnd(sessionId: String, runId: String, completion: String = "unknown"): Task? = synchronized(lock) {
        val key = Key(sessionId, runId)
        if (!reserve(key)) throw CapacityExceeded()
        if (endedRuns.putIfAbsent(key, completion) != null) return null // First accepted classification is immutable.
        // Unknown ends fence this launch too; a late call cannot reopen them.
        val task = entries[key] ?: return null
        if (task.endRequested) return null
        task.skillScope?.let { skill ->
            skill.endOwner = task.tasks.activeOwner()?.takeIf {
                it.taskId == skill.owner.taskId && it.lifecycle == skill.owner.lifecycle
            }
        }
        task.endRequested = true
        task.completion = completion
        task.ending = true
        lock.notifyAll()
        task
    }

    fun settleEnd(task: Task) {
        task.tasks.cancelPending()
        val original = synchronized(lock) { task.activeWorker }
        original?.interruptCurrent(task.tasks)
        synchronized(lock) { task.ending = false }
        completeEnd(task)
        changed()
    }

    private fun completeEnd(task: Task) = settleInactive(task)

    fun completed(taskId: Long, runId: String, generation: Long): PhoneTasks.Owner? {
        val task = task(taskId) ?: return null
        return synchronized(lock) {
            val owner = task.finished?.takeIf { task.runId == runId && it.lifecycle == generation } ?: return null
            if (task.returnClaimed || lastAdmitted[task.sessionId] !== task || !task.tasks.isCurrent(owner)) return null
            task.returnClaimed = true
            owner
        }
    }

    fun ownerCurrent(taskId: Long, owner: PhoneTasks.Owner): Boolean {
        val task = task(taskId) ?: return false
        return synchronized(lock) { lastAdmitted[task.sessionId] === task } && task.tasks.isCurrent(owner)
    }

    fun stopAll(reason: String, source: PhoneTasks.StopSource = PhoneTasks.StopSource.ENVIRONMENT) {
        data class PendingStop(val task: Task, val change: PhoneTasks.Change, val ownsCancellation: Boolean)
        val pending = synchronized(lock) {
            epoch++
            selfCheck?.sealed = true
            if (source != PhoneTasks.StopSource.SCREEN_OFF) screenStoppedSessions.clear()
            entries.values.map { task ->
                // A prior cancellation keeps responsibility for its external work. Still
                // invalidate this lifetime now. An idle record must not gain a stop hold or
                // a session fence merely because the screen/service disappeared.
                val ownsCancellation = !task.cancelling
                val change = task.tasks.stopActiveDeferred(reason, source)
                claimCancellation(task, change.snapshot)
                PendingStop(task, change, ownsCancellation)
            }
        }
        // Every pre-existing owner/admission is invalid before the first external callback.
        // A new record admitted after the batch unlocks is a separate, later admission.
        var failure: Throwable? = null
        for ((task, change, ownsCancellation) in pending) {
            try {
                if (ownsCancellation) {
                    try { cancelScope(task, change.snapshot) }
                    finally {
                        try { task.tasks.publish(change) }
                        finally { cancellationFinished(task) }
                    }
                } else {
                    task.tasks.publish(change)
                }
            } catch (error: Throwable) {
                // One callback must not strand the other already-claimed cancellations.
                if (failure == null) failure = error
            }
        }
        failure?.let { throw it }
    }
    fun retire() {
        val workers: List<SerialWorker>
        val old = synchronized(lock) {
            resetting = true
            selfCheck?.sealed = true
            epoch++
            workers = ((entries.values + retiring).mapNotNull { it.backgroundWorker } + mainWorker).distinct()
            entries.values.toList().also { records ->
                for (task in records) {
                    task.skillScope?.cancelled = true
                    task.retired = task.tasks.snapshot()
                    if (!task.resourcesReleased || task.pending > 0 || task.running || task.closing || task.cancelling || task.journalRecord != null) retiring += task
                }
                entries.clear()
                endedRuns.clear()
                retainedRuns.clear()
                stoppedSessions.clear()
                screenStoppedSessions.clear()
                lastAdmitted.clear()
                lock.notifyAll()
            }
        }
        // Never reset the shared legacy lifecycle after exposing its next launch's admission.
        old.forEach { it.tasks.invalidateOwners(); it.tasks.endTask() }
        workers.forEach { it.retire() }
        synchronized(lock) {
            legacy = Task(null, null, legacy.tasks, legacy.core)
            entries[Key(null, null)] = legacy
            resetting = false
            lock.notifyAll()
        }
        // Holders still point to old records. Their callbacks only remove their own leases.
        old.forEach(::settleInactive)
        changed()
    }
    /** The union of active records and ended-before-call fences shares one budget. Lock held. */
    private fun reserve(key: Key): Boolean {
        if (key in retainedRuns) return true
        if (retainedRuns.size >= maxRuns) return false
        retainedRuns += key
        return true
    }

    class CapacityExceeded : IllegalStateException(CAPACITY_MESSAGE)

    companion object {
        // l10n:keep agent resource admission
        private const val BACKGROUND_UNAVAILABLE = "后台屏当前无法接纳新任务，本次没有操作。请检查后台通道状态后重试。"
        private const val MAX_APPS_PER_SCOPE = 16
        // An implementation memory bound, not a measured throughput limit. Never evict a fence.
        const val MAX_RUNS_PER_LAUNCH = 256
        // l10n:keep agent lifecycle capacity result
        const val CAPACITY_MESSAGE = "本次引擎保留的手机任务生命周期已达上限，不能安全接收新任务。请重启本地引擎后重试；已有任务仍可结束。"
    }

}
