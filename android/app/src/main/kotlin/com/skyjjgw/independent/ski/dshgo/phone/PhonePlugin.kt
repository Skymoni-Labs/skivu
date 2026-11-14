package com.skyjjgw.independent.ski.dshgo.phone

import com.skyjjgw.independent.ski.dshgo.i18n.AppStrings
import com.skyjjgw.independent.ski.R
import com.skyjjgw.independent.ski.dshgo.phone.background.BackgroundPreview
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillDrafts
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillBridge
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillReplaySelections
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillReplayApps
import com.skyjjgw.independent.ski.dshgo.runtime.RuntimeController
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillBundleReader
import com.skyjjgw.independent.ski.dshgo.phone.a11y.OverlayPrefs
import com.skyjjgw.independent.ski.dshgo.phone.background.PrivilegedActionGate
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.Executors

/**
 * Flutter bridge for phone control: MethodChannel `dsh/phone`, EventChannel `dsh/phone/events`.
 * Anything that may block runs off the main thread.
 */
class PhonePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, EventChannel.StreamHandler, PluginRegistry.NewIntentListener {
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var previewEvents: EventChannel
    private val previewOwner = Any()
    private var previewTaskId: Long? = null
    private var previewSink: EventChannel.EventSink? = null
    private val previewLifecycle = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityPaused(host: Activity) {
            if (activity?.activity === host) control.preview.removeConsumer(previewOwner)
        }
        override fun onActivityResumed(host: Activity) {
            if (activity?.activity === host) attachPreviewConsumer()
        }
        override fun onActivityCreated(host: Activity, state: Bundle?) {}
        override fun onActivityStarted(host: Activity) {}
        override fun onActivityStopped(host: Activity) {}
        override fun onActivitySaveInstanceState(host: Activity, state: Bundle) {}
        override fun onActivityDestroyed(host: Activity) {}
    }
    private lateinit var appContext: Context
    private lateinit var control: PhoneControl
    private var activity: ActivityPluginBinding? = null
    private var sink: ((Map<String, Any?>) -> Unit)? = null
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-phone-plugin").apply { isDaemon = true } }
    private val controlIo = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-phone-control").apply { isDaemon = true } }
    @Volatile private var promptOwner = Any()
    @Volatile private var attached = false
    @Volatile private var skillClient: PhoneSkillDrafts.Client? = null
    private class SkillInspection(val client: PhoneSkillDrafts.Client, val epoch: Long,
        val origin: RuntimeController.PhoneSkillOrigin, val bundle: PhoneSkillBundleReader.Read.Accepted,
        val choices: List<PhoneSkillReplayApps.Choice>)
    private var skillInspection: SkillInspection? = null
    private var skillSelectionRequest = Any()
    private val privilegedActions = PrivilegedActionGate()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        control = PhoneControl.get(appContext)
        skillClient = control.skillDrafts.attachClient()
        (appContext as Application).registerActivityLifecycleCallbacks(previewLifecycle)
        promptOwner = Any()
        attached = true
        control.background.restoreKeptChannel()
        methods = MethodChannel(binding.binaryMessenger, "dsh/phone").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "dsh/phone/events").also { it.setStreamHandler(this) }
        previewEvents = EventChannel(binding.binaryMessenger, "dsh/phone/preview").also { channel ->
            channel.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    control.preview.removeConsumer(previewOwner)
                    previewTaskId = null
                    previewSink = null
                    val taskId = ((arguments as? Map<*, *>)?.get("taskId") as? Number)?.toLong()
                    if (taskId == null || taskId <= 0) {
                        events.error("invalid_task", "A current task ID is required", null)
                        return
                    }
                    previewTaskId = taskId
                    previewSink = events
                    attachPreviewConsumer()
                }
                override fun onCancel(arguments: Any?) {
                    control.preview.removeConsumer(previewOwner)
                    previewTaskId = null
                    previewSink = null
                }
            })
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        control.selfCheck.stop(promptOwner)
        control.background.changeGateIntent { attached = false }
        skillSelectionRequest = Any()
        skillInspection = null
        skillClient?.let { control.skillReplaySelections.retireClient(it); control.skillDrafts.retireClient(it) }
        skillClient = null
        (appContext as Application).unregisterActivityLifecycleCallbacks(previewLifecycle)
        control.preview.removeConsumer(previewOwner)
        previewTaskId = null
        previewSink = null
        previewEvents.setStreamHandler(null)
        control.background.cancelUnwantedPending()
        control.prompts.detachOwner(promptOwner)
        activity?.removeOnNewIntentListener(this)
        activity = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink?.let { control.removeSink(it) }
        sink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addOnNewIntentListener(this)
        control.prompts.attachActivity(promptOwner, binding.activity)
        control.prompts.handleOpenIntent(binding.activity.intent)
        attachPreviewConsumer()
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        control.preview.removeConsumer(previewOwner)
        activity?.removeOnNewIntentListener(this)
        control.prompts.attachActivity(promptOwner, null)
        activity = null
    }

    private fun attachPreviewConsumer() {
        val taskId = previewTaskId ?: return
        val events = previewSink ?: return
        val host = activity?.activity ?: return
        if (attached && AppVisibility.isResumed(host)) {
            control.preview.addConsumer(previewOwner, taskId, BackgroundPreview.ConsumerKind.APP_DIALOG) { events.success(it) }
        }
    }

    override fun onNewIntent(intent: Intent): Boolean = attached && control.prompts.handleOpenIntent(intent)

    /** Runs [block] on the plugin thread and answers on the main thread. */
    private fun async(result: MethodChannel.Result, shortControl: Boolean = false, block: () -> Any?) {
        (if (shortControl) controlIo else io).execute {
            val value = try {
                Result.success(block())
            } catch (e: Throwable) {
                Result.failure(e)
            }
            complete(result, value)
        }
    }

    /** Both async control work and the status capture lane finish on the original main handler. */
    private fun complete(result: MethodChannel.Result, value: Result<Any?>) {
        main.post {
            value.fold(
                onSuccess = { result.success(it) },
                onFailure = { result.error("phone_failed", it.message ?: it.javaClass.simpleName, null) },
            )
        }
    }

    private fun startActivity(intent: Intent): Boolean {
        val host = activity?.activity
        return try {
            if (host != null) host.startActivity(intent) else appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> control.status { complete(result, it) }
            "androidShellStatus" -> async(result, shortControl = true) { control.shell.status() }
            "configureAndroidShell" -> {
                val args = call.arguments as? Map<*, *>
                val enabled = args?.get("enabled") as? Boolean
                val backend = args?.get("backend") as? String
                if (args?.keys != setOf("enabled", "backend") || enabled == null || backend !in setOf("shizuku", "adb")) {
                    result.success(mapOf("ok" to false, "errorCode" to "invalidArguments"))
                } else if (enabled && !control.isEnabled()) {
                    result.success(mapOf("ok" to false, "errorCode" to "disabled"))
                } else async(result, shortControl = true) { control.shell.configure(enabled, backend!!) }
            }
            "androidShellRequestPermission" -> async(result) { control.shell.requestShizukuPermission() }
            "androidShellStartPairing" -> async(result) { control.shell.startAdbPairing() }
            "androidShellPair" -> {
                val args = call.arguments as? Map<*, *>
                val code = args?.get("code") as? String
                val port = args?.get("port") as? Int
                if (args == null || args.keys.any { it !in setOf("code", "port") } || code == null ||
                    args["port"] != null && port == null) result.success(mapOf("ok" to false, "errorCode" to "invalidArguments"))
                else async(result) { control.shell.pairAdb(code, port) }
            }
            "androidShellConnect" -> {
                val args = call.arguments as? Map<*, *>
                val port = args?.get("port") as? Int
                if (call.arguments != null && (args == null || args.keys.any { it != "port" } ||
                    args["port"] != null && port == null)) result.success(mapOf("ok" to false, "errorCode" to "invalidArguments"))
                else async(result) { control.shell.connect(port) }
            }
            "androidShellStop" -> { control.shell.cancelAll(); result.success(true) }
            "acknowledgeTaskInterruption" -> async(result) {
                (call.argument<Any?>("batchToken") as? String)?.let(control::acknowledgeTaskInterruption) == true
            }
            "retryTaskInterruptionStorage" -> async(result) { control.retryTaskInterruptionStorage() }
            "startPhoneSelfCheck", "phoneSelfCheckStatus", "cancelPhoneSelfCheck" -> selfCheckCall(call, result)
            "setBackgroundParallelLimit" -> async(result, shortControl = true) {
                val args = call.arguments as? Map<*, *>
                control.setBackgroundParallelLimit(if (args != null && args.keys == setOf("limit")) args["limit"] else null)
            }
            "setBackgroundViewport" -> async(result, shortControl = true) {
                val args = call.arguments as? Map<*, *>
                control.background.setBackgroundViewport(if (args != null && args.keys == setOf("preset")) args["preset"] else null)
            }
            "setSkillSavePrompt" -> {
                val enabled = (call.arguments as? Map<*, *>)?.get("enabled") as? Boolean
                if (enabled == null) result.success(false)
                else async(result, shortControl = true) { control.setSkillSavePrompt(enabled) }
            }
            "skillDraft", "saveSkillDraft", "discardSkillDraft" -> skillCall(call, result)
            "inspectSkillReplay" -> inspectSkillReplay(call, result)
            "prepareSkillReplay" -> prepareSkillReplay(call, result)
            "discardSkillReplay" -> {
                val args = call.arguments as? Map<*, *>
                val id = args?.get("invocation") as? String
                val client = skillClient
                val removed = client != null && args?.keys == setOf("invocation") && id != null &&
                    control.skillReplaySelections.discard(client, id)
                result.success(if (removed) mapOf("kind" to "discarded") else replayRejected("stale"))
            }
            "setBackgroundPreview" -> result.success(control.preview.setEnabled(call.argument<Boolean>("enabled") == true))
            "setBackgroundKeep" -> {
                val selected = call.argument<String>("mode").orEmpty()
                val enabled = call.argument<Boolean>("enabled") == true
                control.selfCheck.stop()
                val (ticket, failure) = control.background.changeKeep(selected, enabled)
                if (ticket == null) result.success(control.background.keepFailure(failure!!))
                else async(result, shortControl = true) { control.background.saveKeep(ticket) }
            }
            // A newer choice drops a queued grant: it must not run through whatever is chosen then.
            "grantSecureSettings" -> {
                val live = stillWanted(privilegedActions.snapshot())
                async(result) {
                    when {
                        !live() -> cancelledSelection()
                        control.background.rootGrantSelected() -> control.background.grantRootSecureSettings()
                        else -> control.grantSecureSettings(live)
                    }
                }
            }
            "setEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") == true
                if (!enabled) {
                    control.selfCheck.stop()
                        control.background.changeGateIntent { privilegedActions.select() }
                    val cleared = control.background.clearKeep()
                    controlIo.execute { control.background.saveKeep(cleared) }
                    control.background.cancelRootSelection()
                }
                if (enabled) {
                    async(result) { control.background.preparePhoneEnable() && control.setEnabled(true) }
                } else {
                    dispatchPhoneDisable(controlIo, io, { control.setEnabled(false) }, {
                        control.background.setBackgroundMode("off")["ok"] == true
                    }) { complete(result, it) }
                }
            }
            "openAccessibilitySettings" -> result.success(startActivity(control.accessibilitySettingsIntent()))
            "openAppDetails" -> result.success(startActivity(control.appDetailsIntent()))
            "testScreen" -> async(result) { control.testScreen() }
            "setBackgroundMode" -> {
                val mode = call.argument<String>("mode") ?: "off"
                control.selfCheck.stop()
                val live = stillWanted(control.background.changeGateIntent { privilegedActions.select() })
                // A mode intent revokes keep before it waits behind any older long operation.
                control.background.clearKeepForMode(mode)?.let { cleared ->
                    controlIo.execute { control.background.saveKeep(cleared) }
                }
                if (mode != "root") control.background.cancelRootSelection()
                async(result) { if (live()) control.background.setBackgroundMode(mode, live) else cancelledSelection() }
            }
            "requestShizukuPermission" -> {
                val live = stillWanted(privilegedActions.snapshot())
                val provider = call.argument<String>("provider")
                async(result) { live() && control.background.requestShizukuPermission(provider) }
            }
            "prepareRoot" -> {
                val live = stillWanted(control.background.changeGateIntent { privilegedActions.select() })
                control.background.cancelUnwantedPending()
                async(result) { if (live()) control.background.prepareRoot(live) else cancelledSelection() }
            }
            "adbStartPairing" -> async(result) { control.background.adbStartPairing() }
            "adbPair" -> async(result) {
                val code = call.argument<String>("code")?.trim().orEmpty()
                if (code.isEmpty()) mapOf("ok" to false, "reason" to AppStrings.get(appContext, R.string.pairing_enter_code_error)) else control.background.adbPair(code, call.argument<Int>("port"))
            }
            "adbConnect" -> {
                val live = stillWanted(privilegedActions.snapshot())
                async(result) { control.background.adbConnect(call.argument<Int>("port"), live) }
            }
            "getPolicies" -> async(result) { control.policiesMap() }
            // Settings-only read projection. Reuses the original launcher-app
            // inventory and Skivu's existing alphabetical/pinyin picker metadata;
            // it is not registered as a model tool or an execution permission.
            "policyApps" -> async(result) {
                val alphabet = com.skyjjgw.independent.ski.AppAlphabet()
                control.system().apps().map { entry ->
                    mapOf("package" to entry.packageName, "name" to entry.label) + alphabet.fields(entry.label)
                }
            }
            "setPolicies" -> async(result) { control.setPolicies(call.arguments as? Map<*, *>) }
            "actionLog" -> result.success(control.log.toMaps(call.argument<Int>("limit") ?: 100))
            // l10n:keep agent stop reason
            "stopTask" -> result.success(if (call.hasArgument("taskId") && taskId(call) == null) false
                else control.stopTask("用户在 App 里停止", taskId(call)))
            "retryTaskCleanup" -> async(result) { taskId(call)?.let(control::retryTaskCleanup) == true }
            "resumeTask" -> result.success(taskId(call)?.let(control::resumeTask) == true)
            "pauseTask" -> result.success(taskId(call)?.let { control.pauseTask(it, call.argument<Boolean>("paused") == true) } == true)
            "finishTask" -> finishTask(call, result)
            "presentPrompt" -> {
                val owner = promptOwner
                val request = EnginePhonePrompt.parse(call.arguments as? Map<*, *>)
                if (!attached) result.success(PhonePrompts.unavailable("stale"))
                else if (request == null) result.success(PhonePrompts.unavailable("invalid"))
                else control.prompts.present(request, owner, { attached && promptOwner === owner }) {
                    if (attached && promptOwner === owner) result.success(it)
                }
            }
            "cancelPrompt" -> {
                val id = call.argument<String>("requestId")
                result.success(id != null && id.length in 1..200 && control.prompts.cancel(id))
            }
            // 设置 → 手机操控 → 悬浮条: {idleOpacity 0.3–1, autoCollapse}; a showing overlay follows at once.
            "overlayPrefs" -> result.success(OverlayPrefs.read(appContext).toMap())
            "setOverlayPrefs" -> result.success(OverlayPrefs.write(appContext, call.arguments as? Map<*, *>).toMap())
            else -> result.notImplemented()
        }
        if (call.method == "setBackgroundMode" || call.method == "adbConnect" || call.method == "requestShizukuPermission") {
            control.emitStatus()
        }
    }

    /** Only this local attachment can admit a run; physical work has its own coordinator worker. */
    private fun selfCheckCall(call: MethodCall, result: MethodChannel.Result) {
        val owner = promptOwner
        val live = { attached && promptOwner === owner }
        if (!live()) { result.success(control.selfCheck.refused(PhoneSelfCheckReport.Reason.RETIRED)); return }
        val args = call.arguments as? Map<*, *>
        val valid = when (call.method) {
            "phoneSelfCheckStatus" -> call.arguments == null
            "startPhoneSelfCheck" -> args != null && args["v"] is Int && args["v"] == 1 &&
                (args.keys == setOf("v") || args.keys == setOf("v", "profile") &&
                    PhoneSelfCheckReport.Profile.parse(args["profile"]) != null)
            else -> args != null && args.keys == setOf("v", "runHandle") && args["v"] is Int &&
                args["v"] == 1 && args["runHandle"] is String
        }
        if (!valid) { result.success(control.selfCheck.refused(PhoneSelfCheckReport.Reason.INVALID_ARGUMENTS)); return }
        val value = when (call.method) {
            "startPhoneSelfCheck" -> {
                val host = activity?.activity
                if (host == null || !AppVisibility.isResumed(host))
                    control.selfCheck.refused(PhoneSelfCheckReport.Reason.UNAVAILABLE)
                else control.selfCheck.start(owner, live,
                    PhoneSelfCheckReport.Profile.parse(args?.get("profile")) ?: PhoneSelfCheckReport.Profile.PROBE_B,
                    { activity?.activity?.takeIf { live() && AppVisibility.isResumed(it) } })
            }
            "phoneSelfCheckStatus" -> control.selfCheck.status()
            else -> control.selfCheck.cancel(checkNotNull(args)["runHandle"] as String)
        }
        result.success(value)
    }

    /** Capture this attachment, never borrow the Client from a newer engine when queued work runs. */
    private fun replayRejected(reason: String): Map<String, Any?> = mapOf("kind" to "rejected", "reason" to reason)

    private fun skillReplayLive(value: SkillInspection): Boolean = attached && skillClient === value.client &&
        control.skillDrafts.clientCurrent(value.client) && control.skillDrafts.currentEpoch() == value.epoch &&
        value.origin.runtime.phoneSkillOriginCurrent(value.origin)

    private fun inspectSkillReplay(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val name = args?.get("skillId") as? String
        val client = skillClient
        val host = activity?.activity
        skillInspection = null
        val request = Any().also { skillSelectionRequest = it }
        if (args?.keys != setOf("skillId") || name == null || !Regex("phone-task-[a-f0-9]{32}").matches(name)) {
            result.success(replayRejected("invalid")); return
        }
        if (!attached || client == null || host == null || !AppVisibility.isResumed(host)) {
            result.success(replayRejected("unavailable")); return
        }
        val runtime = RuntimeController.get(appContext)
        val origin = runtime.capturePhoneSkillOrigin()
        val epoch = control.skillDrafts.currentEpoch()
        if (origin == null) { result.success(replayRejected("stale")); return }
        runtime.readPhoneSkillBundle(origin, name, null, PhoneSkillReplayApps.descriptors) { read ->
            if (read !is PhoneSkillBundleReader.Read.Accepted) {
                result.success(replayRejected("unsupported")); return@readPhoneSkillBundle
            }
            controlIo.execute {
                val choices = PhoneSkillReplayApps.choices(appContext, read.route.descriptorId)
                val summary = PhoneSkillReplayApps.summary(read.route)
                main.post {
                    val inspection = SkillInspection(client, epoch, origin, read, choices)
                    if (skillSelectionRequest !== request || !skillReplayLive(inspection)) {
                        result.success(replayRejected("stale"))
                    } else if (choices.isEmpty() || summary == null) {
                        result.success(replayRejected("unsupported"))
                    } else {
                        skillInspection = inspection
                        result.success(mapOf("kind" to "available", "revision" to read.route.revision,
                            "summary" to summary, "apps" to choices.map { choice -> mapOf(
                                "packageName" to choice.app.packageName, "uid" to choice.app.uid, "label" to choice.label) }))
                    }
                }
            }
        }
    }

    private fun prepareSkillReplay(call: MethodCall, result: MethodChannel.Result) {
        val request = PhoneSkillReplaySelections.Request.parse(call.arguments)
        val inspection = skillInspection
        val host = activity?.activity
        if (request == null) { result.success(replayRejected("invalid")); return }
        if (inspection == null || host == null || !AppVisibility.isResumed(host) || !skillReplayLive(inspection) ||
            inspection.bundle.route.skillName != request.name || inspection.bundle.route.revision != request.revision) {
            result.success(replayRejected("stale")); return
        }
        val selected = inspection.choices.singleOrNull { it.app.packageName == request.packageName && it.app.uid == request.uid }
        if (selected == null) { result.success(replayRejected("unsupported")); return }
        val ticket = Any().also { skillSelectionRequest = it }
        val runtime = inspection.origin.runtime
        runtime.readPhoneSkillBundle(inspection.origin, request.name, request.revision, PhoneSkillReplayApps.descriptors) { read ->
            if (read !is PhoneSkillBundleReader.Read.Accepted || read.routeSha256 != inspection.bundle.routeSha256 ||
                read.skillSha256 != inspection.bundle.skillSha256 || read.draftRevision != inspection.bundle.draftRevision) {
                result.success(replayRejected("stale")); return@readPhoneSkillBundle
            }
            if (SkillReplaySupport.screen(read.route) == null) {
                result.success(replayRejected("unsupported")); return@readPhoneSkillBundle
            }
            controlIo.execute {
                val now = PhoneSkillReplayApps.choices(appContext, read.route.descriptorId)
                    .singleOrNull { it.app == selected.app }
                main.post {
                    if (skillSelectionRequest !== ticket || !skillReplayLive(inspection)) {
                        result.success(replayRejected("stale"))
                    } else if (now == null) result.success(replayRejected("app_changed"))
                    else {
                        val drafts = control.skillDrafts
                        val originalClient = inspection.client
                        val originalEpoch = inspection.epoch
                        val originalOrigin = inspection.origin
                        val pending = control.skillReplaySelections.prepare(originalClient, originalEpoch,
                            { drafts.clientCurrent(originalClient) && drafts.currentEpoch() == originalEpoch &&
                                runtime.phoneSkillOriginCurrent(originalOrigin) }, request, read, now.app)
                        result.success(if (pending == null) replayRejected("busy") else mapOf("kind" to "ready",
                            "invocation" to pending.invocation, "revision" to request.revision,
                            "parameterNames" to emptyList<String>()))
                    }
                }
            }
        }
    }

    private fun skillCall(call: MethodCall, result: MethodChannel.Result) {
        val client = skillClient
        if (client == null) { result.success(PhoneSkillBridge.rejected("stale")); return }
        controlIo.execute {
            fun finish(value: Map<String, Any?>) {
                main.post {
                    if (skillClient === client) result.success(value)
                    else result.success(PhoneSkillBridge.rejected("stale"))
                }
            }
            if (call.method == "skillDraft" && (call.arguments as? Map<*, *>)?.get("action") == "check_save") {
                control.skillBridge.checkSave(client, call.arguments, ::finish)
            } else {
                val value = try { control.skillBridge.call(client, call.method, call.arguments) }
                    catch (_: Exception) { PhoneSkillBridge.rejected("io") }
                finish(value)
            }
        }
    }

    private fun taskId(call: MethodCall): Long? = when (val id = call.argument<Any>("taskId")) {
        is Int -> id.toLong().takeIf { it > 0 }
        is Long -> id.takeIf { it > 0 }
        else -> null
    }

    private fun cancelledSelection(): Map<String, Any?> =
        mapOf("ok" to false, "reason" to AppStrings.get(appContext, R.string.background_selection_cancelled))

    /** Whether the UI action that took [ticket] still counts when the worker reaches it. */
    private fun stillWanted(ticket: Long): () -> Boolean = { attached && privilegedActions.current(ticket) }

    /**
     * `finishTask {taskId, sessionId?, host?, reopen}`: the linked turn ended. Closes the
     * overlay; with [reopen] and the app in the background, brings it forward on that conversation
     * and waits up to 3 seconds to see its real host resumed. Answers also include `notified`
     * and `current`: closed remains a fact if a successor retires delayed return permission.
     * `busy` — not closed while a phone call runs (not proof of ownership); `opened` — the app
     * is on screen now; `launched` — the start adapter returned true, not proof of visibility.
     */
    private fun finishTask(call: MethodCall, result: MethodChannel.Result) {
        val pluginOwner = promptOwner
        val rawTask = call.argument<Any>("taskId")
        val taskId = when (rawTask) { is Int -> rawTask.toLong(); is Long -> rawTask; else -> null }?.takeIf { it > 0 }
        val session = call.argument<String>("sessionId")?.takeIf { it.isNotEmpty() }
        val host = call.argument<String>("host")
        val returnSession = if (call.argument<Boolean>("appOnly") == true) null else session
        val reopen = call.argument<Boolean>("reopen") == true
        val runId = call.argument<String>("runId")
        val rawGeneration = call.argument<Any>("generation")
        val generation = when (rawGeneration) { is Int -> rawGeneration.toLong(); is Long -> rawGeneration; else -> null }
        io.execute {
            if (!attached || promptOwner !== pluginOwner) {
                main.post { result.success(mapOf("closed" to false, "busy" to false, "opened" to false,
                    "launched" to false, "notified" to false, "current" to false, "reason" to "stale")) }
                return@execute
            }
            val state = taskId?.let(control::taskState)
            val matches = taskId != null && (control.taskSession(taskId) == null || control.taskSession(taskId) == session)
            val scope = if (matches) taskId?.let {
                if (control.taskSession(it) != null) {
                    if (runId != null && generation != null) control.completedTask(it, runId, generation) else null
                } else runCatching { control.finishTaskScope(it) }.getOrNull()
            } else null
            val closed = scope != null
            val busy = !closed && taskId != null && control.taskBusy(taskId)
            val waitingOwner = scope ?: if (matches) state?.activeOwner(taskId) else null
            main.post {
                PhoneTaskReturn(
                    current = { attached && promptOwner === pluginOwner && waitingOwner != null && taskId != null && control.taskOwnerCurrent(taskId, waitingOwner) },
                    visible = control.prompts::appResumed,
                    launch = { control.reopen(returnSession, host) },
                    notify = { taskId != null && control.notificationGate.notifyFinished(taskId, returnSession, host) },
                    schedule = { delay, block -> main.postDelayed(block, delay) },
                    clock = SystemClock::elapsedRealtime,
                ).start(closed, busy, reopen, result::success)
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink?.let { control.removeSink(it) }
        val s: (Map<String, Any?>) -> Unit = { events.success(it) }
        sink = s
        control.addSink(s)
    }

    override fun onCancel(arguments: Any?) {
        sink?.let { control.removeSink(it) }
        sink = null
    }

}
