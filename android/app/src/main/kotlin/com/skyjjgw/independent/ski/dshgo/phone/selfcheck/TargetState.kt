package com.skyjjgw.independent.ski.dshgo.phone.selfcheck

/** Actual target lifecycle memory. Android callbacks and task snapshots feed this same state. */
internal class TargetState(val targetRun: String, val profile: TargetContract.Profile = TargetContract.Profile.C1) {
    data class Facts(
        val launchAttempted: Boolean,
        val created: Boolean,
        val closed: Boolean,
        val wrongMain: Boolean,
        val cleanupPending: Boolean,
    )
    private val lock = Object()
    private var sealed = false
    private var scheduled = false
    private var launchFinished = true
    private var attempted = false
    private var expectedDisplay = -1
    private var instance: Any? = null
    private var relaunching = false
    private var created = false
    private var destroyedForFinish = false
    private var destroyedStamp: Any? = null
    private var taskEmpty = false
    private var wrongMain = false
    private var finalized = false
    private var taskId: Int? = null
    private var framePhase = 0

    init { require(TargetContract.validRun(targetRun)) }

    fun schedule(displayId: Int): Boolean = synchronized(lock) {
        if (sealed || scheduled || displayId <= 0) return false
        scheduled = true
        expectedDisplay = displayId
        launchFinished = false
        true
    }

    /**
     * Immediately before the single startActivity call, after all UI preconditions. In lock task mode
     * (screen pinning included) Android drops a new task with no error and no Activity, and an attempted
     * launch without an Activity can never be told apart from a delayed one, so it is not attempted.
     */
    fun attempt(lockTaskActive: Boolean = false): Boolean = synchronized(lock) {
        if (sealed || attempted || !scheduled || lockTaskActive) return false
        attempted = true
        true
    }

    fun launchReturned() = synchronized(lock) { launchFinished = true; lock.notifyAll() }
    fun seal() = synchronized(lock) { sealed = true; lock.notifyAll() }

    /**
     * Even a wrong-display or sealed late creation is a fact, but it must not draw the target. Only the
     * relaunch of a configuration-destroyed instance succeeds it; cleanup then finishes that replacement.
     */
    fun register(value: Any, displayId: Int, actualTaskId: Int): Boolean = synchronized(lock) {
        if (displayId == 0) wrongMain = true
        if (finalized || instance != null && instance !== value && !relaunching) return false
        relaunching = false
        instance = value
        taskId = actualTaskId
        created = true
        taskEmpty = false
        lock.notifyAll()
        val allowed = attempted && !sealed && displayId > 0 && displayId == expectedDisplay
        if (!allowed) sealed = true
        allowed
    }

    /** Actual main job admission, not evidence that pixels were drawn or captured. */
    fun advance(value: Any, displayId: Int, stage: TargetContract.FrameStage): Boolean = synchronized(lock) {
        if (profile != TargetContract.Profile.C2 || sealed || finalized || destroyedForFinish ||
            instance !== value || !created || displayId <= 0 || displayId != expectedDisplay ||
            framePhase != stage.phase - 1) return false
        framePhase = stage.phase
        true
    }

    fun destroyed(value: Any, finishing: Boolean, changingConfiguration: Boolean): Boolean = synchronized(lock) {
        if (instance !== value) return false
        // Configuration destruction cannot acknowledge this run's requested final close; its replacement must.
        destroyedForFinish = finishing && !changingConfiguration
        relaunching = changingConfiguration
        destroyedStamp = null
        taskEmpty = false
        if (changingConfiguration) sealed = true
        lock.notifyAll()
        destroyedForFinish
    }

    /** Called only by the original main-queue barrier after framework window teardown. */
    fun teardownCompleted(value: Any) = synchronized(lock) {
        if (instance !== value || !destroyedForFinish) return
        destroyedStamp = Any()
        taskEmpty = false
        lock.notifyAll()
    }

    fun instance(): Any? = synchronized(lock) { instance }
    fun hasCreated(): Boolean = synchronized(lock) { created }
    // Capture BEFORE the Binder query. A reply begun before the barrier cannot prove final empty.
    fun taskReadStamp(): Any? = synchronized(lock) { destroyedStamp }

    /** Values come from the actual AppTask's TaskInfo; identity is checked again, not pre-approved. */
    fun observeTask(
        readStamp: Any?,
        actualTaskId: Int, componentClass: String?, identifier: String?, displayId: Int,
        running: Boolean, activities: Int, topAbsent: Boolean,
    ): Boolean = synchronized(lock) {
        val matches = (taskId == null || actualTaskId == taskId) && componentClass == TargetContract.ACTIVITY_CLASS &&
            identifier == TargetContract.identifier(targetRun)
        if (!matches) return false
        taskId = actualTaskId
        if (displayId == 0) wrongMain = true
        taskEmpty = readStamp != null && readStamp === destroyedStamp &&
            !running && activities == 0 && topAbsent
        lock.notifyAll()
        true
    }

    fun facts(): Facts = synchronized(lock) {
        val closed = finalized || sealed && launchFinished &&
            (!attempted && !created || created && destroyedForFinish && taskEmpty)
        Facts(attempted, created, closed, wrongMain, sealed && !closed)
    }

    /** Drop the destroyed Activity reference only after both local and structural facts agree. */
    fun finishIfClosed(): Boolean = synchronized(lock) {
        if (!facts().closed) return false
        finalized = true
        instance = null
        true
    }

    /** Waits for real callbacks only; the caller's bounded timeout never supplies a success fact. */
    fun awaitChange(millis: Long) = synchronized(lock) { lock.wait(millis.coerceAtLeast(1)) }
}
