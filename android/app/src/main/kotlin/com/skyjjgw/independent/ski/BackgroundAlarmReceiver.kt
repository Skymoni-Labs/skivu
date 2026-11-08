package com.skyjjgw.independent.ski

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import java.util.concurrent.Executors

class BackgroundAlarmReceiver : BroadcastReceiver() {
    companion object { private val worker = Executors.newSingleThreadExecutor() }
    override fun onReceive(context: Context, intent: Intent) {
        val result = goAsync()
        worker.execute {
            try {
                BackgroundAlarms(context).use { alarms ->
                    if (intent.action != "fire") { alarms.recover(intent.action ?: "recovery"); return@use }
                    val id = intent.getStringExtra("id") ?: return@use
                    val due = intent.getLongExtra("due", -1)
                    val item = alarms.claimFire(id, intent.getLongExtra("revision", -1), due) ?: return@use
                    try {
                        val ring = Intent(context, BackgroundAlarmRingService::class.java)
                            .putExtra("id", id).putExtra("occurrence", due)
                            .putExtra("label", item["label"] as? String ?: "")
                            .putExtra("vibrate", item["vibrate"] == true)
                        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(ring) else context.startService(ring)
                    } catch (_: Exception) { alarms.markRing(id, due, "start_failed") }
                }
            } finally { result.finish() }
        }
    }
}
