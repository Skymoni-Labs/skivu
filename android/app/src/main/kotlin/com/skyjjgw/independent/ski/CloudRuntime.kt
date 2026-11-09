package com.skyjjgw.independent.ski

import android.content.Context
import android.os.ParcelFileDescriptor
import org.json.JSONArray
import org.json.JSONObject
import java.io.*
import java.util.UUID
import java.util.concurrent.*

internal fun plain(value: Any?): Any? = when(value) {
    null, JSONObject.NULL -> null
    is JSONObject -> value.keys().asSequence().associateWith { plain(value.opt(it)) }
    is JSONArray -> (0 until value.length()).map { plain(value.opt(it)) }
    else -> value
}

class CloudNative {
    companion object { init { System.loadLibrary("cloudruntime") } }
    external fun start(input:Int,output:Int,error:Int,proot:String,loader:String,root:String,tmp:String,home:String,work:String,scripts:String):Int
    external fun poll(pid:Int):Int
}

/** Application-owned Linux environment. No package lookup or plugin bootstrap. */
object CloudRuntime {
    private val startLock=Any()
    private val sendLock=Any()
    private val pending=ConcurrentHashMap<String,CompletableFuture<JSONObject>>()
    private val cancelledTasks=ConcurrentHashMap.newKeySet<String>()
    private val runs=ConcurrentHashMap<String,MutableSet<Pair<String,String>>>()
    private val runBindingsLock=Any()
    fun bindRun(context:Context,run:String,owner:String,task:String){synchronized(runBindingsLock){val file=File(context.filesDir,"cloud-run-bindings/$run.json");file.parentFile!!.mkdirs();val scopes=runs.getOrPut(run){ConcurrentHashMap.newKeySet()};if(file.isFile){val old=JSONArray(file.readText());for(i in 0 until old.length()){val row=old.getJSONArray(i);scopes.add(row.getString(0) to row.getString(1))}};scopes.add(owner to task);val temp=File(file.path+".tmp");temp.writeText(JSONArray(scopes.map{listOf(it.first,it.second)}).toString());check(temp.renameTo(file))}}
    fun cancelRun(context:Context,run:String):Boolean{
        val scopes=mutableSetOf<Pair<String,String>>();synchronized(runBindingsLock){scopes.addAll(runs[run].orEmpty());val file=File(context.filesDir,"cloud-run-bindings/$run.json");if(file.isFile){val rows=JSONArray(file.readText());for(i in 0 until rows.length()){val row=rows.getJSONArray(i);scopes.add(row.getString(0) to row.getString(1))}}}
        val record=TaskDatabase.get(context).run(run);val checkpoint=TaskBlobStore(context).checkpoint(run)?.let{JSONObject(it)}
        if(record!=null&&checkpoint?.optString("taskId")?.isNotBlank()==true)scopes.add("cloud:${record.getString("planId")}" to checkpoint.getString("taskId"))
        return scopes.map{(owner,task)->CloudOperations.cancel(context,owner,task);val android=CloudAndroidRuntime.taskControl(context,owner,task,"cancel");val result=invoke(context,"coding.cancel",emptyMap(),owner,task,"cancel_run_"+UUID.randomUUID().toString().replace("-",""));CloudOperations.awaitStopped(owner,task);CloudOperations.stopPersisted(context,owner,task)&&android["stopped"]==true&&result["outcome"]=="verified"&&(result["value"] as? Map<*,*>)?.get("stopped")==true}.all{it}
    }
    private var writer:BufferedWriter?=null
    private var native:CloudNative?=null
    @Volatile private var pid=-1
    @Volatile var phase="not_prepared"; private set
    @Volatile var installedFiles=0;private set
    private var generation=0
    fun status()=mapOf("phase" to phase,"installedFiles" to installedFiles,"running" to (writer!=null),"embedded" to true,"network" to CloudNetworkConfiguration.status())

