package com.skyjjgw.independent.ski.dshgo.phone

import com.skyjjgw.independent.ski.dshgo.i18n.AppStrings
import android.app.Application
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import com.skyjjgw.independent.ski.MainActivity
import com.skyjjgw.independent.ski.R
import com.skyjjgw.independent.ski.dshgo.notify.LiveActivity
import com.skyjjgw.independent.ski.dshgo.phone.a11y.A11yKeeper
import com.skyjjgw.independent.ski.dshgo.phone.a11y.MlKitLocalOcr
import com.skyjjgw.independent.ski.dshgo.phone.a11y.PhoneA11yService
import com.skyjjgw.independent.ski.dshgo.phone.background.BackgroundControl
import com.skyjjgw.independent.ski.dshgo.phone.background.BackgroundPreview
import com.skyjjgw.independent.ski.dshgo.phone.background.SecureSettingsGrant
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillReplayApps
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillReplaySelections
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillOutcomes
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillDrafts
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillBridge
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillLifecycle
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneTaskTrace
import com.skyjjgw.independent.ski.dshgo.runtime.RuntimeController
import com.skyjjgw.independent.ski.dshgo.runtime.DshService
import com.skyjjgw.independent.ski.dshgo.shortcuts.EntryActivity
import java.io.File
import java.time.ZoneId
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Process-wide owner of phone control on Android: the master switch and app lists (prefs), the
 * bridge's lifecycle around the engine (started before DSH launches, stopped when it exits, never
 * in safe mode), the [PhoneEnv] the core runs against, the task's status line, the screen-off
 * stop, and the status pushed to Flutter. [com.skyjjgw.independent.ski.dshgo.runtime.RuntimeController]
 * calls [prepareLaunch] / [launched] / [onEngineReady] / [onEngineStopped].
 */
