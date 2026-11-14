package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.selfcheck.TargetContract

/** Per real tree walk. Raw node text is compared immediately, never retained or returned. */
internal class SelfCheckTargetEvidence(run: String, counter: Int, private val c2: Boolean = false,
                                      private val expectedText: String? = null, private val expectedPhase: Int? = null) {
    data class Bounds(val left: Int, val top: Int, val right: Int, val bottom: Int) {
        val width: Int get() = right - left
        val height: Int get() = bottom - top
        fun inside(width: Int, height: Int): Boolean = left >= 0 && top >= 0 && right > left && bottom > top && right <= width && bottom <= height
    }
    val editorId = TargetContract.viewId(Proto.APP_PACKAGE, TargetContract.EDIT_ID)
    private val patternId = TargetContract.viewId(Proto.APP_PACKAGE, TargetContract.PATTERN_ID)
    private val phaseId = TargetContract.viewId(Proto.APP_PACKAGE, TargetContract.PHASE_ID)
    private var editors = 0
    private var patterns = 0
    private var phases = 0
    private var editorUsable = false
    private var patternVisible = false
    private var phaseMatches = false
    private var textMatches = false
    var patternBounds: Bounds? = null; private set
    var editorBounds: Bounds? = null; private set

    fun needsBounds(id: String?): Boolean = c2 && (id == patternId || id == editorId)
    fun observeBounds(id: String?, left: Int, top: Int, right: Int, bottom: Int) {
        if (id == patternId) patternBounds = Bounds(left, top, right, bottom)
        if (id == editorId) editorBounds = Bounds(left, top, right, bottom)
    }

    private val markerId = TargetContract.viewId(Proto.APP_PACKAGE, TargetContract.MARKER_ID)
    private val counterId = TargetContract.viewId(Proto.APP_PACKAGE, TargetContract.COUNTER_ID)
    val buttonId = TargetContract.viewId(Proto.APP_PACKAGE, TargetContract.BUTTON_ID)
    private val marker = TargetContract.marker(run)
    private val counter = TargetContract.counter(counter)
    private var markers = 0
    private var counters = 0
    private var buttons = 0
    private var markerMatches = false
    private var counterMatches = false
    private var buttonUsable = false

    fun observe(id: String?, visible: Boolean, text: CharSequence?, description: CharSequence?, enabled: Boolean, clickable: Boolean, editable: Boolean = false, showingHint: Boolean = false) {
        if (c2) when (id) {
            editorId -> {
                editors++; editorUsable = visible && enabled && editable
                textMatches = expectedText == null || if (expectedText.isEmpty()) showingHint || text.isNullOrEmpty()
                    else !showingHint && exact(text, expectedText)
            }
            patternId -> { patterns++; patternVisible = visible }
            phaseId -> { phases++; phaseMatches = visible && (expectedPhase == null || exact(text, expectedPhase.toString())) }
        }
        when (id) {
            markerId -> { markers++; markerMatches = visible && exact(description, marker) }
            counterId -> { counters++; counterMatches = visible && exact(text, counter) }
            buttonId -> { buttons++; buttonUsable = visible && enabled && clickable }
        }
    }

    val targetMatched: Boolean get() = markers == 1 && markerMatches && counters == 1 && buttons == 1 && buttonUsable &&
        (!c2 || editors == 1 && editorUsable && patterns == 1 && patternVisible && phases == 1 && phaseMatches)
    val textMatched: Boolean get() = c2 && editors == 1 && textMatches
    val counterMatched: Boolean get() = counters == 1 && counterMatches

    private fun exact(value: CharSequence?, expected: String): Boolean =
        value != null && value.length == expected.length && value.toString() == expected
}
