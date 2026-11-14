package com.skyjjgw.independent.ski.dshgo.phone.background

import java.io.IOException
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** One channel's admission, including the complete reply. No IO or retirement callback under lock. */
internal class PrivilegedCalls(private val limit: Int = 1) {
    private val lock = ReentrantLock(true)
    private val changed = lock.newCondition()
    private var active = 0
    private var waiting = 0
    private var globals = 0
    private var exclusive = false
    @Volatile private var retired = false
    init { require(limit in 1..3) }

    // Read by registry admission too; beforeSend may itself enter registry/Tasks while holding lock.
    fun alive(): Boolean = !retired
    fun retire() = lock.withLock { retired = true; changed.signalAll() }

    fun <T> execute(global: Boolean = false, beforeSend: () -> Unit = {},
                    terminal: (T) -> Boolean = { false }, action: () -> T): T {
        enter(global, beforeSend)
        var ended = false
        try { return action().also { ended = terminal(it) } }
        finally { leave(global, ended) }
    }

    internal fun enter(global: Boolean, beforeSend: () -> Unit) {
        lock.lockInterruptibly()
        try {
            if (global) globals++ else waiting++
            try {
                while (!retired && (if (global) exclusive || active != 0 else exclusive || globals != 0 || active == limit))
                    changed.await()
                if (retired) throw IOException("deviceUnavailable")
                // Client gate -> original resource IO lock. This callback only commits its pin.
                beforeSend()
                if (global) exclusive = true else active++
            } finally {
                if (global) globals-- else waiting--
                changed.signalAll()
            }
        } finally { lock.unlock() }
    }

    internal fun leave(global: Boolean, terminal: Boolean) = lock.withLock {
        if (global) exclusive = false else active--
        if (terminal) retired = true
        changed.signalAll()
    }

    fun <T> tryPreview(action: () -> T): T? {
        if (!lock.tryLock(0, TimeUnit.NANOSECONDS)) return null
        try {
            if (retired || exclusive || globals != 0 || waiting != 0 || active == limit) return null
            active++
        } finally { lock.unlock() }
        try { return action() } finally { leave(false, false) }
    }
}
