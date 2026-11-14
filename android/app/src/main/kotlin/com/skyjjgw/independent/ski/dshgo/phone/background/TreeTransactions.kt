package com.skyjjgw.independent.ski.dshgo.phone.background

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Owns the actual peer connection from registration through the final live node and close. */
internal class TreeTransactions<C : Any>(private val close: (C) -> Boolean) {
    class CleanupPending : Exception()
    private val lock = ReentrantLock()
    private var pending: Pair<Any, C>? = null

    fun ready(): Boolean = lock.withLock { pending == null }
    fun closeOwned(scope: Any): Boolean = lock.withLock {
        val old = pending ?: return true
        if (old.first !== scope) return true
        if (!close(old.second)) return false
        pending = null
        true
    }
    fun <T> read(scope: Any, create: () -> C, body: (C) -> T): T = lock.withLock {
        if (pending != null) throw CleanupPending()
        val connection = create()
        pending = scope to connection
        try { body(connection) }
        finally {
            if (close(connection)) pending = null
            else throw CleanupPending()
        }
    }
}
