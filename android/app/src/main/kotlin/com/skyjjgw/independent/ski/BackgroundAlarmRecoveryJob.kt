package com.skyjjgw.independent.ski

import android.app.job.JobParameters
import android.app.job.JobService
import java.util.concurrent.Executors

/** A durable outbox wakeup is registered before a mutation, cancelled after commit. */
class BackgroundAlarmRecoveryJob : JobService() {
    companion object { private val worker = Executors.newSingleThreadExecutor() }
    override fun onStartJob(params: JobParameters): Boolean {
        val app = applicationContext
        worker.execute {
            var retry = false
            try {
                BackgroundAlarms(app).use { alarms ->
                    alarms.recover("outbox")
                    retry = alarms.ready() && alarms.list().any { it["enabled"] == true && it["state"] in setOf("prepared", "needs_attention") }
                }
            } catch (_: Exception) { retry = true }
            jobFinished(params, retry)
        }
        return true
    }
    override fun onStopJob(params: JobParameters) = true
}
