package com.skyjjgw.independent.ski

import android.content.Context
import java.io.File
import android.content.ContentValues
import org.json.JSONArray
import org.json.JSONObject
import java.time.*
import java.util.UUID

/** Plan state, occurrence claims and reservations commit in the same SQLite database. */
class TaskScheduleStore(private val context: Context) {
    private val store = TaskDatabase.get(context)
    init{migrateImplicitLimits()}
    private fun migrateImplicitLimits(){val preferences=context.getSharedPreferences("cloud-policy-migrations",0);if(preferences.getBoolean("unrestricted-v2",false))return
        store.transaction{db->for(p in store.queryJson(db,"SELECT data FROM plans")){if(!p.has("limitsVersion")){p.put("legacyLimits",JSONObject().put("maxRequestsPerRun",p.optInt("maxRequestsPerRun")).put("maxDailyRequests",p.optInt("maxDailyRequests")).put("maxOutputTokens",p.optInt("maxOutputTokens")).put("allowForeground",p.optBoolean("allowForeground")))
            if(p.optInt("maxRequestsPerRun")==3&&p.optInt("maxDailyRequests")==8&&p.optInt("maxOutputTokens")==1024){p.put("maxRequestsPerRun",0).put("maxDailyRequests",0).put("maxOutputTokens",0)}
            p.put("allowForeground",true)
            p.optJSONObject("modelBinding")?.let{binding->
                val normalized=JSONObject(binding.toString());val connection=binding.optJSONObject("connection")
                if(connection!=null){val authority=JSONObject();for(key in listOf("id","protocol","address","model","auth","credentialId"))if(connection.has(key))authority.put(key,connection.get(key));normalized.put("connection",authority)}
                p.put("legacyModelIdentity",p.optString("modelIdentity")).put("modelIdentity",TaskDatabase.digest(canonical(normalized)))
            }
            p.put("limitsVersion",2);store.writePlan(db,p)
        }}};check(preferences.edit().putBoolean("unrestricted-v2",true).commit())
    }
    fun list(): List<JSONObject> = store.queryJson(store.readableDatabase,"SELECT data FROM plans ORDER BY rowid DESC")
    fun get(id: String): JSONObject = store.plan(id) ?: error("计划不存在。")
    private fun string(p: JSONObject,k: String,max: Int,default: String=""): String = p.optString(k,default).also { require(it.length<=max && !it.contains('\u0000')) }
    private fun rule(raw: JSONObject): JSONObject {
        require(raw.keys().asSequence().all { it in setOf("kind","at","time","weekdays","intervalMinutes","timeZone","followDeviceZone") })
        val kind = raw.getString("kind")
        require(kind in setOf("once","daily","weekly","interval")) { "重复规则无效。" }
        val zone = ZoneId.of(raw.optString("timeZone",ZoneId.systemDefault().id))
        val value = JSONObject().put("kind",kind).put("timeZone",zone.id).put("followDeviceZone",raw.optBoolean("followDeviceZone",!raw.has("timeZone")))
        if (kind=="once" || raw.has("at")) { require(raw.get("at") is Number); value.put("at",raw.getLong("at")) }
        if(kind in setOf("daily","weekly")) { val time=raw.getString("time");require(Regex("([01]\\d|2[0-3]):[0-5]\\d").matches(time)); LocalTime.parse(time);value.put("time",time) }
        if(kind=="weekly") {
            val source=raw.getJSONArray("weekdays"); require(source.length() in 1..7)
            val days=(0 until source.length()).map { source.getInt(it) }.toSortedSet();require(days.all { it in 1..7 });value.put("weekdays",JSONArray(days))
        }
        if(kind=="interval") { val minutes=raw.getInt("intervalMinutes"); require(minutes>0) { "间隔必须为正数；实际触发受系统调度和后台条件影响。" };value.put("intervalMinutes",minutes) }
        return value
    }
    fun next(rule: JSONObject, after: Long): Long? {
        val kind=rule.getString("kind")
        if(kind=="once") return rule.getLong("at").takeIf { it>after }
        if(kind=="interval") {
            val interval=rule.getLong("intervalMinutes")*60_000L
            val base=rule.optLong("at",after+interval)
            return if(base>after) base else base+((after-base)/interval+1)*interval
        }
        val zone=ZoneId.of(if(rule.optBoolean("followDeviceZone")) ZoneId.systemDefault().id else rule.getString("timeZone"))
        val start=Instant.ofEpochMilli(after).atZone(zone).toLocalDate()
        val time=LocalTime.parse(rule.getString("time"))
        for(offset in 0..8) {
            val day=start.plusDays(offset.toLong())
            val days=rule.optJSONArray("weekdays")
            if(kind=="weekly" && (0 until days.length()).none { days.getInt(it)==day.dayOfWeek.value }) continue
            val candidate=day.atTime(time).atZone(zone).toInstant().toEpochMilli()
            if(candidate>after && candidate>=rule.optLong("at",0)) return candidate
        }
        // A future start date may lie beyond this week.
        if(rule.optLong("at",0)>after) return next(rule,rule.getLong("at")-1)
        return null
    }
    private fun validateConfig(p: JSONObject) {
        require(p.getString("goal").isNotBlank())
        require(Regex("[a-f0-9]{64}").matches(p.getString("modelIdentity"))) { "请先选择可用模型。" }
        require(p.getInt("maxRequestsPerRun")>=0&&p.getInt("maxDailyRequests")>=0)
        require(p.getInt("maxOutputTokens")>=0&&p.optLong("maxRunSeconds",0)>=0)
        require(p.getString("missedPolicy") in setOf("latest","skip"))
        require(p.getInt("maxDelayMinutes")>=0)
        require(p.optString("mode","summary") in setOf("summary","local_tasks","device_action","coding"))
        if(p.has("projectId")&&p.optString("projectId").isNotBlank())require(Regex("project_[a-zA-Z0-9_-]{1,110}").matches(p.optString("projectId"))&&java.io.File(context.filesDir,"cloud-projects/${p.optString("projectId")}").isDirectory){"所选内置项目不存在。"}
    }
    fun create(args: JSONObject,operation: String): JSONObject {
        val digest=TaskDatabase.digest("create:${canonical(args)}")
        return store.transaction { db ->
            store.operation(db,operation,digest)?.let { return@transaction store.plan(it,db) ?: error("原计划不存在。") }
            store.queryJson(db,"SELECT data FROM plans").firstOrNull { it.optString("createdBy")==operation }?.let {
                require(it.getString("createDigest")==digest) { "原操作编号的内容已变化。" }
                return@transaction it
            }
            val task=store.task(args.getString("taskId"),db) ?: error("请先保存任务。")
            require(!task.getBoolean("archived")) { "请先恢复任务。" }
            val now=System.currentTimeMillis()
            val r=rule(args.getJSONObject("rule"))
            if(r.getString("kind")=="interval" && !r.has("at")) r.put("at",now+r.getLong("intervalMinutes")*60_000)
            val p=JSONObject().put("id","plan_${UUID.randomUUID().toString().replace('-','_')}").put("taskId",task.getString("id")).put("version",1)
                .put("createdBy",operation).put("createDigest",digest)
                .put("limitsVersion",2).put("kind","assistant").put("goal",args.getString("goal")).put("rule",r)
                .put("mode",args.optString("mode","summary"))
                .put("modelIdentity",string(args,"modelIdentity",64)).put("modelName",string(args,"modelName",160))
                .put("maxRequestsPerRun",args.optInt("maxRequestsPerRun",0)).put("maxDailyRequests",args.optInt("maxDailyRequests",0))
                .put("maxRunSeconds",args.optLong("maxRunSeconds",0)).put("maxOutputTokens",args.optInt("maxOutputTokens",0)).put("missedPolicy",args.optString("missedPolicy","latest"))
                .put("maxDelayMinutes",args.optInt("maxDelayMinutes",0)).put("allowForeground",args.optBoolean("allowForeground",true))
                .put("created",now).put("updated",now).put("state",if(args.optBoolean("enabled",true)) "enabled" else "paused").put("reason","")
            if(args.has("projectId"))p.put("projectId",args.getString("projectId"))
            validateConfig(p)
            if(args.has("modelBinding")) p.put("modelBinding",args.getJSONObject("modelBinding"))
            val due=next(r,now);require(due!=null) { "执行时间已经过去，请选择未来时间。" };p.put("nextAt",due)
            val duplicate=store.queryJson(db,"SELECT data FROM plans WHERE task_id=? AND state!='ended'",arrayOf(task.getString("id"))).firstOrNull {
                it.getString("goal")==p.getString("goal") && canonical(it.getJSONObject("rule"))==canonical(r) && it.getString("modelIdentity")==p.getString("modelIdentity")
            }
            val result=duplicate ?: p
            if(duplicate==null) store.writePlan(db,p)
            store.remember(db,operation,digest,result.getString("id"));result
        }
    }
    fun mutate(action: String,args: JSONObject,operation: String): JSONObject {
        require(action in setOf("update","pause","resume","cancel"))
        val digest=TaskDatabase.digest("$action:${canonical(args)}")
        return store.transaction { db ->
            store.operation(db,operation,digest)?.let { return@transaction store.plan(it,db) ?: error("原计划不存在。") }
            val p=store.plan(args.getString("id"),db) ?: error("计划不存在。")
            require(p.getInt("version")==args.getInt("expectedRevision")) { "计划已在其他位置修改，请重新读取。" }
            if(action=="update") {
                for(key in listOf("goal","mode","projectId","modelIdentity","modelName","modelBinding","maxRequestsPerRun","maxDailyRequests","maxOutputTokens","missedPolicy","maxDelayMinutes","allowForeground","maxRunSeconds")) if(args.has(key)) p.put(key,args.get(key))
                if(args.has("rule")) p.put("rule",rule(args.getJSONObject("rule")))
                validateConfig(p)
                p.put("nextAt",next(p.getJSONObject("rule"),System.currentTimeMillis()) ?: JSONObject.NULL)
                if(p.isNull("nextAt")) p.put("state","ended")
            } else {
                p.put("state",when(action) {"pause"->"paused";"cancel"->"ended";else->"enabled"})
                if(action=="resume") {
                    val task=store.task(p.getString("taskId"),db) ?: error("任务不存在。")
                    require(!task.getBoolean("archived")) { "请先恢复任务。" }
                    // An elapsed one-shot needs an explicit new time; never silently replay it.
                    val due=next(p.getJSONObject("rule"),System.currentTimeMillis()) ?: error("单次执行时间已过，请先修改时间。")
                    p.put("nextAt",due)
                }
                if(action=="cancel") p.put("nextAt",JSONObject.NULL)
            }
            p.put("version",p.getInt("version")+1).put("updated",System.currentTimeMillis()).put("reason","")
            store.writePlan(db,p);store.remember(db,operation,digest,p.getString("id"));p
        }
    }
    fun claim(id:String,version:Int,due:Long):JSONObject?=store.transaction{db->
        val p=store.plan(id,db)?:return@transaction null;val now=System.currentTimeMillis();if(now<due)return@transaction null
        val runId="run_${TaskDatabase.digest("$id:$due")}";val previous=store.run(runId,db)
        if(previous!=null){
            if(previous.optBoolean("retryOnConditionChange")&&previous.optString("failureCondition")==conditionSignature())return@transaction null
            if(previous.optString("state") !in setOf("interrupted","waiting_conditions")||previous.optBoolean("stopRequested")||previous.optBoolean("pauseRequested"))return@transaction null
            val snapshot=previous.optJSONObject("planSnapshot")?:return@transaction null
            previous.put("state","running").put("token",UUID.randomUUID().toString()).put("leaseUntil",now+180_000).put("processId",android.os.Process.myPid()).put("resumedAt",now).put("lastHeartbeatAt",now)
            store.writeRun(db,previous)
            return@transaction JSONObject().put("plan",snapshot).put("run",previous).put("recovered",true)
        }
        if(p.getString("state")!="enabled"||p.getInt("version")!=version||p.optLong("nextAt",-1)!=due)return@transaction null
        val busy=store.queryJson(db,"SELECT data FROM runs WHERE state='running' AND lease_until>?",arrayOf(now.toString()))
        val memory=android.app.ActivityManager.MemoryInfo();context.getSystemService(android.app.ActivityManager::class.java).getMemoryInfo(memory)
        val automatic=maxOf(1,minOf(Runtime.getRuntime().availableProcessors(),(memory.availMem/(160L*1024*1024)).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()))
        val configured=context.getSharedPreferences("cloud-execution-policy",0).getInt("maxBackgroundRuns",0)
        if(busy.any{it.getString("planId")==id}||busy.size>=(if(configured>0)configured else automatic))return@transaction JSONObject().put("busy",true).put("reason","等待项目或实际设备资源")
        val r=JSONObject().put("id",runId).put("planId",id).put("planVersion",version).put("dueAt",due).put("state","running").put("token",UUID.randomUUID().toString()).put("leaseUntil",now+180_000).put("started",now).put("requests",0).put("processId",android.os.Process.myPid()).put("resumeGeneration",0).put("activeMillis",0).put("lastHeartbeatAt",now).put("planSnapshot",JSONObject(p.toString()))
        store.writeRun(db,r);p.put("lastRun",JSONObject().put("id",runId).put("dueAt",due).put("state","running").put("summary","小云正在后台处理。"));store.writePlan(db,p)
        if(p.getInt("maxDelayMinutes")>0&&now-due>p.getInt("maxDelayMinutes")*60_000L||p.getString("missedPolicy")=="skip"&&now-due>60_000){finishInside(db,r,p,"missed","错过执行时间，已按用户策略跳过本次。","");return@transaction null}
        JSONObject().put("plan",p).put("run",r)
    }
    fun interrupt(lease:JSONObject,reason:String){store.transaction{db->
        val r=store.run(lease.getString("id"),db)?:return@transaction
        if(r.optString("token")!=lease.getString("token")||r.optString("state")!="running")return@transaction
        r.put("state","interrupted").put("leaseUntil",0).put("resumeGeneration",r.optInt("resumeGeneration")+1).put("summary",reason);store.writeRun(db,r)
        store.plan(r.getString("planId"),db)?.let{p->p.put("lastRun",JSONObject().put("id",r.getString("id")).put("state","interrupted").put("dueAt",r.getLong("dueAt")).put("summary",reason));store.writePlan(db,p)}
    }}
    fun conditionSignature():String {val version=context.packageManager.getPackageInfo(context.packageName,0).lastUpdateTime;val info=android.app.ActivityManager.RunningAppProcessInfo();android.app.ActivityManager.getMyMemoryState(info);val foreground=info.importance<=android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND;return TaskDatabase.digest("$version:${context.getSharedPreferences("skivu.scheduled-runtime",0).getLong("callback",0)}:$foreground:${context.getSystemService(android.app.KeyguardManager::class.java).isDeviceLocked}:${context.getSystemService(android.os.PowerManager::class.java).isInteractive}:${android.provider.Settings.Secure.getString(context.contentResolver,android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)}")}
    fun deferFailure(lease:JSONObject,stage:String,error:Throwable){val detail="$stage: ${error.stackTraceToString()}";val log=File(context.filesDir,"cloud-schedule-errors/${lease.getString("id")}.log");log.parentFile!!.mkdirs();log.appendText("${System.currentTimeMillis()} $detail\n");store.transaction{db->val r=store.run(lease.getString("id"),db)?:return@transaction;if(r.optString("token")!=lease.getString("token")||r.optString("state")!="running")return@transaction;val failure=TaskDatabase.digest("$stage:${error.javaClass.name}:${error.message}");val signature=conditionSignature();val noProgress=r.optString("failureFingerprint")==failure&&r.optInt("failureRequests",-1)==r.optInt("requests")&&r.optString("failureCondition")==signature;r.put("failureFingerprint",failure).put("failureRequests",r.optInt("requests")).put("failureCondition",signature).put("retryOnConditionChange",noProgress).put("state",if(noProgress)"waiting_conditions"else"interrupted").put("leaseUntil",0).put("resumeGeneration",r.optInt("resumeGeneration")+1).put("summary",if(noProgress)"启动条件没有变化，等待系统或配置变化后核对恢复。$stage: ${error.message}"else"启动中断，检查点保留。$stage: ${error.message}");store.writeRun(db,r);store.plan(r.getString("planId"),db)?.let{p->p.put("lastRun",JSONObject().put("id",r.getString("id")).put("state",r.getString("state")).put("dueAt",r.getLong("dueAt")).put("summary",r.getString("summary")));store.writePlan(db,p)}}}
    fun stopRun(id:String):JSONObject=store.transaction{db->
        val r=store.run(id,db)?:error("执行记录不存在。")
        if(r.getString("state") in setOf("running","interrupted","waiting_conditions")){r.put("stopRequested",true);store.writeRun(db,r)};r
    }
    fun controlRun(id:String,action:String):JSONObject=store.transaction{db->require(action in setOf("pause","resume"));val r=store.run(id,db)?:error("执行记录不存在。");require(!r.optBoolean("stopRequested")&&r.optString("state") in setOf("running","interrupted","waiting_conditions")){"此执行不能暂停或继续。"};r.put("pauseRequested",action=="pause").put("resumeRequested",action=="resume");store.writeRun(db,r);store.plan(r.getString("planId"),db)?.let{p->p.optJSONObject("lastRun")?.put("paused",action=="pause");store.writePlan(db,p)};r}
    fun check(lease: JSONObject) { store.transaction { store.validateLease(it,lease) } }
    fun heartbeat(lease:JSONObject,checkpoint:JSONObject?=null):JSONObject=store.transaction{db->
        store.validateLease(db,lease);val run=store.run(lease.getString("id"),db)!!
        val now=System.currentTimeMillis();val last=run.optLong("lastHeartbeatAt",now)
        run.put("activeMillis",run.optLong("activeMillis")+if(run.optBoolean("pauseRequested"))0 else maxOf(0,now-last)).put("lastHeartbeatAt",now)
        val policy=run.optJSONObject("planSnapshot");val seconds=policy?.optLong("maxRunSeconds",0)?:0
        if(seconds>0&&run.optLong("activeMillis")/1000>=seconds)run.put("stopRequested",true).put("timeoutRequested",true)
        run.put("leaseUntil",now+180_000).put("heartbeatAt",now)
        if(checkpoint!=null)run.put("checkpoint",checkpoint)
        store.writeRun(db,run);run
    }
    fun reserveModel(lease: JSONObject): JSONObject = store.transaction { db ->
        store.validateLease(db,lease)
        val run=store.run(lease.getString("id"),db)!!;val plan=run.optJSONObject("planSnapshot")?:store.plan(run.getString("planId"),db)!!
        val day=LocalDate.now().toString()
        fun used(id: String): Int = db.rawQuery("SELECT calls FROM budgets WHERE day=? AND plan_id=?",arrayOf(day,id)).use { if(it.moveToFirst()) it.getInt(0) else 0 }
        require((plan.getInt("maxRequestsPerRun")==0||run.getInt("requests")<plan.getInt("maxRequestsPerRun"))&&(plan.getInt("maxDailyRequests")==0||used(plan.getString("id"))<plan.getInt("maxDailyRequests"))) { "模型请求用量已达到本次或今日上限。" }
        for(id in listOf(plan.getString("id"),"*")) db.insertWithOnConflict("budgets",null,ContentValues().apply {put("day",day);put("plan_id",id);put("calls",used(id)+1)},android.database.sqlite.SQLiteDatabase.CONFLICT_REPLACE)
        run.put("requests",run.getInt("requests")+1);store.writeRun(db,run)
        JSONObject().put("reserved",true).put("requests",run.getInt("requests"))
    }
    private fun finishInside(db: android.database.sqlite.SQLiteDatabase,r: JSONObject,p: JSONObject,state: String,summary: String,result: String) {
        val now=System.currentTimeMillis()
        if(state=="waiting_conditions"){
            r.put("state",state).put("leaseUntil",0).put("summary",summary).put("result",result).put("resumeGeneration",r.optInt("resumeGeneration")+1);store.writeRun(db,r)
            p.put("lastRun",JSONObject().put("id",r.getString("id")).put("state",state).put("dueAt",r.getLong("dueAt")).put("summary",summary).put("result",result));store.writePlan(db,p);return
        }
        r.put("state",state).put("finished",now).put("leaseUntil",0).put("summary",summary).put("result",result);store.writeRun(db,r)
        run {
            p.put("lastRun",JSONObject().put("id",r.getString("id")).put("dueAt",r.getLong("dueAt")).put("finished",now).put("state",state).put("summary",summary).put("result",result).put("requests",r.getInt("requests")))
            if(r.has("artifactBatches"))p.getJSONObject("lastRun").put("artifactBatches",r.getJSONArray("artifactBatches"))
            if(r.has("artifactIds"))p.getJSONObject("lastRun").put("artifactIds",r.getJSONArray("artifactIds"))
            if(p.getInt("version")==r.getInt("planVersion")&&p.getString("state")=="enabled") {
                val next=next(p.getJSONObject("rule"),maxOf(now,r.getLong("dueAt")))
                p.put("nextAt",next ?: JSONObject.NULL)
                if(next==null) p.put("state","ended")
                if(state=="waiting_conditions") p.put("state","needs_configuration").put("reason",summary)
            }
            store.writePlan(db,p)
        }
    }
    fun finish(lease: JSONObject,state: String,summary: String,result: String,artifactIds:JSONArray?=null,artifactBatches:JSONArray?=null): JSONObject? = store.transaction { db ->
        require(state in setOf("verified","unknown","failed","missed","waiting_conditions","cancelled"))
        val r=store.run(lease.getString("id"),db) ?: return@transaction null
        if(r.getString("token")!=lease.getString("token") || (r.getString("state")!="running"&&!(r.optBoolean("stopRequested")&&state in setOf("cancelled","unknown")))) return@transaction null
        val p=store.plan(r.getString("planId"),db) ?: return@transaction null
        val artifactStore=CloudArtifactStore(context).apply{migrateLegacy()};val artifactOwner="cloud:${p.getString("id")}"
        if(artifactIds!=null){for(i in 0 until artifactIds.length()){val record=artifactStore.get(artifactIds.getString(i));require(record?.optString("owner")==artifactOwner){"成果不属于此计划。"}};r.put("artifactIds",artifactIds)}
        if(artifactBatches!=null){for(i in 0 until artifactBatches.length())require(artifactStore.batch(artifactBatches.getString(i))?.optString("owner")==artifactOwner){"成果组不属于此计划。"};r.put("artifactBatches",artifactBatches)}
        finishInside(db,r,p,state,summary,result);p
    }
    fun recover(){
        for(r in store.queryJson(store.readableDatabase,"SELECT data FROM runs WHERE state='running'")){
            if(r.getLong("leaseUntil")>System.currentTimeMillis()&&r.optInt("processId",-1)==android.os.Process.myPid())continue
            if(r.has("planSnapshot"))interrupt(JSONObject().put("id",r.getString("id")).put("token",r.getString("token")),"系统中断，等待恢复检查点并核对原进程；不会重放未知副作用。")
            else store.plan(r.getString("planId"))?.let{p->finish(JSONObject().put("id",r.getString("id")).put("token",r.getString("token")),"unknown","旧执行没有恢复检查点，结果保留待核对。","")}
        }
    }
    fun rebaseClock(): List<String> = store.transaction {db->
        val now=System.currentTimeMillis()
        val changed=mutableListOf<String>()
        for(p in store.queryJson(db,"SELECT data FROM plans WHERE state='enabled'")) {
            if(store.queryJson(db,"SELECT data FROM runs WHERE plan_id=? AND state='running' AND lease_until>?",arrayOf(p.getString("id"),now.toString())).isNotEmpty())continue
            val rule=p.getJSONObject("rule")
            if(rule.getString("kind") in setOf("daily","weekly") && rule.optBoolean("followDeviceZone")) {
                rule.put("timeZone",ZoneId.systemDefault().id)
                p.put("nextAt",next(rule,now) ?: JSONObject.NULL).put("version",p.getInt("version")+1).put("reason","系统时间或时区已变化，后续按当前本地时间处理。")
                store.writePlan(db,p)
            }
            changed.add(p.getString("id"))
        }
        changed
    }
    companion object {
        fun canonical(v: Any?): String = when(v) {
            is JSONObject -> v.keys().asSequence().toList().sorted().joinToString(",","{","}") { JSONObject.quote(it)+":"+canonical(v.get(it)) }
            is JSONArray -> (0 until v.length()).joinToString(",","[","]") {canonical(v.get(it))}
            is String -> JSONObject.quote(v)
            null, JSONObject.NULL -> "null"
            else -> v.toString()
        }
    }
}
