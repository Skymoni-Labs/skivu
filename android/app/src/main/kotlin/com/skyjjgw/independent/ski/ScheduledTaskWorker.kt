package com.skyjjgw.independent.ski

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.work.Worker
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import org.json.JSONObject
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Headless job: no Activity launch, no unbounded process/foreground service. */
class ScheduledTaskWorker(context: Context,params: WorkerParameters): Worker(context,params) {
    private val main=Handler(Looper.getMainLooper())
    @Volatile private var engine: FlutterEngine? = null
    @Volatile private var lease: JSONObject? = null
    private val completion=CompletableFuture<Unit>()
    override fun doWork(): Result {
        val store=TaskScheduleStore(applicationContext)
        val claimed=try {store.claim(inputData.getString("id") ?: return Result.failure(),inputData.getInt("version",0),inputData.getLong("due",-1))} catch (_: Exception) { return Result.failure() }
        if(claimed==null) { try {TaskScheduler(applicationContext).reconcile(false)} catch (_: Exception) {};return Result.success() }
        if(claimed.optBoolean("busy")) return Result.retry()
        val r=claimed.getJSONObject("run")
        val ownedLease=JSONObject().put("id",r.getString("id")).put("token",r.getString("token"));lease=ownedLease
        main.post {
            if(isStopped) { completion.complete(Unit);return@post }
            try {
                val loader=FlutterInjector.instance().flutterLoader()
                loader.startInitialization(applicationContext);loader.ensureInitializationComplete(applicationContext,null)
                val runtime=FlutterEngine(applicationContext);engine=runtime
                TaskBetaKeys.register(runtime.dartExecutor.binaryMessenger)
                val platform=TaskPlatform(applicationContext,null,ownedLease)
                platform.register(runtime.dartExecutor.binaryMessenger)
                CloudPlatform(applicationContext,null,ownedLease,claimed.getJSONObject("plan").optString("projectId").ifBlank{null}).register(runtime.dartExecutor.binaryMessenger)
                val channel=MethodChannel(runtime.dartExecutor.binaryMessenger,"skivu/scheduled_worker")
                channel.setMethodCallHandler { call,result ->
                    when(call.method) {
                        "initialize" -> result.success(TaskDatabase.unpack(claimed))
                        "finished" -> { result.success(true);completion.complete(Unit) }
                        else -> result.notImplemented()
                    }
                }
                val handle=applicationContext.getSharedPreferences("skivu.scheduled-runtime",0).getLong("callback",0)
                val info=FlutterCallbackInformation.lookupCallbackInformation(handle) ?: error("后台入口尚未登记，请先打开应用。")
                runtime.dartExecutor.executeDartCallback(DartExecutor.DartCallback(applicationContext.assets,loader.findAppBundlePath(),info))
            } catch (_: Throwable) { completion.completeExceptionally(IllegalStateException("后台引擎启动未完成。")) }
        }
        try { completion.get(140,TimeUnit.SECONDS) }
        catch (_: Exception) { store.finish(ownedLease,"unknown","后台执行中断，结果待核对；不会自动重放。","") }
        finally {
            CloudRuntime.cancelRun(applicationContext,ownedLease.getString("id"))
            ExecutionHub.expireRun(applicationContext,ownedLease.getString("id"))
            // If Dart exited without a committed finish, preserve the uncertain occurrence.
            store.finish(ownedLease,"unknown","后台回执中断，结果待核对；不会自动重放。","")
            main.post { engine?.destroy(); engine=null }
        }
        try { TaskScheduler(applicationContext).reconcile(false) } catch (_: Exception) {}
        return Result.success()
    }
    override fun onStopped() {
        lease?.let { try {TaskScheduleStore(applicationContext).finish(it,"unknown","执行已停止，已派发的结果需核对。","")} catch (_: Exception) {} }
        lease?.let{owned->java.util.concurrent.Executors.newSingleThreadExecutor().apply{execute{CloudRuntime.cancelRun(applicationContext,owned.getString("id"));main.post{engine?.let { MethodChannel(it.dartExecutor.binaryMessenger,"skivu/scheduled_worker").invokeMethod("stop",null) };completion.complete(Unit)};shutdown()}}}
        super.onStopped()
    }
    companion object {
        fun notifyResult(context: Context,plan: JSONObject) {
            val manager=context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel("skivu-plan-results","小云定时任务结果",NotificationManager.IMPORTANCE_DEFAULT))
            if(!manager.areNotificationsEnabled()) return
            val task=TaskDatabase.get(context).task(plan.getString("taskId"))
            val open=Intent(context,MainActivity::class.java).putExtra("skivuTaskId",plan.getString("taskId")).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            val action=PendingIntent.getActivity(context,plan.getString("id").hashCode(),open,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val last=plan.optJSONObject("lastRun")
            val notification=Notification.Builder(context,"skivu-plan-results").setSmallIcon(android.R.drawable.ic_menu_agenda)
                .setContentTitle(task?.optString("title") ?: "小云定时任务")
                .setContentText(last?.optString("summary")?.take(160) ?: "任务结果已更新")
                .setContentIntent(action).setAutoCancel(true).build()
            manager.notify(plan.getString("id").hashCode(),notification)
        }
    }
}
