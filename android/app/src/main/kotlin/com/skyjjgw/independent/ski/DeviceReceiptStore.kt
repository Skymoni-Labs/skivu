package com.skyjjgw.independent.ski

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONObject

/** Durable idempotency without a fixed lifetime action-count quota. */
class DeviceReceiptStore(context: Context) : SQLiteOpenHelper(context, "skivu-device-receipts.db", null, 2) {
    private val blobs=TaskBlobStore(context)
    init { setWriteAheadLoggingEnabled(true) }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE receipts (id TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL, outcome TEXT NOT NULL, summary TEXT NOT NULL,value TEXT)")
    }
    override fun onUpgrade(db: SQLiteDatabase, old: Int, next: Int) { if(old<2)db.execSQL("ALTER TABLE receipts ADD COLUMN value TEXT") }
    fun read(id: String): JSONObject? = readableDatabase.query("receipts", arrayOf("fingerprint", "outcome", "summary","value"),
        "id=?", arrayOf(id), null, null, null).use { row ->
        if (!row.moveToFirst()) null else JSONObject(mapOf("fingerprint" to row.getString(0),
            "outcome" to row.getString(1), "summary" to row.getString(2))).apply{if(!row.isNull(3))put("value",JSONObject(blobs.decode(row.getString(3))).opt("value"))}
    }
    fun write(id: String, value: JSONObject) {
        val values = ContentValues().apply {
            put("id", id); put("fingerprint", value.getString("fingerprint"))
            put("outcome", value.getString("outcome")); put("summary", value.getString("summary"))
            if(value.has("value"))put("value",blobs.encode(JSONObject().put("value",value.opt("value")).toString()))
        }
        check(writableDatabase.insertWithOnConflict("receipts", null, values, SQLiteDatabase.CONFLICT_REPLACE) >= 0)
    }
    fun submitted(fingerprint: String): JSONObject? = readableDatabase.query(
        "receipts", arrayOf("outcome", "summary"),
        "fingerprint=? AND outcome IN ('verified','dispatched','unknown')",
        arrayOf(fingerprint), null, null, null, "1").use { row ->
        if (!row.moveToFirst()) null else JSONObject(mapOf(
            "outcome" to row.getString(0), "summary" to row.getString(1)))
    }
    fun remove(id: String) { writableDatabase.delete("receipts", "id=?", arrayOf(id)) }
}
