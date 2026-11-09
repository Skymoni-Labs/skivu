package com.skyjjgw.independent.ski

import android.content.Context
import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/** Cross-engine transactions; the legacy JSON preference is a recovery source only. */
class TaskDatabase private constructor(context: Context) : SQLiteOpenHelper(context, "skivu-managed-tasks.db", null, 1) {
    private val blobs=TaskBlobStore(context)
    init { setWriteAheadLoggingEnabled(true) }
    override fun onConfigure(db: SQLiteDatabase) { super.onConfigure(db); db.setForeignKeyConstraintsEnabled(true); db.rawQuery("PRAGMA busy_timeout=5000",null).use {it.moveToFirst()} }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE documents(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, value TEXT NOT NULL)")
        db.execSQL("CREATE TABLE migration_backup(id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL, created INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE plans(id TEXT PRIMARY KEY, task_id TEXT NOT NULL, version INTEGER NOT NULL, state TEXT NOT NULL, next_ms INTEGER, data TEXT NOT NULL)")
        db.execSQL("CREATE TABLE runs(id TEXT PRIMARY KEY, plan_id TEXT NOT NULL, due_ms INTEGER NOT NULL, plan_version INTEGER NOT NULL, state TEXT NOT NULL, token TEXT NOT NULL, lease_until INTEGER NOT NULL, data TEXT NOT NULL, UNIQUE(plan_id,due_ms))")
        db.execSQL("CREATE TABLE effects(id TEXT PRIMARY KEY, run_id TEXT NOT NULL, fingerprint TEXT NOT NULL, state TEXT NOT NULL, data TEXT NOT NULL, UNIQUE(run_id,fingerprint))")
        db.execSQL("CREATE TABLE resources(id TEXT PRIMARY KEY, task_id TEXT, source_key TEXT UNIQUE, version INTEGER NOT NULL, data TEXT NOT NULL)")
        db.execSQL("CREATE TABLE operations(id TEXT PRIMARY KEY, digest TEXT NOT NULL, entity_id TEXT NOT NULL)")
        db.execSQL("CREATE TABLE budgets(day TEXT NOT NULL, plan_id TEXT NOT NULL, calls INTEGER NOT NULL, PRIMARY KEY(day,plan_id))")
        db.execSQL("CREATE INDEX plan_due ON plans(state,next_ms)")
    }
    override fun onUpgrade(db: SQLiteDatabase, old: Int, new: Int) { error("任务数据库版本不支持，保留原数据。") }
    fun <T> transaction(block: (SQLiteDatabase) -> T): T {
        val db = writableDatabase
        db.beginTransaction()
        try { val value = block(db); db.setTransactionSuccessful(); return value }
        finally { db.endTransaction() }
    }
    fun document(db: SQLiteDatabase = readableDatabase): Map<String, Any?> = db.rawQuery("SELECT version,value FROM documents WHERE id=1", null).use {
        if (it.moveToFirst()) mapOf("version" to it.getInt(0), "value" to blobs.decode(it.getString(1))) else mapOf("version" to 0, "value" to null)
    }
    fun validateDocument(raw: String): JSONObject {
        val value = JSONObject(raw)
        require(value.getInt("version") in 1..3 && value.opt("tasks") is JSONArray && value.opt("memories") is JSONArray)
        for (key in listOf("tasks","memories")) {
            val ids = mutableSetOf<String>()
            val rows = value.getJSONArray(key)
            for (index in 0 until rows.length()) {
                val item = rows.getJSONObject(index)
                require(Regex("[a-zA-Z0-9_-]{1,100}").matches(item.getString("id")) && ids.add(item.getString("id")))
                require(item.getString("title").isNotBlank())
                require(item.opt("done") is Boolean && item.opt("archived") is Boolean)
            }
        }
        return value
    }
    fun initialize(raw: String): Map<String, Any?> {
        validateDocument(raw)
        return transaction { db ->
            val prior = document(db)
            if (prior["value"] == null) {
                db.insertOrThrow("migration_backup", null, ContentValues().apply { put("id",1);put("value",blobs.encode(raw));put("created",System.currentTimeMillis()) })
                db.insertOrThrow("documents", null, ContentValues().apply { put("id",1);put("version",1);put("value",blobs.encode(raw)) })
            }
            document(db)
        }
    }
    fun validateLease(db: SQLiteDatabase, lease: JSONObject?) {
        if (lease == null) return
        val id = lease.getString("id"); val token = lease.getString("token")
        val run=run(id,db)
        require(run!=null&&run.optString("state")=="running"&&run.optString("token")==token&&run.optLong("leaseUntil")>System.currentTimeMillis()&&!run.optBoolean("stopRequested")){"本次执行已停止、租约失效或身份已变化。"}
    }
    fun compareAndSet(version: Int, raw: String, lease: JSONObject?): Boolean {
        val parsed = validateDocument(raw)
        return transaction { db ->
            validateLease(db,lease)
            val saved = db.update("documents", ContentValues().apply { put("value",blobs.encode(raw)); put("version",version+1) }, "id=1 AND version=?", arrayOf(version.toString())) == 1
            if (saved) {
                val archived = mutableSetOf<String>()
                val tasks = parsed.getJSONArray("tasks")
                for (i in 0 until tasks.length()) if(tasks.getJSONObject(i).getBoolean("archived")) archived.add(tasks.getJSONObject(i).getString("id"))
                for (id in archived) {
                    for (p in queryJson(db,"SELECT data FROM plans WHERE task_id=? AND state='enabled'", arrayOf(id))) {
                        p.put("state","paused").put("reason","任务已归档").put("version",p.getInt("version")+1)
                        if(p.optJSONObject("lastRun")?.optString("state")=="running") p.getJSONObject("lastRun").put("summary","任务已归档，后续计划暂停；本次执行可单独停止。")
                        writePlan(db,p)
                    }
                }
            }
            saved
        }
    }
    fun task(id: String, db: SQLiteDatabase = readableDatabase): JSONObject? {
        val raw = document(db)["value"] as? String ?: return null
        val rows = JSONObject(raw).getJSONArray("tasks")
        for(i in 0 until rows.length()) if(rows.getJSONObject(i).getString("id")==id) return rows.getJSONObject(i)
        return null
    }
    fun queryJson(db: SQLiteDatabase, sql: String, args: Array<String>? = null): List<JSONObject> = db.rawQuery(sql,args).use { cursor -> buildList { while(cursor.moveToNext()) add(JSONObject(blobs.decode(cursor.getString(0)))) } }
    fun plan(id: String, db: SQLiteDatabase = readableDatabase): JSONObject? = queryJson(db,"SELECT data FROM plans WHERE id=?", arrayOf(id)).firstOrNull()
    fun writePlan(db: SQLiteDatabase, p: JSONObject) { db.insertWithOnConflict("plans",null,ContentValues().apply {
        put("id",p.getString("id"));put("task_id",p.getString("taskId"));put("version",p.getInt("version"));put("state",p.getString("state"));
        if(p.isNull("nextAt")) putNull("next_ms") else put("next_ms",p.getLong("nextAt"));put("data",blobs.encode(p.toString()))
    },SQLiteDatabase.CONFLICT_REPLACE) }
    fun run(id: String, db: SQLiteDatabase = readableDatabase): JSONObject? = queryJson(db,"SELECT data FROM runs WHERE id=?",arrayOf(id)).firstOrNull()
    fun writeRun(db: SQLiteDatabase, r: JSONObject) { db.insertWithOnConflict("runs",null,ContentValues().apply {
        put("id",r.getString("id"));put("plan_id",r.getString("planId"));put("due_ms",r.getLong("dueAt"));put("plan_version",r.getInt("planVersion"));put("state",r.getString("state"));put("token",r.getString("token"));put("lease_until",r.getLong("leaseUntil"));put("data",blobs.encode(r.toString()))
    },SQLiteDatabase.CONFLICT_REPLACE) }
    fun operation(db: SQLiteDatabase,id: String,digest: String): String? = db.rawQuery("SELECT digest,entity_id FROM operations WHERE id=?",arrayOf(id)).use {
        if (!it.moveToFirst()) null else {require(it.getString(0)==digest) { "操作编号不能复用为不同内容。" };it.getString(1)}
    }
    fun remember(db: SQLiteDatabase,id: String,digest: String,entity: String) {
        require(Regex("[a-zA-Z0-9_:-]{1,200}").matches(id))
        db.insertOrThrow("operations",null,ContentValues().apply {put("id",id);put("digest",digest);put("entity_id",entity)})
    }
    companion object {
        @Volatile private var value: TaskDatabase? = null
        fun get(context: Context): TaskDatabase = value ?: synchronized(this) { value ?: TaskDatabase(context.applicationContext).also { value=it } }
        fun digest(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
        fun unpack(value: Any?): Any? = when(value) {
            null, JSONObject.NULL -> null
            is JSONObject -> value.keys().asSequence().associateWith { unpack(value.get(it)) }
            is JSONArray -> (0 until value.length()).map { unpack(value.get(it)) }
            else -> value
        }
    }
}
