package com.skyjjgw.independent.ski.dshgo.phone.background

/** Main-thread publication state. App events and privileged-frame acknowledgements are independent. */
internal class BackgroundPreviewDelivery {
    var generation = 0L
        private set
    var afterSequence = -1L
        private set
    private var eventSequence = 0L
    private var taskId: Long? = null
    private var message: Map<String, Any?>? = null

    fun reset(task: Long?) {
        generation++
        afterSequence = -1
        taskId = task
        message = task?.let { event(it, "waiting") }
    }

    fun initial(task: Long): Map<String, Any?> =
        message?.takeIf { taskId == task } ?: event(task, "off")

    /** Non-selected consumers never read the selected task's cached JPEG. */
    fun placeholder(task: Long, inUse: Boolean): Map<String, Any?> = event(task, if (inUse) "inUse" else "off")

    fun failure(): Map<String, Any?>? {
        afterSequence = -1 // Re-fetch cached pixels even when the core sequence has not changed.
        if (message?.get("state") == "unavailable") return null
        return event(checkNotNull(taskId), "unavailable").also { message = it }
    }

    fun accept(state: String, coreSequence: Long, width: Int, height: Int, bytes: ByteArray?): Map<String, Any?>? {
        if (state == "busy" || state == "frame" && bytes == null) return null
        if (coreSequence == afterSequence && message?.get("state") == state) return null
        afterSequence = coreSequence
        return event(checkNotNull(taskId), state, width, height, bytes).also { message = it }
    }

    private fun event(task: Long, state: String, width: Int = 0, height: Int = 0, bytes: ByteArray? = null): Map<String, Any?> = mapOf(
        "taskId" to task, "generation" to generation, "sequence" to eventSequence++, "state" to state,
        "width" to width, "height" to height, "imageBytes" to bytes,
    )
}
