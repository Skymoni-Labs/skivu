package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.i18n.AppStrings
import com.skyjjgw.independent.ski.R
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.provider.Settings
import com.skyjjgw.independent.ski.dshgo.phone.PhoneControl
import com.skyjjgw.independent.ski.dshgo.phone.PhoneAppIdentity
import com.skyjjgw.independent.ski.dshgo.phone.a11y.MlKitLocalOcr
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.FutureTask
import com.skyjjgw.independent.ski.dshgo.phone.PhoneTasks

/**
 * The 不打扰模式 surface the core's `PhonePlugin` calls into: the `background` block of `status`,
 * and the actions behind `setBackgroundMode`, `requestShizukuPermission`, `adbStartPairing`,
 * `adbPair`, `adbConnect`. It owns the shared Shizuku/Sui, self-ADB and explicit root starters.
 *
 * Admission is only: a mode other than off, Android 14+, and the selected channel connected and
 * authorized ([BackgroundPolicy.capacity]), minus real momentary occupancy. The input self-check
 * is a diagnostic for the settings page; real display/input failures come back from the task's
 * own operation with their error codes. A release that is not confirmed disconnects that channel:
 * screens belong to the privileged process, and the system reclaims them when it exits. Nothing
 * waits on a cleanup receipt. Method names match the `dsh/phone` channel.
 */
class BackgroundControl private constructor(context: Context) {
    private val app = context.applicationContext

    @Volatile var onStatusChanged: () -> Unit = {}

    private val keepGuard = Any()
    private var transportUsers = 0
    internal class SelfCheckBorrow internal constructor(
        val channel: PrivilegedChannel,
        internal val selection: PrivilegedKeepState.Ticket,
    ) {
        internal var returned = false
    }
    @Volatile private var selfCheckBorrow: SelfCheckBorrow? = null

    // These reservations cover actual setup/self-check/grant bodies, including their cleanup finally.
    private fun beginTransportUse(): Boolean = synchronized(keepGuard) {
        if (selfCheckBorrow != null || selectingResource || interruptRequested) false
        else { transportUsers++; true }
    }
    private fun endTransportUse() {
        synchronized(keepGuard) { check(transportUsers > 0); transportUsers-- }
        finishInterrupt()
    }

    /** Capture only an already-published peer; this never connects or restores consent. */
    internal fun tryBorrowSelfCheck(): SelfCheckBorrow? {
        val borrowed = synchronized(this) {
            synchronized(keepGuard) {
                if (taskResource.occupied || selectingResource || interruptRequested || interruptFinishing ||
                    selfCheckBorrow != null || transportUsers != 0 || restoring != null || selectionChange != null) return null
                val current = channel ?: return null
                if (mode !in PrivilegedKeepState.MODES) return null
                SelfCheckBorrow(current, keep.selectionTicket()).also { selfCheckBorrow = it }
            }
        }
        // Starter identity is checked outside controller locks; the reservation blocks new setup.
        val published = when (borrowed.selection.mode) {
            "root" -> root.isPublished(borrowed.channel)
            "adb" -> adb.isPublished(borrowed.channel)
            "shizuku", "sui" -> shizuku.isPublished(borrowed.channel)
            else -> false
        }
        if (!published || !selfCheckBorrowCurrent(borrowed)) {
            synchronized(keepGuard) {
                if (selfCheckBorrow === borrowed) {
                    borrowed.returned = true
                    selfCheckBorrow = null
                }
            }
            // Start may run on main. Failed local reservation must never disconnect there.
            recovery.execute { finishInterrupt() }
            return null
        }
        return borrowed
    }

    internal fun selfCheckBorrowCurrent(borrowed: SelfCheckBorrow): Boolean = synchronized(keepGuard) {
        selfCheckBorrow === borrowed && !interruptRequested && keep.selectionCurrent(borrowed.selection)
    }

    /** Coordinator worker only; still holds its registry reservation during pending disconnect. */
    internal fun releaseSelfCheckBorrow(borrowed: SelfCheckBorrow): Boolean {
        val released = synchronized(keepGuard) {
            if (borrowed.returned) true
            else if (selfCheckBorrow !== borrowed) false
            else { borrowed.returned = true; selfCheckBorrow = null; true }
        }
        // The run's screen is released, or its channel was discarded. A disconnect failure keeps the
        // existing interrupt gate closed; it must not turn a returned borrow into a false result.
        if (released) runCatching { finishInterrupt() }
        return released
    }

    private fun transportBusy(): Map<String, Any?> = mapOf("ok" to false,
        "reason" to AppStrings.get(app, R.string.phone_background_cleanup_busy))
    private val preferenceGuard = Any()
    private val viewportPrefs = app.getSharedPreferences("phone-background-viewport", Context.MODE_PRIVATE)
    @Volatile private var viewport = BackgroundPolicy.Viewport.parse(
        runCatching { viewportPrefs.getString("preset", "portrait") }.getOrNull()) ?: BackgroundPolicy.Viewport.PORTRAIT
    private val parallelPrefs = app.getSharedPreferences("phone-background-parallelism", Context.MODE_PRIVATE)
    @Volatile private var parallelLimit = parallelPrefs.getInt("limit", 1)
    @Volatile private var selectionChange: Any? = null
    private val keepPrefs = app.getSharedPreferences("phone-privileged-keep", Context.MODE_PRIVATE)
    private val keep = PrivilegedKeepState(keepPrefs.getString("keptMode", "off") ?: "off",
        PhoneControl.switchedOn(app), Build.VERSION.SDK_INT >= BackgroundPolicy.MIN_SDK)
    private val recovery = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-privileged-keep").apply { isDaemon = true } }
    // Pairing from the App and from the notification share one queue: an older attempt can't
    // stop a newer one's discovery, and its result can't replace the newer one's notification.
    private val pairing = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-adb-pair").apply { isDaemon = true } }
    @Volatile private var restoring: FutureTask<PrivilegedChannel?>? = null
    private var restoringTicket: PrivilegedKeepState.Ticket? = null
    private var restoreAgain = false
    private val networkGuard = Any()
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    // Null capabilities mean not probed; only an actual failed attempt records a transport error.
    private val gate = BackgroundGateState()
    private val shizuku = ShizukuStarter(app, {
        synchronized(keepGuard) { if (mode == "shizuku" || mode == "sui") gate.reset() }
    }) { transportChanged("sharedApi") }
    private val adb = AdbStarter(app) { transportChanged("adb") }
    private val root = RootStarter(app) { transportChanged("root") }

    private val mode: String get() = keep.mode
    @Volatile private var rootSelected = mode == "root"
    @Volatile private var channel: PrivilegedChannel? = null
    private val taskResource = BackgroundTaskSlot<BackgroundDisplay, PrivilegedChannel>(this)
    // Lock order: this -> keepGuard -> previewGuard (either prefix may be omitted). Never IPC or a reverse lock under previewGuard.
    private val previewGuard = Any()
    @Volatile private var previewTargets = emptyMap<Long, BackgroundPreviewTarget>()
    @Volatile var onPreviewChanged: () -> Unit = {}
    @Volatile internal var localOcrAllowed: (PhoneAppIdentity) -> Boolean = { false }

