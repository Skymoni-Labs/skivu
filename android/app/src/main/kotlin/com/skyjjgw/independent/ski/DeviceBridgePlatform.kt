// SPDX-License-Identifier: GPL-3.0-only
package com.skyjjgw.independent.ski

import android.app.*
import android.content.*
import android.os.*
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.UUID

/** A fixed, versioned JSON Messenger protocol, never arbitrary Binder reflection. */
class DeviceBridgePlatform(private val context: Context, val engine: FlutterEngine) {
    private val connections = mutableMapOf<String, Connection>()
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "skivu/device_tasks")
    private val main = Handler(Looper.getMainLooper())
    init {
        channel.setMethodCallHandler { call, result ->
            if (Build.VERSION.SDK_INT < 30) {
                result.error("ANDROID_VERSION_UNSUPPORTED", "手机操控需要 Android 11 或更新系统", null)
                return@setMethodCallHandler
            }
            try { when (call.method) {
                "discover" -> {
                    val matches = context.packageManager.queryIntentServices(Intent("org.skivu.devicebridge.V1"), 0)
                    result.success(matches.map { mapOf("component" to ComponentName(it.serviceInfo.packageName, it.serviceInfo.name).flattenToString(), "label" to it.loadLabel(context.packageManager).toString()) })
                }
                "connect" -> {
                    val component = ComponentName.unflattenFromString(call.argument<String>("component") ?: "") ?: error("Choose a companion")
                    val discovered = context.packageManager.queryIntentServices(Intent("org.skivu.devicebridge.V1"), 0)
                    require(discovered.any { it.serviceInfo.packageName == component.packageName && it.serviceInfo.name == component.className })
                    val id = UUID.randomUUID().toString()
                    val connection = Connection(id, component)
                    connections[id] = connection
                    connection.connect(result)
                }
                "request" -> {
                    val c = connections[call.argument<String>("connectionId")] ?: error("Companion disconnected")
                    val request = call.argument<String>("json") ?: error("Missing request")
                    require(request.length <= 65536)
                    c.send(request, result)
                }
                "openCompanion" -> {
                    val c = connections[call.argument<String>("connectionId")] ?: error("Companion disconnected")
                    val intent = context.packageManager.getLaunchIntentForPackage(c.component.packageName) ?: error("Companion has no user interface")
                    context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); result.success(true)
                }
                "disconnect" -> { connections.remove(call.argument<String>("connectionId"))?.close(); result.success(true) }
                "attention" -> {
                    val c = connections[call.argument<String>("connectionId")] ?: error("Companion disconnected")
                    val open = context.packageManager.getLaunchIntentForPackage(c.component.packageName) ?: error("No companion UI")
                    val action = PendingIntent.getActivity(context, 81, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                    val stop = PendingIntent.getService(context, 19, Intent(context, DeviceTaskService::class.java).setAction("stop"), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                    context.getSystemService(NotificationManager::class.java).notify(79, Notification.Builder(context,"skivu-device-tasks").setSmallIcon(android.R.drawable.ic_menu_view)
                        .setContentTitle("手机任务需要你确认").setContentText("点此打开设备伴侣，核对这一次具体动作").setContentIntent(action).setOngoing(true)
                        .addAction(Notification.Action.Builder(null,"停止任务",stop).build()).build())
                    result.success(true)
                }
                "startService" -> {
                    val activity = DeviceTaskService.currentActivity ?: error("Open Skivu before starting a task")
                    require(activity.hasWindowFocus()) { "Start a task while Skivu is visible" }
                    if(Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        activity.requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 9123)
                        result.error("NOTIFICATIONS_REQUIRED","Grant task notifications, then start the task again",null)
                        return@setMethodCallHandler
                    }
                    require(DeviceTaskService.taskId == null) { "Another task is active" }
                    val id = call.argument<String>("taskId") ?: error("Missing task")
                    require(Regex("[a-zA-Z0-9_-]{1,100}").matches(id))
                    DeviceTaskService.retainedEngine = engine
                    DeviceTaskService.channel = channel
                    DeviceTaskService.taskId = id
                    try { context.startForegroundService(Intent(context, DeviceTaskService::class.java).putExtra("taskId", id)) }
                    catch(e:Exception) { DeviceTaskService.taskId=null;DeviceTaskService.retainedEngine=null;throw e }
                    result.success(true)
                }
                "finishService" -> {
                    if (DeviceTaskService.taskId == call.argument<String>("taskId")) context.stopService(Intent(context, DeviceTaskService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            } } catch (e: Exception) { result.error("DEVICE_UNAVAILABLE", e.message?.take(200), null) }
        }
    }
    fun close() { connections.values.forEach { it.close() }; connections.clear(); channel.setMethodCallHandler(null) }
    inner class Connection(val id: String, val component: ComponentName) : ServiceConnection {
        private var remote: Messenger? = null
        private var ticket = 0
        private var opening: MethodChannel.Result? = null
        private val pending = mutableMapOf<Int, MethodChannel.Result>()
        private var bound = false
        private val receiver = Messenger(Handler(Looper.getMainLooper()) { message ->
            if(message.what == 2) { channel.invokeMethod("deviceEvent",message.data.getString("json")); return@Handler true }
            pending.remove(message.arg1)?.success(message.data.getString("json") ?: "{}")
            true
        })
        fun connect(result: MethodChannel.Result) {
            opening = result
            bound = context.bindService(Intent("org.skivu.devicebridge.V1").setComponent(component), this, Context.BIND_AUTO_CREATE)
            if (!bound) { opening = null; error("Cannot bind companion") }
            main.postDelayed({ if (opening != null) { opening?.error("TIMEOUT", "Companion connection timed out", null); opening = null; close() } }, 10000)
        }
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            remote = Messenger(binder)
            opening?.success(mapOf("connectionId" to id)); opening = null
        }
        override fun onServiceDisconnected(name: ComponentName?) { remote = null; pending.values.forEach { it.error("DISCONNECTED", "Companion service stopped; reconcile before retrying", null) }; pending.clear() }
        fun send(json: String, result: MethodChannel.Result) {
            val target = remote ?: error("Companion disconnected")
            val key = ++ticket; pending[key] = result
            target.send(Message.obtain(null, 1, key, 0).apply { replyTo = receiver; data = Bundle().apply { putString("json", json) } })
            main.postDelayed({ pending.remove(key)?.error("RESULT_UNKNOWN", "Companion did not return a receipt; do not replay an action", null) }, 65000)
        }
        fun close() { if (bound) { context.unbindService(this); bound = false }; onServiceDisconnected(null) }
    }
}

class DeviceTaskService : Service() {
    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("skivu-device-tasks", "手机操控任务", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(this, 19, Intent(this, DeviceTaskService::class.java).setAction("stop"), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val open = PendingIntent.getActivity(this, 20, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(this, "skivu-device-tasks").setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("Skivu 正在执行手机任务").setContentText("仅操作你允许的软件；点停止可终止后续动作")
            .setContentIntent(open).setOngoing(true).addAction(Notification.Action.Builder(null, "停止任务", stop).build()).build()
        startForeground(79, notification)
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") {
            channel?.invokeMethod("stop", mapOf("taskId" to taskId))
            stopSelf()
        }
        return START_NOT_STICKY
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onDestroy() {
        channel?.invokeMethod("serviceStopped", mapOf("taskId" to taskId))
        taskId = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        val old = retainedEngine; retainedEngine = null
        if (!activityAttached) {
            val oldPlatform=platform
            if(oldPlatform?.engine === old)platform=null
            Handler(Looper.getMainLooper()).postDelayed({ oldPlatform?.close();old?.destroy() }, 2000)
        }
        super.onDestroy()
    }
    companion object {
        @Volatile var taskId: String? = null
        var retainedEngine: FlutterEngine? = null
        var channel: MethodChannel? = null
        var activityAttached = false
        var currentActivity: Activity? = null
        var platform: DeviceBridgePlatform? = null
    }
}
