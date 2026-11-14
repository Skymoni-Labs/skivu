package com.skyjjgw.independent.ski.dshgo.phone.background

/** Explicit per-mode consent, separate from a live channel. No Android or process operations. */
internal class PrivilegedKeepState(savedMode: String, phoneEnabled: Boolean, supported: Boolean) {
    data class Ticket(val generation: Long, val mode: String)
    private data class Selection(val generation: Long, val mode: String, val kept: String, val saved: Boolean) {
        val active: Boolean get() = saved && kept != "off" && kept == mode
    }
    private val restored = savedMode.takeIf { it in MODES && phoneEnabled && supported } ?: "off"
    @Volatile private var selection = Selection(0, restored, restored, true)
    private var pending: Ticket? = null
    private var nextCheck = 0L
    private var wirelessAttempted = false
    @Volatile private var phase = if (restored == "off") "disabled" else "idle"
    @Volatile private var reason: String? = null

    val mode: String get() = selection.mode
    val keptMode: String get() = selection.kept
    val enabled: Boolean get() = selection.active

    /** A task's selected transport, independent of whether keeping it was enabled/saved. */
    fun selectionTicket(): Ticket = selection.let { Ticket(it.generation, it.mode) }

    /** Lock-free: starter guards must not acquire the controller's keep guard. */
    fun selectionCurrent(ticket: Ticket): Boolean = selection.let {
        it.generation == ticket.generation && it.mode == ticket.mode
    }

    /** Called under a starter's guard: only one volatile snapshot, never a keeper lock. */
    fun current(ticket: Ticket): Boolean = selection.let {
        it.generation == ticket.generation && it.mode == ticket.mode && it.kept == ticket.mode && it.saved
    }

    @Synchronized fun configure(target: String): Ticket {
        val old = selection
        selection = Selection(old.generation + 1, old.mode, target, false)
        phase = if (target == "off") "disabled" else "idle"
        reason = null
        nextCheck = 0
        wirelessAttempted = false
        return Ticket(selection.generation, target)
    }

    fun saving(ticket: Ticket): Boolean = selection.let { it.generation == ticket.generation && it.kept == ticket.mode }

    @Synchronized fun saved(ticket: Ticket, ok: Boolean): Boolean {
        val old = selection
        if (old.generation != ticket.generation || old.kept != ticket.mode) return false
        selection = old.copy(saved = ok)
        if (!ok) { phase = "failed"; reason = "persistenceFailed" }
        return ok
    }

    @Synchronized fun select(mode: String) {
        val old = selection
        if (old.mode == mode && mode != "off") return
        selection = Selection(old.generation + 1, mode, "off", true)
        phase = "disabled"; reason = null; nextCheck = 0; wirelessAttempted = false
    }

    @Synchronized fun begin(now: Long): Ticket? {
        if (!enabled || pending != null || now < nextCheck) return null
        return Ticket(selection.generation, selection.mode).also {
            pending = it; phase = "restoring"; reason = null
        }
    }

    @Synchronized fun complete(ticket: Ticket, connected: Boolean, failure: String?, waiting: Boolean, now: Long) {
        if (pending != ticket) return
        pending = null
        if (!current(ticket)) return
        phase = if (connected) "connected" else if (waiting) "waiting" else "failed"
        reason = if (connected) null else failure
        nextCheck = if (connected || waiting) 0 else now + 5_000
    }

    @Synchronized fun available(ticket: Ticket) { if (current(ticket)) nextCheck = 0 }

    @Synchronized fun takeWirelessAttempt(ticket: Ticket): Boolean {
        if (!current(ticket) || wirelessAttempted) return false
        wirelessAttempted = true
        return true
    }

    /** Unknown/retrying is not failure; completed failure or loss needs a live replacement. */
    @Synchronized fun connectionUnavailable(alive: Boolean): Boolean =
        selection.active && !alive && (phase == "failed" || phase == "connected")

    @Synchronized fun map(alive: Boolean): Map<String, Any?> {
        val s = selection
        // A published channel that died since reports waiting until the next event restores it.
        val lost = s.active && phase == "connected" && !alive
        return mapOf("enabled" to s.active, "mode" to s.kept,
            "phase" to if (lost) "waiting" else phase,
            "reasonCode" to if (lost) "connectFailed" else reason)
    }

    companion object { val MODES = setOf("root", "sui", "shizuku", "adb") }
}
