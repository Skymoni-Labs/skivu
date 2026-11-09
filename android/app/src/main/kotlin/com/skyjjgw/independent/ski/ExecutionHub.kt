package com.skyjjgw.independent.ski

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/** Receipted state, not model prose. Every control addresses one host task ID. */
object ExecutionHub {
    private val lock=Any();private val main=Handler(Looper.getMainLooper())
    private val states=linkedMapOf<String,Map<String,Any?>>()
    private val controllers=ConcurrentHashMap<String,(String)->Unit>()
    private var loaded=false
    var changed:(()->Unit)?=null
    fun bind(task:String,controller:(String)->Unit){controllers[task]=controller}
    private fun load(context:Context){if(loaded)return;loaded=true;val file=File(context.filesDir,"cloud-execution-state.json");if(!file.exists())return
        runCatching{val records=JSONArray(file.readText());for(i in 0 until records.length()){
            @Suppress("UNCHECKED_CAST") val record=(plain(records.getJSONObject(i)) as Map<String,Any?>).toMutableMap()
            if(record["phase"] !in setOf("completed","stopped","failed","result_ready")){record["phase"]="unknown";record["action"]="应用中断，先核对原项目或手机状态；不会自动重放。";record["canStop"]=false;record["canPause"]=false;record["canResume"]=false}
            states[record["taskId"] as String]=record
        }}
    }
    fun list(context:Context):List<Map<String,Any?>> = synchronized(lock){load(context);states.values.toList()}
    fun mode(context:Context)=context.getSharedPreferences("cloud-overlay",0).getString("mode","compact")?:"compact"
    fun setMode(context:Context,mode:String):Map<String,Any?>{require(mode in setOf("compact","dot","hidden"));check(context.getSharedPreferences("cloud-overlay",0).edit().putString("mode",mode).commit());main.post{SkivuAccessibilityService.connected?.refreshOverlay()};return mapOf("mode" to mode)}
    fun update(context:Context,args:Map<String,Any?>):Map<String,Any?> = synchronized(lock){
        load(context);val id=args["taskId"] as String;require(Regex("[a-zA-Z0-9_-]{1,160}").matches(id))
        val previous=states[id];val sequence=(args["sequence"] as? Number)?.toLong()?:0L
        if(previous!=null&&previous["source"]==args["source"]&&((previous["sequence"] as? Number)?.toLong()?:-1)>=sequence)return@synchronized previous
        val phase=args["phase"] as String;require(phase in setOf("observing","deciding","acting","waiting","waiting_user","paused","stopping","stopped","completed","failed","unknown","result_ready"))
        fun text(key:String,max:Int)=args[key]?.toString()?.take(max)?:""
        val target=text("target",200)
        val label=if(target.startsWith("project_"))"当前编程项目" else runCatching{context.packageManager.getApplicationLabel(context.packageManager.getApplicationInfo(target,0)).toString()}.getOrDefault(target)
        val state=mutableMapOf("taskId" to id,"conversationId" to text("conversationId",160),"target" to label,"targetId" to target,"goal" to text("goal",300),"phase" to phase,"action" to text("action",300),"phone" to (args["phone"]==true),"canStop" to (args["canStop"]==true),"canPause" to (args["canPause"]==true),"canResume" to (args["canResume"]==true),"verified" to (args["verified"]==true),"source" to text("source",100),"sequence" to sequence,"updatedAt" to System.currentTimeMillis(),"evidence" to text("evidence",500))
        state["runId"]=text("runId",160)
        require(phase!="completed"||state["verified"]==true){"缺少核对证据，不能发布已完成。"}
        states[id]=state
        while(states.size>128){val old=states.entries.firstOrNull{it.value["canStop"]!=true}?:break;states.remove(old.key);controllers.remove(old.key)}
        val file=File(context.filesDir,"cloud-execution-state.json");val tmp=File(context.filesDir,"cloud-execution-state.tmp");tmp.writeText(JSONArray(states.values).toString());check(tmp.renameTo(file))
        main.post{SkivuAccessibilityService.connected?.refreshOverlay();EmbeddedTaskService.refresh(context,state);notify(context,state);changed?.invoke();if(phase in setOf("completed","stopped","failed","result_ready"))main.postDelayed({SkivuAccessibilityService.connected?.refreshOverlay()},5200)};state
    }
    private fun notify(context:Context,state:Map<String,Any?>){
        val id=state["taskId"] as String
        if(EmbeddedTaskService.taskId==id||state["phone"]!=true&&state["target"].toString().isBlank())return
        val manager=context.getSystemService(android.app.NotificationManager::class.java);if(!manager.areNotificationsEnabled())return
        manager.createNotificationChannel(android.app.NotificationChannel("cloud-executions","小云执行状态",android.app.NotificationManager.IMPORTANCE_LOW))
        val active=state["canStop"]==true
        if(!active){manager.cancel("cloud:$id",77);return}
        fun action(name:String)=android.app.PendingIntent.getBroadcast(context,("$id:$name").hashCode(),android.content.Intent(context,CloudTaskControlReceiver::class.java).setAction(name).putExtra("taskId",id),android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT)
        val open=android.app.PendingIntent.getActivity(context,id.hashCode(),android.content.Intent(context,MainActivity::class.java).putExtra("skivuTaskId",state["conversationId"]?.toString()),android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT)
        val builder=android.app.Notification.Builder(context,"cloud-executions").setSmallIcon(android.R.drawable.ic_menu_view).setContentTitle("小云 · "+label(state["phase"].toString())).setContentText(state["action"]?.toString()?.take(160)).setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(android.app.Notification.Action.Builder(null,"停止本次执行",action("stop")).build())
        if(state["phone"]==true)builder.addAction(android.app.Notification.Action.Builder(null,"恢复浮岛",action("restore")).build())
        manager.notify("cloud:$id",77,builder.build())
    }
    fun currentPhone(context:Context):Map<String,Any?>? {
        val all=list(context)
        val candidate=all.filter{it["phone"]==true&&(it["phase"] !in setOf("completed","stopped","failed","result_ready")||System.currentTimeMillis()-((it["updatedAt"] as? Number)?.toLong()?:0)<5000)}.maxByOrNull{(it["updatedAt"] as? Number)?.toLong()?:0}?:return null
        val latest=all.maxByOrNull{(it["updatedAt"] as? Number)?.toLong()?:0}
        // A new ordinary conversation doesn't keep an inactive old UI task on screen.
        // Its uncertain receipt remains in the original task and is never replayed.
        if(candidate["canStop"]!=true&&latest?.get("phone")==false&&((latest["updatedAt"] as? Number)?.toLong()?:0)>((candidate["updatedAt"] as? Number)?.toLong()?:0))return null
        return candidate
    }
    fun expireRun(context:Context,run:String){
        for(state in list(context).filter{it["runId"]==run}){
            controllers.remove(state["taskId"])
            if(state["phase"] in setOf("completed","failed","stopped","result_ready","unknown"))continue
            update(context,state+mapOf("source" to "worker-finished","sequence" to System.currentTimeMillis(),"phase" to "unknown","canStop" to false,"canPause" to false,"canResume" to false,"verified" to false,"target" to state["targetId"],"action" to "后台执行已结束，原结果需要核对；不会自动重放。"))
        }
    }
    fun control(task:String,action:String):Map<String,Any?>{
        val record=synchronized(lock){states[task]}?:error("执行记录不存在。")
        require(action in setOf("stop","pause","resume"))
        require(record[when(action){"stop"->"canStop";"pause"->"canPause";else->"canResume"}]==true){"当前任务不支持此控制。"}
        val callback=controllers[task]?:error("任务执行器尚未重新连接。请先核对项目或回到原对话。")
        main.post{callback(action)};return mapOf("requested" to true,"taskId" to task,"action" to action)
    }
    fun label(phase:String)=when(phase){"observing"->"正在观察";"deciding"->"正在判断";"acting"->"正在操作";"waiting"->"等待页面响应";"waiting_user"->"等待你处理";"paused"->"已暂停";"stopping"->"正在停止";"stopped"->"已停止";"completed"->"已完成";"failed"->"执行遇到问题";"result_ready"->"本轮回复已结束";else->"结果待核对"}
}
