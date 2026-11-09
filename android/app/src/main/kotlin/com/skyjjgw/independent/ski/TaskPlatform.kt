package com.skyjjgw.independent.ski

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.util.concurrent.Executors

class TaskPlatform(private val context: Context,private val activity: Activity?=null,private val workerLease: JSONObject?=null) {
    private val db=TaskDatabase.get(context)
    private val plans=TaskScheduleStore(context)
    private val main=Handler(Looper.getMainLooper())
    private var retainedChannel: MethodChannel? = null
    fun register(messenger: BinaryMessenger) {
        val channel=MethodChannel(messenger,"skivu/tasks")
        retainedChannel=channel
        synchronized(channels) { channels.add(WeakReference(channel)) }
        channel.setMethodCallHandler { call,result ->
            @Suppress("UNCHECKED_CAST") val args=JSONObject(call.arguments as? Map<String,Any?> ?: emptyMap<String,Any?>())
            worker.execute {
                try {
                    val lease=if(args.has("_lease")) args.getJSONObject("_lease") else workerLease
                    if(workerLease!=null) {
                        require(call.method in setOf("document.read","document.cas","runs.check","runs.pause","runs.resume","runs.stop","runs.checkpoint.read","runs.checkpoint.write","runs.heartbeat","runs.reserveModel","runs.finish","tools.invoke","tools.status","tools.cancel","runtime.status","resources.list","resources.get","resources.verify","resources.calendars","resources.create","resources.update","resources.cancel","plans.list","plans.get","plans.create","plans.update","plans.pause","plans.resume","plans.cancel","runtime.pendingOpen")) { "后台执行不能创建新的定时计划或修改授权。" }
                        require(lease?.optString("id")==workerLease.getString("id") && lease.optString("token")==workerLease.getString("token"));if(call.method in setOf("runs.finish","runs.checkpoint.read","runs.checkpoint.write","tools.cancel")){require(db.run(workerLease.getString("id"))?.optString("token")==workerLease.getString("token"))}else plans.check(workerLease)
                    }
                    val answer: Any? = when(call.method) {
                        "document.read" -> db.document()
                        "document.initialize" -> db.initialize(args.getString("value"))
                        "document.cas" -> mapOf("saved" to db.compareAndSet(args.getInt("version"),args.getString("value"),lease))
                        "plans.list" -> mapOf("plans" to plans.list().map {TaskDatabase.unpack(it)})
                        "resources.list" -> mapOf("resources" to TaskResourceStore(context).list().map {TaskDatabase.unpack(it)})
                        "resources.get","resources.verify" -> TaskResourceStore(context).verify(args.getJSONObject("arguments").getString("id"))
                        "resources.calendars" -> mapOf("calendars" to TaskResourceStore(context).calendars())
                        "resources.create" -> TaskResourceStore(context).create(args.getJSONObject("arguments"),args.getString("requestId"))
                        "resources.update","resources.cancel" -> TaskResourceStore(context).mutate(call.method.removePrefix("resources."),args.getJSONObject("arguments"),args.getString("requestId"))
                        "resources.captureClock" -> TaskResourceStore(context).captureClock(args)
                        "resources.confirmClock" -> TaskResourceStore(context).confirmClock(args.getString("sourceKey"))
                        "resources.userConfirm" -> TaskResourceStore(context).userConfirm(args.getJSONObject("arguments").getString("id"),args.getJSONObject("arguments").getInt("expectedRevision"))
                        "plans.get" -> plans.get(args.getString("id"))
                        "plans.create" -> {
                            require(context.getSharedPreferences("skivu.scheduled-runtime",0).getLong("callback",0)!=0L) { "后台入口未登记，请重新打开应用后启用计划。" }
                            require(args.getJSONObject("arguments").has("modelBinding")) { "请选择计划使用的模型。" }
                            plans.create(args.getJSONObject("arguments"),args.getString("requestId"))
                        }
                        "plans.update","plans.pause","plans.resume","plans.cancel" -> {
                            val p=plans.mutate(call.method.removePrefix("plans."),args.getJSONObject("arguments"),args.getString("requestId"))
                            TaskScheduler(context).cancel(p.getString("id"));p
                        }
                        "runtime.reconcile" -> {TaskScheduler(context).reconcile();mapOf("reconciled" to true)}
                        "runtime.registerWorker" -> {require(workerLease==null);check(context.getSharedPreferences("skivu.scheduled-runtime",0).edit().putLong("callback",args.getLong("handle")).commit());mapOf("registered" to true)}
                        "runtime.status" -> mapOf("notifications" to context.getSystemService(android.app.NotificationManager::class.java).areNotificationsEnabled(),"calendarRead" to (context.checkSelfPermission(android.Manifest.permission.READ_CALENDAR)==PackageManager.PERMISSION_GRANTED),"calendarWrite" to (context.checkSelfPermission(android.Manifest.permission.WRITE_CALENDAR)==PackageManager.PERMISSION_GRANTED),"timeZone" to java.util.TimeZone.getDefault().id,"locked" to context.getSystemService(KeyguardManager::class.java).isDeviceLocked,"globalDailyRequestLimit" to 0,"limitMode" to "unrestricted")
                        "runtime.authorize" -> {
                            require(activity!=null && workerLease==null)
                            val permissions=when(args.getString("kind")) {"calendar" -> arrayOf(android.Manifest.permission.READ_CALENDAR,android.Manifest.permission.WRITE_CALENDAR);"notifications" -> if(Build.VERSION.SDK_INT>=33) arrayOf(android.Manifest.permission.POST_NOTIFICATIONS) else emptyArray();else -> error("授权类型无效。")}
                            main.post {if(permissions.isNotEmpty()) activity.requestPermissions(permissions,9241)}
                            mapOf("requested" to true)
                        }
                        "runtime.pendingOpen" -> {
                            val id=activity?.intent?.getStringExtra("skivuTaskId")
                            activity?.intent?.removeExtra("skivuTaskId")
                            mapOf("taskId" to id)
                        }
                        "runs.get"->{require(workerLease==null||args.getString("id")==workerLease.getString("id"));db.run(args.getString("id"))?:error("执行记录不存在。")}
                        "runs.check" -> {plans.check(lease ?: error("缺少执行租约。"));mapOf("active" to true)}
                        "runs.checkpoint.read" -> mapOf("value" to TaskBlobStore(context).checkpoint((lease?:error("缺少租约。")).getString("id")))
                        "runs.checkpoint.write" -> {TaskBlobStore(context).saveCheckpoint((lease?:error("缺少租约。")).getString("id"),args.getString("value"));mapOf("saved" to true)}
                        "runs.pause","runs.resume"->{require(workerLease==null||args.getString("id")==workerLease.getString("id"));val action=call.method.removePrefix("runs.");val r=plans.controlRun(args.getString("id"),action);if(workerLease==null)ScheduledTaskWorker.requestControl(args.getString("id"),action);TaskScheduler(context).reconcile(false);r}
                        "runs.stop" -> {require(workerLease==null||args.getString("id")==workerLease.getString("id"));val r=plans.stopRun(args.getString("id"));ScheduledTaskWorker.requestStop(context,args.getString("id"));r}
                        "runs.heartbeat" -> plans.heartbeat(lease ?: error("缺少执行租约。"),args.optJSONObject("checkpoint"))
                        "runs.reserveModel" -> plans.reserveModel(lease ?: error("缺少执行租约。"))
                        "runs.finish" -> plans.finish(lease ?: error("缺少执行租约。"),args.getString("state"),args.optString("summary"),args.optString("result"),args.optJSONArray("artifactIds"),args.optJSONArray("artifactBatches"))?.also {
                            ScheduledTaskWorker.notifyResult(context,it)
                            if(context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE!=0) android.util.Log.i("SkivuScheduler","committed plan:${it.getString("id")} state:${it.optJSONObject("lastRun")?.optString("state")}")
                        } ?: mapOf("finished" to false)
                        "tools.invoke" -> TaskBackgroundTools(context).invoke(args,lease ?: error("缺少执行租约。"))
                        "tools.status" -> TaskBackgroundTools(context).status(lease ?: error("缺少执行租约。"))
                        "tools.cancel" -> TaskBackgroundTools(context).cancel(args,lease ?: error("缺少执行租约。"))
                        else -> error("任务接口不存在。")
                    }
                    if(call.method !in setOf("document.read","runtime.status","runtime.pendingOpen","plans.list","plans.get","resources.list","resources.get","resources.calendars","runs.check","runs.get","runs.heartbeat","runs.checkpoint.read","runs.checkpoint.write","tools.invoke","tools.status","runs.reserveModel")) {
                        changed()
                        if(call.method.startsWith("plans.") || call.method=="document.cas") TaskScheduler(context).reconcile()
                    }
                    main.post {result.success(if(answer is JSONObject) TaskDatabase.unpack(answer) else answer)}
                } catch(e: Exception) { main.post { result.error("TASKS",e.message?.take(500) ?: "任务处理未完成。",null) } }
            }
        }
    }
    companion object {
        val worker=Executors.newCachedThreadPool()
        private val channels=mutableListOf<WeakReference<MethodChannel>>()
        fun changed() { Handler(Looper.getMainLooper()).post {synchronized(channels) {channels.removeAll {it.get()==null};channels.forEach {it.get()?.invokeMethod("changed",null)}}} }
    }
}
