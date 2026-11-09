package com.skyjjgw.independent.ski

import android.content.Context
import android.content.ContentValues
import org.json.JSONArray
import org.json.JSONObject
import java.time.*
import java.util.UUID

/** Plan state, occurrence claims and reservations commit in the same SQLite database. */
class TaskScheduleStore(private val context: Context) {
    private val store = TaskDatabase.get(context)
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
        if(kind=="interval") { val minutes=raw.getInt("intervalMinutes"); require(minutes in 15..10080) { "后台重复间隔最少15分钟，实际触发允许系统延迟。" };value.put("intervalMinutes",minutes) }
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
        require(p.getString("goal").trim().length in 1..4000)
        require(Regex("[a-f0-9]{64}").matches(p.getString("modelIdentity"))) { "请先选择可用模型。" }
        require(p.getInt("maxRequestsPerRun") in 1..5 && p.getInt("maxDailyRequests") in 1..20 && p.getInt("maxRequestsPerRun")<=p.getInt("maxDailyRequests"))
        require(p.getInt("maxOutputTokens") in 512..4096)
        require(p.getString("missedPolicy") in setOf("latest","skip"))
        require(p.getInt("maxDelayMinutes") in 1..1440)
        require(p.optString("mode","summary") in setOf("summary","local_tasks","device_action","coding"))
        if(p.optString("mode")=="coding")require(Regex("project_[a-zA-Z0-9_-]{1,110}").matches(p.optString("projectId"))&&java.io.File(context.filesDir,"cloud-projects/${p.optString("projectId")}").isDirectory){"编程计划必须绑定一个现有内置项目。"}
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
                .put("kind","assistant").put("goal",string(args,"goal",4000)).put("rule",r)
                .put("mode",args.optString("mode","summary"))
                .put("modelIdentity",string(args,"modelIdentity",64)).put("modelName",string(args,"modelName",160))
                .put("maxRequestsPerRun",args.optInt("maxRequestsPerRun",3)).put("maxDailyRequests",args.optInt("maxDailyRequests",8))
                .put("maxOutputTokens",args.optInt("maxOutputTokens",1024)).put("missedPolicy",args.optString("missedPolicy","latest"))
                .put("maxDelayMinutes",args.optInt("maxDelayMinutes",60)).put("allowForeground",args.optBoolean("allowForeground",false))
                .put("created",now).put("updated",now).put("state",if(args.optBoolean("enabled",true)) "enabled" else "paused").put("reason","")
            if(args.has("projectId"))p.put("projectId",args.getString("projectId"))
            validateConfig(p)
            if(args.has("modelBinding")) p.put("modelBinding",args.getJSONObject("modelBinding"))
            require(store.queryJson(db,"SELECT data FROM plans WHERE state!='ended'").size<256) { "启用或暂停的计划已达上限，请先整理。" }
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
                for(key in listOf("goal","mode","projectId","modelIdentity","modelName","modelBinding","maxRequestsPerRun","maxDailyRequests","maxOutputTokens","missedPolicy","maxDelayMinutes","allowForeground")) if(args.has(key)) p.put(key,args.get(key))
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
            val active=store.queryJson(db,"SELECT data FROM runs WHERE plan_id=? AND state='running'",arrayOf(p.getString("id"))).firstOrNull()
            if(active!=null) p.put("lastRun",JSONObject().put("id",active.getString("id")).put("dueAt",active.getLong("dueAt")).put("state","unknown").put("summary","计划已修改或停止，已派发的结果待核对。"))
            store.writePlan(db,p);store.remember(db,operation,digest,p.getString("id"));p
        }
    }
    fun claim(id: String,version: Int,due: Long): JSONObject? = store.transaction { db ->
        val p=store.plan(id,db) ?: return@transaction null
        if(p.getString("state")!="enabled" || p.getInt("version")!=version || p.optLong("nextAt",-1)!=due) return@transaction null
        val now=System.currentTimeMillis(); if(now<due) return@transaction null
        val runId="run_${TaskDatabase.digest("$id:$due")}"
        if(store.run(runId,db)!=null) return@transaction null
        val busy=store.queryJson(db,"SELECT data FROM runs WHERE state='running' AND lease_until>?",arrayOf(now.toString()))
        if(busy.isNotEmpty()) return@transaction JSONObject().put("busy",true)
        val r=JSONObject().put("id",runId).put("planId",id).put("planVersion",version).put("dueAt",due).put("state","running")
            .put("token",UUID.randomUUID().toString()).put("leaseUntil",now+180_000).put("started",now).put("requests",0).put("processId",android.os.Process.myPid())
        store.writeRun(db,r)
        p.put("lastRun",JSONObject().put("id",runId).put("dueAt",due).put("state","running").put("summary","小云正在后台处理。"));store.writePlan(db,p)
        if(now-due>p.getInt("maxDelayMinutes")*60_000L || p.getString("missedPolicy")=="skip" && now-due>60_000) {
            finishInside(db,r,p,"missed","错过执行时间，已跳过本次安排。","")
            return@transaction null
        }
        JSONObject().put("plan",p).put("run",r)
    }
    fun check(lease: JSONObject) { store.transaction { store.validateLease(it,lease) } }
    fun reserveModel(lease: JSONObject): JSONObject = store.transaction { db ->
        store.validateLease(db,lease)
        val run=store.run(lease.getString("id"),db)!!;val plan=store.plan(run.getString("planId"),db)!!
        val day=LocalDate.now().toString()
        fun used(id: String): Int = db.rawQuery("SELECT calls FROM budgets WHERE day=? AND plan_id=?",arrayOf(day,id)).use { if(it.moveToFirst()) it.getInt(0) else 0 }
        require(run.getInt("requests")<plan.getInt("maxRequestsPerRun") && used(plan.getString("id"))<plan.getInt("maxDailyRequests") && used("*")<40) { "模型请求用量已达到本次或今日上限。" }
        for(id in listOf(plan.getString("id"),"*")) db.insertWithOnConflict("budgets",null,ContentValues().apply {put("day",day);put("plan_id",id);put("calls",used(id)+1)},android.database.sqlite.SQLiteDatabase.CONFLICT_REPLACE)
        run.put("requests",run.getInt("requests")+1);store.writeRun(db,run)
        JSONObject().put("reserved",true).put("requests",run.getInt("requests"))
    }
    private fun finishInside(db: android.database.sqlite.SQLiteDatabase,r: JSONObject,p: JSONObject,state: String,summary: String,result: String) {
        val now=System.currentTimeMillis()
        r.put("state",state).put("finished",now).put("leaseUntil",0).put("summary",summary.take(400));store.writeRun(db,r)
        if(p.getInt("version")==r.getInt("planVersion")) {
            p.put("lastRun",JSONObject().put("id",r.getString("id")).put("dueAt",r.getLong("dueAt")).put("finished",now).put("state",state).put("summary",summary.take(400)).put("result",result.take(12000)).put("requests",r.getInt("requests")))
            if(r.has("artifactIds"))p.getJSONObject("lastRun").put("artifactIds",r.getJSONArray("artifactIds"))
            if(p.getString("state")=="enabled") {
                val next=next(p.getJSONObject("rule"),maxOf(now,r.getLong("dueAt")))
                p.put("nextAt",next ?: JSONObject.NULL)
                if(next==null) p.put("state","ended")
                if(state=="waiting_conditions") p.put("state","needs_configuration").put("reason",summary.take(240))
            }
            store.writePlan(db,p)
        }
    }
    fun finish(lease: JSONObject,state: String,summary: String,result: String,artifactIds:JSONArray?=null): JSONObject? = store.transaction { db ->
        require(state in setOf("verified","unknown","failed","missed","waiting_conditions","cancelled"))
        val r=store.run(lease.getString("id"),db) ?: return@transaction null
        if(r.getString("token")!=lease.getString("token") || r.getString("state")!="running") return@transaction null
        val p=store.plan(r.getString("planId"),db) ?: return@transaction null
        if(artifactIds!=null){require(artifactIds.length()<=40)
            @Suppress("UNCHECKED_CAST") val actual=CloudArtifacts(context).list("cloud:${p.getString("id")}").map{it as Map<String,Any?>}.filter{it["state"]=="delivered"}.map{it["id"]}.toSet()
            for(i in 0 until artifactIds.length())require(artifactIds.getString(i) in actual){"计划成果记录不存在或不属于此计划。"}
            r.put("artifactIds",artifactIds)
        }
        finishInside(db,r,p,state,summary,result);p
    }
    fun recover() {
        store.transaction { db ->
            val now=System.currentTimeMillis()
            for(r in store.queryJson(db,"SELECT data FROM runs WHERE state='running'")) {
                if(r.getLong("leaseUntil")>now && r.optInt("processId",-1)==android.os.Process.myPid()) continue
                val p=store.plan(r.getString("planId"),db) ?: continue
                finishInside(db,r,p,"unknown","上次执行中断，结果待核对；不会自动重做。","")
            }
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
