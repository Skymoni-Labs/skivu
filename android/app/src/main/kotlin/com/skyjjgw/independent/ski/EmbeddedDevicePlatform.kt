package com.skyjjgw.independent.ski

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.AlarmClock
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import org.skivu.engine.adb.EmbeddedAdbEngine

/** Native, in-APK capability host. All Android authority is checked here again. */
class EmbeddedDevicePlatform(private val activity: android.content.Context) {
    private val hostActivity get()=activity as? Activity
    private val prefs = activity.getSharedPreferences("skivu.device-engine.v1", 0)
    private val worker = Executors.newSingleThreadExecutor()
    private val cancellationWorker = Executors.newSingleThreadExecutor()
    private val inspectionWorker = Executors.newSingleThreadExecutor()
    private val pendingInvocations = java.util.concurrent.atomic.AtomicInteger()
    private val main = Handler(Looper.getMainLooper())
    private val remembered = linkedMapOf<String, Map<String, Any?>>()
    private val receiptStore = lazy {
        DeviceReceiptStore(activity.applicationContext).also { store ->
            val migrated = prefs.all.filterKeys { it.startsWith("request.") }
            for ((key, value) in migrated) if (store.read(key.removePrefix("request.")) == null) {
                store.write(key.removePrefix("request."), JSONObject(value as String))
            }
            if (migrated.isNotEmpty()) check(prefs.edit().apply { migrated.keys.forEach { remove(it) } }.commit())
        }
    }
    private val receipts by receiptStore
    private val adb by lazy { EmbeddedAdbEngine(activity.applicationContext) }
    private val cancellationEpoch = java.util.concurrent.atomic.AtomicLong()
    private val closed = java.util.concurrent.atomic.AtomicBoolean(false)
    private val cancelledRequests = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    @Volatile private var activeRequest: String? = null
    @Volatile private var activeOwner: String? = null
    // Accessed only on the Android main thread; retain recent stop proof after invoke returns.
    private val requestStops = linkedMapOf<String, java.util.concurrent.Future<Map<String, Any?>>>()
    private fun rememberStop(key: String?, future: java.util.concurrent.Future<Map<String, Any?>>?) {
        if (key == null || future == null) return
        requestStops[key] = future
        if (requestStops.size > 100) requestStops.remove(requestStops.keys.first())
    }
    fun close() {
        if (!closed.compareAndSet(false,true)) return
        cancellationEpoch.incrementAndGet(); adb.close()
        if(hostActivity!=null){EmbeddedTaskService.taskId = null; EmbeddedTaskService.stopTask = null
        activity.stopService(Intent(activity, EmbeddedTaskService::class.java))}
        worker.execute { if (receiptStore.isInitialized()) receipts.close() }
        worker.shutdown()
        cancellationWorker.shutdown()
        inspectionWorker.shutdown()
    }

