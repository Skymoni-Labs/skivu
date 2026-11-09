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
    fun bindRun(run:String,owner:String,task:String){runs.getOrPut(run){ConcurrentHashMap.newKeySet()}.add(owner to task)}
    fun cancelRun(context:Context,run:String):Boolean{
        val scopes=runs.remove(run)?:return true
        return scopes.map{(owner,task)->val result=invoke(context,"coding.cancel",emptyMap(),owner,task,"cancel_run_"+UUID.randomUUID().toString().replace("-",""));result["outcome"]=="verified"&&(result["value"] as? Map<*,*>)?.get("stopped")==true}.all{it}
    }
    private var writer:BufferedWriter?=null
    private var native:CloudNative?=null
    @Volatile private var pid=-1
    @Volatile var phase="not_prepared"; private set
    @Volatile var installedFiles=0;private set
    private var generation=0
    fun status()=mapOf("phase" to phase,"installedFiles" to installedFiles,"running" to (writer!=null),"embedded" to true)

    private fun start(context:Context) = synchronized(startLock) {
        if(writer!=null && native?.poll(pid)==0)return@synchronized
        writer=null
        val app=context.applicationContext
        phase="verifying"
        val lockFile=File(app.filesDir,"cloud-install.lock")
        val root=RandomAccessFile(lockFile,"rw").use { file -> file.channel.lock().use {
            CloudRuntimeInstaller(app).install { count -> phase="extracting";installedFiles=count }
        } }
        val scripts=File(app.filesDir,"cloud-executor").apply { mkdirs() }
        for(name in listOf("executor.mjs","formats.mjs"))app.assets.open("cloud/$name").use { input -> File(scripts,name).outputStream().use { input.copyTo(it) } }
        val home=File(app.filesDir,"cloud-home").apply{mkdirs()}
        val projects=File(app.filesDir,"cloud-projects").apply{mkdirs()}
        val tmp=File(app.filesDir,"cloud-tmp").apply{mkdirs()}
        // DNS is ordinary app networking, not a shell/root permission. The same
        // Ubuntu tools remain available; missing tools are probed at execution.
        val resolv=File(root,"etc/resolv.conf")
        if(!resolv.exists())resolv.writeText("nameserver 1.1.1.1\nnameserver 8.8.8.8\n")
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
                if(line.length>4*1024*1024)throw IOException("运行回执过大。")
                val frame=JSONObject(line)
                if(frame.optBoolean("ready")){phase="ready";ready.complete(Unit)}
                else pending.remove(frame.optString("id"))?.complete(frame)
            } } } catch(_:Exception) {} finally {
                if(current==generation){writer=null;phase="interrupted";pending.values.forEach{it.completeExceptionally(IOException("运行环境中断，先核对项目和进程。"))};pending.clear()}
                ready.completeExceptionally(IOException("运行环境未能就绪。"))
            }
        },"cloud-linux-output").apply{isDaemon=true;start()}
        Thread({ // Keep bounded startup diagnostics in app-private storage only.
            val log=File(app.filesDir,"cloud-runtime-last-error.txt")
            ParcelFileDescriptor.AutoCloseInputStream(errors[0]).use { stream -> log.outputStream().use { dest ->
                val b=ByteArray(8192);var total=0;while(true){val n=stream.read(b);if(n<0)break;if(total<65536)dest.write(b,0,minOf(n,65536-total));total+=n}
            } }
        },"cloud-linux-error").apply{isDaemon=true;start()}
        val next=ParcelFileDescriptor.AutoCloseOutputStream(input[1]).bufferedWriter()
        try{ready.get(90,TimeUnit.SECONDS);writer=next}catch(e:Exception){next.close();phase="unavailable";throw IllegalStateException("内置 Linux 初始化未完成，请查看环境状态后重试。",e)}
    }

    fun invoke(context:Context,tool:String,args:Map<String,Any?>,owner:String,taskId:String,requestId:String):Map<String,Any?> {
        if(android.os.Build.VERSION.SDK_INT<26)return mapOf("outcome" to "failed","message" to "内置 Linux 与原 DSH 环境一样需要 Android 8 或更新系统；聊天和其他已支持功能仍可使用。")
        require(Regex("[a-zA-Z0-9_.:-]{1,180}").matches(owner)&&Regex("[a-zA-Z0-9_-]{1,160}").matches(taskId)&&Regex("[a-zA-Z0-9_-]{1,120}").matches(requestId))
        val taskKey="$owner:$taskId"
        if(tool=="coding.cancel")cancelledTasks.add(taskKey)
        else if(taskKey in cancelledTasks)return mapOf("outcome" to "cancelled","message" to "本次执行已停止，没有派发后续编程操作。")
        if(tool=="coding.cancel"&&writer==null)return mapOf("outcome" to "verified","value" to mapOf("stopped" to true,"jobs" to emptyList<Any>()))
        start(context)
        if(tool!="coding.cancel"&&taskKey in cancelledTasks)return mapOf("outcome" to "cancelled","message" to "初始化期间已停止，没有派发后续编程操作。")
        val id=UUID.randomUUID().toString();val response=CompletableFuture<JSONObject>();pending[id]=response
        val frame=JSONObject(mapOf("id" to id,"tool" to tool,"args" to args,"owner" to owner,"taskId" to taskId,"requestId" to requestId))
        try {
            synchronized(sendLock){if(tool!="coding.cancel"&&taskKey in cancelledTasks)return mapOf("outcome" to "cancelled","message" to "请求已撤销，未派发。");val out=writer?:error("运行环境已中断。");out.write(frame.toString());out.newLine();out.flush()}
            val result=response.get(40,TimeUnit.SECONDS)
            @Suppress("UNCHECKED_CAST")
            return plain(result) as Map<String,Any?>
        } catch(_:Exception) {
            return mapOf("outcome" to "unknown","message" to "执行回执中断。文件或进程可能已经改变，请先读取项目和进程，不要重复执行。")
        } finally {pending.remove(id)}
    }
}
