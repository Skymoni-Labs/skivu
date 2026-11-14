package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.PhoneTasks

/** Original task resources. Mutations share the controller's existing ownership monitor. */
internal class BackgroundTaskSlot<D : Any, P : Any>(private val lock: Any) {
    class TaskResource<D : Any, P : Any> internal constructor(
        val owner: PhoneTasks.Owner, val peer: P, val driver: D,
    ) {
        internal var sealed = false
        internal fun matches(other: PhoneTasks.Owner) =
            owner.taskId == other.taskId && owner.lifecycle == other.lifecycle
    }

    @Volatile private var resources = emptyList<TaskResource<D, P>>()
    // Readable under keepGuard without acquiring the ownership monitor in reverse order.
    val occupied: Boolean get() = resources.isNotEmpty()
    val boundPeer: P? get() = resources.firstOrNull()?.peer

    fun find(owner: PhoneTasks.Owner): TaskResource<D, P>? = synchronized(lock) {
        resources.firstOrNull { !it.sealed && it.matches(owner) }
    }

    /** create only constructs an unused driver; it must not connect or perform platform I/O. */
    fun acquire(owner: PhoneTasks.Owner, peer: P, hardLimit: Int,
                current: () -> Boolean, create: () -> D): TaskResource<D, P>? = synchronized(lock) {
        if (!owner.active || !current()) return null
        resources.firstOrNull { it.owner.taskId == owner.taskId }?.let {
            return it.takeIf { !it.sealed && it.matches(owner) && it.peer === peer }
        }
        // The user limit is enforced when Sessions grants the lease. A later downshift
        // cannot revoke that grant before driver construction; this is the peer's hard bound.
        if (resources.size >= hardLimit || boundPeer?.let { it !== peer } == true) return null
        TaskResource(owner, peer, create()).also { resources = resources + it }
    }

    fun current(expected: TaskResource<D, P>): Boolean = synchronized(lock) {
        resources.any { it === expected } && !expected.sealed
    }

    fun cleanupCandidates(): List<TaskResource<D, P>> = synchronized(lock) { resources.filter { it.sealed } }

    /** Cleanup does not require an active Owner; cancellation is why it is often needed. */
    fun seal(taskId: Long? = null): List<TaskResource<D, P>> = synchronized(lock) {
        resources.filter { taskId == null || it.owner.taskId == taskId }.onEach { it.sealed = true }
    }

    /** Only after this exact driver's strict release succeeds outside the monitor. */
    fun complete(expected: TaskResource<D, P>): Boolean = synchronized(lock) {
        if (resources.none { it === expected }) false
        else { check(expected.sealed); resources = resources.filterNot { it === expected }; true }
    }
}
