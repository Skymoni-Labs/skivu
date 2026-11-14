package com.skyjjgw.independent.ski.dshgo.phone.background

/** Four actual query slots. Raw task identities stay inside this one live Core scope. */
internal class SelfCheckMainSamples(
    private val vector: () -> List<Task>?,
    private val focus: () -> Focus?,
) {
    data class Task(val id: Int, val user: Int, val display: Int, val component: String?, val position: Int,
                    val focused: Boolean, val visible: Boolean)
    data class Focus(val display: Int, val task: Int)
    enum class Slot { BEFORE_CREATE, AFTER_LAUNCH, AFTER_INPUTS, AFTER_RELEASE }
    enum class Value(val wire: String) { BASELINE("baseline"), UNCHANGED("unchanged"), CHANGED("changed"), UNAVAILABLE("unavailable") }
    data class Result(val vector: Value, val focus: Value)
    private var baselineVector: List<Task>? = null
    private var baselineFocus: Focus? = null
    private val results = arrayOfNulls<Result>(Slot.entries.size)

    fun sample(slot: Slot): Result {
        results[slot.ordinal]?.let { return it }
        // Install an unknown result before any query: no exceptional path retries a historical slot.
        results[slot.ordinal] = Result(Value.UNAVAILABLE, Value.UNAVAILABLE)
        val actualVector = runCatching { vector()?.takeIf { rows -> rows.size <= 64 &&
            rows.all { it.id >= 0 && it.user >= 0 && it.display == 0 && it.position >= 0 } &&
            rows.map { it.id }.distinct().size == rows.size
        }?.sortedWith(compareBy<Task> { it.position }.thenBy { it.id }) }.getOrNull()
        val actualFocus = runCatching { focus()?.takeIf { it.display >= 0 && it.task >= 0 } }.getOrNull()
        val result = if (slot == Slot.BEFORE_CREATE) {
            baselineVector = actualVector
            baselineFocus = actualFocus
            Result(if (actualVector != null) Value.BASELINE else Value.UNAVAILABLE,
                if (actualFocus != null) Value.BASELINE else Value.UNAVAILABLE)
        } else Result(compare(baselineVector, actualVector), compare(baselineFocus, actualFocus))
        results[slot.ordinal] = result
        return result
    }

    private fun compare(before: Any?, after: Any?): Value = when {
        before == null || after == null -> Value.UNAVAILABLE
        before == after -> Value.UNCHANGED
        else -> Value.CHANGED
    }
}

/** Only the last strict completion. No new query or physical operation occurs on exact replay. */
internal data class SelfCheckTargetCompletion(val request: SelfCheckTargetRelease, val neverCreated: Boolean,
                                             val main: SelfCheckMainSamples.Result)
