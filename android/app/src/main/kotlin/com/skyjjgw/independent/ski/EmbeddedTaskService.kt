package com.skyjjgw.independent.ski

import android.app.*
import android.content.Intent
import android.os.IBinder

/** Visible lifetime for a user-started main assistant task, with an OS stop action. */
class EmbeddedTaskService : Service() {
    private var ownedTaskId: String? = null
    companion object {
        @Volatile var taskId: String? = null
        var stopTask: ((String) -> Unit)? = null
        val activeTasks=java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        @Volatile private var instance:EmbeddedTaskService?=null
        fun refresh(context:android.content.Context,state:Map<String,Any?>){instance?.let{service->if(state["taskId"]==taskId)service.show(state)}}
    }
    override fun onCreate() {
        super.onCreate()
        instance=this
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("skivu-embedded-tasks", "小云手机任务", NotificationManager.IMPORTANCE_LOW))
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra("taskId") ?: return START_NOT_STICKY
        if (intent.action == "stop") {
            if (taskId == id) {
                if(runCatching{ExecutionHub.control(id,"stop")}.isFailure)stopTask?.invoke(id)
                show(mapOf("phase" to "stopping","action" to "等待执行器确认进程退出。"))
            }
            return START_NOT_STICKY
        }
        if(intent.action=="restore"){ExecutionHub.setMode(this,"compact");return START_NOT_STICKY}
        if (taskId != id) return START_NOT_STICKY
        ownedTaskId = id
        show(ExecutionHub.list(this).firstOrNull{it["taskId"]==id}?:mapOf("phase" to "deciding","action" to "点停止可终止后续操作"))
        return START_NOT_STICKY
    }
    private fun show(state:Map<String,Any?>){
        val id=taskId?:return
        val stop = PendingIntent.getService(this, 82, Intent(this, EmbeddedTaskService::class.java)
            .setAction("stop").putExtra("taskId", id), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val open = PendingIntent.getActivity(this, 83, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val restore=PendingIntent.getService(this,84,Intent(this,EmbeddedTaskService::class.java).setAction("restore").putExtra("taskId",id),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        startForeground(82, Notification.Builder(this, "skivu-embedded-tasks")
            .setSmallIcon(android.R.drawable.ic_menu_view).setContentTitle("小云 · "+ExecutionHub.label(state["phase"].toString()))
            .setContentText(state["action"]?.toString()?.take(160)).setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, "停止", stop).build())
            .addAction(Notification.Action.Builder(null, "恢复浮岛", restore).build()).build())
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onDestroy() {
        if(instance===this)instance=null
        val previous = ownedTaskId; ownedTaskId = null
        if (previous != null && taskId == previous) { taskId = null; stopTask?.invoke(previous) }
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
