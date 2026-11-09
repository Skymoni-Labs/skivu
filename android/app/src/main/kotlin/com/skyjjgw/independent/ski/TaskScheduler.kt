package com.skyjjgw.independent.ski

import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import androidx.work.*
import java.util.concurrent.TimeUnit

class TaskScheduler(private val context: Context) {
    fun cancel(id: String) { WorkManager.getInstance(context).cancelAllWorkByTag("skivu-plan:$id").result.get(10,TimeUnit.SECONDS) }
    fun reconcile(cancelInactive: Boolean=true) {
        val plans=TaskScheduleStore(context)
        plans.recover()
        for(p in plans.list()) {
            val id=p.getString("id")
            if(p.getString("state")!="enabled" || p.isNull("nextAt")) { if(cancelInactive) cancel(id); continue }
            val due=p.getLong("nextAt")
            val name="skivu-plan:$id:${p.getInt("version")}:$due"
            val work=OneTimeWorkRequest.Builder(ScheduledTaskWorker::class.java)
                .setInputData(Data.Builder().putString("id",id).putInt("version",p.getInt("version")).putLong("due",due).build())
                .setInitialDelay(maxOf(0,due-System.currentTimeMillis()),TimeUnit.MILLISECONDS)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.LINEAR,30,TimeUnit.SECONDS)
                .addTag("skivu-managed-plans").addTag("skivu-plan:$id").build()
            try {WorkManager.getInstance(context).enqueueUniqueWork(name,ExistingWorkPolicy.KEEP,work).result.get(10,TimeUnit.SECONDS)}
            catch(e: Exception) {
                TaskDatabase.get(context).transaction {db->
                    val saved=TaskDatabase.get(context).plan(id,db) ?: return@transaction
                    if(saved.getInt("version")==p.getInt("version")) {saved.put("state","needs_configuration").put("reason","系统调度登记未完成，请重新核对并启用。");TaskDatabase.get(context).writePlan(db,saved)}
                }
                throw e
            }
        }
    }
}

class TaskRecoveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context,intent: Intent) {
        if(intent.action !in setOf(Intent.ACTION_BOOT_COMPLETED,Intent.ACTION_MY_PACKAGE_REPLACED,Intent.ACTION_TIME_CHANGED,Intent.ACTION_TIMEZONE_CHANGED)) return
        WorkManager.getInstance(context).enqueueUniqueWork("skivu-plan-recovery",ExistingWorkPolicy.REPLACE,OneTimeWorkRequest.Builder(TaskRecoveryWorker::class.java).setInputData(Data.Builder().putBoolean("clockChanged",intent.action in setOf(Intent.ACTION_TIME_CHANGED,Intent.ACTION_TIMEZONE_CHANGED)).build()).build())
    }
}
class TaskRecoveryWorker(context: Context,params: WorkerParameters): Worker(context,params) {
    override fun doWork(): Result = try {
        val scheduler=TaskScheduler(applicationContext)
        if(inputData.getBoolean("clockChanged",false)) TaskScheduleStore(applicationContext).rebaseClock().forEach {scheduler.cancel(it)}
        scheduler.reconcile();TaskPlatform.changed();Result.success()
    } catch (_: Exception) { Result.retry() }
}
