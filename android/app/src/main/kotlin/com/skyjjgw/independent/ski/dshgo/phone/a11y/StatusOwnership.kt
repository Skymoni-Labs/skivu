package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.phone.TaskControls

/** Main-queue confined ownership of the displayed status, independent of prompt cards.
 * Checks only short task state. Platform/UI work always runs after the check returns. */
internal class StatusOwnership {
    private var current: ((() -> Unit) -> Boolean)? = null

    /** 暂停 / 停止 / 插话 of the task whose status is displayed; never re-resolved at tap time. */
    var controls: TaskControls? = null
        private set

    var editingControls: TaskControls? = null
        private set

    fun beginEditing(): Boolean {
        editingControls = controls
        return editingControls != null
    }

    fun endEditing() { editingControls = null }

    fun publish(ifCurrent: (() -> Unit) -> Boolean): Boolean = publish(ifCurrent) { null }

    /** [capture] runs inside [ifCurrent], so the controls belong to the very status being shown. */
    fun publish(ifCurrent: (() -> Unit) -> Boolean, capture: () -> TaskControls?): Boolean {
        var captured: TaskControls? = null
        if (!ifCurrent { captured = capture() }) return false
        val shown = captured
        current = ifCurrent
        controls = shown
        val editor = editingControls
        if (editor != null && (shown == null || editor.taskId != shown.taskId || editor.lifecycle != shown.lifecycle)) {
            editingControls = null
        }
        return true
    }

    fun clear() { current = null; controls = null; editingControls = null }

    /** A newer task may invalidate an old cleanup ticket without owning the old status. */
    fun takeStale(): Boolean {
        val owner = current ?: return false
        // A new execution invalidates old publications, not the same owner's visible
        // control. The display lifetime still ends on any intervening owner or retirement.
        if (owner {} || controls?.isCurrentDisplay() == true) return false
        clear()
        return true
    }
}
