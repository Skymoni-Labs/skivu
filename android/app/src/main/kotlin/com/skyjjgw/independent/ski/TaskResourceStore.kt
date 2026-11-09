package com.skyjjgw.independent.ski

import android.Manifest
import android.content.Context
import android.content.ContentValues
import android.content.ContentUris
import android.content.ContentProviderOperation
import android.content.pm.PackageManager
import android.provider.CalendarContract
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.TimeZone

/** External IDs are read from the actual provider; a local reference is never called a system ID. */
class TaskResourceStore(private val context: Context) {
    private val store=TaskDatabase.get(context)
    private val resolver=context.contentResolver
    private val events=CalendarContract.Events.CONTENT_URI
    private val reminders=CalendarContract.Reminders.CONTENT_URI
    private fun id()="resource_${UUID.randomUUID().toString().replace('-','_')}"
    private fun requireCalendar() {
        if(context.checkSelfPermission(Manifest.permission.READ_CALENDAR)!=PackageManager.PERMISSION_GRANTED || context.checkSelfPermission(Manifest.permission.WRITE_CALENDAR)!=PackageManager.PERMISSION_GRANTED) throw SecurityException("请先允许读取和写入系统日历。")
    }
    fun list(): List<JSONObject> = store.queryJson(store.readableDatabase,"SELECT data FROM resources ORDER BY rowid DESC")
    fun get(id: String): JSONObject = store.queryJson(store.readableDatabase,"SELECT data FROM resources WHERE id=?",arrayOf(id)).firstOrNull() ?: error("系统关联记录不存在。")
    private fun save(r: JSONObject): JSONObject {
        store.writableDatabase.insertWithOnConflict("resources",null,ContentValues().apply {
            put("id",r.getString("id"));put("version",r.getInt("version"));
            if(r.has("taskId")) put("task_id",r.getString("taskId")) else putNull("task_id")
            if(r.has("sourceKey")) put("source_key",r.getString("sourceKey")) else putNull("source_key")
            put("data",r.toString())
        },android.database.sqlite.SQLiteDatabase.CONFLICT_REPLACE)
        return r
    }
    fun captureClock(p: JSONObject): JSONObject {
        val source=p.getString("sourceKey")
        require(Regex("execution:[a-f0-9]{64}").matches(source))
        list().firstOrNull {it.optString("sourceKey")==source}?.let {return it}
        val args=p.getJSONObject("arguments")
        val locator=JSONObject().put("hour",args.getInt("hour")).put("minute",args.getInt("minute")).put("label",args.optString("label")).put("days",args.optJSONArray("days") ?: JSONArray())
        require(locator.getInt("hour") in 0..23 && locator.getInt("minute") in 0..59 && locator.getString("label").length<=160)
        return save(JSONObject().put("id",id()).put("version",1).put("sourceKey",source).put("provider","clock").put("locator",locator).put("state","pending_verification").put("summary","手机时钟操作已提交，尚未取得可读写的系统对象编号；不会通过再次创建来核对。"))
    }
    fun confirmClock(source: String): JSONObject {
        val r=list().firstOrNull {it.optString("sourceKey")==source} ?: return JSONObject().put("found",false)
        require(r.getString("provider")=="clock")
        r.put("state","user_confirmed").put("summary","用户已确认系统软件中的结果；这不是程序自动核验。").put("version",r.getInt("version")+1)
        return save(r)
    }
    fun calendars(): List<Map<String,Any?>> {
        requireCalendar()
        val columns=arrayOf(CalendarContract.Calendars._ID,CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,CalendarContract.Calendars.IS_PRIMARY)
        return resolver.query(CalendarContract.Calendars.CONTENT_URI,columns,"${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL}>=? AND ${CalendarContract.Calendars.VISIBLE}=?",arrayOf(CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR.toString(),"1"),"${CalendarContract.Calendars.IS_PRIMARY} DESC,${CalendarContract.Calendars._ID} ASC")?.use {c->buildList {
            while(c.moveToNext()) add(mapOf("id" to c.getLong(0),"name" to c.getString(1),"primary" to (c.getInt(2)==1)))
        }} ?: emptyList()
    }
    private fun marker(task: String)="skivu://tasks/$task"
    private fun event(id: Long): JSONObject? {
        requireCalendar()
        val columns=arrayOf(CalendarContract.Events._ID,CalendarContract.Events.CALENDAR_ID,CalendarContract.Events.TITLE,CalendarContract.Events.DTSTART,CalendarContract.Events.DTEND,CalendarContract.Events.EVENT_TIMEZONE,CalendarContract.Events.RRULE,CalendarContract.Events.CUSTOM_APP_PACKAGE,CalendarContract.Events.CUSTOM_APP_URI,CalendarContract.Events.DELETED)
        val value=resolver.query(ContentUris.withAppendedId(events,id),columns,null,null,null)?.use {c->
            if(!c.moveToFirst() || c.getInt(9)==1) null else JSONObject().put("eventId",c.getLong(0)).put("calendarId",c.getLong(1)).put("title",c.getString(2) ?: "").put("at",c.getLong(3)).put("end",if(c.isNull(4)) JSONObject.NULL else c.getLong(4)).put("timeZone",c.getString(5)).put("rrule",c.getString(6) ?: "").put("package",c.getString(7) ?: "").put("marker",c.getString(8) ?: "")
        } ?: return null
        val times=resolver.query(reminders,arrayOf(CalendarContract.Reminders.MINUTES,CalendarContract.Reminders.METHOD),"${CalendarContract.Reminders.EVENT_ID}=?",arrayOf(id.toString()),null)?.use {c->buildList {while(c.moveToNext()) add(mapOf("minutes" to c.getInt(0),"method" to c.getInt(1)))}} ?: emptyList()
        value.put("reminders",JSONArray(times))
        value.put("tag",TaskDatabase.digest(TaskScheduleStore.canonical(value)))
        return value
    }
    private fun owned(r: JSONObject): JSONObject? {
        val actual=event(r.getLong("externalId")) ?: return null
        require(actual.getString("package")==context.packageName && actual.getString("marker")==marker(r.getString("taskId"))) { "系统对象的关联标识已变化，未覆盖或删除。" }
        return actual
    }
    private fun recurrence(args: JSONObject): String {
        return when(args.optString("repeat","none")) {
            "none"->""
            "daily"->"FREQ=DAILY"
            "weekly"->{val days=args.getJSONArray("weekdays");require(days.length() in 1..7);val names=arrayOf("MO","TU","WE","TH","FR","SA","SU");"FREQ=WEEKLY;BYDAY="+(0 until days.length()).map {days.getInt(it).also {day->require(day in 1..7)}}.distinct().sorted().joinToString(",") { names[it-1] }}
            else->error("系统提醒重复规则无效。")
        }
    }
    private fun desired(task: JSONObject,args: JSONObject,allowPast: Boolean=false): JSONObject {
        val at=args.getLong("at");require(allowPast || at>System.currentTimeMillis()) { "提醒时间必须在未来。" }
        val title=args.optString("title",task.getString("title"));require(title.length in 1..160)
        val minutes=args.optInt("reminderMinutes",0);require(minutes in 0..40320)
        return JSONObject().put("title",title).put("at",at).put("reminderMinutes",minutes).put("rrule",recurrence(args)).put("timeZone",args.optString("timeZone",TimeZone.getDefault().id))
    }
    private fun reminderSignature(values: JSONArray): List<String> = (0 until values.length()).map { TaskScheduleStore.canonical(values.getJSONObject(it)) }.sorted()
    private fun matching(actual: JSONObject,wanted: JSONObject): Boolean = actual.getString("title")==wanted.getString("title") && actual.getLong("at")==wanted.getLong("at") && actual.getString("rrule")==wanted.getString("rrule") &&
        if(wanted.has("preservedReminders")) reminderSignature(actual.getJSONArray("reminders"))==reminderSignature(wanted.getJSONArray("preservedReminders"))
        else (0 until actual.getJSONArray("reminders").length()).any {
            val r=actual.getJSONArray("reminders").getJSONObject(it);r.getInt("minutes")==wanted.getInt("reminderMinutes") && r.getInt("method")==CalendarContract.Reminders.METHOD_ALERT
        }
    private fun eventValues(wanted: JSONObject): ContentValues = ContentValues().apply {
        put(CalendarContract.Events.TITLE,wanted.getString("title"));put(CalendarContract.Events.DTSTART,wanted.getLong("at"));put(CalendarContract.Events.EVENT_TIMEZONE,wanted.getString("timeZone"));put(CalendarContract.Events.HAS_ALARM,1)
        if(wanted.getString("rrule").isEmpty()) {putNull(CalendarContract.Events.RRULE);putNull(CalendarContract.Events.DURATION);put(CalendarContract.Events.DTEND,wanted.getLong("at")+900_000)}
        else {put(CalendarContract.Events.RRULE,wanted.getString("rrule"));putNull(CalendarContract.Events.DTEND);put(CalendarContract.Events.DURATION,"PT15M")}
    }
    fun create(args: JSONObject,operation: String): JSONObject {
        requireCalendar()
        val digest=TaskDatabase.digest("reminder.create:${TaskScheduleStore.canonical(args)}")
        val previous=store.transaction {store.operation(it,operation,digest)}
        if(previous!=null) return verify(previous)
        list().firstOrNull { it.optString("createdBy")==operation }?.let {
            require(it.getString("createDigest")==digest) { "原操作编号的内容已变化。" }
            return verify(it.getString("id"))
        }
        val task=store.task(args.getString("taskId")) ?: error("请先保存待办。")
        require(!task.getBoolean("archived"))
        require(list().none {it.getString("provider")=="clock" && it.optString("sourceKey")==task.optString("sourceKey") && task.optString("sourceKey").isNotEmpty() && it.getString("state")!="cancelled"}) { "任务已有手机时钟关联，请先定位原闹钟，不能另建提醒来代替。" }
        val wanted=desired(task,args)
        val existing=list().firstOrNull {it.getString("provider")=="calendar" && it.optString("taskId")==task.getString("id") && it.getString("state") !in setOf("cancelled","missing")}
        if(existing!=null) {
            require(existing.optJSONObject("desired")?.let {TaskScheduleStore.canonical(it)==TaskScheduleStore.canonical(wanted)}==true) { "已有原系统提醒，请先读取后修改，不能另建替代项。" }
            store.transaction {store.remember(it,operation,digest,existing.getString("id"))}
            return verify(existing.getString("id"))
        }
        val choices=calendars();require(choices.isNotEmpty()) { "没有可写的系统日历，请先在手机日历中配置账户或日历。" }
        val calendarId=if(args.has("calendarId")) args.getLong("calendarId") else choices.first()["id"] as Long
        require(choices.any {it["id"]==calendarId})
        val r=JSONObject().put("id",id()).put("version",1).put("taskId",task.getString("id")).put("provider","calendar").put("state","prepared").put("desired",wanted).put("operationId",operation).put("createdBy",operation).put("createDigest",digest).put("calendarId",calendarId).put("summary","系统提醒准备中。")
        store.transaction {save(r);store.remember(it,operation,digest,r.getString("id"))}
        // Marker recovery handles a process death between the provider commit and local receipt.
        r.put("state","dispatching");save(r)
        val values=eventValues(wanted).apply {put(CalendarContract.Events.CALENDAR_ID,calendarId);put(CalendarContract.Events.CUSTOM_APP_PACKAGE,context.packageName);put(CalendarContract.Events.CUSTOM_APP_URI,marker(task.getString("id")))}
        val batch=arrayListOf(ContentProviderOperation.newInsert(events).withValues(values).build(),ContentProviderOperation.newInsert(reminders).withValueBackReference(CalendarContract.Reminders.EVENT_ID,0).withValue(CalendarContract.Reminders.MINUTES,wanted.getInt("reminderMinutes")).withValue(CalendarContract.Reminders.METHOD,CalendarContract.Reminders.METHOD_ALERT).build())
        try {
            val applied=resolver.applyBatch(CalendarContract.AUTHORITY,batch)
            val eventId=ContentUris.parseId(applied[0].uri ?: error("日历未返回真实对象编号。"))
            r.put("externalId",eventId);save(r)
            return verify(r.getString("id"))
        } catch(e: Exception) {r.put("state","unknown").put("summary","系统提醒提交结果待核对，不会自动新建第二条。");save(r);throw e}
    }
    fun verify(id: String): JSONObject {
        val r=get(id)
        if(r.getString("provider")=="clock") {
            val proof=TaskClockVerification.read(context,r)
            if(proof!=null) {for(k in proof.keys())r.put(k,proof.get(k));save(r)}
            return r.put("instructions","时钟没有通用可读写对象接口。请用 apps.list 找实际获准时钟，再用 apps.launch/ui.observe 定位与 locator 或 desiredChange 唯一匹配的原闹钟，执行 pendingAction 的修改或删除后再次 verify；不能重新创建来冒充修改。锁屏、目标不唯一或无法取得实际核对依据时保留待核对，可由用户确认。")
        }
        requireCalendar()
        if(!r.has("externalId")) {
            val ids=resolver.query(events,arrayOf(CalendarContract.Events._ID),"${CalendarContract.Events.CUSTOM_APP_PACKAGE}=? AND ${CalendarContract.Events.CUSTOM_APP_URI}=? AND ${CalendarContract.Events.DELETED}=0",arrayOf(context.packageName,marker(r.getString("taskId"))),null)?.use {c->buildList {while(c.moveToNext()) add(c.getLong(0))}} ?: emptyList()
            if(ids.size!=1) return save(r.put("state","unknown").put("summary","尚未定位唯一的系统提醒，不会通过新建来核对。"))
            r.put("externalId",ids.single())
        }
        val actual=owned(r)
        if(actual==null) return save(r.put("state",if(r.optString("pendingAction")=="cancel") "cancelled" else "missing").put("summary","系统日历中该对象已不存在。"))
        r.put("actual",actual)
        val desired=r.optJSONObject("desired")
        if(desired!=null && matching(actual,desired)) r.put("state","verified").put("summary","已读取系统日历核对，日程和提醒已登记。").remove("pendingAction")
        else r.put("state","changed_externally").put("summary","系统日历中的内容与原安排不同，请先读取最新内容后再修改。")
        return save(r)
    }
    fun mutate(action: String,args: JSONObject,operation: String): JSONObject {
        require(action in setOf("update","cancel"))
        val digest=TaskDatabase.digest("reminder.$action:${TaskScheduleStore.canonical(args)}")
        store.transaction {store.operation(it,operation,digest)}?.let { return verify(it) }
        val r=get(args.getString("id"))
        require(r.getInt("version")==args.getInt("expectedRevision")) { "关联记录已变化，请重新读取。" }
        if(r.getString("provider")=="clock") {
            r.put("pendingAction",action).put("desiredChange",args).put("state","pending_verification").put("version",r.getInt("version")+1).put("summary","仅记录了要修改或取消原闹钟的请求，尚未在时钟执行。继续用 apps.list/apps.launch/ui.observe 定位原项并处理，再调用 verify 核对；不要新建替代项。")
                .put("instructions","必须继续处理原时钟项；本回执不表示实际闹钟已更改。读取 locator 和 desiredChange，在获准时钟界面唯一定位后再操作，无法核对时如实保持待核对。")
            return store.transaction {save(r);store.remember(it,operation,digest,r.getString("id"));r}
        }
        requireCalendar()
        if(r.optString("operationId")==operation && r.getString("state") in setOf("dispatching","unknown")) return verify(r.getString("id"))
        val current=owned(r)
        if(current==null) return save(r.put("state",if(action=="cancel") "cancelled" else "missing").put("summary","系统日历中该对象已不存在。"))
        require(args.optString("expectedTag")==current.getString("tag")) { "系统日历已被修改，请先核对最新内容。" }
        val wanted=if(action=="update") {
            val base=JSONObject().put("at",current.getLong("at")).put("title",current.getString("title")).put("reminderMinutes",r.optJSONObject("desired")?.optInt("reminderMinutes",0) ?: 0).put("timeZone",current.getString("timeZone"))
            for(k in listOf("at","title","reminderMinutes","timeZone","repeat","weekdays")) if(args.has(k)) base.put(k,args.get(k))
            desired(store.task(r.getString("taskId")) ?: error("待办不存在。"),base,!args.has("at")).also {
                if(!args.has("repeat")) it.put("rrule",current.getString("rrule"))
                if(!args.has("reminderMinutes")) it.put("preservedReminders",current.getJSONArray("reminders"))
            }
        } else null
        r.put("pendingAction",action).put("operationId",operation).put("state","dispatching").put("version",r.getInt("version")+1)
        if(wanted!=null) r.put("desired",wanted)
        store.transaction {save(r);store.remember(it,operation,digest,r.getString("id"))}
        try {
            val eventId=r.getLong("externalId")
            if(action=="cancel") resolver.delete(ContentUris.withAppendedId(events,eventId),null,null)
            else {
                val values=eventValues(wanted!!)
                if(!args.has("at") && !args.has("repeat")) for(key in listOf(CalendarContract.Events.DTSTART,CalendarContract.Events.DTEND,CalendarContract.Events.DURATION,CalendarContract.Events.RRULE)) values.remove(key)
                if(!args.has("reminderMinutes")) values.remove(CalendarContract.Events.HAS_ALARM)
                val batch=arrayListOf(ContentProviderOperation.newUpdate(ContentUris.withAppendedId(events,eventId)).withValues(values).build())
                if(args.has("reminderMinutes")) {
                    batch.add(ContentProviderOperation.newDelete(reminders).withSelection("${CalendarContract.Reminders.EVENT_ID}=?",arrayOf(eventId.toString())).build())
                    batch.add(ContentProviderOperation.newInsert(reminders).withValue(CalendarContract.Reminders.EVENT_ID,eventId).withValue(CalendarContract.Reminders.MINUTES,wanted.getInt("reminderMinutes")).withValue(CalendarContract.Reminders.METHOD,CalendarContract.Reminders.METHOD_ALERT).build())
                }
                resolver.applyBatch(CalendarContract.AUTHORITY,batch)
            }
            return verify(r.getString("id"))
        } catch(e: Exception) {r.put("state","unknown").put("summary","系统修改结果待核对，不会自动重发。");save(r);throw e}
    }
    fun userConfirm(id: String,revision: Int): JSONObject {
        val r=get(id);require(r.getInt("version")==revision) { "关联已变化，请重新打开。" }
        r.put("state","user_confirmed").put("summary",if(r.optString("pendingAction")=="cancel") "用户已确认系统提醒取消；这是用户确认，不是程序自动核验。" else "用户已确认实际结果；这是用户确认，不是程序自动核验。").put("version",revision+1)
        return save(r)
    }
}
