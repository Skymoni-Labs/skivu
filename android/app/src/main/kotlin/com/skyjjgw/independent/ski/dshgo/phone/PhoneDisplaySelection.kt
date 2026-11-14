package com.skyjjgw.independent.ski.dshgo.phone

/** The actual notification/overlay selection. Lock order is Tasks -> selection; no UI or IO here. */
class PhoneDisplaySelection {
    class Ticket internal constructor(val task: PhoneTasks, val owner: PhoneTasks.Owner, internal val displayLifetime: Any) {
        internal var line: String? = null // Owned by the selection lock.
    }
    data class View(val task: PhoneTasks, val owner: PhoneTasks.Owner, val state: PhoneTasks.Snapshot, val line: String?)

    private val lock = Any()
    private var selected: Ticket? = null

    fun select(task: PhoneTasks, owner: PhoneTasks.Owner): Ticket? {
        var ticket: Ticket? = null
        task.runIfCurrent(owner) {
            synchronized(lock) {
                // Publication always gets a new ticket. An already shown status can remain
                // only through uninterrupted selection of the same owner, never A -> B -> A.
                val previous = selected?.takeIf {
                    it.task === task && it.owner.taskId == owner.taskId && it.owner.lifecycle == owner.lifecycle
                }
                ticket = Ticket(task, owner, previous?.displayLifetime ?: Any())
                selected = ticket
            }
        }
        return ticket
    }

    fun ticket(): Ticket? = synchronized(lock) { selected }
    fun clear() = synchronized(lock) { selected = null }

    /** Captured inside a status's guard: the controls stay bound to that ticket's owner, never to a later selection. */
    fun controls(stopOwner: (PhoneTasks, PhoneTasks.Owner, String) -> Boolean): TaskControls? {
        val ticket = ticket() ?: return null
        val task = ticket.task
        val owner = ticket.owner
        return object : TaskControls {
            override val taskId = owner.taskId
            override val lifecycle = owner.lifecycle
            override fun isCurrentDisplay(): Boolean {
                var current = false
                task.runIfCurrent(owner) {
                    synchronized(lock) { current = selected?.displayLifetime === ticket.displayLifetime }
                }
                return current
            }
            override fun isPaused(): Boolean {
                var paused = false
                task.runIfCurrent(owner) { paused = task.isPaused }
                return paused
            }
            override fun setPaused(paused: Boolean) = task.setPausedIfCurrent(owner, paused)
            override fun stop(reason: String) = stopOwner(task, owner, reason)
            override fun interject(text: String) = task.interjectIfCurrent(owner, text)
        }
    }

    /** Captured at execution, never recaptured from whichever execution happens to be selected later. */
    fun guard(ticket: Ticket): ((() -> Unit) -> Boolean) = { update ->
        var accepted = false
        ticket.task.runIfCurrent(ticket.owner) {
            synchronized(lock) {
                if (selected === ticket) { update(); accepted = true }
            }
        }
        accepted
    }

    /** Preserve the execution guard through a scoped gate, including its original ticket. */
    fun scoped(task: PhoneTasks, original: (() -> Unit) -> Boolean): ((() -> Unit) -> Boolean) {
        val captured = ticket()
        return { update ->
            var accepted = false
            original {
                synchronized(lock) {
                    if (captured != null && captured.task === task && selected === captured) {
                        update()
                        accepted = true
                    }
                }
            }
            accepted
        }
    }

    fun currentGuard(task: PhoneTasks): ((() -> Unit) -> Boolean) {
        val captured = ticket()?.takeIf { it.task === task } ?: return { false }
        return guard(captured)
    }

    /** Caller supplies the original execution guard; mutation stays within that short commit. */
    fun status(text: String?, ifCurrent: (() -> Unit) -> Boolean): Boolean {
        var changed = false
        ifCurrent {
            synchronized(lock) {
                selected?.let { if (it.line != text) { it.line = text; changed = true } }
            }
        }
        return changed
    }

    /** Captures a cleanup ticket now. A late cleanup cannot erase another execution's line/status. */
    fun inactive(task: PhoneTasks, state: PhoneTasks.Snapshot): ((() -> Unit) -> Unit) {
        val captured = ticket()?.takeIf { it.task === task && it.owner.taskId == state.id }
        return { update ->
            if (captured != null) task.runIfInactive(state) {
                synchronized(lock) {
                    if (selected === captured) { captured.line = null; update() }
                }
            }
            Unit
        }
    }

    fun view(): View? {
        val captured = ticket() ?: return null // Release selection lock BEFORE entering Tasks.
        var view: View? = null
        captured.task.runIfCurrent(captured.owner) {
            val state = captured.task.snapshot()
            synchronized(lock) {
                if (selected === captured && state.active) view = View(captured.task, captured.owner, state, captured.line)
            }
        }
        return view
    }
}
