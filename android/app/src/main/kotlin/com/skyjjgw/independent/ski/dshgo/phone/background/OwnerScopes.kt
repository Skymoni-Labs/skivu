package com.skyjjgw.independent.ski.dshgo.phone.background

/** The real Host admission table. No platform work runs while its monitor is held. */
internal class OwnerScopes<C : Any, R : Any>(private val limit: Int = 3, private val history: Int = 256) {
    class Record<C>(val owner: String, val maintenance: Boolean, val core: C) {
        internal var busy = false
        internal var closing = false
    }
    sealed class Entry<C, R> {
        class Acquired<C, R>(val record: Record<C>) : Entry<C, R>()
        class Completed<C, R>(val receipt: R) : Entry<C, R>()
        class Refused<C, R>(val code: String, val unknown: Boolean) : Entry<C, R>()
    }
    private val lock = Any()
    private val active = linkedMapOf<String, Record<C>>()
    private val completed = linkedMapOf<String, R>()
    private var global = false
    private var mode: Boolean? = null

    fun enter(owner: String, opening: Boolean, maintenance: Boolean, release: Boolean,
              create: () -> C): Entry<C, R> = synchronized(lock) {
        val known = active.containsKey(owner) || completed.containsKey(owner)
        fun no(code: String) = Entry.Refused<C, R>(code, !known)
        if (mode == false) return no("scopeModeMismatch")
        if (global) return no("scopeBusy")
        val done = completed[owner]
        if (done != null) return if (release) Entry.Completed(done) else no("identityChanged")
        var record = active[owner]
        if (record == null) {
            if (!opening) return no("identityChanged")
            if (active.size >= limit) return no("scopeCapacity")
            if (active.values.any { it.maintenance } || maintenance && active.isNotEmpty()) return no("scopeBusy")
            record = Record(owner, maintenance, create())
            active[owner] = record
            mode = true
        }
        if (release) record.closing = true
        if (record.busy) return no(if (release) "releasePending" else "scopeBusy")
        if (record.closing && !release) return no("releasePending")
        record.busy = true
        Entry.Acquired(record)
    }

    fun leave(record: Record<C>, receipt: R? = null) = synchronized(lock) {
        check(active[record.owner] === record && record.busy)
        if (receipt != null) {
            check(record.closing)
            completed[record.owner] = receipt
            active.remove(record.owner)
            // Receipts only answer a repeated RELEASE; the oldest one is forgotten instead of
            // refusing every later task on this connection. A forgotten owner reads as unknown.
            if (completed.size > history) completed.remove(completed.keys.first())
        } else record.busy = false
    }

    fun enterGlobal(legacyResource: Boolean = false): String? = synchronized(lock) {
        if (global || active.isNotEmpty()) return "scopeBusy"
        if (legacyResource && mode == true) return "scopeModeMismatch"
        if (legacyResource) mode = false
        global = true
        null
    }

    fun leaveGlobal() = synchronized(lock) { check(global); global = false }
}
