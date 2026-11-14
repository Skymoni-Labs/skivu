package com.skyjjgw.independent.ski.dshgo.phone.background

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import com.skyjjgw.independent.ski.dshgo.phone.PhoneControl
import com.skyjjgw.independent.ski.dshgo.phone.a11y.A11yKeeper

/**
 * One boot opportunity, not a periodic service or an authorization bypass: it only asks the
 * keeper to restore what the person chose to keep. A stopped job's late [jobFinished] is ignored.
 */
class PrivilegedKeepJob : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        Thread({
            try {
                if (wanted(applicationContext) != "off") {
                    A11yKeeper.check(applicationContext)
                    BackgroundControl.get(applicationContext).restoreKeptChannel()?.get()
                }
            } catch (_: Exception) {
                // The keeper reports the observed failure in status, never raw process output.
            } finally {
                jobFinished(params, false)
            }
        }, "dsh-privileged-boot").apply { isDaemon = true }.start()
        return true
    }

    // No retry: the next foreground, task or channel event restores again.
    override fun onStopJob(params: JobParameters): Boolean = false

    class Receiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) schedule(context)
        }
    }

    companion object {
        private const val JOB_ID = 0x44534850
        private fun wanted(context: Context): String {
            if (Build.VERSION.SDK_INT < BackgroundPolicy.MIN_SDK || !PhoneControl.switchedOn(context)) return "off"
            return context.getSharedPreferences("phone-privileged-keep", Context.MODE_PRIVATE)
                .getString("keptMode", "off")?.takeIf { it in PrivilegedKeepState.MODES } ?: "off"
        }
        fun schedule(context: Context) {
            val mode = wanted(context)
            if (mode == "off") return
            val job = JobInfo.Builder(JOB_ID, ComponentName(context, PrivilegedKeepJob::class.java))
            if (mode == "adb") job.setRequiredNetwork(NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build())
            runCatching { context.getSystemService(JobScheduler::class.java).schedule(job.build()) }
        }
        fun cancel(context: Context) {
            runCatching { context.getSystemService(JobScheduler::class.java).cancel(JOB_ID) }
        }
    }
}
