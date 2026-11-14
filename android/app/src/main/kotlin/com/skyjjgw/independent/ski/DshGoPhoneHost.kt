package com.skyjjgw.independent.ski

import android.app.*
import android.content.*
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import com.skyjjgw.independent.ski.dshgo.phone.*
import org.json.JSONObject
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Adapts Skivu's trusted assistant transport to dsh-go's ORIGINAL authenticated
 * MCP server. Tool parsing, ownership, confirmation, screen drivers, privilege
 * handling and cancellation stay in the upstream module. There is no second LLM.
 */
class DshGoPhoneHost(context: Context) {
    private val app=context.applicationContext
    private val control=PhoneControl.get(app)
    private val receipts=DeviceReceiptStore(app)
    private val receiptLock=Any()
    private val io=Executors.newCachedThreadPool { r -> Thread(r,"skivu-phone-host").apply { isDaemon=true } }
    private val main=Handler(Looper.getMainLooper())
    private val cancelled=java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private val runs=java.util.concurrent.ConcurrentHashMap<String,String>()
    private val statusSink:(Map<String,Any?>)->Unit={ state ->
        val tasks=(state["tasks"] as? List<*>)?.filterIsInstance<Map<*,*>>()?:emptyList()
        for(task in tasks){
            val owner=task["sessionId"] as? String?:continue
            if(task["stopped"]==true && task["runId"]==runs[owner] && cancelled.add(owner) && owner.startsWith("assistant:"))
                main.post{channel?.invokeMethod("taskStopped",mapOf("taskId" to owner.removePrefix("assistant:")))}
        }
    }
    @Volatile private var closed=false
    private var channel:MethodChannel?=null
    private var engine:io.flutter.embedding.engine.FlutterEngine?=null
    private var navigation:Map<String,Any?>?=null

    fun handleIntent(intent:Intent){
        val session=intent.getStringExtra("skivu_phone_session")
        val settings=intent.dataString=="dshgo://open/phone-unlocks"
        if(!settings && session==null)return
        io.execute {
            val next=if(settings)mapOf("kind" to "settings") else {
                if(session==null || !session.startsWith("assistant:") || lastTasks().none{it["sessionId"]==session})return@execute
                mapOf("kind" to "task","taskId" to session.removePrefix("assistant:"))
            }
            synchronized(this){navigation=next}
            main.post{channel?.invokeMethod("navigation",null)}
        }
    }

    fun register(messenger: BinaryMessenger, flutterEngine:io.flutter.embedding.engine.FlutterEngine) {
        if(channel!=null)return
        engine=flutterEngine
        control.addSink(statusSink)
        channel=MethodChannel(messenger,"skivu/device_engine").also { c ->
            c.setMethodCallHandler { call,result ->
                @Suppress("UNCHECKED_CAST")
                val p=call.arguments as? Map<String,Any?>?:emptyMap()
                io.execute {
                    try {
                        check(!closed){"手机操控连接已关闭。"}
                        val answer:Any?=when(call.method){
                            "navigation.take" -> synchronized(this){(navigation?:emptyMap<String,Any?>()).also{navigation=null}}
                            "status" -> status()
                            "catalog" -> mapOf("tools" to PhoneToolCatalog.tools.map { it.toJson() })
                            "apps" -> emptyList<Map<String,Any?>>() // The model uses the original phone.apps tool.
                            "invoke" -> invoke(p)
                            "effect.lookup" -> mapOf("found" to false) // Never infer a new task from a previous phone action.
                            "session.start" -> {
                                val task=p["taskId"] as? String?:error("缺少任务身份。")
                                require(task.matches(Regex("[a-zA-Z0-9_-]{1,100}")))
                                cancelled.remove("assistant:$task")
                                // Allocate the original phone run only on its first
                                // real phone call. Text/coding-only turns must not
                                // consume dsh-go's retained phone-run fence budget.
                                runs.remove("assistant:$task")
                                EmbeddedTaskService.retainedEngine=engine
                                EmbeddedTaskService.activeTasks.add(task)
                                EmbeddedTaskService.taskId=task
                                app.startForegroundService(Intent(app,EmbeddedTaskService::class.java).putExtra("taskId",task))
                                mapOf("active" to true)
                            }
                            "session.end" -> end(p)
                            "cancelRequest" -> {
                                val owner=p["owner"] as? String?:error("缺少任务身份。")
                                cancelOwner(owner)
                                mapOf("stopped" to true,"scopeSealed" to true)
                            }
                            "stop" -> { control.stopTask("用户停止手机操控"); mapOf("stopped" to true) }
                            "result.open" -> openResult(p)
                            else -> error("此旧版手机操控接口已停用，请在手机操控设置中使用 dsh-go 接入。")
                        }
                        main.post { result.success(answer) }
                    } catch(e:Exception) {
                        main.post { result.error("DSH_GO_PHONE",e.message?:"手机操控未完成。",null) }
                    }
                }
            }
        }
        EmbeddedTaskService.stopTask={ task ->
            val owner="assistant:$task"
            io.execute { cancelOwner(owner) }
            main.post { channel?.invokeMethod("taskStopped",mapOf("taskId" to task)) }
        }
    }

