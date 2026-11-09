package com.skyjjgw.independent.ski

import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import androidx.work.*
import java.util.concurrent.TimeUnit

class TaskScheduler(private val context: Context) {
    fun cancel(id:String){val manager=WorkManager.getInstance(context);for(work in manager.getWorkInfosByTag("skivu-plan:$id").get())if(work.state in setOf(WorkInfo.State.ENQUEUED,WorkInfo.State.BLOCKED))manager.cancelWorkById(work.id).result.get()}
    fun reconcile(cancelInactive: Boolean=true) {
        val plans=TaskScheduleStore(context)
        plans.recover()
        for(run in TaskDatabase.get(context).queryJson(TaskDatabase.get(context).readableDatabase,"SELECT data FROM runs WHERE state IN ('interrupted','waiting_conditions')")){
            if(run.optBoolean("stopRequested")||run.optBoolean("pauseRequested"))continue
            if(run.optBoolean("retryOnConditionChange")&&run.optString("failureCondition")==plans.conditionSignature()){
                val probe=OneTimeWorkRequest.Builder(TaskConditionProbeWorker::class.java).setInitialDelay(60,TimeUnit.SECONDS).addTag("skivu-condition-probes").build();WorkManager.getInstance(context).enqueueUniqueWork("skivu-condition:${run.getString("id")}:${System.currentTimeMillis()/60000}",ExistingWorkPolicy.KEEP,probe);continue
            }
            val work=OneTimeWorkRequest.Builder(ScheduledTaskWorker::class.java).setInputData(Data.Builder().putString("id",run.getString("planId")).putInt("version",run.getInt("planVersion")).putLong("due",run.getLong("dueAt")).build()).setInitialDelay(if(run.getString("state")=="waiting_conditions")60 else 5,TimeUnit.SECONDS).addTag("skivu-managed-runs").build()
            WorkManager.getInstance(context).enqueueUniqueWork("skivu-resume:${run.getString("id")}:${run.optInt("resumeGeneration")}",ExistingWorkPolicy.KEEP,work).result.get()
        }

        for(p in plans.list()) {
            val id=p.getString("id")
            if(p.getString("state")!="enabled" || p.isNull("nextAt")) { if(cancelInactive) cancel(id); continue }
            val due=p.getLong("nextAt")
            if(p.optJSONObject("lastRun")?.let{it.optLong("dueAt")==due&&it.optString("state") in setOf("running","interrupted","waiting_conditions")}==true)continue
            val name="skivu-plan:$id:${p.getInt("version")}:$due"
            val work=OneTimeWorkRequest.Builder(ScheduledTaskWorker::class.java)
                .setInputData(Data.Builder().putString("id",id).putInt("version",p.getInt("version")).putLong("due",due).build())
                .setInitialDelay(maxOf(0,due-System.currentTimeMillis()),TimeUnit.MILLISECONDS)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.LINEAR,30,TimeUnit.SECONDS)
                .addTag("skivu-managed-plans").addTag("skivu-plan:$id").build()
            try {WorkManager.getInstance(context).enqueueUniqueWork(name,ExistingWorkPolicy.KEEP,work).result.get()}
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

/** Checks native condition changes only. It never instantiates a model or repeats
 * an external action while a known startup failure has no new information. */
class TaskConditionProbeWorker(context:Context,params:WorkerParameters):Worker(context,params){override fun doWork():Result=try{TaskScheduler(applicationContext).reconcile(false);Result.success()}catch(_:Exception){Result.retry()}}
