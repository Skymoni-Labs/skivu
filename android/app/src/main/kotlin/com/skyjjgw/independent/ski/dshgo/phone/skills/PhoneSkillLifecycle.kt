package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.phone.PhoneTasks

/** Legacy single-task integration. No rendering/IO; callers never acquire PhoneTasks from this lock. */
internal class PhoneSkillLifecycle(private val trace: PhoneTaskTrace, private val drafts: PhoneSkillDrafts) {
    private data class Active(val owner: PhoneTasks.Owner)
    private var active: Active? = null
    private var running = false

    @Synchronized fun launched() { running = true }

    /** Core invokes this after trace.start, under runIfCurrent for the original new-task owner. */
    @Synchronized fun started(owner: PhoneTasks.Owner) {
        active?.let { trace.complete(it.owner, false) }
        active = null
        if (!running) { trace.discard(PhoneTaskTrace.key(owner)); return }
        active = Active(owner)
    }

    /** Registry-owned scopes are independent; never adopt or end the legacy single active slot. */
    @Synchronized fun startManaged(owner: PhoneTasks.Owner): Long? {
        if (!running) return null
        trace.start(owner)
        return drafts.currentEpoch()
    }

    /** An old listener delivery cannot retire a newer task. Stop/idle/invalidation never qualify. */
    @Synchronized fun changed(snapshot: PhoneTasks.Snapshot) {
        val a = active ?: return
        if (snapshot.id > a.owner.taskId || (snapshot.id == a.owner.taskId &&
                (snapshot.lifecycle > a.owner.lifecycle || (snapshot.lifecycle == a.owner.lifecycle && !snapshot.active)))) {
            trace.complete(a.owner, false)
            active = null
        }
    }

    /** Native integration only: B2 calls after real body drain AND cleanup, with its start-time epoch. */
    @Synchronized fun completeDrained(owner: PhoneTasks.Owner, startedEpoch: Long, completion: String): Boolean {
        if (!running || startedEpoch != drafts.currentEpoch()) return false
        trace.complete(owner, completion == "completed")
        val snapshot = trace.snapshot(owner) ?: return false
        return drafts.offer(startedEpoch, snapshot)
    }

    @Synchronized fun retired() {
        running = false
        active = null
        drafts.onEngineRetired()
        trace.clear()
    }
}
