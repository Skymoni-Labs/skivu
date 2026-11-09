package com.skyjjgw.independent.ski

import android.content.Context
import android.content.ContentValues
import android.provider.Settings
import org.json.JSONObject

/** The headless executor cannot open apps or synthesize UI; permissions are checked again. */
class TaskBackgroundTools(private val context: Context) {
    fun invoke(p: JSONObject,lease: JSONObject): Map<String,Any?> {
        val store=TaskDatabase.get(context)
        val schedules=TaskScheduleStore(context)
        schedules.check(lease)
        val tool=p.getString("tool");val id=p.getString("requestId");val args=p.getJSONObject("arguments")
        fun receipt(state: String,summary: String,value: Any?=null)=mapOf("requestId" to id,"tool" to tool,"outcome" to state,"summary" to summary,"value" to value)
        val prefs=context.getSharedPreferences("skivu.device-engine.v1",0)
        if(tool=="device.status") return receipt("verified","后台能力状态已读取。",mapOf("enabled" to prefs.getBoolean("enabled",false),"system" to prefs.getBoolean("system",false),"background" to true,"foregroundAllowed" to false))
        if(tool !in setOf("settings.brightness.read","settings.brightness.write")) return receipt("permission_required","此操作需要当前可操作的手机界面，已暂停等待条件；没有打开其他软件。")
        if(!prefs.getBoolean("enabled",false)) return receipt("permission_required","请先启用手机能力。")
        if(tool=="settings.brightness.read") return receipt("verified","已读取实际屏幕亮度。",mapOf("level" to Settings.System.getInt(context.contentResolver,Settings.System.SCREEN_BRIGHTNESS,-1),"mode" to Settings.System.getInt(context.contentResolver,Settings.System.SCREEN_BRIGHTNESS_MODE,-1)))
        if(!prefs.getBoolean("system",false) || !Settings.System.canWrite(context)) return receipt("permission_required","修改系统亮度尚未授权。")
        require(args.length()==1 && args.has("level") && args.getInt("level") in 0..255)
        val fingerprint=TaskDatabase.digest("$tool:${TaskScheduleStore.canonical(args)}")
        val effectId=TaskDatabase.digest("${lease.getString("id")}:$fingerprint")
        val prior=store.transaction { db ->
            store.validateLease(db,lease)
            val old=store.queryJson(db,"SELECT data FROM effects WHERE id=?",arrayOf(effectId)).firstOrNull()
            if(old==null) db.insertOrThrow("effects",null,ContentValues().apply {put("id",effectId);put("run_id",lease.getString("id"));put("fingerprint",fingerprint);put("state","unknown");put("data",JSONObject().put("outcome","unknown").put("summary","已有同轮操作提交记录，不会自动重发。").toString())})
            old
        }
        if(prior!=null) return receipt(prior.getString("outcome"),prior.getString("summary"))
        schedules.check(lease)
        val wanted=args.getInt("level")
        val saved=Settings.System.putInt(context.contentResolver,Settings.System.SCREEN_BRIGHTNESS,wanted)
        val actual=Settings.System.getInt(context.contentResolver,Settings.System.SCREEN_BRIGHTNESS,-1)
        val state=if(saved && actual==wanted) "verified" else "unknown"
        val summary="已读取实际亮度核对结果。"
        store.writableDatabase.update("effects",ContentValues().apply {put("state",state);put("data",JSONObject().put("outcome",state).put("summary",summary).toString())},"id=?",arrayOf(effectId))
        return receipt(state,summary,mapOf("level" to actual))
    }
}
