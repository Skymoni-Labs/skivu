package com.skyjjgw.independent.ski.dshgo.diagnostics

/** No log text, identifiers or unrecognised fields can cross this boundary. */
data class SystemImeEvent(
    val timestamp: Long,
    val event: String,
    val fromUser: Boolean?,
    val reason: String,
    val origin: String,
) {
    fun map(): Map<String, Any?> = mapOf(
        "timestamp" to timestamp, "event" to event, "fromUser" to fromUser,
        "reason" to reason, "origin" to origin,
    )
}

object SystemImeEvidence {
    const val APP_PACKAGE = com.skyjjgw.independent.ski.BuildConfig.APPLICATION_ID
    const val WINDOW_MS = 120_000L
    const val MAX_EVENTS = 64
    const val MAX_BYTES = 128 * 1024
    const val MAX_LINE_BYTES = 2048
    const val RUNTIME_MS = 1500L
    const val REQUEST_MAX_AGE_MS = 4000L

    fun requestFresh(requestedAt: Long, now: Long): Boolean =
        requestedAt > 0 && requestedAt in (now - REQUEST_MAX_AGE_MS)..now
    val command = listOf(
        "/system/bin/logcat", "-d", "-v", "epoch", "-t", "1000",
        "ImeTracker:I", "InputMethodManager:D", "RemoteInputConnectionImpl:W",
        "IInputConnectionWrapper:W", "*:S",
    )
    val reasons = setOf(
        "SHOW_SOFT_INPUT", "SHOW_SOFT_INPUT_FROM_IME", "SHOW_AUTO_EDITOR_FORWARD_NAV",
        "SHOW_STATE_VISIBLE_FORWARD_NAV", "SHOW_STATE_ALWAYS_VISIBLE", "HIDE_SOFT_INPUT",
        "HIDE_SOFT_INPUT_FROM_IME", "HIDE_STATE_HIDDEN_FORWARD_NAV",
        "HIDE_ALWAYS_HIDDEN_STATE", "HIDE_WINDOW_LOST_FOCUS",
    )
    private val header = Regex("^ *([0-9]{10,12})[.]([0-9]{3,9}) +([0-9]+) +[0-9]+ +[VDIWEF] +([A-Za-z]+) *: (.*)$")
    private val tracker = Regex(
        "^" + Regex.escape(APP_PACKAGE) + ":[A-Za-z0-9]+: onRequest(Show|Hide) at " +
            "ORIGIN_(CLIENT|SERVER|IME) reason ([A-Z_]+)(?: fromUser (true|false))?$",
    )
    // Only anchored framework message shapes, never method words found inside text.
    private val show = Regex("^showSoftInput[(][)] view=.{1,1600} flags=[0-9]+(?: reason=[A-Z_]+)?$")
    private val hide = Regex("^hideSoftInputFromWindow[(][)] token=.{1,1600} flags=[0-9]+(?: reason=[A-Z_]+)?$")

    fun parse(line: String, appPid: Int, capturedAt: Long): SystemImeEvent? {
        if (line.length > MAX_LINE_BYTES) return null
        val match = header.matchEntire(line) ?: return null
        val seconds = match.groupValues[1].toLongOrNull() ?: return null
        val timestamp = seconds * 1000 + match.groupValues[2].take(3).toLong()
        if (timestamp < capturedAt - WINDOW_MS || timestamp > capturedAt) return null
        val pid = match.groupValues[3].toIntOrNull() ?: return null
        // Package names inside log messages are claims; authenticate the emitter.
        if (appPid <= 0 || pid != appPid) return null
        val tag = match.groupValues[4]
        val message = match.groupValues[5]
        if (tag == "ImeTracker") {
            val request = tracker.matchEntire(message) ?: return null
            val reason = request.groupValues[3].takeIf { it in reasons } ?: return null
            return SystemImeEvent(timestamp,
                if (request.groupValues[1] == "Show") "requestShow" else "requestHide",
                request.groupValues[4].takeIf { it.isNotEmpty() }?.toBooleanStrict(), reason, "imeTracker")
        }
        val event = when (tag) {
            "InputMethodManager" -> when {
                show.matches(message) -> "requestShow"
                hide.matches(message) -> "requestHide"
                else -> return null
            }
            "RemoteInputConnectionImpl", "IInputConnectionWrapper" ->
                if (message == "Calling View.onInputConnectionClosed()") "connectionClosed" else return null
            else -> return null
        }
        return SystemImeEvent(timestamp, event, null, "unknown",
            if (tag == "InputMethodManager") "inputMethodManager" else "inputConnection")
    }

    /** Revalidate the privileged reply instead of forwarding any free-form core data. */
    fun valid(event: SystemImeEvent, capturedAt: Long): Boolean =
        event.timestamp in (capturedAt - WINDOW_MS)..capturedAt && when (event.origin) {
            "imeTracker" -> event.event in setOf("requestShow", "requestHide") && event.reason in reasons
            "inputMethodManager" -> event.event in setOf("requestShow", "requestHide") &&
                event.fromUser == null && event.reason == "unknown"
            "inputConnection" -> event.event == "connectionClosed" && event.fromUser == null && event.reason == "unknown"
            else -> false
        }

    fun coreCode(ok: Boolean, code: String?): String = when {
        ok && code in setOf("ok", "noEvents") -> code!!
        code == "invalidArguments" -> "unsupported" // An older core does not recognise the fixed op.
        code in setOf("unsupported", "timeout", "limitExceeded", "busy", "failed", "cancelled") -> code!!
        else -> "unavailable"
    }

    fun result(code: String, capturedAt: Long = System.currentTimeMillis(), events: List<SystemImeEvent> = emptyList()): Map<String, Any?> = mapOf(
        "ok" to (code == "ok" || code == "noEvents"), "code" to code,
        "capturedAt" to capturedAt, "source" to "privilegedIme",
        "events" to if (code == "ok") events.map { it.map() } else emptyList<Map<String, Any?>>(),
    )
}

/** A new instance per dialog: neither an earlier phone permission nor a previous tap is consent. */
class SystemImeConsent {
    @Volatile private var cancelled = false
    @Volatile private var consumed = false
    @Synchronized fun approveAndConsume(): Boolean {
        if (cancelled || consumed) return false
        consumed = true
        return true
    }
    fun cancel() { cancelled = true }
    fun allowed(): Boolean = consumed && !cancelled
}
