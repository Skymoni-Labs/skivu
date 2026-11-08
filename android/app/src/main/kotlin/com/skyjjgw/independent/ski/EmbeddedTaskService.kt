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
    }
    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("skivu-embedded-tasks", "小云手机任务", NotificationManager.IMPORTANCE_LOW))
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra("taskId") ?: return START_NOT_STICKY
        if (intent.action == "stop") {
            if (taskId == id) { stopTask?.invoke(id); taskId = null; ownedTaskId = null; stopSelf() }
            return START_NOT_STICKY
        }
        if (taskId != id) return START_NOT_STICKY
        ownedTaskId = id
        val stop = PendingIntent.getService(this, 82, Intent(this, EmbeddedTaskService::class.java)
            .setAction("stop").putExtra("taskId", id), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val open = PendingIntent.getActivity(this, 83, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        startForeground(82, Notification.Builder(this, "skivu-embedded-tasks")
            .setSmallIcon(android.R.drawable.ic_menu_view).setContentTitle("小云正在执行手机任务")
            .setContentText("点停止可终止后续操作").setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(null, "停止", stop).build()).build())
        return START_NOT_STICKY
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onDestroy() {
        val previous = ownedTaskId; ownedTaskId = null
        if (previous != null && taskId == previous) { taskId = null; stopTask?.invoke(previous) }
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
