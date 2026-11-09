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

/** A durable occurrence has a renewable lease, checkpoint and OS foreground
 * notification. There is no application-defined completion deadline. */
class ScheduledTaskWorker(context:Context,params:WorkerParameters):Worker(context,params){
    private val main=Handler(Looper.getMainLooper())
    @Volatile private var engine:FlutterEngine?=null
    @Volatile private var lease:JSONObject?=null
    @Volatile private var explicitStop=false
    @Volatile private var stage="claim"
    private var pluginRuntime:OpenPluginRuntimePlatform?=null
    private val completion=CompletableFuture<Unit>()
    private fun foreground(run:String):androidx.work.ForegroundInfo{
        val manager=applicationContext.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("skivu-long-runs","小云持续任务",NotificationManager.IMPORTANCE_LOW))
        val stop=PendingIntent.getBroadcast(applicationContext,run.hashCode(),Intent(applicationContext,CloudTaskControlReceiver::class.java).setAction("run.stop").setData(android.net.Uri.parse("skivu://runs/$run/stop")).putExtra("runId",run),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification=Notification.Builder(applicationContext,"skivu-long-runs").setSmallIcon(android.R.drawable.ic_menu_agenda).setContentTitle("小云正在处理定时任务").setContentText("进度和检查点持续保存；停止仅结束本次执行。").setOngoing(true).addAction(Notification.Action.Builder(null,"停止本次执行",stop).build()).build()
        return if(android.os.Build.VERSION.SDK_INT>=34)androidx.work.ForegroundInfo(run.hashCode(),notification,android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)else androidx.work.ForegroundInfo(run.hashCode(),notification)
    }
    override fun doWork():Result{
        val store=TaskScheduleStore(applicationContext)
        val claimed=try{store.claim(inputData.getString("id")?:return Result.failure(),inputData.getInt("version",0),inputData.getLong("due",-1))}catch(_:Exception){return Result.failure()}
        if(claimed==null){runCatching{TaskScheduler(applicationContext).reconcile(false)};return Result.success()}
        if(claimed.optBoolean("busy"))return Result.retry()
        val record=claimed.getJSONObject("run");val run=record.getString("id")
        val owned=JSONObject().put("id",run).put("token",record.getString("token"));lease=owned;live[run]=this
        val heartbeat=java.util.concurrent.Executors.newSingleThreadScheduledExecutor()
        try{
            stage="foreground"
            try{setForegroundAsync(foreground(run)).get();TaskDatabase.get(applicationContext).transaction{db->val r=TaskDatabase.get(applicationContext).run(run,db)?:return@transaction;r.put("foregroundState","foreground_service");TaskDatabase.get(applicationContext).writeRun(db,r)}}catch(error:Exception){val manager=applicationContext.getSystemService(NotificationManager::class.java);val notice=runCatching{if(manager.areNotificationsEnabled())manager.notify("run:$run",77,foreground(run).notification)};TaskDatabase.get(applicationContext).transaction{db->val r=TaskDatabase.get(applicationContext).run(run,db)?:return@transaction;r.put("foregroundState","ordinary_system_job").put("foregroundError",(error.cause?:error).toString()).put("notificationEnabled",manager.areNotificationsEnabled());notice.exceptionOrNull()?.let{r.put("notificationError",it.toString())};TaskDatabase.get(applicationContext).writeRun(db,r)}}
            heartbeat.scheduleAtFixedRate({try{val renewed=store.heartbeat(owned);if(renewed.optBoolean("stopRequested"))stopExplicit()}catch(_:Exception){if(TaskDatabase.get(applicationContext).run(run)?.optBoolean("stopRequested")==true)stopExplicit()else completion.completeExceptionally(IllegalStateException("执行租约失效，保存检查点后恢复。"))}},15,15,TimeUnit.SECONDS)
            main.post{
                if(isStopped){completion.complete(Unit);return@post}
                try{
                    stage="flutter_initialization";val loader=FlutterInjector.instance().flutterLoader();loader.startInitialization(applicationContext);loader.ensureInitializationComplete(applicationContext,null)
                    val runtime=FlutterEngine(applicationContext);engine=runtime
                    TaskBetaKeys.register(runtime.dartExecutor.binaryMessenger)
                    pluginRuntime=OpenPluginRuntimePlatform(applicationContext).also{it.register(runtime.dartExecutor.binaryMessenger)}
                    OpenPluginExternalPlatform(applicationContext){!applicationContext.getSystemService(android.app.KeyguardManager::class.java).isDeviceLocked&&applicationContext.getSystemService(android.os.PowerManager::class.java).isInteractive&&claimed.getJSONObject("plan").optBoolean("allowForeground",true)}.register(runtime.dartExecutor.binaryMessenger)
                    TaskPlatform(applicationContext,null,owned).register(runtime.dartExecutor.binaryMessenger)
                    CloudPlatform(applicationContext,null,owned,claimed.getJSONObject("plan").optString("projectId").ifBlank{null}).register(runtime.dartExecutor.binaryMessenger)
                    MethodChannel(runtime.dartExecutor.binaryMessenger,"skivu/scheduled_worker").setMethodCallHandler{call,result->when(call.method){
                        "initialize"->{if(explicitStop)record.put("stopRequested",true);TaskDatabase.get(applicationContext).run(run)?.let{latest->record.put("pauseRequested",latest.optBoolean("pauseRequested")).put("resumeRequested",latest.optBoolean("resumeRequested"))};result.success(TaskDatabase.unpack(claimed))}
                        "finished"->{result.success(true);completion.complete(Unit)}
                        else->result.notImplemented()
                    }}
                    stage="callback_lookup";val handle=applicationContext.getSharedPreferences("skivu.scheduled-runtime",0).getLong("callback",0)
                    val info=FlutterCallbackInformation.lookupCallbackInformation(handle)?:error("后台入口尚未登记，请先打开应用。")
                    stage="dart_execution";runtime.dartExecutor.executeDartCallback(DartExecutor.DartCallback(applicationContext.assets,loader.findAppBundlePath(),info))
                }catch(error:Throwable){completion.completeExceptionally(error)}
            }
            completion.get()
        }catch(error:Exception){
            if(explicitStop)runCatching{CloudRuntime.cancelRun(applicationContext,run)}
            else store.deferFailure(owned,stage,error.cause?:error)
        }finally{
            heartbeat.shutdownNow();live.remove(run,this)
            applicationContext.getSystemService(NotificationManager::class.java).cancel("run:$run",77)
            if(!explicitStop&&!isStopped&&TaskDatabase.get(applicationContext).run(run)?.optString("state")=="running")store.interrupt(owned,"后台回执未完成，保留原发生编号和检查点恢复。")
            if(explicitStop){val stopped=runCatching{CloudRuntime.cancelRun(applicationContext,run)}.getOrDefault(false);store.finish(owned,if(stopped)"cancelled"else"unknown",if(stopped)"本次执行已停止，后续计划保持原状态。"else"停止结果仍待核对。","")}
            TaskBackgroundTools.close(run)
            main.post{pluginRuntime?.close();pluginRuntime=null;engine?.destroy();engine=null}
        }
        runCatching{TaskScheduler(applicationContext).reconcile(false)};return Result.success()
    }
    private fun stopExplicit(){explicitStop=true;main.post{engine?.let{MethodChannel(it.dartExecutor.binaryMessenger,"skivu/scheduled_worker").invokeMethod("stop",null)}}}
    override fun onStopped(){
        lease?.let{owned->runCatching{TaskScheduleStore(applicationContext).interrupt(owned,"系统停止本轮调度，检查点保留，恢复前核对原进程与回执。")}}
        main.post{engine?.let{MethodChannel(it.dartExecutor.binaryMessenger,"skivu/scheduled_worker").invokeMethod(if(explicitStop)"stop"else"suspend",null)}}
        completion.complete(Unit);super.onStopped()
    }
    companion object{
        private val live=java.util.concurrent.ConcurrentHashMap<String,ScheduledTaskWorker>()
        fun requestStop(context:Context,id:String){val worker=live[id];if(worker!=null){worker.stopExplicit();return};val store=TaskScheduleStore(context);val r=TaskDatabase.get(context).run(id)?:return;val phone=TaskBackgroundTools.stopRun(context,id);val linux=runCatching{CloudRuntime.cancelRun(context,id)}.getOrDefault(false);store.finish(JSONObject().put("id",id).put("token",r.getString("token")),if(phone&&linux)"cancelled"else"unknown",if(phone&&linux)"本次执行已停止，后续计划保持原状态。"else"停止结果仍待核对。","");TaskPlatform.changed()}
        fun requestControl(id:String,action:String){live[id]?.let{worker->worker.main.post{worker.engine?.let{MethodChannel(it.dartExecutor.binaryMessenger,"skivu/scheduled_worker").invokeMethod(action,null)}}}}
        fun notifyResult(context: Context,plan: JSONObject) {
            val manager=context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel("skivu-plan-results","小云定时任务结果",NotificationManager.IMPORTANCE_DEFAULT))
            if(!manager.areNotificationsEnabled()) return
            val task=TaskDatabase.get(context).task(plan.getString("taskId"))
            val open=Intent(context,MainActivity::class.java).setData(android.net.Uri.parse("skivu://plans/${plan.getString("id")}/result")).putExtra("skivuTaskId",plan.getString("taskId")).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
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