    private fun status():Map<String,Any?> {
        val done=CountDownLatch(1)
        var value:Result<Map<String,Any?>>?=null
        control.status { value=it; done.countDown() }
        check(done.await(15,TimeUnit.SECONDS)){"手机操控状态读取超时。"}
        val native=checkNotNull(value).getOrThrow()
        return native+mapOf("backend" to "dsh-go", "upstreamCommit" to UPSTREAM,
            "control" to control.isEnabled(), "system" to control.isEnabled(),
            "accessibility" to (PhoneRegistry.mainDriver != null))
    }

    /** Uses the original same-uid/token socket protocol, including its reply commit. */
    private fun rpc(method:String,params:Map<String,Any?>,id:String,live:()->Boolean={true}):Map<*,*> {
        check(!closed && live()){"此手机请求已停止。"}
        val endpoint=control.prepareNativeHost()?:error("请先在手机操控设置中开启功能。")
        val name=endpoint.abstractName?:error("本机手机操控桥未能建立。")
        LocalSocket().use { socket ->
            socket.connect(LocalSocketAddress(name,LocalSocketAddress.Namespace.ABSTRACT))
            socket.soTimeout=12*60*1000
            val output=socket.outputStream
            fun send(value:Any?){output.write((Json.write(value)+"\n").toByteArray(Charsets.UTF_8));output.flush()}
            send(mapOf("dshPhone" to 1,"token" to endpoint.token))
            check(!closed && live()){"此手机请求已停止。"}
            send(mapOf("jsonrpc" to "2.0","id" to id,"method" to method,"params" to params))
            val line=PhoneBridge.readLine(socket.inputStream,32*1024*1024)?:error("手机操控连接已结束；请核对原回执，不要重复动作。")
            val message=Json.parse(line) as? Map<*,*>?:error("手机操控回执无效。")
            check(message["id"]==id){"手机操控回执身份不匹配。"}
            check(message["error"]==null){(message["error"] as? Map<*,*>)?.get("message")?.toString()?:"手机操控拒绝了请求。"}
            return message["result"] as? Map<*,*>?:error("手机操控没有返回结果。")
        }
    }

