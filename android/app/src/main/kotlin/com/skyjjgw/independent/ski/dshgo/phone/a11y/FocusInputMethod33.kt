package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.InputMethod
import android.annotation.TargetApi
import android.view.inputmethod.EditorInfo
import android.os.Looper

/** API33 callbacks only observe; explicit capture retains one wrapper without reading or writing text. */
@TargetApi(33)
internal class FocusInputMethod33(
    service: AccessibilityService,
    private val observation: FocusInputObservation,
) : InputMethod(service) {
    private var token = observation.replaceAdapter()

    /** Current service adapter only. Requires a later real start; never reuses the old snapshot. */
    fun reconnect() {
        check(Looper.myLooper() == Looper.getMainLooper())
        token = observation.replaceAdapter()
    }

    /** Capture on the callback looper; never fetch a replacement connection after confirmation. */
    fun capture(): FocusCapturedInput33? {
        check(Looper.myLooper() == Looper.getMainLooper())
        val snapshot = observation.snapshot() ?: return null
        if (!observation.isEditorCurrent(token, snapshot)) return null
        val connection = currentInputConnection ?: return null
        return FocusCapturedInput33(connection, observation, token, snapshot)
    }

    override fun onStartInput(attribute: EditorInfo, restarting: Boolean) {
        observation.start(token, FocusInputObservation.Editor(
            attribute.packageName, attribute.fieldId, attribute.inputType),
            attribute.initialSelStart, attribute.initialSelEnd)
    }

    override fun onFinishInput() {
        // Framework clears its connection only AFTER this callback; retire our facts first.
        // No super call: the observer must never request composition or text changes.
        observation.finish(token)
    }

    override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int,
        newSelEnd: Int, candidatesStart: Int, candidatesEnd: Int) {
        // Do not infer freshness from the old-selection pair (AOSP13 forwards oldSelEnd twice).
        observation.selection(token, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
    }
}
