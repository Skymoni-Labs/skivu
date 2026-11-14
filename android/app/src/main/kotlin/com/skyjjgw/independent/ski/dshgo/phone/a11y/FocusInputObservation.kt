package com.skyjjgw.independent.ski.dshgo.phone.a11y

/** Callback facts only, never authority to write or proof of window identity. */
internal class FocusInputObservation {
    enum class Composition { UNKNOWN, PRESENT }
    data class Editor(val packageName: String?, val fieldId: Int, val inputType: Int)
    data class Snapshot(
        val editorGeneration: Long,
        val selectionRevision: Long,
        val editor: Editor,
        val selectionStart: Int,
        val selectionEnd: Int,
        val composition: Composition,
    )

    private var adapter: Any? = null
    private var generation = 0L
    private var current: Snapshot? = null

    @Synchronized fun replaceAdapter(): Any = Any().also {
        adapter = it
        current = null
    }

    /** Also used by the eventual service/driver retirement boundary. */
    @Synchronized fun retire() {
        adapter = null
        current = null
    }

    // A restart creates a new editor generation too; no preceding finish is required.
    @Synchronized fun start(token: Any, editor: Editor, start: Int, end: Int) {
        if (adapter !== token) return
        current = Snapshot(++generation, 0L, editor, start, end, Composition.UNKNOWN)
    }

    @Synchronized fun finish(token: Any) {
        if (adapter === token) current = null
    }

    @Synchronized fun selection(token: Any, start: Int, end: Int, candidatesStart: Int, candidatesEnd: Int) {
        if (adapter !== token) return
        val old = current ?: return
        // A negative/cache range is not proof that the live editor has no composition.
        val composition = if (candidatesStart >= 0 && candidatesEnd > candidatesStart)
            Composition.PRESENT else Composition.UNKNOWN
        current = old.copy(selectionRevision = old.selectionRevision + 1L,
            selectionStart = start, selectionEnd = end, composition = composition)
    }

    /** Post-dispatch evidence may survive selection callbacks, never an editor/adapter change. */
    @Synchronized fun isEditorCurrent(token: Any, snapshot: Snapshot): Boolean =
        adapter === token && current?.editorGeneration == snapshot.editorGeneration

    @Synchronized fun snapshot(): Snapshot? = current
    @Synchronized fun isCurrent(snapshot: Snapshot): Boolean = current === snapshot
}
