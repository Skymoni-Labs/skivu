package com.skyjjgw.independent.ski

import android.content.Context
import android.content.ContentValues
import android.provider.Settings
import org.json.JSONObject

/** Headless calls use the same current authorized accessibility backend. Never
 * launches a host Activity/permission dialog; locked/missing conditions wait. */
class TaskBackgroundTools(private val context: Context) {
    private fun <T> ui(action:()->T):T{val task=java.util.concurrent.FutureTask(action);android.os.Handler(android.os.Looper.getMainLooper()).post(task);return task.get(12,java.util.concurrent.TimeUnit.SECONDS)}
    fun invoke(p: JSONObject,lease: JSONObject): Map<String,Any?> {
        val store=TaskDatabase.get(context)
        val schedules=TaskScheduleStore(context)
        schedules.check(lease)
        val tool=p.getString("tool");val id=p.getString("requestId");val args=p.getJSONObject("arguments")
        fun receipt(state: String,summary: String,value: Any?=null)=mapOf("requestId" to id,"tool" to tool,"outcome" to state,"summary" to summary,"value" to value)
        val prefs=context.getSharedPreferences("skivu.device-engine.v1",0)
        if(tool=="device.status") return receipt("verified","后台能力状态已读取。",mapOf("enabled" to prefs.getBoolean("enabled",false),"system" to prefs.getBoolean("system",false),"background" to true,"foregroundAllowed" to false))
        if(!prefs.getBoolean("enabled",false)) return receipt("permission_required","请先启用手机能力。")
        if(tool.startsWith("ui.")){
            val service=SkivuAccessibilityService.connected
            if(service==null||context.getSystemService(android.app.KeyguardManager::class.java).isDeviceLocked||!context.getSystemService(android.os.PowerManager::class.java).isInteractive)return receipt("permission_required","当前屏幕不可操作或无障碍未连接；等待条件，没有启动小云或重放动作。")
            val allowed=prefs.getStringSet("packages",emptySet()).orEmpty().toSet()
            val owner=p.getString("owner")
            @Suppress("UNCHECKED_CAST") val parameters=plain(args) as Map<String,Any?>
            if(tool=="ui.observe")return receipt("verified","已观察当前授权页面。",ui{service.observe(allowed)})
            if(tool=="ui.wait"){
                val until=android.os.SystemClock.uptimeMillis()+args.optLong("milliseconds",500).also{require(it in 100..10000)}
                while(android.os.SystemClock.uptimeMillis()<until){schedules.check(lease);Thread.sleep(100)}
                return receipt("verified","已等待并重新观察。",ui{service.observe(allowed)})
            }
            if(tool=="ui.screenshot")return receipt("verified","已取得实际截图；视觉能力由当前模型决定。",service.screenshot(allowed))
            if(tool=="ui.verify"){val proof=ui{service.verify(parameters,allowed,owner)};return receipt(if(proof["matched"]==true)"verified" else "unknown","已核对当前页面，未重放原动作。",proof)}
            if(!prefs.getBoolean("control",false))return receipt("permission_required","界面操控尚未授权。")
            val fingerprint=TaskDatabase.digest("$tool:${TaskScheduleStore.canonical(args)}");val effectId=TaskDatabase.digest("${lease.getString("id")}:$fingerprint")
            val prior=store.transaction{db->store.validateLease(db,lease);val old=store.queryJson(db,"SELECT data FROM effects WHERE id=?",arrayOf(effectId)).firstOrNull();if(old==null)db.insertOrThrow("effects",null,ContentValues().apply{put("id",effectId);put("run_id",lease.getString("id"));put("fingerprint",fingerprint);put("state","unknown");put("data",JSONObject().put("outcome","unknown").put("summary","原动作已有派发围栏，不自动重复。").toString())});old}
            if(prior!=null)return receipt(prior.getString("outcome"),prior.getString("summary"))
            val accepted=ui{service.act(tool,parameters,allowed,{schedules.check(lease)},id,owner)}
            val state=if(accepted)"dispatched" else "failed";val summary=if(accepted)"系统已接受动作，请重新观察核对。" else "控件未接受动作。"
            store.writableDatabase.update("effects",ContentValues().apply{put("state",state);put("data",JSONObject().put("outcome",state).put("summary",summary).toString())},"id=?",arrayOf(effectId))
            return receipt(state,summary)
        }
        if(tool !in setOf("settings.brightness.read","settings.brightness.write")) return receipt("permission_required","此操作缺少可用的后台接口，已等待条件，没有打开其他软件。")
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