    private fun start(context:Context,taskKey:String) = synchronized(startLock) {
        CloudNetworkConfiguration.refresh(context.applicationContext)
        if(writer!=null && native?.poll(pid)==0)return@synchronized
        writer=null
        val app=context.applicationContext
        phase="verifying"
        val lockFile=File(app.filesDir,"cloud-install.lock")
        val root=RandomAccessFile(lockFile,"rw").use { file -> file.channel.lock().use {
            CloudRuntimeInstaller(app).install { count -> check(taskKey !in cancelledTasks){"环境准备已停止，已校验资源保留。"};phase="extracting";installedFiles=count }
        } }
        val scripts=File(app.filesDir,"cloud-executor").apply { mkdirs() }
        for(name in app.assets.list("cloud").orEmpty().filter{it.endsWith(".mjs")})app.assets.open("cloud/$name").use { input -> File(scripts,name).outputStream().use { input.copyTo(it) } }
        val home=File(app.filesDir,"cloud-home").apply{mkdirs()}
        val projects=File(app.filesDir,"cloud-projects").apply{mkdirs()}
        val tmp=File(app.filesDir,"cloud-tmp").apply{mkdirs()}
        // DNS is ordinary app networking, not a shell/root permission. The same
        // Ubuntu tools remain available; missing tools are probed at execution.
        CloudNetworkConfiguration.attach(app,root)
        val input=ParcelFileDescriptor.createPipe();val output=ParcelFileDescriptor.createPipe();val errors=ParcelFileDescriptor.createPipe()
        val runner=native?:CloudNative().also{native=it}
        phase="starting";val current=++generation
        pid=runner.start(input[0].fd,output[1].fd,errors[1].fd,File(app.applicationInfo.nativeLibraryDir,"libproot.so").path,
            File(app.applicationInfo.nativeLibraryDir,"libprootloader.so").path,root.path,tmp.path,home.path,projects.path,scripts.path)
        input[0].close();output[1].close();errors[1].close()
        require(pid>0){"内置编程进程未能启动。"}
        val ready=CompletableFuture<Unit>()
        Thread({
            try { ParcelFileDescriptor.AutoCloseInputStream(output[0]).bufferedReader().useLines { lines -> lines.forEach { line ->
                var frame=JSONObject(line)
                if(frame.has("replyRef")){
                    val root=File(app.filesDir,"cloud-home").canonicalFile
                    val file=File(root,frame.getString("replyRef")).canonicalFile
                    require(file.path.startsWith(File(root,"cloud-rpc").path+"/"))
                    frame=JSONObject(file.readText());file.delete()
                }
                if(frame.optBoolean("ready")){phase="ready";ready.complete(Unit)}
                else pending.remove(frame.optString("id"))?.complete(frame)
            } } } catch(_:Exception) {} finally {
                if(current==generation){writer=null;phase="interrupted";pending.values.forEach{it.completeExceptionally(IOException("运行环境中断，先核对项目和进程。"))};pending.clear()}
                ready.completeExceptionally(IOException("运行环境未能就绪。"))
            }
        },"cloud-linux-output").apply{isDaemon=true;start()}
        Thread({ // Full diagnostics remain on disk; presentation can page it.
            val log=File(app.filesDir,"cloud-runtime-last-error.txt")
            ParcelFileDescriptor.AutoCloseInputStream(errors[0]).use { stream -> log.outputStream().use { dest ->
                val b=ByteArray(8192);while(true){val n=stream.read(b);if(n<0)break;dest.write(b,0,n)}
            } }
        },"cloud-linux-error").apply{isDaemon=true;start()}
        val next=ParcelFileDescriptor.AutoCloseOutputStream(input[1]).bufferedWriter()
        try{while(true){check(taskKey !in cancelledTasks){"环境初始化已停止。"};try{ready.get(250,TimeUnit.MILLISECONDS);break}catch(_:TimeoutException){if(runner.poll(pid)!=0)error("初始化进程已退出。")}};writer=next}catch(e:Exception){next.close();phase="unavailable";throw IllegalStateException("内置 Linux 初始化未完成，请查看环境状态后重试。",e)}
    }

    fun hasOwnedJobs(context:Context,owner:String,task:String?=null):Boolean=File(context.filesDir,"cloud-home/cloud/jobs").listFiles().orEmpty().filter{it.name.endsWith(".json")&&!it.name.endsWith(".status.json")&&!it.name.endsWith(".spec.json")}.any{runCatching{val r=JSONObject(it.readText());r.optString("owner")==owner&&(task==null||r.optString("taskId")==task)}.getOrDefault(false)}
    fun invoke(context:Context,tool:String,args:Map<String,Any?>,owner:String,taskId:String,requestId:String):Map<String,Any?> {
        if(android.os.Build.VERSION.SDK_INT<26)return mapOf("outcome" to "failed","message" to "内置 Linux 与原 DSH 环境一样需要 Android 8 或更新系统；聊天和其他已支持功能仍可使用。")
        require(Regex("[a-zA-Z0-9_.:-]{1,180}").matches(owner)&&Regex("[a-zA-Z0-9_-]{1,160}").matches(taskId)&&Regex("[a-zA-Z0-9_-]{1,120}").matches(requestId))
        val taskKey="$owner:$taskId"
        if(tool=="coding.cancel"){CloudOperations.cancel(context,owner,taskId);cancelledTasks.add(taskKey)}
        else if(taskKey in cancelledTasks||CloudOperations.wasStopped(context,owner,taskId))return mapOf("outcome" to "cancelled","message" to "本次执行已停止，没有派发后续编程操作。")
        if(tool=="coding.cancel"&&writer==null&&!hasOwnedJobs(context,owner,taskId))return mapOf("outcome" to "verified","value" to mapOf("stopped" to true,"jobs" to emptyList<Any>()))
        start(context,taskKey)
        if(tool!="coding.cancel"&&taskKey in cancelledTasks)return mapOf("outcome" to "cancelled","message" to "初始化期间已停止，没有派发后续编程操作。")
        val id=UUID.randomUUID().toString();val response=CompletableFuture<JSONObject>();pending[id]=response
        val frame=JSONObject(mapOf("id" to id,"tool" to tool,"args" to args,"owner" to owner,"taskId" to taskId,"requestId" to requestId))
        try {
            // Only a small reference crosses the pipe. Large content is a private
            // spool object, not a communication-frame size or synchronous deadline.
            val rpc=File(context.filesDir,"cloud-home/cloud-rpc").apply{mkdirs()}
            val requestFile=File(rpc,"request-$id.json");requestFile.writeText(frame.toString())
            synchronized(sendLock){if(tool!="coding.cancel"&&taskKey in cancelledTasks)return mapOf("outcome" to "cancelled","message" to "请求已撤销，未派发。");val out=writer?:error("运行环境已中断。");out.write(JSONObject(mapOf("id" to id,"frameRef" to "cloud-rpc/${requestFile.name}")).toString());out.newLine();out.flush()}
            val result=response.get();requestFile.delete()
            @Suppress("UNCHECKED_CAST")
            return plain(result) as Map<String,Any?>
        } catch(_:Exception) {
            return mapOf("outcome" to "unknown","message" to "执行回执中断。文件或进程可能已经改变，请先读取项目和进程，不要重复执行。")
        } finally {pending.remove(id)}
    }
}
