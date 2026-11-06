package com.skyjjgw.independent.ski

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONObject

/** Durable idempotency without a fixed lifetime action-count quota. */
class DeviceReceiptStore(context: Context) : SQLiteOpenHelper(context, "skivu-device-receipts.db", null, 1) {
    init { setWriteAheadLoggingEnabled(true) }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE receipts (id TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL, outcome TEXT NOT NULL, summary TEXT NOT NULL)")
    }
    override fun onUpgrade(db: SQLiteDatabase, old: Int, next: Int) { error("Unsupported receipt version") }
    fun read(id: String): JSONObject? = readableDatabase.query("receipts", arrayOf("fingerprint", "outcome", "summary"),
        "id=?", arrayOf(id), null, null, null).use { row ->
        if (!row.moveToFirst()) null else JSONObject(mapOf("fingerprint" to row.getString(0),
            "outcome" to row.getString(1), "summary" to row.getString(2)))
    }
    fun write(id: String, value: JSONObject) {
        val values = ContentValues().apply {
            put("id", id); put("fingerprint", value.getString("fingerprint"))
            put("outcome", value.getString("outcome")); put("summary", value.getString("summary"))
        }
        check(writableDatabase.insertWithOnConflict("receipts", null, values, SQLiteDatabase.CONFLICT_REPLACE) >= 0)
    }
    fun remove(id: String) { writableDatabase.delete("receipts", "id=?", arrayOf(id)) }
}
