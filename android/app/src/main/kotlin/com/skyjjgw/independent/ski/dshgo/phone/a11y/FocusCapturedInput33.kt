package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.accessibilityservice.InputMethod
import android.annotation.TargetApi
import android.os.Looper
import android.os.SystemClock
import java.util.concurrent.atomic.AtomicBoolean

/** One original wrapper, one attempt. Owner/window/policy/consent remain the caller's responsibility. */
@TargetApi(33)
internal class FocusCapturedInput33 internal constructor(
    private val connection: InputMethod.AccessibilityInputConnection,
    private val observation: FocusInputObservation,
    private val adapter: Any,
    val snapshot: FocusInputObservation.Snapshot,
) {
    private val dispatched = AtomicBoolean(false)
    val attempted: Boolean get() = dispatched.get()

    fun currentBeforeDispatch(): Boolean = !attempted && observation.isCurrent(snapshot)
    fun sameEditor(): Boolean = observation.isEditorCurrent(adapter, snapshot)

    /** A request budget is not a bound on a misbehaving remote's actual blocking time. */
    fun readBounded(deadlineUptimeMs: Long): FocusReadback.Sample? {
        check(Looper.myLooper() != Looper.getMainLooper())
        val afterAttempt = attempted
        fun current() = if (afterAttempt) sameEditor() else currentBeforeDispatch()
        if (Thread.currentThread().isInterrupted || SystemClock.uptimeMillis() >= deadlineUptimeMs || !current()) return null
        val knownSelection = observation.snapshot() ?: return null
        if (knownSelection.selectionStart >= 0 && knownSelection.selectionEnd >= 0 &&
            kotlin.math.abs(knownSelection.selectionEnd.toLong() - knownSelection.selectionStart) > 4096L) return null
        // The selected range is also returned and can exceed this requested context window.
        // Acceptance limits cannot bound Binder allocation for an oversized remote response.
        val result = connection.getSurroundingText(1024, 1024, 0) ?: return null
        if (Thread.currentThread().isInterrupted || SystemClock.uptimeMillis() >= deadlineUptimeMs || !current()) return null
        val text = result.text
        if (text.length > 4096) return null
        // Do not retain Parcelable spans or EditorInfo/whole-field text. Leaf comparison validates indices.
        return FocusReadback.Sample(text.toString(), result.selectionStart, result.selectionEnd, result.offset)
    }

    /** Normal return is only a submitted attempt, never an execution ACK. Exceptions leave attempted=true. */
    fun commitOnce(text: String) {
        check(Looper.myLooper() != Looper.getMainLooper())
        check(!Thread.currentThread().isInterrupted && currentBeforeDispatch())
        check(dispatched.compareAndSet(false, true))
        // No lock spans IPC. A subsequent callback/remote change cannot be made atomic by this leaf.
        connection.commitText(text, 1, null)
    }
}