class PhoneControl private constructor(private val app: Context) : PhoneEnv, ControlListener {
    private val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    @Volatile private var policiesCache: PhonePolicies = readPolicies()
    private val main = Handler(Looper.getMainLooper())
    private val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val ticker = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "dsh-phone-status").apply { isDaemon = true } }

    private val taskIds = java.util.concurrent.atomic.AtomicLong()
    private val cleanupIo = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-phone-cleanup").apply { isDaemon = true } }

    private val taskJournal = PhoneTaskJournal(
        read = { app.getSharedPreferences("phone_task_journal", Context.MODE_PRIVATE).getString("records", null) },
        commit = { value -> app.getSharedPreferences("phone_task_journal", Context.MODE_PRIVATE)
            .edit().putString("records", value).commit() },
    )

    val tasks = PhoneTasks(clock = SystemClock::elapsedRealtime, idSource = taskIds::incrementAndGet)
    val log = ActionLog()
    val system = SystemActions(app)
    private val localizedUi = PhoneUiText { key, args ->
        when (key) {
            "phone_log_clipboard_write" -> return@PhoneUiText AppStrings.plural(app, R.plurals.phone_log_clipboard_write, args[0] as Int, *args.toTypedArray())
            "phone_log_type" -> return@PhoneUiText AppStrings.plural(app, R.plurals.phone_log_type, args[2] as Int, *args.toTypedArray())
        }
        val id = when (key) {
            "phone_shell_confirm" -> R.string.phone_shell_confirm
            "phone_waived_status" -> R.string.phone_waived_status
            "phone_move_background" -> R.string.phone_move_background
            "phone_opening_background" -> R.string.phone_opening_background
            "phone_reading_background" -> R.string.phone_reading_background
            "phone_reading_screen" -> R.string.phone_reading_screen
            "phone_system_handler_unconfirmed" -> R.string.phone_system_handler_unconfirmed
            "phone_system_attempt_stopped" -> R.string.phone_system_attempt_stopped
            "phone_system_review_notice" -> R.string.phone_system_review_notice
            "phone_system_review_unavailable" -> R.string.phone_system_review_unavailable
            "phone_system_review_timeout" -> R.string.phone_system_review_timeout
            "phone_system_review_continued" -> R.string.phone_system_review_continued
            "phone_reading_list" -> R.string.phone_reading_list
            "phone_acting" -> R.string.phone_acting
            "phone_status_tap" -> R.string.phone_status_tap
            "phone_status_long_tap" -> R.string.phone_status_long_tap
            "phone_status_type" -> R.string.phone_status_type
            "phone_status_scroll" -> R.string.phone_status_scroll
            "phone_status_tap_xy" -> R.string.phone_status_tap_xy
            "phone_status_coordinate" -> R.string.phone_status_coordinate
            "phone_status_key" -> R.string.phone_status_key
            "phone_status_press" -> R.string.phone_status_press
            "phone_key_back" -> R.string.phone_key_back
            "phone_key_home" -> R.string.phone_key_home
            "phone_key_recents" -> R.string.phone_key_recents
            "phone_key_notifications" -> R.string.phone_key_notifications
            "phone_confirm_first_app" -> R.string.phone_confirm_first_app
            "phone_confirm_element" -> R.string.phone_confirm_element
            "phone_confirm_tap" -> R.string.phone_confirm_tap
            "phone_confirm_long_tap" -> R.string.phone_confirm_long_tap
            "phone_confirm_type" -> R.string.phone_confirm_type
            "phone_confirm_submit" -> R.string.phone_confirm_submit
            "phone_confirm_tap_xy" -> R.string.phone_confirm_tap_xy
            "phone_confirm_background_coordinate" -> R.string.phone_confirm_background_coordinate
            "phone_confirm_visual_main" -> R.string.phone_confirm_visual_main
            "phone_confirm_visual_background" -> R.string.phone_confirm_visual_background
            "phone_confirm_coordinate_long" -> R.string.phone_confirm_coordinate_long
            "phone_confirm_coordinate_swipe" -> R.string.phone_confirm_coordinate_swipe
            "phone_confirm_scroll" -> R.string.phone_confirm_scroll
            "phone_confirm_key" -> R.string.phone_confirm_key
            "phone_current_app" -> R.string.phone_current_app
            "phone_log_apps" -> R.string.phone_log_apps
            "phone_log_apps_filtered" -> R.string.phone_log_apps_filtered
            "phone_log_open_url" -> R.string.phone_log_open_url
            "phone_log_open_url_scheme" -> R.string.phone_log_open_url_scheme
            "phone_log_open_app" -> R.string.phone_log_open_app
            "phone_log_system_returned_success" -> R.string.phone_log_system_returned_success
            "phone_log_system_returned_failure" -> R.string.phone_log_system_returned_failure
            "phone_log_open_background" -> R.string.phone_log_open_background
            "phone_log_notify" -> R.string.phone_log_notify
            "phone_log_clipboard_read" -> R.string.phone_log_clipboard_read
            "phone_log_background_read" -> R.string.phone_log_background_read
            "phone_log_screen_read" -> R.string.phone_log_screen_read
            "phone_log_collect" -> R.string.phone_log_collect
            "phone_log_scroll" -> R.string.phone_log_scroll
            "phone_log_tap_xy" -> R.string.phone_log_tap_xy
            "phone_log_coordinate" -> R.string.phone_log_coordinate
            "phone_log_key" -> R.string.phone_log_key
            "phone_log_handoff" -> R.string.phone_log_handoff
            "phone_log_long_tap" -> R.string.phone_log_long_tap
            "phone_log_tap" -> R.string.phone_log_tap
            "phone_log_submit" -> R.string.phone_log_submit
            "phone_log_type_secret" -> R.string.phone_log_type_secret
            "phone_role_button" -> R.string.phone_role_button
            "phone_role_input" -> R.string.phone_role_input
            "phone_role_list" -> R.string.phone_role_list
            "phone_role_switch" -> R.string.phone_role_switch
            "phone_role_checkbox" -> R.string.phone_role_checkbox
            "phone_role_radio" -> R.string.phone_role_radio
            "phone_role_slider" -> R.string.phone_role_slider
            "phone_role_dropdown" -> R.string.phone_role_dropdown
            "phone_role_link" -> R.string.phone_role_link
            "phone_role_tab" -> R.string.phone_role_tab
            "phone_role_image" -> R.string.phone_role_image
            "phone_role_text" -> R.string.phone_role_text
            else -> null
        }
        id?.let { AppStrings.get(app, it, *args.toTypedArray()) }
    }

    override fun uiText(): PhoneUiText = localizedUi

    val skillTrace = PhoneTaskTrace()
    internal val skillDrafts = PhoneSkillDrafts()
    internal val skillReplaySelections = com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillReplaySelections(SystemClock::elapsedRealtime)
    private val skillReplayOutcomes = PhoneSkillOutcomes(
        read = { prefs.getString("skillReplayOutcomesV1", null) },
        commit = { prefs.edit().putString("skillReplayOutcomesV1", it).commit() },
        process = java.util.UUID.randomUUID().toString().replace("-", ""))
    private val skillLifecycle = PhoneSkillLifecycle(skillTrace, skillDrafts)
    internal val skillBridge = PhoneSkillBridge(skillDrafts,
        { write, done -> RuntimeController.get(app).savePhoneSkill(write, done) }, ::emitStatus,
        check = { binding, publication, done ->
            val origin = binding.origin
            if (origin == null) done(com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillInstallResult.BundleUnverified(
                binding.identity, publication, com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillBundleInstaller.Verification.ORIGIN_UNAVAILABLE))
            else origin.runtime.checkPhoneSkillSave(binding, publication, done)
        })
    private val displaySelection = PhoneDisplaySelection()
    private val legacyObservations = PhoneTaskObservations(tasks)
    val core = PhoneCore(this, tasks, log, skillTrace = skillTrace,
        onExecution = { owner -> selectExecution(tasks, owner) })
    val notificationGate = NotificationGate(app) { text, ifCurrent -> setStatusLine(text, ifCurrent) }
    val prompts: PhonePrompts = PhonePrompts(app, tasks, ::isEnabled, ::isLocked, notificationGate, ::reopen, displaySelection) { id, session ->
        sessions.task(id)?.takeIf { it.sessionId == null || it.sessionId == session }?.tasks
    }
    private val sessions = PhoneTaskSessions(SystemClock::elapsedRealtime, taskIds::incrementAndGet, ::createSessionCore, tasks, core, ::emitStatus,
        { task -> if (task.sessionId != null) onSessionTask(task.tasks, task.tasks.snapshot()) },
        settleResources = { taskId -> background.endTask(taskId) },
        dispatchCleanup = { action ->
            if (Looper.myLooper() == Looper.getMainLooper()) cleanupIo.execute(action) else action()
        },
        journal = taskJournal,
        backgroundCapacity = { background.parallelism().effectiveLimit },
        screenRecoveryReady = { isEnabled() && !isLocked() },
        prepareBackground = { task, owner -> background.prepareForTask(owner) { task.tasks.isCurrent(owner) } },
        startSkillScope = skillLifecycle::startManaged,
        completeSkillScope = skillLifecycle::completeDrained,
        cancelScope = { record, state ->
            // Registry admission stays sealed until these lock-free side effects finish.
            background.sealTask(state.id)
            shell.cancel(state.id)
            if (state.stopped) record.activeWorker?.interruptCurrent(record.tasks)
            prompts.stopTask(record.tasks)
        })
    private val server = McpServer(PhoneToolCatalog.listJson(), { name, args, _ -> sessions.run(sessions.admit(null), name, args) }, SERVER_VERSION)
    private val bridge = PhoneBridge(server, { line -> logger(line) }, { call ->
        if (call.name == PhoneCore.REPLAY) replayWork(call) else {
        val admission = sessions.admit(call.caller)
        val nativeReplyCommit = PhoneReplyCommit()
        PhoneCallWork(
            invoke = { call.runWithCommit(nativeReplyCommit) { name, args, _ -> sessions.run(admission, name, args) } },
            remainingMs = { sessions.remainingMs(admission) },
            expiredReply = { call.run { _, _, _ -> sessions.expire(admission) } },
            nativeReplyCommit = nativeReplyCommit,
        )
        }
    }, { end ->
        try {
            val task = sessions.admitEnd(end.sessionId, end.runId, end.completion)
            PhoneBridge.EndWork(end.ack()) {
                if (task != null) { background.sealTask(task.tasks.snapshot().id); sessions.settleEnd(task) }
            }
        } catch (_: PhoneTaskSessions.CapacityExceeded) {
            PhoneBridge.EndWork(McpServer.error(end.id, -32000, PhoneTaskSessions.CAPACITY_MESSAGE)) {}
        }
    })

    /** Private prepared invocation only; status/cancel/duplicates never take a Task admission. */
    private fun replayWork(call: McpServer.Dispatch.Call): PhoneCallWork {
        fun reply(value: Map<String, Any?>) = PhoneCallWork({ call.run { _, _, _ ->
            // Internal debt recovery is not a grant to query/execute an old source. Even a
            // rejected/retired invocation can trigger it on the existing call executor.
            skillReplaySelections.retryAccounting(skillReplayOutcomes)
            PhoneSkillReplaySelections.output(value)
        } })
        fun rejected() = reply(mapOf("v" to 1, "state" to "rejected", "stepDispatch" to "not_dispatched",
            "completedSteps" to 0, "cancelRequested" to false, "reason" to "没有匹配的本机当前路线准备，未执行。")) // l10n:keep replay result
        if (call.args.keys != setOf("operation", "invocation")) return rejected()
        val operation = call.args["operation"] as? String ?: return rejected()
        if (operation !in setOf("start", "status", "cancel")) return rejected()
        val id = (call.args["invocation"] as? String)?.takeIf { it.matches(Regex("[a-f0-9]{32}")) } ?: return rejected()
        val caller = call.caller?.takeIf { it.runLifecycle == 1 } ?: return rejected()
        val selection = skillReplaySelections.find(id) ?: return rejected()
        if (!selection.sourceCurrent()) return rejected()
        if (operation != "start") {
            skillReplaySelections.control(selection, caller, operation == "cancel") ?: return rejected()
            return PhoneCallWork({ call.run { _, _, _ ->
                skillReplaySelections.retryAccounting(skillReplayOutcomes)
                PhoneSkillReplaySelections.output(skillReplaySelections.snapshot(selection))
            } })
        }
        // Native static registration stays empty until 3255 device/compatibility evidence permits it.
        if (selection.bundle.route.descriptorId !in PhoneSkillReplayApps.descriptors) return rejected()
        when (val claim = skillReplaySelections.claim(selection, caller)) {
            PhoneSkillReplaySelections.Claim.Refused -> return rejected()
            is PhoneSkillReplaySelections.Claim.Existing -> return reply(claim.result)
            is PhoneSkillReplaySelections.Claim.Start -> Unit
        }
        val admission = try { sessions.admit(caller) } catch (_: Exception) {
            skillReplaySelections.finish(selection, false, null)
            return reply(skillReplaySelections.snapshot(selection))
        }
        return PhoneCallWork(
            invoke = { call.run { _, _, _ ->
                var normal = false
                try {
                    val out = sessions.runReplay(admission, selection, skillReplaySelections, skillReplayOutcomes)
                    normal = !out.isError
                } finally {
                    skillReplaySelections.finish(selection, normal, sessions.deadlineMs(admission))
                    // Only call executor threads settle IO. The deadline callback below does not.
                    skillReplaySelections.retryAccounting(skillReplayOutcomes)
                }
                PhoneSkillReplaySelections.output(skillReplaySelections.snapshot(selection))
            } },
            remainingMs = { sessions.remainingMs(admission) },
            expiredReply = { call.run { _, _, _ ->
                sessions.expire(admission)
                PhoneSkillReplaySelections.output(skillReplaySelections.expire(selection))
            } },
        )
    }

    private fun createSessionCore(task: PhoneTasks, sessionId: String?): PhoneCore {
        val gate = prompts.scoped(task, sessionId)
        val observations = PhoneTaskObservations(task)
        val env = object : PhoneEnv by this@PhoneControl {
            override fun gate(): UserGate = gate
            override fun onTaskStarted(owner: PhoneTasks.Owner) {} // Registry owns managed trace start.
            override fun driver(screen: PhoneScreen, owner: PhoneTasks.Owner): PhoneDriver? =
                driverForTask(screen, task, owner)?.let { observations.bind(it, owner) }
            override fun existingReplayDriver(owner: PhoneTasks.Owner, app: PhoneAppIdentity): PhoneDriver? =
                background.existingReplayDriver(owner, app) { task.isCurrent(owner) }
                    ?.let { observations.bind(it, owner) }
            override fun notifyFix(kind: String) = notifyFixFor(task, kind)
            override fun beforeHandoff(screen: PhoneScreen, owner: PhoneTasks.Owner): String? {
                if (screen != PhoneScreen.BACKGROUND) return null
                background.endTask(owner.taskId)
                return "后台屏已释放。请用户在主屏完成操作，继续前先重新读取主屏。" // l10n:keep agent handoff result
            }
        }
        task.addListener { state -> onSessionTask(task, state) }
        return PhoneCore(env, task, log, core.worker, skillTrace = skillTrace,
            onExecution = { owner -> selectExecution(task, owner) })
    }

    private fun onSessionTask(task: PhoneTasks, state: PhoneTasks.Snapshot) {
        if (!state.active || state.paused || state.stopped) shell.cancel(state.id)
        preview.refresh()
        prompts.check()
        val record = sessions.all().firstOrNull { it.tasks === task } ?: return
        if (!state.active) sessions.onInactive(record, state)
        updateTaskUi(task, state)
        emitStatus()
    }

    @Volatile private var logger: (String) -> Unit = {}
    @Volatile private var rootfs: File? = null
    @Volatile private var lastStatus: Map<String, Any?>? = null
    // Only the process-lifetime ticker capture lane reads or increments this value.
    private var statusRevision = 0L
    @Volatile private var keptTask = 0L
    private var screenReceiver: BroadcastReceiver? = null
    private val sinks = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()
    val background: BackgroundControl = BackgroundControl.get(app)
    val shell = com.skyjjgw.independent.ski.dshgo.phone.shell.AndroidShellController(app) {
        ticker.execute { emitStatus() }
    }
    val preview = BackgroundPreview(app, background::previewTarget, { taskId ->
        val task = sessions.task(taskId)?.tasks?.snapshot()
        task?.active == true && task.id == taskId && !isLocked()
    }, ::emitStatus)

    internal val selfCheck = PhoneSelfCheck(sessions, background, SystemClock::elapsedRealtime,
        unavailable = {
            when {
                !isEnabled() -> PhoneSelfCheckReport.Reason.PHONE_DISABLED
                Build.VERSION.SDK_INT < com.skyjjgw.independent.ski.dshgo.phone.background.BackgroundPolicy.MIN_SDK -> PhoneSelfCheckReport.Reason.UNSUPPORTED
                isLocked() -> PhoneSelfCheckReport.Reason.LOCKED
                else -> null
            }
        }, prepareReceiver = ::registerScreenOffNow,
        changed = { refreshScreenOff(); emitStatus() })

    init {
        PhoneRegistry.notificationGate = notificationGate
        PhoneRegistry.promptGate = prompts
        PhoneRegistry.controlListener = this
        PhoneRegistry.unlocks = { policies().unlocks }
        // Never enter registry from a BackgroundControl callback's ownership monitor.
        background.onStatusChanged = { ticker.execute { sessions.backgroundCapacityChanged() } }
        background.onPreviewChanged = { main.post { preview.refresh() } }
        background.localOcrAllowed = { target ->
            isEnabled() && !isLocked() && target.packageName != app.packageName &&
                target.packageName !in policies().denyPackages
        }
        (app as? Application)?.let { AppVisibility.register(it) }
        tasks.addListener { onTask(it) }
        ticker.scheduleWithFixedDelay({ tick() }, 2, 2, TimeUnit.SECONDS)
        // The app's start: a force stop took the accessibility service out of the settings.
        cleanupIo.execute { taskJournal.load(); emitStatus() }
        ticker.execute(::keep)
    }

    // ── Switch and app lists ────────────────────────────────────────────────────────

    fun isEnabled(): Boolean = switchedOn(app)

    /** Off closes the bridge and stops the task after any in-flight keeper settings write.
     * On needs an engine restart (the UI does it); the rebind gap never holds this switch.
     */
    fun setEnabled(enabled: Boolean): Boolean {
        synchronized(keeperSwitchLock) {
            prefs.edit().putBoolean(K_ENABLED, enabled).apply()
        }
        if (!enabled) {
            // l10n:keep agent stop reason
            sessions.stopAll("手机操控已关闭")
            skillLifecycle.retired()
            stopBridge()
        } else {
            tasks.clearStop()
            ticker.execute(::keep)
        }
        emitStatus()
        return true
    }

    override fun policies(): PhonePolicies = policiesCache

    /** Construction only, before any registry/worker can read the published cache. */
    private fun readPolicies(): PhonePolicies {
        val stored = prefs.getString(K_POLICIES, null)
        return try {
            PhonePolicies.fromMap(stored?.let { Json.parse(it) as? Map<*, *> })
        } catch (_: Exception) {
            PhonePolicies()
        }
    }

    fun setPolicies(map: Map<*, *>?): Boolean {
        applyLocalOcrPolicyUpdate(map,
            publish = { MlKitLocalOcr.get(app).setEnabled(it) },
            commit = { app.getSharedPreferences(MlKitLocalOcr.PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(MlKitLocalOcr.KEY, it).commit() },
        )?.let { return it }
        // Partial updates keep what they don't mention (the 免确认 switch sends only its flag).
        // 解除限制 is refused while any task, selected or not, may still act; restoring never is.
        val p = sessions.updatePolicies(map, { policiesCache }, { policiesCache = it }) ?: return false
        // The plugin serializes setters on its IO executor; never hold admission over preferences IO.
        prefs.edit().putString(K_POLICIES, Json.write(p.toMap())).apply()
        return true
    }

    /** `getPolicies`: the lists, a label for every listed package, and the shipped defaults. */
    fun policiesMap(): Map<String, Any?> {
        val p = policies()
        val labels = LinkedHashMap<String, String>()
        for (pkg in (p.denyPackages + p.confirmEveryWritePackages + PhonePolicies().denyPackages + PhonePolicies().confirmEveryWritePackages).distinct()) {
            label(pkg)?.let { labels[pkg] = it }
        }
        return p.toMap() + mapOf("labels" to labels, "defaults" to PhonePolicies().toMap(),
            LOCAL_OCR_POLICY_FIELD to MlKitLocalOcr.get(app).enabled)
    }

    private fun label(pkg: String): String? = try {
        app.packageManager.getApplicationLabel(app.packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) {
        null
    }

    /** Skivu hosts the same MCP bridge from its existing assistant loop. */
    @Synchronized fun prepareNativeHost(): PhoneGuest.Endpoint? {
        if (!isEnabled()) return null
        bridge.endpoint?.let { return it }
        tasks.invalidateOwners()
        skillLifecycle.retired()
        // Match prepareLaunch: a lost listener can still own physical screen
        // leases. Retire the previous original session/worker before relaunch.
        stopBridge()
        sessions.beginCallerLaunch()
        tasks.clearStop()
        skillLifecycle.launched()
        RuntimeController.get(app).activate()
        return bridge.start(withTcp = false).also { refreshScreenOff(); emitStatus() }
    }

    // ── Engine lifecycle (RuntimeController's worker thread) ───────────────────────

    /**
     * Before DSH launches: with the switch on and not in safe mode, writes the guest files, starts
     * the bridge and returns true (the launch then adds the `--patch` overlay). Otherwise makes
     * sure nothing is listening and returns false: DSH mounts no phone tools at all.
     */
    fun prepareLaunch(rootfs: File, safe: Boolean, log: (String) -> Unit): Boolean {
        logger = log
        tasks.invalidateOwners()
        skillLifecycle.retired()
        stopBridge()
        sessions.beginCallerLaunch()
        this.rootfs = rootfs
        if (!isEnabled() || safe) {
            PhoneGuest.clearConfig(rootfs)
            if (isEnabled()) log("[dsh-app] phone control stays off in safe mode")
            emitStatus()
            return false
        }
        return try {
            PhoneGuest.writeFiles(rootfs)
            tasks.clearStop()
            skillLifecycle.launched()
            val ep = bridge.start(withTcp = prefs.getBoolean(K_TCP_FALLBACK, false))
            PhoneGuest.writeConfig(rootfs, ep)
            refreshScreenOff()
            emitStatus()
            true
        } catch (e: Exception) {
            log("[dsh-app] phone control: setup failed (${e.message}); starting without phone tools")
            skillLifecycle.retired()
            stopBridge()
            false
        }
    }

    /** After the launch command was built: [mounted] false means this runtime's template had no `dsh web` to add the overlay to. */
    fun launched(mounted: Boolean) {
        if (mounted) return
        skillLifecycle.retired()
        logger("[dsh-app] phone control: this runtime's launch command has no `dsh web` to add the phone overlay to; phone tools are off")
        stopBridge()
    }

    /**
     * DSH printed its login line, so every plugin (including the MCP client's first connection)
     * has loaded. No authenticated connection 5 s later means the guest couldn't reach the abstract socket:
     * open the loopback fallback now (the client's reconnect re-reads bridge.json) and keep it on
     * for later launches.
     */
    fun onEngineReady() {
        // Grace period: the client's first connection normally lands before the login line anyway.
        ticker.schedule({ checkReached() }, 5, TimeUnit.SECONDS)
    }

    private fun checkReached() {
        if (!bridge.listening || bridge.authenticatedConnections > 0) return
        val ep = bridge.endpoint ?: return
        if (ep.tcpPort != null) {
            logger("[dsh-app] phone control: DSH did not connect to the phone bridge (unix socket nor loopback)")
            return
        }
        logger("[dsh-app] phone control: DSH did not reach the unix socket; adding the loopback fallback")
        try {
            val next = bridge.addTcp() ?: return
            rootfs?.let { PhoneGuest.writeConfig(it, next) }
            prefs.edit().putBoolean(K_TCP_FALLBACK, true).apply()
        } catch (e: Exception) {
            logger("[dsh-app] phone control: loopback fallback failed: ${e.message}")
        }
        emitStatus()
    }

    fun onEngineStopped() {
        tasks.invalidateOwners()
        skillLifecycle.retired()
        stopBridge()
        core.worker.retire()
        tasks.endTask()
        emitStatus()
    }

    private fun stopBridge() {
        shell.cancelAll()
        skillReplaySelections.retire()
        selfCheck.stop()
        background.sealTask()
        bridge.stop()
        sessions.retire()
        displaySelection.clear()
        PhoneRegistry.overlayGate?.clearStatus { /* Stale displayed status only. */ }
        core.worker.retire()
        rootfs?.let { PhoneGuest.clearConfig(it) }
        refreshScreenOff()
    }

    val bridgeListening: Boolean get() = bridge.listening

    // ── Task ────────────────────────────────────────────────────────────────────────

    fun stopTask(reason: String, taskId: Long? = null): Boolean {
        val record = if (taskId == null) sessions.all().firstOrNull { it.sessionId == null } ?: return false
            else sessions.task(taskId) ?: return false
        val state = record.tasks.snapshot()
        if (taskId != null && state.id != taskId) return false
        return sessions.stop(record, state, reason)
    }

    /** A notification's 停止操作: only the task it was shown for, and only while that task still runs. */
    fun stopShownTask(reason: String, taskId: Long): Boolean {
        val task = sessions.task(taskId)?.tasks ?: return false
        return stopOwner(task, task.activeOwner(taskId) ?: return false, reason)
    }

    /** Exact owner only: a stopped, ended or replaced one is refused, never redirected to another task. */
    private fun stopOwner(task: PhoneTasks, owner: PhoneTasks.Owner, reason: String): Boolean {
        val record = sessions.task(owner.taskId)?.takeIf { it.tasks === task } ?: return false
        return sessions.stop(record, owner, reason)
    }
    fun retryTaskCleanup(taskId: Long): Boolean = sessions.retryCleanup(taskId)
    fun resumeTask(taskId: Long): Boolean {
        val record = sessions.task(taskId) ?: return false
        val expected = record.tasks.snapshot()
        if (expected.id != taskId) return false
        return sessions.resume(record, expected)
    }
    fun pauseTask(taskId: Long, paused: Boolean): Boolean {
        val task = sessions.task(taskId)?.tasks ?: return false
        val owner = task.activeOwner(taskId) ?: return false
        return task.setPausedIfCurrent(owner, paused)
    }
    fun taskState(taskId: Long): PhoneTasks? = sessions.task(taskId)?.tasks
    fun taskBusy(taskId: Long): Boolean = sessions.task(taskId)?.let(sessions::isBusy) == true
    fun taskSession(taskId: Long): String? = sessions.task(taskId)?.sessionId
    fun completedTask(taskId: Long, runId: String, generation: Long): PhoneTasks.Owner? = sessions.completed(taskId, runId, generation)
    fun taskOwnerCurrent(taskId: Long, owner: PhoneTasks.Owner): Boolean = sessions.ownerCurrent(taskId, owner)


    /**
     * Dart (`finishTask`): the turn that drove the phone ended. Ends the task — a stop's hold too —
     * and closes the overlay, ball and cards included. False when there was nothing to end, or a
     * phone call still runs, or the requested task changed. Any thread.
     */
    fun finishTask(expectedTaskId: Long? = null): Boolean {
        val taskId = expectedTaskId ?: tasks.snapshot().id
        return tasks.finish(taskId)
    }

    fun finishTaskScope(expectedTaskId: Long): PhoneTasks.Owner? {
        val record = sessions.task(expectedTaskId) ?: return null
        val expected = record.tasks.snapshot()
        if (expected.id != expectedTaskId) return null
        return sessions.finish(record, expected)
    }

    /**
     * Brings the app forward on [sessionId] (just the app when null) after a finished task. Started
     * from the accessibility service when bound. This is a best-effort start under Android's
     * background-start restrictions, not a guarantee. False when start threw; the caller must
     * separately observe its ActivityAware host resumed (some vendors block silently).
     */
    fun reopen(sessionId: String?, host: String?): Boolean {
        val intent = if (sessionId != null) {
            EntryActivity.openChat(app, sessionId, host)
        } else {
            Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val from: Context = PhoneA11yService.instance ?: app
        return try {
            from.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun onTask(s: PhoneTasks.Snapshot) {
        if (!s.active || s.paused || s.stopped) shell.cancel(s.id)
        preview.refresh() // Clear local pixels before endTask can enter blocking release IPC.
        skillLifecycle.changed(s)
        prompts.check()
        val record = sessions.all().firstOrNull { it.tasks === tasks }
        if (!s.active && record != null) sessions.onInactive(record, s)
        updateTaskUi(tasks, s)
        emitStatus()
    }

    private fun selectExecution(task: PhoneTasks, owner: PhoneTasks.Owner): (((() -> Unit) -> Boolean)?) {
        val ticket = displaySelection.select(task, owner) ?: return null
        // Selecting another owner retires the old pill, even for an apps-only execution.
        // Consecutive calls by the same owner keep its displayed control. Platform sinks
        // run after the short Tasks -> selection commit, never while either lock is held.
        PhoneRegistry.overlayGate?.clearStatus { /* Check displayed status's own guard only. */ }
        DshService.updateNotification(app)
        LiveActivity.refresh(app)
        emitStatus()
        return displaySelection.guard(ticket)
    }

    private fun updateTaskUi(task: PhoneTasks, state: PhoneTasks.Snapshot) {
        if (state.active && state.id != keptTask) {
            keptTask = state.id
            ticker.execute(::keep)
        }
        if (!state.active) {
            val cleanup = displaySelection.inactive(task, state)
            cleanup {} // Clear the matching line now, outside any UI/Binder operation.
            // Always enqueue: an old displayed status may be stale after B became selected.
            PhoneRegistry.overlayGate?.clearStatus(cleanup)
        }
        DshService.updateNotification(app)
        LiveActivity.refresh(app)
    }

    private fun setStatusLine(text: String?, ifCurrent: (() -> Unit) -> Boolean) {
        if (!displaySelection.status(text, ifCurrent)) return
        DshService.updateNotification(app)
        LiveActivity.refresh(app)
    }

    /** One coherent task/owner/line snapshot; never splice another execution's line into its id. */
    fun liveTask(): LiveTask? = displaySelection.view()?.let {
        LiveTask(it.state.id, it.line, it.state.app, it.state.paused)
    }

    data class LiveTask(val id: Long, val line: String?, val app: String?, val paused: Boolean)

    fun foregroundLine(): String? = liveTask()?.let { foregroundLine(it) }

    fun foregroundLine(task: LiveTask): String =
        task.line ?: AppStrings.get(app, R.string.phone_running) + (task.app?.let { label -> " · $label" } ?: "")

    /** Receiver ownership stays on main; a pending selfcheck outlives an engine bridge. */
    private fun refreshScreenOff() {
        if (Looper.myLooper() != main.looper) { main.post { refreshScreenOff() }; return }
        if (bridge.listening || selfCheck.needsReceiver) registerScreenOffNow()
        else {
            screenReceiver?.let { runCatching { app.unregisterReceiver(it) } }
            screenReceiver = null
        }
    }

    /** The local start method runs on main and requires registration before taking a lease. */
    private fun registerScreenOffNow(): Boolean {
        if (screenReceiver != null) return true
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != Intent.ACTION_SCREEN_OFF) return
                selfCheck.stop()
                preview.refresh()
                background.requestInterrupt {
                    sessions.stopAll("熄屏", PhoneTasks.StopSource.SCREEN_OFF) // l10n:keep agent stop reason
                }
                cleanupIo.execute { background.finishInterrupt() }
            }
        }
        return try {
            app.registerReceiver(receiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
            screenReceiver = receiver
            true
        } catch (_: Exception) { false }
    }

    // ── Things the plugin asks for ──────────────────────────────────────────────────

    fun a11yEnabledInSettings(): Boolean = PhoneA11yService.isEnabled(app)

    fun accessibilitySettingsIntent(): Intent {
        val component = PhoneA11yService.component(app).flattenToString()
        // Undocumented but honoured by AOSP Settings and several ROMs: highlight our row.
        val args = Bundle().apply { putString(":settings:fragment_args_key", component) }
        return Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            .putExtra(":settings:fragment_args_key", component)
            .putExtra(":settings:show_fragment_args", args)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    fun appDetailsIntent(): Intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${app.packageName}"))
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /** Debug probe only. The worker builds values; only the successful caller may persist them. */
    internal fun collectNavigationMaterial(driver: com.skyjjgw.independent.ski.dshgo.phone.a11y.MainScreenDriver,
                                          seq: Int, publish: (ByteArray) -> Unit) {
        fun allowed(): Boolean = app.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0 &&
            PhoneRegistry.mainDriver === driver && enabled() && !isLocked() &&
            core.safety.checkReadSources(policies(), listOf(com.skyjjgw.independent.ski.dshgo.phone.a11y.MarkorNavigation.PACKAGE)) == null
        fun unavailable(reason: String) = Json.write(mapOf("schema" to 1, "seq" to seq,
            "kind" to "unavailable", "reason" to reason)).toByteArray(Charsets.UTF_8)
        val bytes = try {
            if (!allowed()) unavailable("unavailable") else {
                val result = sessions.readForSelfCheck(core.worker, 8_000, 15_000) {
                    if (!allowed()) com.skyjjgw.independent.ski.dshgo.phone.a11y.NavigationMaterials.Unavailable("unavailable")
                    else driver.navigationMaterial()
                }
                when (result) {
                    null -> unavailable("busy")
                    is SerialWorker.Outcome.Done -> when (val value = result.value) {
                        is com.skyjjgw.independent.ski.dshgo.phone.a11y.NavigationMaterials.Unavailable -> unavailable(value.reason)
                        is com.skyjjgw.independent.ski.dshgo.phone.a11y.NavigationMaterials.Sample -> {
                            val encoded = Json.write(mapOf("schema" to 1, "seq" to seq, "kind" to "observed") + value.fields)
                                .toByteArray(Charsets.UTF_8)
                            if (encoded.size > com.skyjjgw.independent.ski.dshgo.phone.a11y.NavigationMaterials.MAX_BYTES) unavailable("limit")
                            else if (!allowed() || !value.current()) unavailable("changed") else encoded
                        }
                    }
                    else -> unavailable("unavailable")
                }
            }
        } catch (_: Exception) { unavailable("unavailable") }
        publish(bytes)
    }

    /**
     * 「读一下当前屏幕」: the person's own on-device check, never sent to a model, so it shows
     * whatever is in front (DSH's own settings page included; the own-app rule is for tool calls).
     */
    fun testScreen(): Map<String, Any?> {
        val driver = PhoneRegistry.mainDriver
            ?: return mapOf("ok" to false, "reason" to if (a11yEnabledInSettings()) AppStrings.get(app, R.string.phone_a11y_connecting) else AppStrings.get(app, R.string.phone_a11y_off))
        val outcome = sessions.readForSelfCheck(core.worker, 8_000, 15_000) {
            if (PhoneRegistry.mainDriver !== driver) throw InterruptedException()
            val av = driver.availability()
            val read = if (!av.ok) null to (av.userReason ?: av.reason ?: AppStrings.get(app, R.string.phone_a11y_unavailable)) else driver.observe(detail = false, image = false) to null
            if (PhoneRegistry.mainDriver !== driver) throw InterruptedException()
            read
        } ?: return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.phone_busy))
        return when (outcome) {
            is SerialWorker.Outcome.Done -> {
                val (snap, reason) = outcome.value
                if (snap == null) mapOf("ok" to false, "reason" to reason) else mapOf("ok" to true, "text" to snap.text)
            }
            is SerialWorker.Outcome.TimedOut -> mapOf("ok" to false, "reason" to if (outcome.queued) AppStrings.get(app, R.string.phone_busy) else AppStrings.get(app, R.string.phone_read_timeout))
            is SerialWorker.Outcome.Failed -> mapOf("ok" to false, "reason" to (outcome.error.message ?: outcome.error.javaClass.simpleName))
            SerialWorker.Outcome.Interrupted -> mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.phone_stopped))
        }
    }

    /** Reads the existing immutable gate snapshot without refreshing phone state. */
    fun backgroundProbeDiagnostics(): Map<String, Any?> = background.inputProbeDiagnostics()

    fun setSkillSavePrompt(enabled: Boolean): Boolean {
        prefs.edit().putBoolean(K_SKILL_PROMPT, enabled).apply()
        emitStatus()
        return true
    }

    private fun skillsStatus(): Map<String, Any?> = mapOf(
        "v" to 1, "askAfterSuccess" to prefs.getBoolean(K_SKILL_PROMPT, false),
        "saveResults" to skillDrafts.saveResults(),
        "candidates" to skillDrafts.candidates().map { mapOf(
            "taskId" to it.owner.taskId, "generation" to it.owner.lifecycle, "steps" to it.steps) },
    )

    fun acknowledgeTaskInterruption(batchToken: String): Boolean =
        taskJournal.acknowledge(batchToken).also { emitStatus() }

    fun retryTaskInterruptionStorage(): Boolean = sessions.retryJournalStorage().also { emitStatus() }

    /** Capture on the same lane as events; never occupy the plugin control queue while waiting. */
    fun status(done: (Result<Map<String, Any?>>) -> Unit) {
        ticker.execute {
            val value = try { Result.success(captureStatus()) }
                catch (failure: Throwable) { Result.failure(failure) }
            done(value)
        }
    }

    /** Called only on ticker: complete sampling and revision assignment cannot interleave. */
    private fun captureStatus(): Map<String, Any?> {
        val value = linkedMapOf<String, Any?>(
            "enabled" to isEnabled(),
            "skills" to skillsStatus(),
            "bridgeListening" to bridge.listening,
            "a11y" to linkedMapOf("enabled" to a11yEnabledInSettings(), "serviceConnected" to (PhoneRegistry.mainDriver != null)),
            "overlay" to (PhoneRegistry.overlayGate != null),
            "notifications" to nm.areNotificationsEnabled(),
            "confirmationNotifications" to notificationGate.available(),
            "background" to backgroundStatus(),
            "a11yKeeper" to keeperStatus(),
            "task" to tasks.snapshot().toMap(),
            "taskInterruption" to taskJournal.status(),
            "taskProtocol" to 1,
            "callerCapability" to sessions.callerCapability(),
            "tasks" to sessions.snapshot(),
            "selectedTaskId" to (displaySelection.ticket()?.owner?.taskId ?: 0L),
            "parallelLimit" to 1,
            "device" to linkedMapOf(
                "manufacturer" to Build.MANUFACTURER,
                "sdkInt" to Build.VERSION.SDK_INT,
                "sideloaded" to sideloaded(),
                "restricted" to RestrictedSettings.read(app),
            ),
        )
        value["statusRevision"] = ++statusRevision
        return value
    }

    fun setBackgroundParallelLimit(value: Any?): Map<String, Any?> {
        val result = background.setBackgroundParallelLimit(value)
        if (result["ok"] == true) sessions.backgroundCapacityChanged()
        return result
    }

    private fun backgroundStatus(): Map<String, Any?> = try {
        background.status() + mapOf(
            "preview" to mapOf("v" to 1, "enabled" to preview.enabled),
            "parallelism" to background.parallelism().map(sessions.backgroundHeldSlots()),
        )
    } catch (e: Exception) {
        linkedMapOf("mode" to "off", "ready" to false, "reason" to (e.message ?: AppStrings.get(app, R.string.phone_background_error)), "androidOk" to (Build.VERSION.SDK_INT >= 34), "preview" to mapOf("v" to 1, "enabled" to preview.enabled))
    }

    /** 自动恢复无障碍: whether it may work (the permission), the one-tap way to it, the command for the other. */
    private fun keeperStatus(): Map<String, Any?> {
        val granted = A11yKeeper.granted(app)
        return linkedMapOf(
            "granted" to granted,
            "path" to runCatching { background.grantPath(granted) }.getOrDefault(SecureSettingsGrant.SETUP),
            "command" to SecureSettingsGrant.command(app.packageName),
        )
    }

    /**
     * 自动恢复无障碍 → the one tap: the shell-uid engine grants WRITE_SECURE_SETTINGS over Shizuku or
     * self-ADB. Shizuku without its own permission asks for that first (`pending`) and grants once
     * the person allows. Blocks; the plugin thread.
     */
    fun grantSecureSettings(mayStart: () -> Boolean): Map<String, Any?> {
        if (!mayStart()) return mapOf("ok" to false,
            "reason" to AppStrings.get(app, R.string.background_selection_cancelled))
        return when (val path = background.grantPath(A11yKeeper.granted(app))) {
            SecureSettingsGrant.GRANTED -> mapOf("ok" to true)
            SecureSettingsGrant.SHIZUKU, SecureSettingsGrant.ADB -> {
                val attempt = background.grantSecureSettings(path, mayStart)
                val ok = A11yKeeper.granted(app)
                if (ok) ticker.execute(::keep)
                emitStatus()
                val failed = SecureSettingsGrant.failureReason(ok, attempt)
                mapOf("ok" to ok, "reason" to failed?.let { AppStrings.get(app, it) })
            }
            SecureSettingsGrant.SHIZUKU_PERMISSION -> {
                // Permission may arrive after a new mode/off intent. Keep the original UI lease
                // through both the manager callback and this worker's queue.
                val asked = background.requestShizukuPermission { ticker.execute { grantSecureSettings(mayStart) } }
                mapOf("ok" to false, "pending" to asked, "reason" to if (asked) null else AppStrings.get(app, R.string.background_shizuku_permission))
            }
            else -> mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.a11y_keeper_needs_setup))
        }
    }

    private fun keep() {
        runCatching { A11yKeeper.check(app) }
    }

    /** Installed from a browser or file manager rather than a store (Android 13+ restricted settings apply). */
    private fun sideloaded(): Boolean? = try {
        val installer = if (Build.VERSION.SDK_INT >= 30) {
            app.packageManager.getInstallSourceInfo(app.packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION") app.packageManager.getInstallerPackageName(app.packageName)
        }
        installer == null || installer !in STORES
    } catch (_: Exception) {
        null
    }

    fun addSink(sink: (Map<String, Any?>) -> Unit) {
        sinks += sink
        ticker.execute { pushIfChanged(force = true) }
    }

    fun removeSink(sink: (Map<String, Any?>) -> Unit) {
        sinks -= sink
    }

    /** Recomputes the status off the main thread and pushes it if it changed. */
    fun emitStatus() {
        if (sinks.isEmpty()) return
        ticker.execute { pushIfChanged(force = false) }
    }

    private fun pushIfChanged(force: Boolean) {
        if (sinks.isEmpty()) return
        val s = try {
            captureStatus()
        } catch (_: Exception) {
            return
        }
        val report = s - "statusRevision"
        if (!force && report == lastStatus) return
        lastStatus = report
        main.post {
            if (sinks.isEmpty()) return@post
            val outgoing = capacityStatusForDelivery(s, background.configuredParallelLimit())
            sinks.forEach { runCatching { it(outgoing) } }
            // Capture/lastStatus/revision stay on ticker; never splice a new limit into old facts.
            if (outgoing !== s) ticker.execute { pushIfChanged(force = true) }
        }
    }

    /** Every 2 s: end idle tasks; 自动恢复无障碍; push status changes we can't observe (accessibility connecting). */
    private fun tick() {
        try {
            sessions.all().forEach { it.tasks.expireIdle() }
            A11yKeeper.check(app)
            pushIfChanged(force = false)
        } catch (_: Exception) {
        }
    }

    // ── ControlListener (the overlay's 暂停 / 停止 / 插话, the service's own stops) ──

    override fun shownControls(): TaskControls? =
        displaySelection.controls { task, owner, reason -> stopOwner(task, owner, reason) }

    override fun onStopAllRequested(reason: String, source: PhoneTasks.StopSource) { shell.cancelAll(); selfCheck.stop(); sessions.stopAll(reason, source) }

    override fun onAccessibilityChanged(connected: Boolean) = emitStatus()

    // ── PhoneEnv ────────────────────────────────────────────────────────────────────

    override fun onTaskStarted(owner: PhoneTasks.Owner) = skillLifecycle.started(owner)

    override fun enabled(): Boolean = isEnabled()

    override fun isLocked(): Boolean {
        val km = app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        return km.isKeyguardLocked || !power.isInteractive
    }

    override fun gate(): UserGate = prompts

    /**
     * The background driver is registered per task: bring it up on first use (worker thread; may
     * connect). The main one may be on its way back (自动恢复无障碍): give it a few seconds.
     */
    override fun driver(screen: PhoneScreen): PhoneDriver? {
        val owner = tasks.activeOwner() ?: return null
        return driver(screen, owner)
    }

    override fun driver(screen: PhoneScreen, owner: PhoneTasks.Owner): PhoneDriver? =
        driverForTask(screen, tasks, owner)?.let { legacyObservations.bind(it, owner) }

    private fun driverForTask(screen: PhoneScreen, task: PhoneTasks, owner: PhoneTasks.Owner): PhoneDriver? {
        if (screen == PhoneScreen.MAIN && PhoneRegistry.mainDriver == null && A11yKeeper.check(app)) {
            val until = SystemClock.elapsedRealtime() + KEEPER_WAIT_MS
            while (PhoneRegistry.mainDriver == null && SystemClock.elapsedRealtime() < until) Thread.sleep(100)
        }
        if (screen != PhoneScreen.BACKGROUND) return PhoneRegistry.mainDriver
        return runCatching {
            background.driverForTask(owner, { task.isCurrent(owner) }) { commit ->
                task.runIfCurrent(owner, commit)
            }
        }.getOrNull()
    }

    override fun beforeHandoff(screen: PhoneScreen, owner: PhoneTasks.Owner): String? {
        if (screen != PhoneScreen.BACKGROUND) return null
        background.endTask(owner.taskId)
        // l10n:keep agent stop reason
        return "后台屏已释放。请用户在主屏完成操作，继续前先重新读取主屏（s 开头的屏幕号）。"
    }

    override fun a11yState(): A11yState = when {
        PhoneRegistry.mainDriver != null -> A11yState.CONNECTED
        a11yEnabledInSettings() -> A11yState.ENABLED_NOT_CONNECTED
        else -> A11yState.DISABLED
    }

    override fun backgroundUnavailable(): String {
        val reason = (backgroundStatus()["reason"] as? String)?.let { "（$it）" } ?: ""
        // l10n:keep agent stop reason
        return "不打扰模式（后台屏）用不了$reason。只能在主屏操作；要用后台屏请用户到 设置 → 手机操控 → 不打扰模式 开通。"
    }

    override fun system(): SystemApi = system

    override fun androidShell(): PhoneShellExecutor = PhoneShellExecutor { ownerId, command, timeoutMs, live, confirm ->
        shell.execute(ownerId, command, timeoutMs, live, confirm)
    }

    override fun zone(): ZoneId = ZoneId.systemDefault()

    override fun notifyFix(kind: String) = notifyFixFor(tasks, kind)

    private fun notifyFixFor(task: PhoneTasks, kind: String) {
        if (!task.firstNotice(kind)) return
        if (!nm.areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL_FIX, AppStrings.get(app, R.string.phone_fix_channel), NotificationManager.IMPORTANCE_HIGH))
        }
        val pi = PendingIntent.getActivity(app, 0, accessibilitySettingsIntent(), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(app, CHANNEL_FIX) else @Suppress("DEPRECATION") Notification.Builder(app)
        val text = if (a11yEnabledInSettings()) AppStrings.get(app, R.string.phone_a11y_disconnected_notice) else AppStrings.get(app, R.string.phone_a11y_enable_notice)
        nm.notify(
            NOTIFY_FIX_ID,
            b.setSmallIcon(R.drawable.ic_stat_dsh).setContentTitle(AppStrings.get(app, R.string.phone_a11y_title)).setContentText(text)
                .setContentIntent(pi).setAutoCancel(true).build(),
        )
    }

    companion object {
        const val SERVER_VERSION = "1"
        private const val PREFS = "dsh_phone"
        private const val K_ENABLED = "enabled"
        private const val K_SKILL_PROMPT = "skillSavePrompt"

        /** Only master preference publication and the keeper's final settings writes share this lock. */
        internal val keeperSwitchLock = Any()
        private const val K_POLICIES = "policies"
        private const val K_TCP_FALLBACK = "tcpFallback"
        private const val CHANNEL_FIX = "dsh-phone-fix"
        private const val NOTIFY_FIX_ID = 4099

        /** How long a call needing the main screen waits for 自动恢复无障碍 to bring it back. */
        private const val KEEPER_WAIT_MS = 3_000L

        /** Installer packages of app stores; anything else (or none) counts as sideloaded. */
        private val STORES = setOf(
            "com.android.vending", "com.xiaomi.market", "com.heytap.market", "com.oppo.market", "com.bbk.appstore",
            "com.huawei.appmarket", "com.hihonor.appmarket", "com.tencent.android.qqdownloader", "com.baidu.appsearch",
            "com.wandoujia.phoenix2", "com.qihoo.appstore", "com.sec.android.app.samsungapps", "com.meizu.mstore",
            "com.smartisanos.appstore", "zte.com.market", "com.lenovo.leos.appstore", "com.coolapk.market",
        )

        @Volatile private var instance: PhoneControl? = null

        fun get(context: Context): PhoneControl =
            instance ?: synchronized(this) {
                instance ?: PhoneControl(context.applicationContext).also { instance = it }
            }

        /** Without creating it (DshService builds notifications before anything else may exist). */
        fun peek(): PhoneControl? = instance

        /** The master switch 「手机操控」, without creating the controller. */
        fun switchedOn(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(K_ENABLED, false)
    }
}

