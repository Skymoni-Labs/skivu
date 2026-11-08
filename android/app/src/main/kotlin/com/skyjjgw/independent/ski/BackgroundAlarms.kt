package com.skyjjgw.independent.ski

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.os.UserManager
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/** Native-owned scheduling. No Activity is started by this module. */
class BackgroundAlarms(context: Context, private val beforeSchedule: (() -> Unit)? = null) : AutoCloseable {
    private val app = context.applicationContext
    private val schedulingContext = app.createDeviceProtectedStorageContext()
    private val db = Store(schedulingContext)
    private val manager = app.getSystemService(AlarmManager::class.java)
    private val notifications = app.getSystemService(NotificationManager::class.java)
    companion object {
        val lock = Any()
        val processNonce = UUID.randomUUID().toString()
        const val CHANNEL = "skivu-native-alarms-v1"
        const val RING_NOTIFICATION = 9301
        const val RECOVERY_JOB = 9321
        private val zones = TimeZone.getAvailableIDs().toSet()
        fun canonical(value: Any?): String = when (value) {
            is Map<*, *> -> value.keys.map { it as String }.sorted().joinToString(",", "{", "}") {
                "${JSONObject.quote(it)}:${canonical(value[it])}"
            }
            is List<*> -> value.joinToString(",", "[", "]") { canonical(it) }
            else -> JSONObject.wrap(value).let { if (it is String) JSONObject.quote(it) else it.toString() }
        }
        fun hash(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray())
            .joinToString("") { "%02x".format(it) }

        /** ISO weekdays, unlike the legacy system-clock Calendar weekday API. */
        fun nextWallTime(spec: JSONObject, after: Long, zone: TimeZone = TimeZone.getDefault()): Long {
            val selected = spec.optString("timeZone").takeIf { it.isNotEmpty() }?.let { TimeZone.getTimeZone(it) } ?: zone
            val base = Calendar.getInstance(selected).apply { timeInMillis = after }
            val date = spec.optString("date")
            if (date.isNotEmpty()) {
                val parsed = SimpleDateFormat("yyyy-MM-dd", Locale.ROOT).apply {
                    isLenient = false; timeZone = selected
                }.parse(date) ?: error("日期无效。")
                base.time = parsed
            }
            val days = spec.optJSONArray("days") ?: JSONArray()
            val allowed = (0 until days.length()).map { days.getInt(it) }.toSet()
            repeat(9) {
                val candidate = (base.clone() as Calendar).apply {
                    set(Calendar.HOUR_OF_DAY, spec.getInt("hour")); set(Calendar.MINUTE, spec.getInt("minute"))
                    set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                }
                val weekday = (candidate.get(Calendar.DAY_OF_WEEK) + 5) % 7 + 1
                if (candidate.timeInMillis > after && (allowed.isEmpty() || weekday in allowed)) return candidate.timeInMillis
                require(date.isEmpty()) { "指定日期时间已经过去，请使用未来时间。" }
                base.add(Calendar.DAY_OF_YEAR, 1)
            }
            error("未能计算下一次闹钟时间。")
        }
    }
    private class Store(context: Context) : SQLiteOpenHelper(context, "skivu-background-alarms-v1.db", null, 1) {
        init { setWriteAheadLoggingEnabled(true) }
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("CREATE TABLE alarms (id TEXT PRIMARY KEY NOT NULL, data TEXT NOT NULL)")
            db.execSQL("CREATE TABLE operations (id TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL, resource TEXT NOT NULL)")
        }
        override fun onUpgrade(db: SQLiteDatabase, old: Int, next: Int) { error("Unsupported alarm database") }
    }
    override fun close() = db.close()
    private fun unlocked() = app.getSystemService(UserManager::class.java).isUserUnlocked
    private fun labels() = app.getSharedPreferences("skivu-native-alarm-labels-v1", 0)
    private fun label(id: String) = if (unlocked()) labels().getString(id, "") ?: "" else ""
    private fun setLabel(id: String, text: String) {
        check(unlocked()) { "请先解锁手机。" }
        check(labels().edit().putString(id, text).commit()) { "闹钟名称未能保存。" }
    }
    fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= 26) notifications.createNotificationChannel(
            NotificationChannel(CHANNEL, "小云闹钟与计时", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "原生闹钟的停止、稍后提醒和运行状态"; setSound(null, null)
                enableVibration(false)
            })
    }
    fun capability(): Map<String, Any?> {
        ensureChannel()
        val exact = Build.VERSION.SDK_INT < 31 || manager.canScheduleExactAlarms()
        val visible = notifications.areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < 26 || notifications.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)
        return mapOf("exactAlarms" to exact, "alarmNotifications" to visible,
            "alarmReady" to (exact && visible), "alarmTimezone" to TimeZone.getDefault().id,
            "alarmBackend" to "skivu_native")
    }
    fun ready(): Boolean = capability()["alarmReady"] == true
    private fun get(id: String): JSONObject? = db.readableDatabase.query("alarms", arrayOf("data"),
        "id=?", arrayOf(id), null, null, null).use { if (it.moveToFirst()) JSONObject(it.getString(0)) else null }
    private fun all(): List<JSONObject> = db.readableDatabase.query("alarms", arrayOf("data"),
        null, null, null, null, "id").use { cursor -> buildList { while (cursor.moveToNext()) add(JSONObject(cursor.getString(0))) } }
    private fun put(item: JSONObject) {
        check(db.writableDatabase.insertWithOnConflict("alarms", null, ContentValues().apply {
            put("id", item.getString("id")); put("data", item.toString())
        }, SQLiteDatabase.CONFLICT_REPLACE) >= 0)
    }
    private fun publicItem(item: JSONObject): Map<String, Any?> = buildMap {
        for (key in listOf("id", "kind", "hour", "minute", "date", "timeZone", "enabled", "revision", "nextAt", "state", "lastFiredAt", "ringState", "error", "vibrate", "createdAt", "updatedAt"))
            if (item.has(key)) put(key, item.get(key).takeUnless { it == JSONObject.NULL })
        val days = item.optJSONArray("days") ?: JSONArray()
        put("days", (0 until days.length()).map { days.getInt(it) })
        put("label", label(item.getString("id")))
        if (item.has("nextAt")) {
            val zone = item.optString("timeZone").takeIf { it.isNotEmpty() }?.let { TimeZone.getTimeZone(it) } ?: TimeZone.getDefault()
            put("nextLocal", SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.ROOT).apply { timeZone = zone }.format(java.util.Date(item.getLong("nextAt"))) + " " + zone.id)
        }
        put("source", "skivu_native"); put("verification", when (item.optString("state")) {
            "scheduled" -> "schedule_registered"; "cancelled" -> "cancellation_registered"; else -> "resource_read"
        })
    }
    fun list(): List<Map<String, Any?>> = synchronized(lock) {
        all().sortedWith(compareBy<JSONObject> { !it.optBoolean("enabled") }.thenBy { it.optLong("nextAt", Long.MAX_VALUE) }).map(::publicItem)
    }
    fun read(id: String): Map<String, Any?> = synchronized(lock) { publicItem(get(id) ?: error("没有找到这个小云闹钟。")) }
    private fun pending(item: JSONObject, flags: Int): PendingIntent? = PendingIntent.getBroadcast(app, 0,
        Intent(app, BackgroundAlarmReceiver::class.java).setAction("fire")
            .setData(Uri.parse("skivu-alarm://${app.packageName}/${item.getString("id")}"))
            .putExtra("id", item.getString("id")).putExtra("revision", item.getLong("revision"))
            .putExtra("due", item.getLong("nextAt")), flags or PendingIntent.FLAG_IMMUTABLE)
    private fun cancelSchedule(item: JSONObject) { pending(item, PendingIntent.FLAG_NO_CREATE)?.let { manager.cancel(it); it.cancel() } }
    private fun schedule(item: JSONObject) {
        check(ready()) { "需要通知和精确闹钟授权；请在小云能力设置中配置。" }
        val callback = pending(item, PendingIntent.FLAG_UPDATE_CURRENT)!!
        run {
            // showIntent is opened only by an explicit tap on Android's next-alarm UI.
            val show = PendingIntent.getActivity(app, 9302, Intent(app, MainActivity::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            manager.setAlarmClock(AlarmManager.AlarmClockInfo(item.getLong("nextAt"), show), callback)
        }
    }
    private fun boot() = Settings.Global.getInt(app.contentResolver, Settings.Global.BOOT_COUNT, 0)
    private fun queueRecovery() {
        val job = JobInfo.Builder(RECOVERY_JOB, ComponentName(app, BackgroundAlarmRecoveryJob::class.java))
            .setMinimumLatency(1000).setOverrideDeadline(5000).setPersisted(true).build()
        check(app.getSystemService(JobScheduler::class.java).schedule(job) == JobScheduler.RESULT_SUCCESS) { "后台恢复任务未能登记。" }
    }
    private fun settleRecovery() {
        if (all().none { it.optBoolean("enabled") && it.optString("state") in setOf("prepared", "needs_attention") })
            app.getSystemService(JobScheduler::class.java).cancel(RECOVERY_JOB)
    }
    private fun creationKey(item: JSONObject, text: String) = hash(canonical(mapOf(
        "kind" to item.getString("kind"), "time" to if (item.getString("kind") == "timer") item.getInt("seconds") else item.getLong("nextAt"),
        "days" to item.optJSONArray("days").toString(), "timeZone" to item.optString("timeZone"), "label" to text, "vibrate" to item.optBoolean("vibrate"))))
    private fun number(args: Map<String, Any?>, key: String, range: IntRange): Int {
        val raw = args[key]; require(raw is Int || raw is Long) { "$key 必须是整数。" }
        val n = (raw as Number).toLong(); require(n >= range.first && n <= range.last) { "$key 超出范围。" }; return n.toInt()
    }
    private fun validate(spec: JSONObject) {
        require(spec.getInt("hour") in 0..23 && spec.getInt("minute") in 0..59)
        val date = spec.optString("date")
        require(date.isEmpty() || Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}").matches(date)) { "日期必须为 YYYY-MM-DD。" }
        val days = spec.optJSONArray("days") ?: JSONArray()
        require(days.length() <= 7 && (0 until days.length()).all { days.getInt(it) in 1..7 }) { "星期采用周一1到周日7。" }
        require(date.isEmpty() || days.length() == 0) { "指定日期与按周重复不能同时使用。" }
        val zone = spec.optString("timeZone"); require(zone.isEmpty() || zone in zones) { "时区无效。" }
    }
    private fun updateSpec(item: JSONObject, args: Map<String, Any?>) {
        for (key in listOf("hour", "minute")) if (args.containsKey(key)) item.put(key, number(args, key, if (key == "hour") 0..23 else 0..59))
        for (key in listOf("date", "timeZone")) if (args.containsKey(key)) {
            require(args[key] is String); item.put(key, args[key])
        }
        if (args.containsKey("vibrate")) { require(args["vibrate"] is Boolean); item.put("vibrate", args["vibrate"]) }
        if (args.containsKey("days")) {
            val days = args["days"] as? List<*> ?: error("星期无效。")
            require(days.size <= 7 && days.all { (it is Int || it is Long) && (it as Number).toLong() in 1..7 })
            item.put("days", JSONArray(days.map { (it as Number).toInt() }.distinct().sorted()))
        }
        validate(item)
    }
    /** Reserve operation/resource first. Repeated scheduling of this resource replaces its own PendingIntent. */
    fun execute(tool: String, args: Map<String, Any?>, operation: String, beforeWrite: () -> Unit = {}): Map<String, Any?> = synchronized(lock) {
        if (tool == "assistant.alarm.list") {
            require(args.keys.all { it in setOf("includeInactive", "offset", "limit") })
            require(!args.containsKey("includeInactive") || args["includeInactive"] is Boolean)
            val offset = if (args.containsKey("offset")) number(args, "offset", 0..1000000) else 0
            val limit = if (args.containsKey("limit")) number(args, "limit", 1..100) else 50
            val entries = list().filter { args["includeInactive"] == true || it["enabled"] == true || it["ringState"] in setOf("pending", "starting", "playing", "playing_fallback") }
            return mapOf("items" to entries.drop(offset).take(limit), "total" to entries.size,
                "offset" to offset, "hasMore" to (offset + limit < entries.size), "source" to "skivu_native")
        }
        if (tool == "assistant.alarm.get") { require(args.keys == setOf("id")); return read(args["id"] as? String ?: error("缺少闹钟编号。")) }
        val fingerprint = hash("$tool:${canonical(args)}")
        val oldOperation = db.readableDatabase.query("operations", arrayOf("fingerprint", "resource"),
            "id=?", arrayOf(operation), null, null, null).use { row ->
            if (!row.moveToFirst()) null else Pair(row.getString(0), row.getString(1))
        }
        if (oldOperation != null) {
            require(oldOperation.first == fingerprint) { "同一操作编号不能用于不同参数。" }
            val existing = get(oldOperation.second) ?: error("执行记录对应的闹钟不存在。")
            if (existing.optBoolean("enabled") && existing.optString("state") == "prepared") { beforeWrite(); register(existing) }
            if (!existing.optBoolean("enabled")) { beforeWrite(); cancelSchedule(existing); stopRinging(existing.getString("id")) }
            settleRecovery()
            return publicItem(existing) + ("reusedOperation" to true)
        }
        val creating = tool == "assistant.alarm.create" || tool == "assistant.timer.start"
        require(creating || tool in setOf("assistant.alarm.update", "assistant.alarm.cancel"))
        val allowed = when (tool) {
            "assistant.alarm.create" -> setOf("hour", "minute", "date", "days", "timeZone", "label", "vibrate")
            "assistant.timer.start" -> setOf("seconds", "label", "vibrate")
            "assistant.alarm.update" -> setOf("id", "hour", "minute", "date", "days", "timeZone", "label", "vibrate", "enabled")
            else -> setOf("id")
        }
        require(args.keys.all { it in allowed }) { "闹钟参数无效。" }
        val now = System.currentTimeMillis()
        var item = if (creating) JSONObject().put("id", UUID.randomUUID().toString()).put("revision", 0)
            .put("createdAt", now)
            .put("kind", if (tool == "assistant.timer.start") "timer" else "alarm")
            .put("enabled", true).put("vibrate", true).put("days", JSONArray())
            else get(args["id"] as? String ?: error("缺少闹钟编号。")) ?: error("没有找到这个小云闹钟。")
        if (tool == "assistant.alarm.cancel") item.put("enabled", false)
        else {
            if (args.containsKey("enabled")) { require(args["enabled"] is Boolean); item.put("enabled", args["enabled"]) }
            if (item.getString("kind") == "timer") {
                if (creating) {
                    val seconds = number(args, "seconds", 1..604800)
                    item.put("seconds", seconds).put("nextAt", now + seconds * 1000L).put("elapsedDeadline", SystemClock.elapsedRealtime() + seconds * 1000L).put("boot", boot())
                } else require(args.keys.all { it in setOf("id", "enabled", "label", "vibrate") }) { "倒计时请取消后重新启动。" }
            } else {
                updateSpec(item, args)
                if (item.getBoolean("enabled")) item.put("nextAt", nextWallTime(item, now))
            }
            if (args.containsKey("vibrate")) { require(args["vibrate"] is Boolean); item.put("vibrate", args["vibrate"]) }
        }
        if (item.getBoolean("enabled")) check(ready()) { "需要通知和精确闹钟授权。" }
        if (item.getBoolean("enabled") && item.getString("kind") == "timer" && !creating)
            require(item.getLong("nextAt") > now) { "已过期的倒计时请重新启动。" }
        val labelText = if (args.containsKey("label")) args["label"] as? String ?: error("名称无效。") else ""
        require(labelText.length <= 160 && !labelText.contains('\u0000'))
        var reused = false
        if (creating) {
            val signature = creationKey(item, labelText)
            val active = all().firstOrNull { it.optBoolean("enabled") && it.optLong("nextAt") > now && creationKey(it, label(it.getString("id"))) == signature }
            if (active != null) { item = active; reused = true }
        }
        val id = item.getString("id")
        beforeWrite()
        queueRecovery()
        if (args.containsKey("label")) {
            setLabel(id, labelText)
        }
        item.put("revision", item.getLong("revision") + 1).put("updatedAt", now).put("state", if (item.getBoolean("enabled")) "prepared" else "cancelled").remove("error")
        val database = db.writableDatabase
        database.beginTransaction()
        try {
            put(item)
            check(database.insertOrThrow("operations", null, ContentValues().apply {
                put("id", operation); put("fingerprint", fingerprint); put("resource", id)
            }) >= 0)
            database.setTransactionSuccessful()
        } finally { database.endTransaction() }
        if (item.getBoolean("enabled")) register(item) else { cancelSchedule(item); stopRinging(id) }
        settleRecovery()
        publicItem(item) + ("reusedResource" to reused)
    }
    private fun register(item: JSONObject) {
        item.put("state", "prepared"); put(item)
        try {
            beforeSchedule?.invoke()
            schedule(item); item.put("state", "scheduled").remove("error"); put(item)
        } catch (error: Exception) {
            item.put("state", "prepared").put("error", error.message?.take(180)); put(item); throw error
        }
    }
    fun cancel(id: String): Map<String, Any?> = execute("assistant.alarm.cancel", mapOf("id" to id), "user-cancel-${UUID.randomUUID()}")
    fun recover(reason: String) = synchronized(lock) {
        for (item in all()) {
            try {
                if (item.optString("ringState") in setOf("pending", "starting", "playing", "playing_fallback") && item.optString("ringProcess") != processNonce)
                    { item.put("ringState", "interrupted"); put(item) }
                if (!item.optBoolean("enabled")) { cancelSchedule(item); if (item.optString("state") == "cancelled") stopRinging(item.getString("id")); continue }
                if (reason in setOf("capabilities", "outbox") && item.optString("state") == "scheduled") continue
                if (!ready()) { item.put("state", "permission_required"); put(item); continue }
                val now = System.currentTimeMillis()
                if (item.getString("kind") == "timer" && item.optInt("boot") == boot()) {
                    item.put("nextAt", now + item.getLong("elapsedDeadline") - SystemClock.elapsedRealtime())
                } else if (reason in setOf(Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED) && item.getString("kind") == "alarm" && !item.optBoolean("snoozed")) {
                    item.put("nextAt", nextWallTime(item, now)).put("revision", item.getLong("revision") + 1)
                }
                if (item.getLong("nextAt") <= now) {
                    if (now - item.getLong("nextAt") <= 120000) { register(item); continue }
                    if (item.getString("kind") == "alarm" && (item.optJSONArray("days")?.length() ?: 0) > 0)
                        item.put("nextAt", nextWallTime(item, now)).put("revision", item.getLong("revision") + 1)
                    else { item.put("enabled", false).put("state", "missed"); put(item); cancelSchedule(item); continue }
                }
                register(item)
            } catch (error: Exception) { item.put("state", "needs_attention").put("error", error.message?.take(180)); put(item) }
        }
    }
    fun claimFire(id: String, revision: Long, due: Long): Map<String, Any?>? = synchronized(lock) {
        val item = get(id) ?: return null
        if (!item.optBoolean("enabled") || item.getLong("revision") != revision || item.getLong("nextAt") != due ||
            System.currentTimeMillis() + 1000 < due) return null
        if (item.getString("kind") == "timer" && item.optInt("boot") == boot() &&
            SystemClock.elapsedRealtime() + 1000 < item.getLong("elapsedDeadline")) return null
        item.put("lastFiredAt", due).put("ringState", "pending").put("revision", revision + 1).put("snoozed", false)
            .put("ringRevision", revision + 1).put("ringProcess", processNonce)
        if (item.getString("kind") == "alarm" && (item.optJSONArray("days")?.length() ?: 0) > 0) {
            item.put("nextAt", nextWallTime(item, System.currentTimeMillis() + 1000)).put("state", "prepared")
            queueRecovery()
            put(item)
            try { register(item); settleRecovery() } catch (_: Exception) { /* current occurrence must still ring */ }
        } else { item.put("enabled", false).put("state", "fired"); put(item) }
        publicItem(item) + ("occurrence" to due)
    }
    fun markRing(id: String, occurrence: Long, state: String, onlyPending: Boolean = false): Boolean = synchronized(lock) {
        val item = get(id) ?: return false
        if (item.optLong("lastFiredAt") != occurrence || (onlyPending && (item.optString("ringState") != "pending" ||
            item.optLong("ringRevision") != item.optLong("revision") || item.optString("state") == "cancelled" ||
            item.optString("ringProcess") != processNonce))) return false
        item.put("ringState", state); put(item); true
    }
    fun snooze(id: String, occurrence: Long): Boolean = synchronized(lock) {
        val item = get(id) ?: return false
        if (item.optLong("lastFiredAt") != occurrence || item.optString("ringState") !in setOf("starting", "playing", "playing_fallback") || !ready()) return false
        item.put("enabled", true).put("snoozed", true).put("nextAt", System.currentTimeMillis() + 300000)
            .put("elapsedDeadline", SystemClock.elapsedRealtime() + 300000).put("boot", boot())
            .put("revision", item.getLong("revision") + 1).put("state", "prepared").put("ringState", "snoozed")
        queueRecovery(); put(item); register(item); settleRecovery(); stopRinging(id); true
    }
    private fun stopRinging(id: String) { BackgroundAlarmRingService.stopAlarm(id) }
}
