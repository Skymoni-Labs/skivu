package com.skyjjgw.independent.ski.dshgo.phone.background

/** Fixed, content-free observations; never serializes a Throwable message, stack or class name. */
internal object InputProbeDiagnostics {
    enum class Stage(val wire: String) {
        PRECONDITION("precondition"), UI_DISPATCH("ui_dispatch"),
        PRESENTATION_CREATE("presentation_create"), PRESENTATION_CONFIGURE("presentation_configure"),
        PRESENTATION_SHOW("presentation_show"), ACTIVITY_START("activity_start"),
        ACTIVITY_READY_WAIT("activity_ready_wait"), VIEW_LAYOUT_WAIT("view_layout_wait"),
        FRAME_COMMIT_WAIT("frame_commit_wait"), TARGET_VALIDATE("target_validate"),
        INPUT_SEND("input_send"), RECEIPT_WAIT("receipt_wait"), CLEANUP("cleanup"),
    }

    data class Observation(val stage: Stage, val exceptionType: String, val elapsedMs: Long) {
        fun encode(): String = "probe-v1;stage=${stage.wire};type=$exceptionType;elapsedMs=$elapsedMs"
    }

    private val types = setOf("none", "SecurityException", "IllegalStateException", "IllegalArgumentException",
        "InvalidDisplayException", "BadTokenException", "TimeoutException", "InterruptedException", "OtherException")
    private val wire = Regex("probe-v1;stage=([a-z_]+);type=([A-Za-z]+);elapsedMs=([0-9]{1,5})")

    fun observe(stage: Stage, error: Throwable?, elapsedMs: Long): Observation {
        val cause = if (error is java.util.concurrent.ExecutionException || error is java.lang.reflect.InvocationTargetException)
            error.cause ?: error else error
        val type = when (cause?.javaClass?.name) {
            null -> "none"
            "java.lang.SecurityException" -> "SecurityException"
            "java.lang.IllegalStateException" -> "IllegalStateException"
            "java.lang.IllegalArgumentException" -> "IllegalArgumentException"
            "android.view.WindowManager\$InvalidDisplayException" -> "InvalidDisplayException"
            "android.view.WindowManager\$BadTokenException" -> "BadTokenException"
            "java.util.concurrent.TimeoutException" -> "TimeoutException"
            "java.lang.InterruptedException" -> "InterruptedException"
            else -> "OtherException"
        }
        return Observation(stage, type, elapsedMs.coerceIn(0, 60_000))
    }

    fun decode(detail: String?): Observation? {
        if (detail == null || detail.length > 160) return null
        val values = wire.matchEntire(detail)?.groupValues ?: return null
        val stage = Stage.entries.firstOrNull { it.wire == values[1] } ?: return null
        if (values[2] !in types) return null
        val elapsed = values[3].toLongOrNull()?.takeIf { it <= 60_000 } ?: return null
        return Observation(stage, values[2], elapsed)
    }

    /** One existing gate snapshot: last accepted input/receipt facts, not live connectivity or authorization. */
    fun snapshot(gate: BackgroundGateState.Snapshot): Map<String, Any?> {
        val base = linkedMapOf<String, Any?>("v" to 1, "observed" to false,
            "connectionFailure" to (gate.connectionError != null))
        if (gate.injectOk == true) {
            base["observed"] = true
            base["result"] = "success"
        } else {
            val failure = decode(gate.gateDetail) ?: return base
            if (gate.trustedDisplayOk != false && gate.injectOk != false) return base
            base["observed"] = true
            base["result"] = "failure"
            base["stage"] = failure.stage.wire
            base["exceptionType"] = failure.exceptionType
            base["elapsedMs"] = failure.elapsedMs
        }
        return base
    }
}