    private fun invoke(p:Map<String,Any?>):Map<String,Any?> {
        require(p["version"]==1){"不支持此设备调用协议。"}
        val id=p["requestId"] as? String?:error("缺少请求编号。")
        val owner=p["owner"] as? String?:error("缺少调用身份。")
        val tool=p["tool"] as? String?:error("缺少工具名。")
        require(id.matches(Regex("[a-zA-Z0-9_-]{1,100}")))
        require(owner.matches(Regex("[a-zA-Z0-9_.:-]{1,180}")))
        @Suppress("UNCHECKED_CAST")
        val args=p["arguments"] as? Map<String,Any?>?:error("缺少工具参数。")
        fun receipt(outcome:String,summary:String,value:Any?=null)=mapOf("requestId" to id,"tool" to tool,"outcome" to outcome,"summary" to summary,"value" to value)
        if(tool=="device.status")return receipt("verified","已读取 dsh-go 手机操控状态。",status())
        if(tool=="device.receipt"){
            val original=args["originalRequestId"] as? String?:error("缺少原请求编号。")
            val saved=synchronized(receiptLock){receipts.read(digest("$owner:$original"))}
            return receipt("verified","已读取原请求，没有重新执行。",if(saved==null)mapOf("found" to false)else mapOf(
                "found" to true,"originalRequestId" to original,"outcome" to saved.optString("outcome"),
                "summary" to saved.optString("summary"),"value" to plain(saved.opt("value"))))
        }
        require(tool.startsWith("phone.") && PhoneToolCatalog.tools.any{it.name==tool.removePrefix("phone.")}){
            "手机操控已切换到 dsh-go；旧界面操作不会重放，请重新读取当前屏幕。"
        }
        if(!control.isEnabled())return receipt("permission_required","请先在手机操控设置中开启功能。")
        val key=digest("$owner:$id")
        val fingerprint=digest("$tool:${Json.write(canonical(args))}")
        synchronized(receiptLock){
            val saved=receipts.read(key)
            if(saved!=null){
                require(saved.optString("fingerprint")==fingerprint){"同一请求编号不能用于不同操作。"}
                return receipt(saved.optString("outcome"),saved.optString("summary"),plain(saved.opt("value")))
            }
            receipts.write(key,JSONObject(mapOf("fingerprint" to fingerprint,"outcome" to "unknown","summary" to "原请求结果待核对，不会自动重放。")))
        }
        if(owner in cancelled)return receipt("cancelled","此任务已停止，没有派发新操作。")
        val result=try {
            val raw=rpc("tools/call",mapOf("name" to tool.removePrefix("phone."),"arguments" to args,
                "_meta" to mapOf(PhoneCaller.META_KEY to mapOf("v" to 1,"sessionId" to owner,"runId" to runs.computeIfAbsent(owner){java.util.UUID.randomUUID().toString()},"callId" to id,"runLifecycle" to 1))),id){owner !in cancelled}
            val error=raw["isError"]==true
            val dispatched=tool=="phone.intent"
            // Preserve the original MCP error flag. A tool error does NOT prove
            // that no effect occurred; the original result text is retained.
            // Lost transport/unknown delivery is handled separately below.
            val unverified=error && tool !in setOf("phone.apps","phone.screen")
            val outcome=if(owner in cancelled)"cancelled"else if(unverified)"unknown"else if(error)"failed"else if(dispatched)"dispatched"else "verified"
            receipt(outcome,if(unverified)"原生操作返回错误；动作可能已发生，请先核对实际状态，不要重复执行。"else if(error)"dsh-go 未完成本次读取，请按原回执处理。"else "dsh-go 原生接口已返回；具体业务目标以原回执和实际屏幕为准。",if(unverified)raw+mapOf("hasUnverifiedActions" to true)else raw)
        } catch(e:Exception){
            receipt(if(owner in cancelled)"cancelled"else "unknown",e.message?:"结果待核对，不会自动重放。")
        }
        synchronized(receiptLock){receipts.write(key,JSONObject(result+mapOf("fingerprint" to fingerprint)))}
        return result
    }