    fun previewTarget(taskId: Long): BackgroundPreviewTarget? = previewTargets[taskId]

    /** Memory publication only; callers notify after releasing controller locks. */
    private fun replaceChannel(value: PrivilegedChannel?): Boolean = synchronized(previewGuard) {
        if (channel === value) false else {
            channel = value
            previewTargets = emptyMap()
            true
        }
    }

    /** Ready belongs to its original record; it does not select a preview consumer. */
    private fun publishPreviewTarget(record: BackgroundTaskSlot.TaskResource<BackgroundDisplay, PrivilegedChannel>,
                                     value: PrivilegedChannel) {
        val changed = synchronized(this) {
            synchronized(previewGuard) {
                val active = record.driver
                val taskId = record.owner.taskId
                if (!taskResource.current(record) || channel !== value || value.backgroundLimit == 0 || !active.previewAvailable(value)) false
                else if (previewTargets[taskId]?.let { it.driver === active && it.channel === value } == true) false
                else {
                    previewTargets = previewTargets + (taskId to BackgroundPreviewTarget(taskId, active.ownerToken, value, active))
                    true
                }
            }
        }
        if (changed) onPreviewChanged()
    }

    /** Called after sealing dispatch; no callback or platform work here. */
    private fun withdrawPreviewTarget(value: BackgroundDisplay): Boolean = synchronized(previewGuard) {
        val old = previewTargets.entries.firstOrNull { it.value.driver === value } ?: return false
        previewTargets = previewTargets - old.key
        true
    }
    @Volatile private var interruptRequested = false
    @Volatile private var selectingResource = false
    private var interruptFinishing = false
    private var interruptStopping = false

    // The journal of the removed resource-recovery admission. Nothing reads it any more; an
    // upgraded install must not keep a stuck record around. Deleting a missing file is a no-op.
    init { recovery.execute { runCatching { app.deleteSharedPreferences("phone-background-resources") } } }

    /** Pure memory intent change; transport, callbacks and disk stay outside. */
    internal fun <T> changeGateIntent(change: () -> T): T = gate.changeIntent(change)

    /**
     * Drops [peer] after a release it could not confirm: its screens may still exist, and they
     * belong to that privileged process. Disconnecting ends the process, the system reclaims
     * them, and the next use connects again. Never blocks later use, success or not.
     */
    internal fun discardPeer(peer: PrivilegedChannel) {
        val changed = synchronized(this) { synchronized(keepGuard) { channel === peer && replaceChannel(null) } }
        if (changed) onPreviewChanged()
        shizuku.disconnectIfCurrent(peer)
        adb.disconnectIfCurrent(peer)
        root.disconnectIfCurrent(peer)
        peer.close()
        notifyChanged()
    }

    private fun notifyChanged() = runCatching { onStatusChanged() }

    private fun androidOk(): Boolean = Build.VERSION.SDK_INT >= BackgroundPolicy.MIN_SDK

    // ---- status ------------------------------------------------------------

    /** Last accepted self-check facts only: no connection, permission query or fresh self-test. */
    fun inputProbeDiagnostics(): Map<String, Any?> = InputProbeDiagnostics.snapshot(gate.snapshot)

    /** The `background` sub-map of the `dsh/phone` `status` method. */
    fun status(): Map<String, Any?> {
        val reason = readiness()
        val shizukuStatus = shizuku.status()
        val adbStatus = adb.status()
        val rootStatus = root.status()
        val cached = gate.snapshot
        return mapOf(
            "mode" to PrivilegedPathPolicy.legacyMode(mode),
            "ready" to PrivilegedPathPolicy.legacyReady(mode, reason == null),
            "reason" to PrivilegedPathPolicy.legacyReason(
                mode, reason, AppStrings.get(app, R.string.background_root_legacy_client),
            ),
            "androidOk" to androidOk(),
            "viewport" to mapOf("v" to 1, "preset" to viewport.preset),
            "trustedDisplay" to cached.trustedDisplayOk,
            "inject" to cached.injectOk,
            "selfCheckWarning" to if (reason == null && mode != "off") selfCheckWarning() else null,
            "shizuku" to shizukuStatus.map(),
            "adb" to adbStatus.map(),
            "root" to rootStatus.map(),
            "privileged" to mapOf(
                "v" to 1,
                "mode" to mode,
                "ready" to (reason == null),
                "reason" to reason,
                "supportedModes" to PrivilegedPathPolicy.modes,
                "recommendedMode" to PrivilegedPathPolicy.recommended(
                    mode, reason == null, androidOk(), shizukuStatus.provider,
                    shizukuStatus.running, shizukuStatus.granted, rootSelected,
                    rootStatus.connected, adbStatus.paired, adbStatus.wirelessDebugging,
                ),
                "grantPath" to SecureSettingsGrant.privilegedPath(
                    secureSettingsGranted(), shizukuStatus, adbStatus, rootSelected, rootStatus.connected,
                ),
                "rootSelected" to rootSelected,
                "keep" to keep.map(channel?.alive() == true),
            ),
        )
    }

    private val UNSUPPORTED: String get() = AppStrings.get(app, R.string.background_unsupported)

    /** Only the new model's facts: mode, Android version, the channel's own state, a switch in progress. */
    private fun readiness(): String? {
        val channelReason = when (mode) {
            "shizuku", "sui" -> shizuku.reason() ?: run {
                when (val provider = shizuku.status().provider) {
                    mode -> connectionReason()
                    ShizukuStatus.SUI -> AppStrings.get(app, R.string.background_provider_mismatch, "Shizuku", "Sui")
                    ShizukuStatus.SHIZUKU -> AppStrings.get(app, R.string.background_provider_mismatch, "Sui", "Shizuku")
                    else -> AppStrings.get(app, R.string.background_not_ready)
                }
            }
            "root" -> rootReason() ?: connectionReason()
            "adb" -> adb.reason() ?: connectionReason()
            else -> null
        }
        return when (BackgroundPolicy.unready(mode, androidOk(), selectingResource, channelReason)) {
            null -> null
            BackgroundPolicy.Unready.OFF -> AppStrings.get(app, R.string.background_off)
            BackgroundPolicy.Unready.ANDROID -> AppStrings.get(app, R.string.background_requires_android)
            BackgroundPolicy.Unready.SWITCHING -> AppStrings.get(app, R.string.background_gate_checking)
            BackgroundPolicy.Unready.CHANNEL -> channelReason
            BackgroundPolicy.Unready.UNKNOWN_MODE -> AppStrings.get(app, R.string.background_unknown_mode)
        }
    }

    /** A kept channel that is down, or the last connection failure while no channel is live. */
    private fun connectionReason(): String? {
        if (channel?.alive() == true) return null
        if (keep.connectionUnavailable(false)) return AppStrings.get(app, R.string.background_not_ready)
        return gate.snapshot.connectionError?.let { AppStrings.get(app, it) }
    }

