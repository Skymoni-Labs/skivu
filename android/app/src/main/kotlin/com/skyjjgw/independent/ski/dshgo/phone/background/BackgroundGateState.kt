package com.skyjjgw.independent.ski.dshgo.phone.background

/** Self-check facts and the last failed connection; an untested channel is still unknown. */
internal class BackgroundGateState {
    data class Snapshot(
        val trustedDisplayOk: Boolean? = null,
        val injectOk: Boolean? = null,
        val injectError: String? = null,
        val gateDetail: String? = null,
        val connectionError: Int? = null,
    )

    /** One accepted response, not the latest capability cache or a strict cleanup receipt. */
    data class Receipt(
        val trustedDisplayOk: Boolean,
        val injectOk: Boolean?,
        val injectFailure: InjectFailure?,
        val observation: InputProbeDiagnostics.Observation?,
    )

    enum class InjectFailure {
        API_UNAVAILABLE, PERMISSION_DENIED, WINDOW_NOT_READY, UNCONFIRMED, CLEANUP_FAILED, CANCELLED, OTHER;

        companion object {
            fun fromWire(error: String?): InjectFailure = when (error) {
                "inputApiUnavailable" -> API_UNAVAILABLE
                "systemOperationDenied" -> PERMISSION_DENIED
                "inputWindowNotReady" -> WINDOW_NOT_READY
                "inputUnconfirmed" -> UNCONFIRMED
                "inputProbeCleanupFailed" -> CLEANUP_FAILED
                "cancelled" -> CANCELLED
                else -> OTHER
            }
        }
    }

    sealed interface Update {
        data class Accepted(val receipt: Receipt) : Update
        object Busy : Update
        object Cancelled : Update
        object Invalid : Update
    }

    class Probe internal constructor(internal val mayApply: () -> Boolean)
    private var probe: Probe? = null
    private var failedChannel: Any? = null

    /** Diagnostics only: display/input facts never gate admission; connectionError is shown while unconnected. */
    @Volatile var snapshot = Snapshot()
        private set

    @Synchronized fun reset() { probe = null; failedChannel = null; snapshot = Snapshot() }

    /** A deliberate retry can enter even after a failure; it does not erase capability facts. */
    @Synchronized fun begin(mayApply: () -> Boolean): Probe? {
        if (!mayApply()) return null
        failedChannel = null
        if (snapshot.connectionError != null) snapshot = snapshot.copy(connectionError = null)
        return Probe(mayApply).also { probe = it }
    }

    /** Revoke an old UI attempt before its worker returns, without forgetting completed facts. */
    @Synchronized fun cancelUnwantedPending() {
        if (probe?.mayApply?.invoke() == false) probe = null
    }

    /** The real UI/keep intent change shares begin/admit's memory-only linearization point. */
    @Synchronized fun <T> changeIntent(change: () -> T): T {
        val result = change()
        if (probe?.mayApply?.invoke() == false) probe = null
        return result
    }

    @Synchronized fun current(owner: Probe): Boolean = probe === owner && owner.mayApply()

    /** Pure-memory gate claim and the original IO commit. No transport or storage here. */
    @Synchronized fun admit(owner: Probe, commit: () -> Unit): Boolean {
        if (!current(owner)) return false
        commit()
        return true
    }

    /** A connect that failed before any probe. Cleared by the next connect, probe or reset. */
    @Synchronized fun connectionFailed(reason: Int, mayApply: () -> Boolean) {
        if (!mayApply()) return
        failedChannel = null
        snapshot = snapshot.copy(connectionError = reason)
    }

    @Synchronized fun failed(owner: Probe, reason: Int, channel: Any? = null): Boolean {
        if (!current(owner)) return false
        failedChannel = channel
        snapshot = snapshot.copy(connectionError = reason)
        return true
    }

    /** A connection can replace only the failure observed before that attempt started. */
    @Synchronized fun connected(observed: Snapshot, channel: Any) {
        if (snapshot === observed && snapshot.connectionError != null && failedChannel !== channel) {
            probe = null
            failedChannel = null
            snapshot = snapshot.copy(connectionError = null)
        }
    }

    /** The settings caller consumes the existing strict B reply, not legacy OP_GATE's OK. */
    fun updateStrict(owner: Probe, expectedOwner: String, wireOwner: Any?, version: Any?,
                     ok: Any?, displayReady: Any?, injectOk: Any?, error: Any?, injectError: Any?, detail: Any?): Update {
        if (wireOwner !is String || wireOwner != expectedOwner || version !is Int || version != 1 || ok !is Boolean ||
            displayReady !is Boolean || injectOk != null && injectOk !is Boolean ||
            error != null && error !is String || injectError != null && injectError !is String ||
            detail != null && detail !is String || ok != (displayReady && injectOk == true) ||
            !displayReady && injectOk != null || ok && (error != null || injectError != null)) return Update.Invalid
        val decoded = InjectFailure.fromWire((injectError ?: error) as? String)
        // The WINDOW_NOT_READY wording says no tap was sent. A recorded send attempt wins
        // over a contradictory error label; delivery remains unconfirmed.
        val failure = if (injectOk == false && decoded == InjectFailure.WINDOW_NOT_READY)
            InjectFailure.UNCONFIRMED else decoded
        val code = when (failure) {
            InjectFailure.API_UNAVAILABLE -> "inputApiUnavailable"
            InjectFailure.PERMISSION_DENIED -> "systemOperationDenied"
            InjectFailure.WINDOW_NOT_READY -> "inputWindowNotReady"
            InjectFailure.UNCONFIRMED -> "inputUnconfirmed"
            InjectFailure.CLEANUP_FAILED -> "inputProbeCleanupFailed"
            InjectFailure.CANCELLED -> "cancelled"
            InjectFailure.OTHER -> "inputProbeFailed"
        }
        // Raw peer detail/error never enters status; reuse the existing fixed diagnostics decoder.
        return update(owner, displayReady, null, injectOk as Boolean?, code,
            InputProbeDiagnostics.decode(detail as? String)?.encode(),
            unsentFailure = if (displayReady && injectOk == null && (injectError != null || error != null)) failure else null)
    }

    /** Accept the response and freeze its safe facts under the same owner check. */
    @Synchronized fun update(owner: Probe, ok: Boolean, error: String?, injectOk: Boolean?, injectError: String?, detail: String?,
                             unsentFailure: InjectFailure? = null): Update {
        if (!current(owner)) return Update.Cancelled
        if (error == "probeBusy") return Update.Busy // Not run: keep historical facts unchanged.
        val inputFailure = if (injectOk == false) InjectFailure.fromWire(injectError)
            else if (injectOk == null) unsentFailure else null
        val receipt = Receipt(ok, injectOk, inputFailure, InputProbeDiagnostics.decode(detail))
        failedChannel = null
        snapshot = Snapshot(ok, injectOk, if (inputFailure != null) injectError else null, detail)
        return Update.Accepted(receipt)
    }
}