private const val LOCAL_OCR_POLICY_FIELD = "localOcrEnabled"

/** Null leaves the existing policy update untouched. OCR uses its own single-key transaction. */
internal fun applyLocalOcrPolicyUpdate(map: Map<*, *>?, publish: (Boolean) -> Unit,
    commit: (Boolean) -> Boolean): Boolean? {
    if (map?.containsKey(LOCAL_OCR_POLICY_FIELD) != true) return null
    if (map.size != 1) return false
    val enabled = map[LOCAL_OCR_POLICY_FIELD] as? Boolean ?: return false
    // OFF revokes admission even if storage fails. ON waits for a confirmed save.
    if (!enabled) publish(false)
    val saved = try { commit(enabled) } catch (_: Exception) { false }
    if (!saved) return false
    if (enabled) publish(true)
    return true
}

/** Strip a stale capacity block; never splice a new limit into old effective/held facts. */
internal fun capacityStatusForDelivery(status: Map<String, Any?>, configuredLimit: Int): Map<String, Any?> {
    val background = status["background"] as? Map<*, *> ?: return status
    val parallelism = background["parallelism"] as? Map<*, *> ?: return status
    val sampled = parallelism["configuredLimit"] as? Int ?: return status
    if (sampled == configuredLimit) return status
    return status + ("background" to (background - "parallelism"))
}
