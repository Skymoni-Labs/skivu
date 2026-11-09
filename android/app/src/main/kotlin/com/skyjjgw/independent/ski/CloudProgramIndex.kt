package com.skyjjgw.independent.ski

import android.content.Context
import org.json.JSONObject
import java.io.File

/** Host UI only: discover owned program metadata without starting an environment. */
object CloudProgramIndex {
    fun page(context:Context,offset:Int,count:Int):Map<String,Any?> {
        require(offset>=0&&count>0)
        val root=context.filesDir
        val records=sequence {
            for(file in File(root,"cloud-home/cloud/jobs").listFiles().orEmpty())if(file.name.matches(Regex("job_[a-f0-9]+\\.json")))yield("linux" to file)
            for(dir in File(root,"cloud-android-jobs").listFiles().orEmpty())yield("android" to File(dir,"record.json"))
            for(dir in File(root,"cloud-shell-logs").listFiles().orEmpty())yield("adb" to File(dir,"metadata.json"))
        }.mapNotNull{(backend,file)->runCatching{val row=JSONObject(file.readText());mapOf("id" to row.getString("id"),"owner" to row.getString("owner"),"taskId" to row.optString("taskId"),"projectId" to row.optString("projectId").takeIf{it.startsWith("project_")},"state" to row.optString("state"),"createdAt" to row.optLong("createdAt"),"backend" to backend,"commandPreview" to row.optString("command").lineSequence().firstOrNull()?.take(200))}.getOrNull()}.sortedByDescending{(it["createdAt"] as Long)}.toList()
        val items=records.drop(offset).take(minOf(count,100))
        return mapOf("items" to items,"total" to records.size,"nextOffset" to if(offset+items.size<records.size)offset+items.size else null)
    }
    fun policy(context:Context):Map<String,Any?> {
        val memory=android.app.ActivityManager.MemoryInfo();context.getSystemService(android.app.ActivityManager::class.java).getMemoryInfo(memory)
        val cpu=Runtime.getRuntime().availableProcessors();val auto=minOf(cpu,(memory.availMem/(64L*1024*1024)).coerceAtLeast(1).coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
        val backgroundAuto=minOf(cpu,(memory.availMem/(160L*1024*1024)).coerceAtLeast(1).coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
        val file=File(context.filesDir,"cloud-home/cloud/execution-policy.json")
        val linux=if(file.isFile)JSONObject(file.readText()).optInt("maxParallelJobs")else 0
        val android=context.getSharedPreferences("cloud_execution",0).getInt("maxAndroidJobs",0)
        val background=context.getSharedPreferences("cloud-execution-policy",0).getInt("maxBackgroundRuns",0)
        return mapOf("maxParallelJobs" to linux,"maxAndroidJobs" to android,"maxBackgroundRuns" to background,"automaticParallelJobs" to auto,"automaticBackgroundRuns" to backgroundAuto,"programMemoryReferenceBytes" to 64L*1024*1024,"backgroundMemoryReferenceBytes" to 160L*1024*1024,"availableMemoryBytes" to memory.availMem,"processors" to cpu,"timeoutMs" to 0,"outputRetention" to "complete","source" to "0=device_resources; positive=user")
    }
    fun configure(context:Context,args:Map<String,Any?>):Map<String,Any?> {
        require(args.keys==setOf("maxParallelJobs","maxAndroidJobs","maxBackgroundRuns"))
        val values=args.mapValues{(_,value)->val number=value as? Number?:error("并发数无效。");require(number.toDouble()==number.toInt().toDouble()&&number.toInt()>=0);number.toInt()}
        val file=File(context.filesDir,"cloud-home/cloud/execution-policy.json");file.parentFile!!.mkdirs();val temp=File(file.path+".tmp");temp.writeText(JSONObject(mapOf("maxParallelJobs" to values.getValue("maxParallelJobs"))).toString());check(temp.renameTo(file))
        check(context.getSharedPreferences("cloud_execution",0).edit().putInt("maxAndroidJobs",values.getValue("maxAndroidJobs")).commit())
        check(context.getSharedPreferences("cloud-execution-policy",0).edit().putInt("maxBackgroundRuns",values.getValue("maxBackgroundRuns")).commit())
        CloudAndroidRuntime.restore(context);TaskScheduler(context).reconcile(false);return policy(context)
    }
}