    /** The self-check's failure, as a non-blocking note: the channel stays usable. */
    private fun selfCheckWarning(): String? {
        val cached = gate.snapshot
        val detail = when {
            cached.trustedDisplayOk == false -> Reasons.withDetail(UNSUPPORTED, cached.gateDetail)
            cached.injectOk != true && cached.injectError != null -> Reasons.withDetail(inputFailureReason(
                BackgroundGateState.InjectFailure.fromWire(cached.injectError)), cached.gateDetail)
            else -> return null
        }
        return AppStrings.get(app, R.string.background_self_check_warning, detail)
    }

    private fun inputFailureReason(reason: BackgroundGateState.InjectFailure): String = AppStrings.get(app, when (reason) {
        BackgroundGateState.InjectFailure.API_UNAVAILABLE -> R.string.background_input_api_unavailable
        BackgroundGateState.InjectFailure.PERMISSION_DENIED -> R.string.background_input_permission_denied
        BackgroundGateState.InjectFailure.WINDOW_NOT_READY -> R.string.background_input_window_not_ready
        BackgroundGateState.InjectFailure.UNCONFIRMED -> R.string.background_input_unconfirmed
        BackgroundGateState.InjectFailure.CLEANUP_FAILED -> R.string.background_input_cleanup_failed
        BackgroundGateState.InjectFailure.CANCELLED -> R.string.background_input_cancelled
        BackgroundGateState.InjectFailure.OTHER -> R.string.background_injection_denied
    })

    /** A failed connection attempt: the starter's own stage, never a capability verdict. */
    private fun setupFailureResource(code: String?): Int = when (code) {
        "bindTimeout" -> R.string.background_setup_bind_timeout
        "unbindTimeout", "bindingBusy" -> R.string.background_setup_unbind_wait
        "unbindFailed", "unbindDispatchFailed" -> R.string.background_setup_unbind_failed
        "bindFailed", "bindDispatchFailed", "noBinder", "probeFailed", "mainThread", "probeRejected", "muxFailed" ->
            R.string.background_setup_bind_failed
        "protocolMismatch" -> R.string.background_setup_old_service
        "serviceUnavailable" -> R.string.background_shizuku_stopped
        "permissionDenied" -> R.string.background_shizuku_permission
        "cancelled", "interrupted" -> R.string.background_selection_cancelled
        else -> R.string.background_not_ready
    }

    private fun rootReason(): String? {
        val status = root.status()
        if (status.connected) return null
        val resource = when {
            status.starting -> R.string.background_root_starting
            !status.checked -> R.string.background_root_not_selected
            status.reasonCode == "rootTimeout" -> R.string.background_root_timeout
            status.reasonCode == "rootCancelled" -> R.string.background_root_cancelled
            status.reasonCode == "rootIdentityMismatch" -> R.string.background_root_identity
            status.reasonCode == "rootDisconnected" -> R.string.background_root_disconnected
            status.reasonCode == "rootGrantFailed" -> R.string.background_root_grant_failed
            else -> R.string.background_root_failed
        }
        return AppStrings.get(app, resource)
    }

    internal data class Parallelism(val configuredLimit: Int, val effectiveLimit: Int, val reason: String?) {
        fun map(heldSlots: Int): Map<String, Any?> = mapOf("v" to 1,
            "configuredLimit" to configuredLimit, "effectiveLimit" to effectiveLimit,
            "heldSlots" to heldSlots, "reason" to reason)
    }

    /** Main-thread delivery check: only reads the already published preference. */
    internal fun configuredParallelLimit(): Int = parallelLimit

    /** Registry-safe memory snapshot: no controller locks, IPC, permission query or disk. */
    internal fun parallelism(): Parallelism {
        val configured = parallelLimit
        val busy = selfCheckBorrow != null || selectingResource || interruptRequested ||
            selectionChange != null || restoring?.isDone == false
        val capacity = BackgroundPolicy.capacity(mode, androidOk(), busy, channel?.backgroundLimit ?: 0, configured)
        return Parallelism(configured, capacity.effective, capacity.reason)
    }

    // ---- actions -----------------------------------------------------------