    private fun stopOwner(owner:String) {
        val tasks=lastTasks()
        for(task in tasks){
            val id=(task["id"] as? Number)?.toLong()?:continue
            if(control.taskSession(id)==owner)control.stopTask("用户停止手机操控",id)
        }
    }
    private fun cancelOwner(owner:String){
        cancelled.add(owner)
        val run=runs[owner]
        // Use the original order-independent run-end fence, including calls
        // queued before admission. A status-only search would miss that race.
        try{
            if(run!=null && control.isEnabled())rpc("dsh-go/phone-run-end",
                mapOf("v" to 1,"sessionId" to owner,"runId" to run,"completion" to "other"),"cancel_${System.nanoTime()}")
        }finally{stopOwner(owner)}
    }
    private fun lastTasks():List<Map<*,*>> {
        val state=status()
        return (state["tasks"] as? List<*>)?.filterIsInstance<Map<*,*>>()?:emptyList()
    }
    private fun end(p:Map<String,Any?>):Map<String,Any?> {
        val task=p["taskId"] as? String?:error("缺少任务身份。")
        val owner="assistant:$task"
        val run=runs[owner]
        var endConfirmed=run==null
        if(control.isEnabled() && run!=null){
            rpc("dsh-go/phone-run-end",mapOf("v" to 1,"sessionId" to owner,"runId" to run,
                "completion" to (p["completion"] as? String?:"unknown")),"end_$task")
            endConfirmed=true
        }
        EmbeddedTaskService.activeTasks.remove(task)
        if(EmbeddedTaskService.taskId==task){
            EmbeddedTaskService.taskId=EmbeddedTaskService.activeTasks.firstOrNull()
            if(EmbeddedTaskService.taskId==null)app.stopService(Intent(app,EmbeddedTaskService::class.java))
        }
        return mapOf("active" to false,"nativeEndConfirmed" to endConfirmed)
    }
    private fun openResult(p:Map<String,Any?>):Map<String,Any?> {
        val target=p["target"] as? String?:error("缺少结果入口。")
        val intent=when(target){
            "clock.alarms" -> Intent(android.provider.AlarmClock.ACTION_SHOW_ALARMS)
            "clock.timers" -> Intent(android.provider.AlarmClock.ACTION_SHOW_TIMERS)
            else -> {require(target.startsWith("app:"));app.packageManager.getLaunchIntentForPackage(target.removePrefix("app:"))?:error("软件没有入口。")}
        }
        app.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return mapOf("opened" to true)
    }
    @Synchronized fun close(){
        if(closed)return
        closed=true;channel?.setMethodCallHandler(null);control.removeSink(statusSink)
        control.onEngineStopped();com.skyjjgw.independent.ski.dshgo.runtime.RuntimeController.get(app).retire();io.shutdown()
        Thread({while(!io.awaitTermination(1,TimeUnit.MINUTES)){};receipts.close()},"skivu-phone-host-close").apply{isDaemon=true;start()}
    }
    companion object {
        const val UPSTREAM="9cf96c531cfb9c654ac6df830d3c0b48acadbc58"
        private fun digest(value:String)=MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString(""){"%02x".format(it)}
        private fun canonical(value:Any?):Any?=when(value){
            is Map<*,*> -> value.entries.sortedBy{it.key.toString()}.associate{it.key.toString() to canonical(it.value)}
            is List<*> -> value.map(::canonical)
            else -> value
        }
        private fun plain(value:Any?):Any?=when(value){
            is JSONObject -> value.keys().asSequence().associateWith{plain(value.get(it))}
            is org.json.JSONArray -> (0 until value.length()).map{plain(value.get(it))}
            JSONObject.NULL -> null
            else -> value
        }
        /** Hook from the original phone status selection; existing FGS owns process lifetime. */
        fun refreshNotification(context:Context){
            val phone=PhoneControl.peek()?:return
            val live=phone.liveTask()?:return
            val session=phone.taskSession(live.id)?:return
            if(!session.startsWith("assistant:"))return
            EmbeddedTaskService.refresh(context,mapOf("taskId" to session.removePrefix("assistant:"),
                "phase" to if(live.paused)"paused"else "executing","action" to phone.foregroundLine(live)))
        }
    }
}
