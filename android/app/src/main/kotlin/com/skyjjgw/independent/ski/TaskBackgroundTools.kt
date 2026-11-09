package com.skyjjgw.independent.ski

import android.content.Context
import org.json.JSONObject

/** Same executor, permissions and durable receipt fences as foreground. */
class TaskBackgroundTools(private val context:Context){
    companion object {
        private val devices=java.util.concurrent.ConcurrentHashMap<String,EmbeddedDevicePlatform>()
        private val active=java.util.concurrent.ConcurrentHashMap<String,JSONObject>()
        fun stopRun(context:Context,run:String):Boolean{active[run]?.let{call->devices[run]?.cancelInvocation(call.getString("owner"),call.getString("requestId"))};while(active.containsKey(run))Thread.sleep(50);return true}
        private val owners=java.util.concurrent.ConcurrentHashMap<String,MutableSet<String>>()
        fun close(run:String){owners.remove(run)?.forEach{PhoneControlArbiter.release(it)};devices.remove(run)?.close()}
    }
    private fun device(lease:JSONObject)=devices.getOrPut(lease.getString("id")){EmbeddedDevicePlatform(context.applicationContext)}
    fun status(lease:JSONObject)=device(lease).status()+mapOf("background" to true)
    fun cancel(args:JSONObject,lease:JSONObject)=device(lease).cancelInvocation(args.getString("owner"),args.getString("requestId"))
    fun invoke(args:JSONObject,lease:JSONObject):Map<String,Any?>{
        val schedules=TaskScheduleStore(context);schedules.check(lease)
        val tool=args.getString("tool")
        val ui=tool.startsWith("ui.")||tool in setOf("apps.launch","clock.alarm.create","clock.timer.start","clock.alarms.show","settings.open")
        if(ui){
            val store=TaskDatabase.get(context);val run=store.run(lease.getString("id"))?:error("本次执行记录不存在。")
            val plan=store.plan(run.getString("planId"))?:error("计划不存在。")
            val locked=context.getSystemService(android.app.KeyguardManager::class.java).isDeviceLocked
            val interactive=context.getSystemService(android.os.PowerManager::class.java).isInteractive
            if(locked||!interactive||!plan.optBoolean("allowForeground",true))return mapOf("requestId" to args.getString("requestId"),"tool" to tool,"outcome" to "permission_required","summary" to if(locked||!interactive)"屏幕不可操作；当前步骤等待解锁，其他独立步骤可继续。"else "用户的计划配置禁止前台步骤；此步骤等待条件。")
        }
        @Suppress("UNCHECKED_CAST") val payload=(plain(args) as Map<String,Any?>).filterKeys{it!="_lease"}
        owners.getOrPut(lease.getString("id")){java.util.concurrent.ConcurrentHashMap.newKeySet()}.add(args.getString("owner"))
        val run=lease.getString("id");active[run]=args
        return try{device(lease).invokeLeased(payload){schedules.check(lease)}}finally{active.remove(run,args)}
    }
}