    /** Save before publication; existing logical leases and original resources remain owned. */
    internal fun setBackgroundParallelLimit(value: Any?): Map<String, Any?> {
        if (value !is Int || value !in 1..3)
            return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_parallel_limit_invalid))
        val saved = synchronized(preferenceGuard) {
            if (!parallelPrefs.edit().putInt("limit", value).commit()) false
            else { parallelLimit = value; true }
        }
        return if (saved) mapOf("ok" to true)
        else mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_parallel_limit_save_failed))
    }

    /** Preference only. Existing drivers keep their captured viewport until released. */
    fun setBackgroundViewport(value: Any?): Map<String, Any?> {
        val selected = BackgroundPolicy.Viewport.parse(value)
            ?: return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_viewport_invalid))
        val saved = synchronized(preferenceGuard) {
            if (!viewportPrefs.edit().putString("preset", selected.preset).commit()) false
            else { viewport = selected; true }
        }
        if (saved) notifyChanged()
        return if (saved) mapOf("ok" to true)
            else mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_viewport_save_failed))
    }

    fun setBackgroundMode(newMode: String, mayStart: () -> Boolean = { true }): Map<String, Any?> {
        if (!beginTransportUse()) return transportBusy()
        try {
            val provider = shizuku.status().provider
            val selected = PrivilegedPathPolicy.canonicalMode(newMode, provider)
                ?: return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_unknown_mode))
            if (selected == "sui" && provider != ShizukuStatus.SUI) {
                return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_sui_not_provider))
            }
            if (selected != "off" && !androidOk()) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_requires_android))
            val changing = selected != mode || selected == "off"
            synchronized(this) {
                synchronized(keepGuard) {
                    if (selectingResource || interruptRequested || selfCheckBorrow != null ||
                        transportUsers != 1 || restoring != null || selectionChange != null || !changing && taskResource.occupied) return transportBusy()
                    // Same-mode rechecks reserve the selection too, before any connection work.
                    selectingResource = true
                    if (changing) taskResource.seal().forEach { it.driver.seal() }
                }
            }
            try {
                // An unconfirmed release disconnects its channel; it never holds the switch back.
                if (changing) endTask()
                val (selection, transition, previewChanged) = synchronized(this) {
                    synchronized(keepGuard) {
                        if (!mayStart() || selectionChange != null) return keepFailure("selectionChanged")
                        val leaving = if (mode == "sui") "shizuku" else mode
                        val owner = if (changing) Any().also { selectionChange = it } else null
                        keep.select(selected)
                        rootSelected = selected == "root"
                        val changed = changing && replaceChannel(null)
                        Triple(keep.selectionTicket(), owner?.let { it to leaving }, changed)
                    }
                }
                if (previewChanged) onPreviewChanged()
                if (transition != null) {
                    try {
                        // Retire the old family before admitting new borrowers; no long IPC under keepGuard.
                        disconnectTransports { selected == "off" || it == transition.second }
                        gate.reset()
                    } finally {
                        val finished = synchronized(keepGuard) {
                            if (selectionChange !== transition.first) false
                            else { selectionChange = null; true }
                        }
                        // configure() may have changed keep generation while cleanup ran. The transition
                        // owns its own completion, and a newly saved keep must get another restore chance.
                        if (finished) restoreKeptChannel()
                    }
                }
                val allowed = { mayStart() && !interruptRequested && selectionChange == null && keep.selectionCurrent(selection) }
                val cleared = synchronized(preferenceGuard) {
                    keep.keptMode != "off" || keepPrefs.edit().putString("keptMode", "off").commit()
                }
                updateKeepListeners()
                if (!cleared) { notifyChanged(); return keepFailure("persistenceFailed") }
                when (selected) {
                    "off" -> { notifyChanged(); return mapOf("ok" to true) }
                    "shizuku", "sui" -> shizuku.ensureListeners()
                    // 不打扰模式's only su; tasks just connect() to what it leaves.
                    "root" -> root.start(allowed)?.let { connected ->
                        val changed = synchronized(this) {
                            synchronized(keepGuard) { allowed() && replaceChannel(connected) }
                        }
                        if (changed) onPreviewChanged()
                    }
                }
                notifyChanged()
                if (!allowed()) return keepFailure("selectionChanged")
                // Connect now so a missing grant or a dead service shows at once. The self-check after
                // it only feeds the settings page's note; it never fails this choice.
                val failure = connectAndCheck(selection, allowed)
                return mapOf("ok" to (failure == null), "reason" to failure)
            } finally {
                synchronized(this) { selectingResource = false }
                finishInterrupt()
                if (keep.enabled) restoreKeptChannel()
            }
        } finally { endTransportUse() }
    }

    fun requestShizukuPermission(provider: String? = null): Boolean =
        (provider == null || provider == shizuku.status().provider) && shizuku.requestPermission()

    /** Root for the explicit WSS grant; it never changes the background mode. */
    fun prepareRoot(mayStart: () -> Boolean): Map<String, Any?> {
        if (!beginTransportUse()) return transportBusy()
        var ownsSelection = false
        try {
            val original = synchronized(this) {
                synchronized(keepGuard) {
                    if (mode != "root") null
                    else taskResource.boundPeer ?: run {
                        if (transportUsers != 1 || restoring?.isDone == false || selectionChange != null)
                            return transportBusy()
                        selectingResource = true
                        ownsSelection = true
                        null
                    }
                }
            }
            rootSelected = true
            // A different family is an authorized temporary WSS path. Its transport reservation
            // prevents mode switching until finally; the current background peer remains untouched.
            val connected = if (original != null) original.takeIf { mayStart() && it.alive() }
                else root.start { mayStart() && !interruptRequested }
            return if (connected != null) mapOf("ok" to true)
                else mapOf("ok" to false, "reason" to rootReason())
        } finally {
            if (ownsSelection) synchronized(this) { selectingResource = false }
            endTransportUse()
            notifyChanged()
        }
    }

    fun rootGrantSelected(): Boolean = rootSelected

    /** Detach invalidates only the caller's unpublished UI attempt, not borrowed healthy channels. */
    fun cancelUnwantedPending() {
        // Seal the original lane before revoking its presentation probe. Published peers stay pinned.
        gate.cancelUnwantedPending()
        root.cancelUnwantedPending()
        shizuku.cancelUnwantedPending()
        adb.cancelUnwantedPending()
    }

    fun cancelRootSelection() {
        rootSelected = false
        // Revoke unpublished authorization now; a borrowed resource pin closes only after cleanup.
        root.cancelUnwantedPending()
    }

    private fun secureSettingsGranted(): Boolean =
        app.checkSelfPermission(SecureSettingsGrant.PERMISSION) == PackageManager.PERMISSION_GRANTED

    /** The RPC result isn't the answer: the permission itself is. An existing root connection is required. */
    fun grantRootSecureSettings(): Map<String, Any?> {
        if (!beginTransportUse()) return transportBusy()
        try {
            if (secureSettingsGranted()) return mapOf("ok" to true)
            val ran = root.grantSecureSettings()
            if (secureSettingsGranted()) return mapOf("ok" to true)
            return mapOf("ok" to false, "reason" to ((if (ran) null else rootReason()) ?: AppStrings.get(app, R.string.background_root_grant_failed)))
        } finally { endTransportUse() }
    }

    fun adbStartPairing(): Map<String, Any?> {
        if (!androidOk()) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_requires_android))
        return pairing.submit<Map<String, Any?>> {
            AdbPairingNotification.show(app)
            adb.startPairing()
        }.get()
    }

    fun adbPair(code: String, port: Int?): Map<String, Any?> = pairing.submit<Map<String, Any?>> { adb.pair(code, port) }.get()

    /** The code typed into the notification: paired after anything queued, its result shown from the queue. */
    fun adbPairFromNotification(code: String) {
        pairing.execute { AdbPairingNotification.showResult(app, adb.pair(code, null)) }
    }

    fun adbConnect(port: Int? = null, mayStart: () -> Boolean = { true }): Map<String, Any?> {
        if (!beginTransportUse()) return transportBusy()
        var ownsSelection = false
        try {
            if (!androidOk()) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_requires_android))
            if (port != null && port !in 1..65535)
                return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_adb_invalid_port))
            val original = synchronized(this) {
                synchronized(keepGuard) {
                    if (mode != "adb") null
                    else taskResource.boundPeer ?: run {
                        if (transportUsers != 1 || restoring?.isDone == false || selectionChange != null)
                            return transportBusy()
                        selectingResource = true
                        ownsSelection = true
                        null
                    }
                }
            }
            val connected = if (original != null) mayStart() && original.alive()
                else adb.connect(port, mayStart = { mayStart() && !interruptRequested }) != null
            return mapOf("ok" to connected, "reason" to if (connected) null else adb.reason())
        } finally {
            if (ownsSelection) synchronized(this) { selectingResource = false }
            endTransportUse()
            notifyChanged()
        }
    }

    // ---- 自动恢复无障碍 (WRITE_SECURE_SETTINGS through the engine) -------------

    /** The one-tap way to the permission right now ([SecureSettingsGrant.path]). */
    fun grantPath(granted: Boolean): String =
        if (granted) SecureSettingsGrant.GRANTED else SecureSettingsGrant.path(false, shizuku.status(), adb.status())

    /**
     * Has the engine grant the permission over [via] (`shizuku` / `adb`): 不打扰模式's channel when it
     * uses the same starter, else one opened for this and closed after. Blocks (an adb connect can
     * take seconds). Retains this attempt before closing any temporary channel.
     */
    fun grantSecureSettings(via: String, mayStart: () -> Boolean): SecureSettingsGrant.Attempt {
        if (!beginTransportUse()) return SecureSettingsGrant.Attempt.UNAVAILABLE
        try {
            if (!mayStart()) return SecureSettingsGrant.Attempt.CANCELLED
            val sharedApi = via == SecureSettingsGrant.SHIZUKU || via == SecureSettingsGrant.SUI
            val shared = PrivilegedPathPolicy.sharesGrantChannel(mode, via)
            val ch = when {
                shared -> activeChannel(mayStart, transportReserved = true)
                sharedApi -> shizuku.connect(mayStart = mayStart)
                else -> adb.connect(mayStart = mayStart)
            }
            try {
                // A connect may return null because the original UI lease was cancelled.
                if (!mayStart()) return SecureSettingsGrant.Attempt.CANCELLED
                if (ch == null) return SecureSettingsGrant.Attempt.UNAVAILABLE
                val request = Bundle().apply {
                    putString(Proto.OP, Proto.OP_GRANT_SECURE_SETTINGS)
                    putInt(Proto.USER, Process.myUid() / PER_USER_RANGE)
                }
                return runCatching {
                    val response = ch.execute(request)
                    SecureSettingsGrant.attempt(response.getBoolean(Proto.OK), response.getString(Proto.ERROR))
                }.getOrDefault(SecureSettingsGrant.Attempt.UNAVAILABLE)
            } finally {
                // Shared task channels remain owned by their task; only retire this temporary link.
                if (!shared) if (sharedApi) shizuku.disconnectIfCurrent(ch) else adb.disconnectIfCurrent(ch)
            }
        } finally { endTransportUse() }
    }

    fun requestShizukuPermission(then: () -> Unit): Boolean = shizuku.requestPermission(then)

    /** Read-only diagnostics: only the already selected live link; never starts a transport or gate. */
    fun collectSystemIme(mayStart: () -> Boolean): Map<String, Any?> {
        val evidence = com.skyjjgw.independent.ski.dshgo.diagnostics.SystemImeEvidence
        if (!mayStart()) return evidence.result("cancelled")
        if (PhoneControl.peek()?.tasks?.snapshot()?.active == true || taskResource.occupied)
            return evidence.result("busy")
        val selected = synchronized(keepGuard) {
            if (selectionChange != null || mode == "off") return evidence.result("unavailable")
            keep.selectionTicket() to channel
        }
        val ch = selected.second ?: return evidence.result("unavailable")
        if (!ch.alive()) return evidence.result("unavailable")
        val allowed = { mayStart() && selectionChange == null && keep.selectionCurrent(selected.first) && channel === ch }
        if (!allowed()) return evidence.result("cancelled")
        return try {
            val response = ch.execute(Bundle().apply {
                putString(Proto.OP, Proto.OP_COLLECT_SYSTEM_IME)
                putInt(Proto.IME_PID, Process.myPid())
                putLong(Proto.IME_REQUESTED_AT, System.currentTimeMillis())
            })
            if (!allowed()) return evidence.result("cancelled")
            val code = evidence.coreCode(response.getBoolean(Proto.OK), response.getString(Proto.ERROR))
            if (code != "ok" && code != "noEvents") return evidence.result(code)
            val at = response.getLong("capturedAt")
            if (at <= 0 || kotlin.math.abs(System.currentTimeMillis() - at) > 10_000)
                return evidence.result("failed")
            val times = response.getLongArray("imeTimes") ?: return evidence.result("failed")
            val events = response.getStringArray("imeEvents") ?: return evidence.result("failed")
            val users = response.getIntArray("imeFromUser") ?: return evidence.result("failed")
            val reasons = response.getStringArray("imeReasons") ?: return evidence.result("failed")
            val origins = response.getStringArray("imeOrigins") ?: return evidence.result("failed")
            if (times.size > evidence.MAX_EVENTS || listOf(events.size, users.size, reasons.size, origins.size).any { it != times.size })
                return evidence.result("failed")
            val safe = times.indices.map { i ->
                if (users[i] !in -1..1) return evidence.result("failed")
                com.skyjjgw.independent.ski.dshgo.diagnostics.SystemImeEvent(times[i], events[i],
                    when (users[i]) { 1 -> true; 0 -> false; else -> null }, reasons[i], origins[i])
            }
            if (safe.any { !evidence.valid(it, at) } || (code == "noEvents") != safe.isEmpty())
                return evidence.result("failed")
            evidence.result(code, at, safe)
        } catch (_: Exception) { evidence.result(if (mayStart()) "unavailable" else "cancelled") }
    }

    // ---- task lifecycle (called by the bridge/core) ------------------------

    /** Sessions calls this outside registry/Tasks/worker locks, before acquiring BG leases. */
    internal fun prepareForTask(owner: PhoneTasks.Owner, currentOwner: () -> Boolean): String? {
        if (!currentOwner()) return AppStrings.get(app, R.string.background_selection_cancelled)
        if (mode == "off" || !androidOk()) return unavailableReason()
        synchronized(this) {
            // Reuse does not create a slot or replace a peer. Other WSS users must not revoke it.
            if (taskResource.find(owner) != null) return null
        }
        if (keep.enabled && (channel?.backgroundLimit ?: 0) == 0) {
            try { restoreKeptChannel()?.get() } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return AppStrings.get(app, R.string.background_selection_cancelled)
            } catch (_: Exception) { return AppStrings.get(app, R.string.background_not_ready) }
        }
        if (activeChannel(currentOwner) == null || parallelism().effectiveLimit == 0) return unavailableReason()
        return null
    }

    /** The status reason, else the starter's own failed-connect stage; never a self-check verdict. */
    private fun unavailableReason(): String = readiness()
        ?: (if (mode == "shizuku" || mode == "sui") shizuku.connectReasonCode else null)
            ?.let { AppStrings.get(app, setupFailureResource(it)) }
        ?: AppStrings.get(app, R.string.background_not_ready)

    /** Read-only original record lookup. No bootstrap, slot acquisition, IPC or target change. */
    fun existingReplayDriver(owner: PhoneTasks.Owner, app: PhoneAppIdentity,
                             currentOwner: () -> Boolean): BackgroundDisplay? {
        fun current() = owner.active && currentOwner() && !Thread.currentThread().isInterrupted
        if (!current() || mode == "off" || !androidOk()) return null
        val record = synchronized(this) {
            synchronized(keepGuard) {
                if (selfCheckBorrow != null || interruptRequested || selectingResource ||
                    restoring?.isDone == false || selectionChange != null) return null
                taskResource.find(owner)?.takeIf { channel === it.peer } ?: return null
            }
        }
        // mayUse consults the original Tasks owner; never call it under controller/keep locks.
        // The driver inspects its original peer/IO state without platform calls.
        if (!record.driver.existingReplayTarget(app) || !current()) return null
        return synchronized(this) {
            synchronized(keepGuard) {
                if (mode == "off" || channel !== record.peer || !taskResource.current(record) ||
                    selfCheckBorrow != null || interruptRequested || selectingResource ||
                    restoring?.isDone == false || selectionChange != null) null else record.driver
            }
        }
    }

    /** The lease already exists. The actual channel returned here becomes this driver's peer. */
    fun driverForTask(owner: PhoneTasks.Owner, currentOwner: () -> Boolean,
                      admitOwner: ((() -> Unit) -> Boolean)): BackgroundDisplay? {
        fun current() = currentOwner() && !Thread.currentThread().isInterrupted
        if (mode == "off" || !androidOk()) return null
        val selection = synchronized(this) {
            synchronized(keepGuard) {
                if (selfCheckBorrow != null || interruptRequested || !current()) return null
                taskResource.find(owner)?.let { return it.driver }
                if (selectingResource || restoring?.isDone == false || selectionChange != null) return null
                keep.selectionTicket()
            }
        }
        fun allowed() = current() && keep.selectionCurrent(selection)
        // Bootstrap before the lease was only preparation. Capture this invocation's actual peer;
        // no controller monitor is held while checking or establishing the authorized channel.
        val peer = activeChannel(::allowed) ?: return null
        val ocr = MlKitLocalOcr.get(app) // First preference read stays outside resource monitors.
        val acquired = synchronized(this) {
            synchronized(keepGuard) {
                if (!allowed() || channel !== peer || selfCheckBorrow != null || interruptRequested ||
                    selectingResource || restoring?.isDone == false || selectionChange != null) return null
                lateinit var record: BackgroundTaskSlot.TaskResource<BackgroundDisplay, PrivilegedChannel>
                record = taskResource.acquire(owner, peer, peer.backgroundLimit, ::allowed) {
                    BackgroundDisplay(
                        channelProvider = { peer },
                        mayUse = { currentOwner() && !interruptRequested },
                        admitUse = { action -> admitOwner { check(!interruptRequested); action() } },
                        viewport = viewport,
                        localOcr = ocr,
                        localOcrAllowed = { target -> localOcrAllowed(target) },
                        onResourceReady = { publishPreviewTarget(record, it) },
                    )
                } ?: return null
                record
            }
        }
        notifyChanged()
        return acquired.driver
    }

    /** Immediately seals every selected original; null explicitly means all. */
    fun sealTask(expectedTaskId: Long? = null) {
        var changed = false
        synchronized(this) {
            for (record in taskResource.seal(expectedTaskId)) {
                record.driver.seal()
                changed = withdrawPreviewTarget(record.driver) || changed
            }
        }
        if (changed) onPreviewChanged()
    }

    /**
     * Seal the whole batch before releasing any member. Every record leaves its slot: a release
     * that is not confirmed disconnects that channel instead of keeping the slot (and the switch,
     * and every later task) waiting on a receipt that may never come.
     */
    fun endTask(expectedTaskId: Long? = null) {
        var previewChanged = false
        val captured = synchronized(this) {
            taskResource.seal(expectedTaskId).onEach {
                it.driver.seal()
                previewChanged = withdrawPreviewTarget(it.driver) || previewChanged
            }
        }
        if (previewChanged) onPreviewChanged()
        for (record in captured) {
            if (!record.driver.release()) discardPeer(record.peer)
            taskResource.complete(record)
        }
        if (captured.isNotEmpty()) notifyChanged()
        finishInterrupt()
    }

    /** Keep the gate closed until the logical stop batch has committed outside controller locks. */
    fun requestInterrupt(stopTasks: () -> Unit) {
        var changed = false
        synchronized(this) {
            interruptStopping = true
            gate.changeIntent { interruptRequested = true }
            for (record in taskResource.seal()) {
                record.driver.seal()
                changed = withdrawPreviewTarget(record.driver) || changed
            }
        }
        if (changed) onPreviewChanged()
        // The screen-off caller has already stopped the self-check Run. Do not move that
        // cancellation past this boundary: its beforeSend commits under the original Run lock.
        stopTasks()
        synchronized(this) { interruptStopping = false }
        // The caller schedules finishInterrupt on its existing cleanup executor, never on main.
    }

    fun finishInterrupt() {
        synchronized(this) {
            if (!interruptRequested || interruptStopping || interruptFinishing || taskResource.occupied || selectingResource) return
            synchronized(keepGuard) {
                if (selfCheckBorrow != null || transportUsers != 0 || restoring != null || selectionChange != null) return
                interruptFinishing = true
            }
        }
        var disconnected = false
        try {
            disconnectAll(PrivilegedPathPolicy::closesOnInterrupt)
            disconnected = true
        } finally {
            synchronized(this) {
                // Merge overlapping screen-off intents only after the latest logical stop
                // has returned. No new resource can publish while requested stays true.
                // Clearing finishing in this SAME commit prevents a lost cleanup wake-up.
                if (disconnected && !interruptStopping) interruptRequested = false
                interruptFinishing = false
            }
            notifyChanged()
        }
    }

    // ---- channel plumbing --------------------------------------------------

    private fun activeChannel(mayStart: () -> Boolean = { true }, explicit: Boolean = false,
                              transportReserved: Boolean = false): PrivilegedChannel? {
        if (!transportReserved && !beginTransportUse()) return null
        var ownsSelection = false
        var previewChanged = false
        try {
            if (!mayStart() || interruptRequested) return null
            val (selection, cached, bound) = synchronized(this) {
                synchronized(keepGuard) {
                    if (selectionChange != null) return null
                    Triple(keep.selectionTicket(), channel, taskResource.boundPeer)
                }
            }
            // Starter guards may call this; the predicate must not acquire controller locks.
            val allowed = { mayStart() && !interruptRequested && selectionChange == null && keep.selectionCurrent(selection) }
            val selected = selection.mode
            if ((selected == "shizuku" || selected == "sui") && shizuku.status().provider != selected) return null
            val observed = gate.snapshot
            if (bound != null && cached !== bound) return null
            if (cached?.alive() == true) return synchronized(this) {
                synchronized(keepGuard) {
                    if (!allowed() || channel !== cached) null
                    else { gate.connected(observed, cached); cached }
                }
            }
            // A live task's peer is never replaced under it; that task's end releases the slot.
            if (bound != null || !allowed() || keep.enabled && !explicit) return null
            synchronized(this) {
                synchronized(keepGuard) {
                    if (!allowed() || taskResource.occupied || selfCheckBorrow != null ||
                        transportUsers != 1 || restoring?.isDone == false || selectionChange != null) return null
                    if (!selectingResource) {
                        selectingResource = true
                        ownsSelection = true
                    }
                    // Otherwise the explicit settings caller owns the same existing reservation.
                }
            }
            if (ownsSelection) notifyChanged()
            val connected = when (selected) {
                // A refused older service (still running from before an App update) was unbound with
                // removal by that refusal; the one retry binds the current APK's service.
                "shizuku", "sui" -> shizuku.connect(mayStart = allowed)
                    ?: if (shizuku.connectReasonCode == "protocolMismatch") shizuku.connect(mayStart = allowed) else null
                "root" -> root.connect()
                "adb" -> adb.connect(mayStart = allowed)
                else -> null
            } ?: return null
            return synchronized(this) {
                synchronized(keepGuard) {
                    if (!allowed()) null else {
                        previewChanged = replaceChannel(connected)
                        gate.connected(observed, connected)
                        connected
                    }
                }
            }
        } finally {
            if (ownsSelection) synchronized(this) { selectingResource = false }
            if (previewChanged) onPreviewChanged()
            if (!transportReserved) endTransportUse()
            if (ownsSelection) notifyChanged()
        }
    }

    private fun disconnectAll(closes: (String) -> Boolean = { true }) {
        val changed = synchronized(this) { synchronized(keepGuard) { replaceChannel(null) } }
        if (changed) onPreviewChanged()
        disconnectTransports(closes)
    }

    private fun disconnectTransports(closes: (String) -> Boolean) {
        if (closes("shizuku")) shizuku.disconnect()
        if (closes("adb")) adb.disconnect()
        if (closes("root")) root.disconnect()
    }

    /**
     * Settings owns one outer transport use. Connects the selected channel; a failure here is the
     * only result. The input self-check after it is a diagnostic for the settings page.
     */
    private fun connectAndCheck(selection: PrivilegedKeepState.Ticket, mayStart: () -> Boolean): String? {
        when (mode) {
            "shizuku", "sui" -> shizuku.reason()
            "root" -> rootReason()
            "adb" -> adb.reason()
            else -> AppStrings.get(app, R.string.background_off)
        }?.let { return it }
        var peer = activeChannel(mayStart, explicit = true, transportReserved = true)
        if (peer != null && !peer.alive() && selection.mode == "root" && mayStart()) {
            // Reached only from the user's explicit setBackgroundMode: a dead root peer restarts here.
            root.start(mayStart)?.let { fresh ->
                val changed = synchronized(this) {
                    synchronized(keepGuard) { mayStart() && replaceChannel(fresh) }
                }
                if (changed) onPreviewChanged()
            }
            peer = activeChannel(mayStart, explicit = true, transportReserved = true)
        }
        if (peer == null) {
            val reason = setupFailureResource(
                if (selection.mode == "shizuku" || selection.mode == "sui") shizuku.connectReasonCode else null)
            gate.connectionFailed(reason, mayStart)
            notifyChanged()
            return AppStrings.get(app, reason)
        }
        selfCheck(peer, mayStart)
        return null
    }

    /**
     * One input self-check on its own owner scope. Its outcome only updates [gate]'s snapshot. A
     * release that is not confirmed discards the channel; no state waits for a cleanup receipt.
     */
    private fun selfCheck(peer: PrivilegedChannel, mayStart: () -> Boolean) {
        val probe = gate.begin(mayStart) ?: return
        val io = BackgroundDisplayIo<PrivilegedChannel>()
        try {
            io.call {
                val reply = OwnerScopeProtocol.first(io, peer, Bundle().apply {
                    putString(Proto.OP, Proto.OP_SELF_CHECK_PROBE)
                    putString(Proto.OWNER, io.owner)
                    putInt(Proto.SELF_CHECK_PROBE_VERSION, 1)
                    putInt(Proto.RELEASE_RECEIPT, 1)
                }) { commit -> gate.admit(probe, commit) }
                if (io.wasNotAdmitted()) return@call
                val result = gate.updateStrict(probe, io.owner, reply.get(Proto.OWNER),
                    reply.get(Proto.SELF_CHECK_PROBE_VERSION), reply.get(Proto.OK),
                    reply.get(Proto.SELF_CHECK_DISPLAY_READY), reply.get(Proto.INJECT_OK),
                    reply.get(Proto.ERROR), reply.get(Proto.INJECT_ERROR), reply.get(Proto.ERROR_DETAIL))
                if (result == BackgroundGateState.Update.Invalid) gate.failed(probe, R.string.background_no_response, peer)
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        } catch (_: Exception) {
            gate.failed(probe, R.string.background_no_response, peer)
        } finally {
            val released = try { io.release { OwnerScopeProtocol.release(it, io.owner) } } catch (_: Exception) { false }
            if (!released) discardPeer(peer)
            notifyChanged()
        }
    }

    // ---- explicit channel keep consent and event-driven recovery ------------

    /** Main-thread intent boundary. The returned ticket is persisted on the short control queue. */
    internal fun changeKeep(selected: String, enabled: Boolean): Pair<PrivilegedKeepState.Ticket?, String?> {
        val failure = when {
            enabled && !androidOk() -> "unsupportedAndroid"
            enabled && !PhoneControl.switchedOn(app) -> "phoneDisabled"
            else -> null
        }
        if (failure != null) return null to failure
        // Checked under the guard keep.select takes: an off or a switch queued just before this tap
        // either lands first (selectionChanged) or resets this consent, never leaves the old mode kept.
        val ticket = synchronized(keepGuard) {
            if (selected != mode || selected !in PrivilegedKeepState.MODES) null
            else gate.changeIntent { keep.configure(if (enabled) selected else "off") }
        } ?: return null to "selectionChanged"
        cancelUnwantedPending()
        if (!enabled) { updateKeepListeners(); PrivilegedKeepJob.cancel(app) }
        notifyChanged()
        return ticket to null
    }

    /** A previously disabled phone must not revive an old persisted keep on the next process start. */
    internal fun preparePhoneEnable(): Boolean = PhoneControl.switchedOn(app) || saveKeep(clearKeep())["ok"] == true

    internal fun clearKeepForMode(requested: String): PrivilegedKeepState.Ticket? {
        cancelUnwantedPending()
        val selected = PrivilegedPathPolicy.canonicalMode(requested, shizuku.status().provider)
        return if (selected != mode || selected == "off") clearKeep() else null
    }

    /** Called immediately on mode/off intents, before any queued or blocked transport operation. */
    internal fun clearKeep(): PrivilegedKeepState.Ticket {
        val ticket = synchronized(keepGuard) { gate.changeIntent { keep.configure("off") } }
        cancelUnwantedPending()
        updateKeepListeners()
        PrivilegedKeepJob.cancel(app)
        notifyChanged()
        return ticket
    }

    internal fun saveKeep(ticket: PrivilegedKeepState.Ticket): Map<String, Any?> {
        val ok: Boolean
        val accepted: Boolean
        synchronized(preferenceGuard) {
            if (!keep.saving(ticket)) return keepFailure("selectionChanged")
            ok = keepPrefs.edit().putString("keptMode", ticket.mode).commit()
            accepted = synchronized(keepGuard) { keep.saved(ticket, ok) }
        }
        if (!accepted) return keepFailure(if (ok) "selectionChanged" else "persistenceFailed")
        updateKeepListeners()
        if (keep.enabled) restoreKeptChannel()
        notifyChanged()
        return mapOf("ok" to true)
    }

    internal fun keepFailure(code: String): Map<String, Any?> = mapOf("ok" to false, "reasonCode" to code,
        "reason" to AppStrings.get(app, when (code) {
            "phoneDisabled" -> R.string.background_keep_phone_disabled
            "unsupportedAndroid" -> R.string.background_requires_android
            "persistenceFailed" -> R.string.background_keep_save_failed
            else -> R.string.background_selection_cancelled
        }))

    /** Foreground/start/BOOT hook; existing explicit keep consent only. */
    fun restoreKeptChannel(): Future<PrivilegedChannel?>? {
        if (interruptRequested || !PhoneControl.switchedOn(app) || !androidOk() || !keep.enabled) return null
        updateKeepListeners()
        synchronized(this) {
            synchronized(keepGuard) {
                if (interruptRequested || selectingResource || selectionChange != null || selfCheckBorrow != null ||
                    transportUsers != 0) return null
                restoring?.let {
                    if (restoringTicket?.let(keep::current) != true) restoreAgain = true
                    return it
                }
                val ticket = keep.begin(SystemClock.elapsedRealtime()) ?: return null
                // The same monitor protects both this reservation and future slot publication.
                // A queued restore retains this exact peer even if its last record later clears.
                val original = taskResource.boundPeer
                val task = FutureTask { restore(ticket, original) }
                restoring = task
                restoringTicket = ticket
                recovery.execute {
                    try { task.run() } finally {
                        val again = synchronized(keepGuard) {
                            restoring = null; restoringTicket = null
                            restoreAgain.also { restoreAgain = false }
                        }
                        finishInterrupt()
                        if (again) {
                            synchronized(keepGuard) { keep.available(ticket) }
                            restoreKeptChannel()
                        }
                    }
                }
                return task
            }
        }
    }

    private fun restore(ticket: PrivilegedKeepState.Ticket, original: PrivilegedChannel?): PrivilegedChannel? {
        val observed = gate.snapshot
        var failure: String? = "connectFailed"
        var waiting = false
        var value: PrivilegedChannel? = null
        var previewChanged = false
        fun allowed() = !interruptRequested && !selectingResource && keep.current(ticket)
        try {
            if (!allowed()) return null
            value = if (original != null) {
                // No fallback start/connect, even when this original is now dead or unknown.
                original.takeIf { it.alive() }
            } else when (ticket.mode) {
                "root" -> root.start { allowed() }.also {
                    if (it == null) failure = root.status().reasonCode ?: "restoreBusy"
                }
                "sui", "shizuku" -> {
                    val facts = shizuku.status()
                    failure = when {
                        !facts.running -> "serviceUnavailable"
                        facts.provider != ticket.mode -> "providerChanged"
                        !facts.granted -> "permissionRequired"
                        else -> null
                    }
                    if (failure != null) { waiting = true; null }
                    else shizuku.connect(whenAvailable = { recoveryAvailable(ticket) }, mayStart = { allowed() })
                        .also { if (it == null) failure = "connectFailed" }
                }
                "adb" -> {
                    val facts = adb.status()
                    if (!facts.paired) { waiting = true; failure = "notPaired"; null }
                    else if (!wifiAvailable()) { waiting = true; failure = "networkUnavailable"; null }
                    else {
                        enableWirelessOnce(ticket, facts.wirelessDebugging)
                        adb.connect(whenAvailable = { recoveryAvailable(ticket) }, mayStart = { allowed() })
                            .also { if (it == null) failure = "connectFailed" }
                    }
                }
                else -> null
            }
            val connected = value?.takeIf { it.alive() }
            synchronized(this) {
                synchronized(keepGuard) {
                    if (selectionChange == null && allowed() && connected != null) {
                        previewChanged = replaceChannel(connected)
                        gate.connected(observed, connected)
                    }
                }
            }
            return value?.takeIf { allowed() && it.alive() }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return null
        } catch (_: Exception) {
            return null
        } finally {
            if (previewChanged) onPreviewChanged()
            val alive = value?.alive() == true
            synchronized(keepGuard) { keep.complete(ticket, alive, failure, waiting, SystemClock.elapsedRealtime()) }
            notifyChanged()
        }
    }

    /** Only a connect rejected by an older busy owner can register this one-shot callback. */
    private fun recoveryAvailable(ticket: PrivilegedKeepState.Ticket) {
        val run = synchronized(keepGuard) {
            if (!keep.current(ticket)) return
            if (restoring != null) { restoreAgain = true; false }
            else { keep.available(ticket); true }
        }
        if (run) restoreKeptChannel()
    }

    private fun transportChanged(source: String) {
        if (mode == source || source == "sharedApi" && mode in setOf("sui", "shizuku")) {
            recovery.execute {
                // Platform liveness checks stay outside the preview/controller monitors.
                val dead = previewTargets.values.filter { !it.channel.alive() }
                val removed = synchronized(previewGuard) {
                    val ids = dead.filter { previewTargets[it.taskId] === it }.map { it.taskId }
                    if (ids.isEmpty()) false else { previewTargets = previewTargets - ids.toSet(); true }
                }
                if (removed) onPreviewChanged()
            }
        }
        notifyChanged()
        if (keep.enabled && (mode == source || source == "sharedApi" && mode in setOf("sui", "shizuku")))
            restoreKeptChannel()
    }

    private fun wifiAvailable(): Boolean = runCatching {
        val cm = app.getSystemService(ConnectivityManager::class.java)
        cm.allNetworks.any { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true }
    }.getOrDefault(false)

    private fun enableWirelessOnce(ticket: PrivilegedKeepState.Ticket, wireless: Boolean?) {
        if (wireless == true || !secureSettingsGranted()) return
        if (runCatching { Settings.Global.getInt(app.contentResolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) }.getOrDefault(0) != 1) return
        if (keep.takeWirelessAttempt(ticket)) runCatching { Settings.Global.putInt(app.contentResolver, "adb_wifi_enabled", 1) }
    }

    private fun updateKeepListeners() {
        if (keep.enabled && mode in setOf("shizuku", "sui")) shizuku.ensureListeners()
        synchronized(networkGuard) {
            val cm = app.getSystemService(ConnectivityManager::class.java)
            if (keep.enabled && mode == "adb") {
                if (networkCallback == null) {
                    val callback = object : ConnectivityManager.NetworkCallback() {
                        override fun onAvailable(network: Network) {
                            notifyChanged()
                            val current = synchronized(networkGuard) { networkCallback === this }
                            if (current && keep.enabled && mode == "adb") restoreKeptChannel()
                        }
                        override fun onLost(network: Network) { notifyChanged() }
                    }
                    runCatching {
                        cm.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), callback)
                        networkCallback = callback
                    }
                }
            } else {
                networkCallback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
                networkCallback = null
            }
        }
    }

    companion object {
        /** UserHandle.PER_USER_RANGE: a uid's user is uid / this. */
        private const val PER_USER_RANGE = 100_000

        @Volatile private var instance: BackgroundControl? = null
        fun get(context: Context): BackgroundControl =
            instance ?: synchronized(this) {
                instance ?: BackgroundControl(context).also { instance = it }
            }
    }
}