    fun register(messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, "skivu/device_engine")
        EmbeddedTaskService.stopTask = { id ->
            if (activeOwner == "assistant:$id") {
                val key = activeRequest
                key?.let { cancelledRequests.add(it) }
                rememberStop(key, adb.stop())
            }
            main.post { channel.invokeMethod("taskStopped", mapOf("taskId" to id)) }
        }
        channel.setMethodCallHandler { call, result ->
            if (closed.get()) {
                result.error("DEVICE_ENGINE_CLOSED", "设备会话已关闭。", null)
                return@setMethodCallHandler
            }
            @Suppress("UNCHECKED_CAST")
            val p = call.arguments as? Map<String, Any?> ?: emptyMap()
            // The authorization page must remain usable while a long script
            // owns the execution worker. Never probe over its active stream.
            val flowInspection = call.method == "invoke" && p["tool"] == "ui.flow.read"
            if ((call.method in setOf("status", "apps") || flowInspection) && pendingInvocations.get() > 0) {
                inspectionWorker.execute {
                    try {
                        check(!closed.get()) { "设备会话已关闭。" }
                        val answer = when {
                            flowInspection -> invoke(p)
                            call.method == "status" -> status(false)
                            else -> installedApps()
                        }
                        main.post { result.success(answer) }
                    } catch (e: Exception) {
                        main.post { result.error("DEVICE_ENGINE", e.message ?: "设备状态未能读取。", null) }
                    } catch (_: LinkageError) {
                        main.post { result.error("DEVICE_ENGINE_UNSUPPORTED", "此系统暂不支持当前设备状态查询。", null) }
                    }
                }
                return@setMethodCallHandler
            }
            if (call.method == "cancelRequest") {
                if (p["owner"] !is String || p["requestId"] !is String) {
                    result.error("DEVICE_ENGINE", "缺少本次请求身份。", null)
                    return@setMethodCallHandler
                }
                val key = digest("${p["owner"]}:${p["requestId"]}")
                cancelledRequests.add(key)
                val stopping = requestStops[key] ?: if (activeRequest == key) adb.stop() else null
                rememberStop(key, stopping)
                cancellationWorker.execute {
                    val answer = adb.awaitStop(stopping)
                    main.post { result.success(answer) }
                }
                return@setMethodCallHandler
            }
            var stopping: java.util.concurrent.Future<Map<String, Any?>>? = null
            if (call.method == "adb.stop" || call.method == "stop" ||
                call.method == "configure") {
                cancellationEpoch.incrementAndGet()
                stopping = adb.stop()
                rememberStop(activeRequest, stopping)
            }
            if (call.method == "stop") {
                val future = stopping
                cancellationWorker.execute {
                    val answer = adb.awaitStop(future)
                    main.post { result.success(answer) }
                }
                return@setMethodCallHandler
            }
            val epoch = cancellationEpoch.get()
            val invocation = call.method == "invoke"
            if (invocation) pendingInvocations.incrementAndGet()
            worker.execute {
                try {
                    check(epoch == cancellationEpoch.get()) { "这次设备请求已经取消。" }
                    val answer = when (call.method) {
                        "status" -> status()
                        "effect.lookup" -> {
                            require(p.keys == setOf("tool", "arguments"))
                            val tool = text(p, "tool", 120)
                            @Suppress("UNCHECKED_CAST")
                            val args = p["arguments"] as? Map<String, Any?> ?: error("操作参数无效。")
                                                // Read-only lookup also covers requests from older app versions.
                            val prior = receipts.submitted(digest("$tool:${JSONObject(args)}"))
                            if (prior == null) mapOf("found" to false) else mapOf(
                                "found" to true, "outcome" to prior.getString("outcome"),
                                "summary" to prior.getString("summary"))
                        }
                        "apps" -> installedApps()
                        "result.open" -> {
                            require(p.keys == setOf("target"))
                            val target = text(p, "target", 220)
                            // Display-only navigation, never replay the creating action.
                            when (target) {
                                "clock.alarms" -> openSystem(Intent(AlarmClock.ACTION_SHOW_ALARMS)) {}
                                "clock.timers" -> openSystem(Intent(AlarmClock.ACTION_SHOW_TIMERS)) {}
                                "settings.display" -> ui { launch(Intent(Settings.ACTION_DISPLAY_SETTINGS)) }
                                else -> {
                                    require(target.startsWith("app:")) { "结果入口不存在。" }
                                    val pkg = target.removePrefix("app:")
                                    require(pkg in packages()) { "此软件已不在授权范围内。" }
                                    val intent = activity.packageManager.getLaunchIntentForPackage(pkg) ?: error("软件没有可打开的入口。")
                                    ui { launch(intent) }
                                }
                            }
                            mapOf("opened" to true)
                        }
                        "pairing.start" -> {
                            require(Build.VERSION.SDK_INT >= 30) { "无线配对需要 Android 11 或更新系统。" }
                            require(enabled("enabled") && enabled("shell")) { "请先启用代码执行能力。" }
                            if(!activity.getSystemService(android.app.NotificationManager::class.java).areNotificationsEnabled()) {
                                mapOf("outcome" to "permission_required", "summary" to "请先允许 Skivu 显示通知，以便在系统窗口内填写配对码。")
                            } else {
                                ui { activity.startForegroundService(Intent(activity, EmbeddedPairingService::class.java)) }
                                mapOf("outcome" to "dispatched", "summary" to "配对通知已开启。打开系统配对窗口，保持窗口打开，在通知中输入六位代码。")
                            }
                        }
                        "session.start" -> {
                            val id = text(p,"taskId",100)
                            EmbeddedTaskService.activeTasks.add(id)
                            EmbeddedTaskService.taskId = id
                            ui { activity.startForegroundService(Intent(activity, EmbeddedTaskService::class.java).putExtra("taskId",id)) }
                            mapOf("active" to true)
                        }
                        "session.end" -> {
                            EmbeddedTaskService.activeTasks.remove(p["taskId"])
                            if (EmbeddedTaskService.taskId == p["taskId"]) {
                                val next=EmbeddedTaskService.activeTasks.firstOrNull()
                                EmbeddedTaskService.taskId = next
                                ui { if(next==null)activity.stopService(Intent(activity, EmbeddedTaskService::class.java))else activity.startForegroundService(Intent(activity,EmbeddedTaskService::class.java).putExtra("taskId",next)) }
                            }
                            PhoneControlArbiter.release("assistant:${p["taskId"]}")
                            mapOf("active" to false)
                        }
                        "configure" -> configure(p)
                        "authorization" -> authorize(p)
                        "adb.pair" -> {
                            require(enabled("enabled") && enabled("shell")) { "请先启用代码执行能力。" }
                            require(p.keys == setOf("port", "code"))
                            adb.pair(integer(p, "port", 1024..65535), text(p, "code", 6))
                        }
                        "adb.connect" -> {
                            require(enabled("enabled") && enabled("shell")) { "请先启用代码执行能力。" }
                            require(p.keys.all { it in setOf("port", "legacy", "allowRoot", "trustPeer") })
                            require(!p.containsKey("trustPeer") || p["trustPeer"] is Boolean)
                            require((p["legacy"] != true && p["allowRoot"] != true) ||
                                activity.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0 &&
                                activity.packageName.endsWith(".engineqa")) {
                                "正式入口仅接受系统无线配对连接。"
                            }
                            adb.connect(integer(p, "port", 1024..65535), p["legacy"] == true, p["allowRoot"] == true, p["trustPeer"] == true)
                        }
                        "adb.stop" -> { adb.disconnect(); mapOf("connected" to false) }
                        "invoke" -> {
                            val key = digest("${p["owner"]}:${p["requestId"]}")
                            activeRequest = key
                            activeOwner = p["owner"] as? String
                            try { invoke(p) } finally {
                                activeRequest = null; activeOwner = null; cancelledRequests.remove(key)
                            }
                        }
                        else -> error("设备引擎方法不存在。")
                    }
                    main.post { result.success(answer) }
                } catch (e: Exception) {
                    main.post { result.error("DEVICE_ENGINE", e.message ?: "设备操作未完成。", null) }
                } catch (_: LinkageError) {
                    main.post { result.error("DEVICE_ENGINE_UNSUPPORTED", "此系统暂不支持当前内置执行后端，请保留回执并核对已执行操作。", null) }
                } finally {
                    if (invocation) pendingInvocations.decrementAndGet()
                }
            }
        }
    }

    private fun <T> ui(action: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return action()
        val task = FutureTask(action)
        main.post(task)
        return task.get()
    }
    private fun enabled(name: String) = prefs.getBoolean(name, false)
    private fun packages():Set<String> = if(prefs.getBoolean("allApplications",false))activity.packageManager.getInstalledApplications(0).map{it.packageName}.toSet() else prefs.getStringSet("packages", emptySet()).orEmpty().toSet()
    private fun installedApps(): List<Map<String, Any?>> {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val alphabet = AppAlphabet()
        val allowed = packages()
        return activity.packageManager.queryIntentActivities(intent, 0)
            .distinctBy { it.activityInfo.packageName }.map {
                val name = it.loadLabel(activity.packageManager).toString()
                mapOf("package" to it.activityInfo.packageName,
                    "name" to name,
                    "allowed" to (it.activityInfo.packageName in allowed)) + alphabet.fields(name)
            }
    }
    internal fun status(probeBackend: Boolean = true): Map<String, Any?> {
        val backend = if (enabled("enabled") && enabled("shell")) {
            if (probeBackend) adb.probe() else adb.executionSnapshot()
        } else emptyMap()
        return mapOf(
        "version" to 1, "androidSdk" to Build.VERSION.SDK_INT,
        "developerOptions" to (Settings.Global.getInt(activity.contentResolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) == 1),
        "enabled" to enabled("enabled"), "system" to enabled("system"),
        "control" to enabled("control"), "shell" to enabled("shell"),
        "accessibility" to (SkivuAccessibilityService.connected != null),
        "locked" to activity.getSystemService(android.app.KeyguardManager::class.java).isDeviceLocked,
        "interactive" to activity.getSystemService(android.os.PowerManager::class.java).isInteractive,
        "writeSettings" to Settings.System.canWrite(activity),
        "notifications" to activity.getSystemService(android.app.NotificationManager::class.java).areNotificationsEnabled(),
        "shellConnected" to (backend["connected"] == true), "shellUid" to backend["uid"],
        "shellStatusSource" to if (probeBackend) "probe" else "execution_snapshot",
        "shellPaired" to adb.isPaired(),
        "packages" to prefs.getStringSet("packages",emptySet()).orEmpty().toList(),"allApplications" to prefs.getBoolean("allApplications",false),
        "recognitionMode" to prefs.getString("recognitionMode","auto"),"localOcr" to (Build.VERSION.SDK_INT>=30)
        )
    }

    private fun configure(p: Map<String, Any?>): Map<String, Any?> {
        require(p.keys.containsAll(setOf("enabled", "system", "control", "shell", "packages"))&&p.keys.all{it in setOf("enabled", "system", "control", "shell", "packages","allApplications","recognitionMode")})
        if(p.containsKey("recognitionMode"))PhoneVision.mode(p["recognitionMode"])
        for (key in listOf("enabled", "system", "control", "shell")) require(p[key] is Boolean)
        val apps = (p["packages"] as? List<*>)?.map {
            require(it is String && Regex("^[a-zA-Z][a-zA-Z0-9_]*(\\.[a-zA-Z0-9_]+)+$").matches(it))
            it
        }?.toSet() ?: error("请选择软件范围。")
        require(prefs.edit().apply {
            for (key in listOf("enabled", "system", "control", "shell")) putBoolean(key, p[key] as Boolean)
            putStringSet("packages", apps)
            if(p["allApplications"] is Boolean)putBoolean("allApplications",p["allApplications"] as Boolean)
            if(p.containsKey("recognitionMode"))putString("recognitionMode",p["recognitionMode"] as String)
        }.commit()) { "授权设置没有保存。" }
        if (p["enabled"] != true || p["shell"] != true) {
            ui { activity.stopService(Intent(activity, EmbeddedPairingService::class.java)) }
        }
        return status()
    }

    private fun authorize(p: Map<String, Any?>): Map<String, Any?> {
        if(p["page"] == "notifications" && Build.VERSION.SDK_INT >= 33) {
            ui { (hostActivity?:error("系统权限需要用户在小云页面确认。")).requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),7221) }
            return mapOf("outcome" to "dispatched", "summary" to "请由用户在系统窗口确认通知授权。")
        }
        val intent = when (p["page"]) {
            "notifications" -> Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE,activity.packageName)
            "accessibility" -> Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            "writeSettings" -> Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:${activity.packageName}"))
            "wirelessDebugging" -> Intent(if (Settings.Global.getInt(activity.contentResolver,
                Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) == 1)
                Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS else Settings.ACTION_DEVICE_INFO_SETTINGS)
            else -> error("授权页面不存在。")
        }
        ui { launch(intent) }
        return mapOf("outcome" to "dispatched", "summary" to "已打开系统设置，请完成授权后返回核对状态。")
    }

    internal fun invoke(p: Map<String, Any?>,leaseCheck:()->Unit={}): Map<String, Any?> {
        require(p.keys == setOf("version", "owner", "requestId", "tool", "arguments") && p["version"] == 1)
        val id = p["requestId"] as? String ?: error("缺少请求编号。")
        val owner = p["owner"] as? String ?: error("缺少调用身份。")
        require(Regex("^[a-zA-Z0-9_-]{1,100}$").matches(id))
        require(Regex("^[a-zA-Z0-9_.:-]{1,180}$").matches(owner))
        val tool = p["tool"] as? String ?: error("缺少工具名称。")
        @Suppress("UNCHECKED_CAST")
        val args = p["arguments"] as? Map<String, Any?> ?: error("缺少工具参数。")
        val key = digest("$owner:$id")
        val fingerprint = digest("$tool:${JSONObject(args)}")
        fun receipt(outcome: String, summary: String, value: Any? = null): Map<String, Any?> =
            mapOf("requestId" to id, "tool" to tool, "outcome" to outcome,
                "summary" to summary, "value" to value)
        if (tool == "device.status") return receipt("verified", "设备状态已读取。", status())
        if(tool=="device.receipt"){val original=args["originalRequestId"] as String;val saved=receipts.read(digest("$owner:$original"));return receipt("verified","原请求持久回执已读取，没有重新执行。",if(saved==null)mapOf("found" to false)else mapOf("found" to true,"originalRequestId" to original,"outcome" to saved.optString("outcome"),"summary" to saved.optString("summary"),"value" to plain(saved.opt("value"))))}
        if(tool=="ui.flow.read") {
            require(args.keys==setOf("originalRequestId"))
            val original=args["originalRequestId"] as? String?:error("缺少原流程编号。")
            val saved=receipts.read(digest("$owner:$original"))
            val value=saved?.let{plain(it.opt("value"))} as? Map<*,*>
            require(value?.get("flowVersion")==1){"本会话没有这个本地流程。"}
            return receipt("verified","已读取本地流程检查点，没有执行动作。",value!!.filterKeys{it!="plan"})
        }
        if(tool in setOf("shell.output.read","shell.output.export")){
            val output=args["outputId"] as String;val stream=args["stream"] as? String?:"stdout";val logs=CloudShellOutputs(activity)
            return receipt("verified","已读取原高权限执行日志，没有重新连接或执行。",if(tool=="shell.output.export")logs.export(owner,output,stream)else logs.page(owner,output,stream,(args["offset"] as? Number)?.toLong()?:0,(args["length"] as? Number)?.toInt()?:48000))
        }
        val permission = when {
            tool in setOf("apps.list","ui.observe","ui.verify","ui.wait","ui.screenshot","settings.brightness.read") -> "observe"
            tool == "apps.launch" || tool.startsWith("ui.") -> "control"
            tool.startsWith("clock.") || tool.startsWith("settings.") -> "system"
            tool == "shell.execute" -> "shell"
            else -> error("设备工具不存在。")
        }
        if (!enabled("enabled") || (permission != "observe" && !enabled(permission)))
            return receipt("permission_required", "请先在手机能力设置中启用并授权这项能力。")
        leaseCheck()
        if(tool.startsWith("ui.")||tool in setOf("apps.launch","clock.alarm.create","clock.timer.start","clock.alarms.show","settings.open")){
            PhoneControlArbiter.acquire(owner){leaseCheck();check(key !in cancelledRequests){"此设备调用已撤销。"}}
        }
        val cached = receipts.read(key)
        if (cached != null) {
            require(cached.getString("fingerprint") == fingerprint) { "同一请求编号不能用于不同操作。" }
            return remembered[key] ?: receipt(cached.getString("outcome"), cached.getString("summary"),plain(cached.opt("value")))
        }
        val writing = tool !in setOf("apps.list","ui.observe","ui.verify","ui.wait","ui.screenshot","settings.brightness.read")
        fun persist(outcome: String, summary: String, value:Any?=null) {
            // Large result bodies live in app-private immutable blob segments.
            val item = JSONObject(mapOf("fingerprint" to fingerprint, "outcome" to outcome, "summary" to summary))
            if(value!=null)item.put("value",value)
            receipts.write(key, item)
        }
        if (key in cancelledRequests) {
            if (writing) persist("cancelled", "此设备调用已撤销，未派发操作。")
            return receipt("cancelled", "此设备调用已撤销，未派发操作。")
        }
        if (writing) {
            persist("unknown", "上次请求结果尚未核对，不会自动重放。")
        }
        var actionAttempted = false
        fun beforeAction() {
            leaseCheck();check(key !in cancelledRequests) { "此设备调用已撤销。" }
            if(!enabled("enabled") || (permission!="observe" && !enabled(permission)))throw PhoneFlow.Blocked("permission_required","这项手机操作的授权已关闭，未派发动作。")
            actionAttempted = true
        }
        fun checkObservation() {
            leaseCheck();check(key !in cancelledRequests){"此设备调用已撤销。"}
            if(!enabled("enabled") || (writing && permission!="observe" && !enabled(permission)))throw PhoneFlow.Blocked("permission_required","手机操控授权已关闭。")
            val service=SkivuAccessibilityService.connected?:error("无障碍服务未连接。")
            ui { val root=service.current(packages());@Suppress("DEPRECATION") root.recycle() }
        }
        val recognitionMode=PhoneVision.mode(args["recognitionMode"],prefs.getString("recognitionMode","auto")?:"auto")
        val answer = try {
            when (tool) {
                "apps.list" -> {
                    require(args.isEmpty())
                    receipt("verified", "已读取授权范围内可启动的软件。", installedApps().filter{it["allowed"]==true})
                }
                "apps.launch" -> {
                    require(args.keys == setOf("package"))
                    val target = args["package"] as? String ?: error("缺少软件包名。")
                    require(target in packages()) { "目标软件尚未授权。" }
                    val intent = activity.packageManager.getLaunchIntentForPackage(target) ?: error("软件没有启动入口。")
                    ui { beforeAction(); launch(intent) }
                    receipt("dispatched", "已请求打开软件，请观察界面核对。")
                }
                "ui.observe" -> {
                    val service = SkivuAccessibilityService.connected
                    if (service == null) receipt("permission_required", "请先开启 Skivu 无障碍服务。")
                    else receipt("verified", "已观察授权软件当前界面。", service.vision.observe(packages(),args,recognitionMode,owner,::checkObservation))
                }
                "ui.wait"->{
                    require(args.keys.all{it in setOf("milliseconds")});val duration=(args["milliseconds"] as? Number)?.toLong()?:500;require(duration in 100..10000)
                    val until=android.os.SystemClock.uptimeMillis()+duration
                    while(android.os.SystemClock.uptimeMillis()<until){check(key !in cancelledRequests);Thread.sleep(minOf(100,until-android.os.SystemClock.uptimeMillis()).coerceAtLeast(1))}
                    val service=SkivuAccessibilityService.connected
                    if(service==null)receipt("permission_required","无障碍服务未连接。")else receipt("verified","已等待并重新观察。",service.vision.observe(packages(),emptyMap(),recognitionMode,owner,::checkObservation))
                }
                "ui.verify"->{val service=SkivuAccessibilityService.connected
                    if(service==null)receipt("permission_required","无障碍服务未连接。")else {val proof=if(service.vision.hasProof(args["requestId"].toString(),owner))service.vision.verify(args,packages(),owner,recognitionMode,::checkObservation)else ui{service.verify(args,packages(),owner)};receipt(if(proof["matched"]==true)"verified" else "unknown",if(proof["matched"]==true)"已依据新观察核对原动作。" else "未满足明确核对条件；不会重复原动作。",proof)}
                }
                "ui.screenshot"->{val service=SkivuAccessibilityService.connected
                    if(service==null)receipt("permission_required","无障碍服务未连接。")else receipt("verified","已取得授权页面实际截图；图片能否理解取决于当前模型真实视觉能力。",service.screenshot(packages(),args))}
                "ui.flow", "ui.flow.resume" -> {
                    runPhoneFlow(tool,args,owner,id,key,fingerprint,leaseCheck,::beforeAction)
                }
                "ui.tap", "ui.input", "ui.scroll", "ui.back", "ui.home", "ui.longPress", "ui.swipe" -> {
                    val service = SkivuAccessibilityService.connected
                    if (service == null) receipt("permission_required", "请先开启 Skivu 无障碍服务。")
                    else {
                        val accepted = if((args["observationId"] as? String)?.startsWith("ocr:")==true)service.vision.act(tool,args,packages(),owner,id,recognitionMode,::checkObservation,::beforeAction)else ui { service.act(tool, args, packages(), ::beforeAction,id,owner) }
                        receipt(if (accepted) "dispatched" else "failed",
                            if (accepted) "系统已接受动作，请重新观察核对结果。" else "控件未接受动作。")
                    }
                }
                "clock.alarm.create" -> {
                    require(args.keys.all { it in setOf("hour", "minute", "label", "days", "vibrate") })
                    val hour = integer(args, "hour", 0..23)
                    val minute = integer(args, "minute", 0..59)
                    val intent = Intent(AlarmClock.ACTION_SET_ALARM)
                        .putExtra(AlarmClock.EXTRA_HOUR, hour).putExtra(AlarmClock.EXTRA_MINUTES, minute)
                        .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                    if (args.containsKey("label")) intent.putExtra(AlarmClock.EXTRA_MESSAGE, text(args, "label", 160))
                    if (args.containsKey("vibrate")) {
                        require(args["vibrate"] is Boolean)
                        intent.putExtra(AlarmClock.EXTRA_VIBRATE, args["vibrate"] as Boolean)
                    }
                    if (args.containsKey("days")) {
                        val days = (args["days"] as? List<*>)?.map {
                            require(it is Int || it is Long) { "星期必须是整数。" }
                            (it as Number).toInt()
                        } ?: error("星期无效。")
                        require(days.size <= 7 && days.all { it in 1..7 })
                        intent.putIntegerArrayListExtra(AlarmClock.EXTRA_DAYS, ArrayList(days.distinct()))
                    }
                    openSystem(intent, ::beforeAction)
                    receipt("dispatched", "闹钟请求已交给手机时钟，请核对实际闹钟。")
                }
                "clock.timer.start" -> {
                    require(args.keys.all { it in setOf("seconds", "label") })
                    val seconds = integer(args, "seconds", 1..604800)
                    val intent = Intent(AlarmClock.ACTION_SET_TIMER).putExtra(AlarmClock.EXTRA_LENGTH, seconds)
                        .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                    if (args.containsKey("label")) intent.putExtra(AlarmClock.EXTRA_MESSAGE, text(args, "label", 160))
                    openSystem(intent, ::beforeAction)
                    receipt("dispatched", "倒计时请求已交给手机时钟，请核对实际结果。")
                }
                "clock.alarms.show" -> {
                    require(args.isEmpty())
                    val target=openSystem(Intent(AlarmClock.ACTION_SHOW_ALARMS), ::beforeAction)
                    receipt("dispatched", "已请求打开闹钟列表。",mapOf("expectedPackage" to target))
                }
                "settings.open" -> {
                    require(args.keys == setOf("page"))
                    val action = mapOf("settings" to Settings.ACTION_SETTINGS, "wifi" to Settings.ACTION_WIFI_SETTINGS,
                        "bluetooth" to Settings.ACTION_BLUETOOTH_SETTINGS, "display" to Settings.ACTION_DISPLAY_SETTINGS,
                        "sound" to Settings.ACTION_SOUND_SETTINGS, "accessibility" to Settings.ACTION_ACCESSIBILITY_SETTINGS,
                        "application" to Settings.ACTION_APPLICATION_DETAILS_SETTINGS)[args["page"]] ?: error("设置页面不存在。")
                    val intent = Intent(action)
                    if (args["page"] == "application") intent.data = Uri.parse("package:${activity.packageName}")
                    val target=openSystem(intent, ::beforeAction)
                    receipt("dispatched", "已打开设置页面，尚未更改设置。",mapOf("expectedPackage" to target))
                }
                "settings.brightness.read" -> {
                    require(args.isEmpty())
                    receipt("verified", "已读取系统亮度。", mapOf(
                        "level" to Settings.System.getInt(activity.contentResolver, Settings.System.SCREEN_BRIGHTNESS, -1),
                        "mode" to Settings.System.getInt(activity.contentResolver, Settings.System.SCREEN_BRIGHTNESS_MODE, -1)))
                }
                "settings.brightness.write" -> {
                    require(args.keys == setOf("level"))
                    val level = integer(args, "level", 0..255)
                    if (!Settings.System.canWrite(activity)) receipt("permission_required", "请先由用户允许 Skivu 修改系统设置。")
                    else {
                        beforeAction()
                        val saved = Settings.System.putInt(activity.contentResolver, Settings.System.SCREEN_BRIGHTNESS, level)
                        val actual = Settings.System.getInt(activity.contentResolver, Settings.System.SCREEN_BRIGHTNESS, -1)
                        receipt(if (saved && actual == level) "verified" else "unknown", "已读取系统亮度核对结果。", mapOf("level" to actual))
                    }
                }
                "shell.execute" -> {
                    require(args.keys.all { it in setOf("command", "timeoutSeconds") })
                    val command = args["command"] as? String?:error("缺少命令。")
                    require(command.isNotBlank()&&!command.contains('\u0000'))
                    val seconds=(args["timeoutSeconds"] as? Number)?.toLong()?:0L
                    require(seconds>=0&&seconds<=Long.MAX_VALUE/1000)
                    if (adb.probe()["connected"] != true) {
                        receipt("permission_required", "高权限执行后端未连接，请先完成设备配对和连接。")
                    } else {
                        beforeAction()
                        val value = CloudShellOutputs(activity).execute(owner,id){out,err->adb.execute(command, seconds,out,err) { key !in cancelledRequests }}
                        receipt("verified", "命令进程已结束；业务结果仍需根据回执核对。", value + mapOf("verification" to "process_exit", "businessVerified" to false))
                    }
                }
                else -> error("设备工具不存在。")
            }
        } catch (e: Exception) {
            val cause=(e as? java.util.concurrent.ExecutionException)?.cause as? Exception?:e
            receipt(if (actionAttempted) "unknown" else (cause as? PhoneFlow.Blocked)?.outcome?:"failed", cause.message?.take(300) ?: "设备操作未完成。")
        }
        if (writing) {
            if(tool in setOf("ui.flow","ui.flow.resume")) {
                // The runner stores its full resumable checkpoint before each action.
                // Do not replace that journal with the compact public response.
                if(receipts.read(key)?.optJSONObject("value")?.optInt("flowVersion")==1) {
                    remembered[key]=answer
                    return answer
                }
            }
            if (answer["outcome"] == "permission_required") {
                receipts.remove(key)
            } else {
                persist(answer["outcome"] as String, answer["summary"] as String,answer["value"])
                remembered[key] = answer
                if (remembered.size > 100) remembered.remove(remembered.keys.first())
            }
        }
        return answer
    }

    internal fun cancelInvocation(owner:String,requestId:String):Map<String,Any?>{
        val key=digest("$owner:$requestId");cancelledRequests.add(key)
        val stopping=if(activeRequest==key)adb.stop()else null
        return if(stopping!=null)adb.awaitStop(stopping)else mapOf("outcome" to "cancelled")
    }

    private fun runPhoneFlow(tool:String,args:Map<String,Any?>,owner:String,id:String,key:String,fingerprint:String,
                             leaseCheck:()->Unit,beforeAction:()->Unit):Map<String,Any?> {
        val epoch=cancellationEpoch.get()
        val previous=if(tool=="ui.flow.resume") {
            require(args.keys==setOf("originalRequestId")){"恢复流程只接受原请求编号。"}
            val original=args["originalRequestId"] as? String?:error("缺少原流程编号。")
            val saved=receipts.read(digest("$owner:$original"))?:error("本会话没有这个流程。")
            PhoneFlow.map(plain(saved.opt("value")),"checkpoint").also{require(it["flowVersion"]==1){"原请求不是本地流程。"}}
        } else null
        val plan=previous?.let{PhoneFlow.map(it["plan"],"plan")}?:args
        PhoneFlow.validate(plan)
        val root=previous?.get("rootRequestId") as? String?:id
        val rootKey=digest("$owner:$root")
        val rootFingerprint=if(root==id)fingerprint else receipts.read(rootKey)?.getString("fingerprint")?:error("流程原记录丢失。")
        val backend=object:PhoneFlow.Backend {
            private var stepContext=emptyMap<String,Any?>()
            private var waitingAt:Long?=null
            override fun prepare(step:Map<String,Any?>){stepContext=step;waitingAt=null}
            override fun awaitingResult(){if(waitingAt==null)waitingAt=now()}
            override fun check() {
                if(closed.get()||epoch!=cancellationEpoch.get()||key in cancelledRequests)throw PhoneFlow.Blocked("cancelled","本地流程已停止；已派发步骤保留待核对。")
                leaseCheck()
                if(!enabled("enabled")||!enabled("control"))throw PhoneFlow.Blocked("permission_required","手机操控授权已关闭。")
                if(plan["package"] !in packages())throw PhoneFlow.Blocked("permission_required","流程软件已不在授权范围内。")
                if(SkivuAccessibilityService.connected==null)throw PhoneFlow.Blocked("permission_required","无障碍服务未连接。")
            }
            override fun now()=android.os.SystemClock.uptimeMillis()
            override fun snapshot(pkg:String):PhoneFlow.Snapshot {
                check()
                val mode=PhoneVision.mode(plan["recognitionMode"],prefs.getString("recognitionMode","auto")?:"auto")
                return SkivuAccessibilityService.connected!!.vision.snapshot(packages(),pkg,mode,owner,::check,stepContext,waitingAt==null,waitingAt==null||now()-waitingAt!!>=500)
            }
            override fun perform(step:Map<String,Any?>,pkg:String,requestId:String):PhoneFlow.Dispatch {
                var dispatched=false
                try {
                    check()
                    val mode=PhoneVision.mode(plan["recognitionMode"],prefs.getString("recognitionMode","auto")?:"auto")
                    return SkivuAccessibilityService.connected!!.vision.perform(step,pkg,packages(),mode,owner,"flow_${digest("$owner:$requestId")}",::check,before={check();beforeAction();dispatched=true})
                } catch(error:Exception) {
                    val cause=(error as? java.util.concurrent.ExecutionException)?.cause as? Exception?:error
                    if(!dispatched)throw PhoneFlow.NotDispatched(cause)
                    throw cause
                }
            }
            override fun awaitChange(milliseconds:Long) {
                check();SkivuAccessibilityService.connected?.awaitFlowChange(milliseconds)
            }
        }
        val result=PhoneFlow.run(plan,root,backend,previous){checkpoint ->
            fun write(target:String,hash:String) {
                receipts.write(target,JSONObject(mapOf("fingerprint" to hash,"outcome" to if(checkpoint["state"]=="running")"unknown" else checkpoint["state"],
                    "summary" to checkpoint["reason"],"value" to checkpoint)))
                remembered.remove(target)
            }
            write(rootKey,rootFingerprint)
            if(key!=rootKey)write(key,fingerprint)
        }
        return mapOf("requestId" to id,"tool" to tool,"outcome" to result.outcome,"summary" to result.summary,"value" to result.value)
    }
    internal fun invokeLeased(p:Map<String,Any?>,check:()->Unit):Map<String,Any?>{
        val key=digest("${p["owner"]}:${p["requestId"]}");activeRequest=key;activeOwner=p["owner"] as? String
        return try{invoke(p,check)}finally{if(activeRequest==key){activeRequest=null;activeOwner=null};cancelledRequests.remove(key)}
    }
    private fun launch(intent:Intent){
        if(hostActivity!=null)activity.startActivity(intent)
        else (SkivuAccessibilityService.connected?:activity).startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
    private fun openSystem(intent: Intent, beforeDispatch: () -> Unit):String {
        val pm = activity.packageManager
        val default = intent.resolveActivity(pm)?.packageName
        val allowed = pm.queryIntentActivities(intent, 0).map { it.activityInfo.packageName }
            .distinct().filter { it in packages() }
        val selected = if (default in allowed) default else allowed.singleOrNull()
        require(selected != null) { "请选择并授权一个可处理此请求的软件。" }
        intent.setPackage(selected)
        ui { beforeDispatch(); launch(intent) }
        return selected
    }
    private fun text(p: Map<String, Any?>, key: String, max: Int): String {
        val value = p[key] as? String ?: error("文字参数无效。")
        require(!value.contains('\u0000'))
        return value
    }
    private fun integer(p: Map<String, Any?>, key: String, range: IntRange): Int {
        val raw = p[key]
        require(raw is Int || raw is Long) { "$key 必须是整数。" }
        val value = (raw as Number).toLong()
        require(value >= range.first && value <= range.last) { "$key 超出有效范围。" }
        return value.toInt()
    }
    private fun digest(value: String) = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
}
