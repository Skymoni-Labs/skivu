package com.skyjjgw.independent.ski

/** Cooperative cancellation covers native copies as well as Linux processes.
 * A stop receipt waits for already-owned operations to leave their I/O loops. */
object CloudOperations {
    private val cancelled=java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private val active=java.util.concurrent.ConcurrentHashMap<String,java.util.concurrent.atomic.AtomicInteger>()
    private val progress=java.util.concurrent.ConcurrentHashMap<String,Map<String,Any?>>()
    private val current=ThreadLocal<String?>()
    private fun key(owner:String,task:String)="$owner:$task"
    fun enter(context:android.content.Context,owner:String,task:String){val id=key(owner,task);check(!wasStopped(context,owner,task)){"本次任务已停止。"};ensureReserve(context);active.getOrPut(id){java.util.concurrent.atomic.AtomicInteger()}.incrementAndGet();current.set(id);if(id in cancelled){leave();error("本次任务已停止。")}}
    fun leave(){current.get()?.let{id->active[id]?.decrementAndGet();progress.remove(id)};current.remove()}
    fun checkCurrent(){val id=current.get()?:return;check(id !in cancelled){"本次任务已停止，未继续复制或派发。"}}
    fun checkScope(owner:String,task:String){check(key(owner,task) !in cancelled){"本次任务已停止。"}}
    private fun marker(context:android.content.Context,owner:String,task:String)=java.io.File(context.filesDir,"cloud-home/cloud/task-controls/${TaskDatabase.digest(key(owner,task))}.json")
    fun wasStopped(context:android.content.Context,owner:String,task:String):Boolean{val id=key(owner,task);if(id in cancelled)return true;val file=marker(context,owner,task);if(file.isFile){val record=org.json.JSONObject(file.readText());if(record.optString("state")=="stopped"){cancelled.add(id);return true}};return false}
    private fun reserve(context:android.content.Context)=java.io.File(context.filesDir,"cloud-home/cloud/emergency.reserve")
    private val reserveLock=Any()
    private fun ensureReserve(context:android.content.Context){synchronized(reserveLock){val file=reserve(context);if(!file.exists())runCatching{file.parentFile!!.mkdirs();file.outputStream().use{output->output.write(ByteArray(1024*1024));output.fd.sync()}}}}
    fun stopPersisted(context:android.content.Context,owner:String,task:String)=runCatching{val file=marker(context,owner,task);file.isFile&&org.json.JSONObject(file.readText()).optString("state")=="stopped"}.getOrDefault(false)
    fun cancel(context:android.content.Context,owner:String,task:String):Boolean{cancelled.add(key(owner,task));if(stopPersisted(context,owner,task))return true;val file=marker(context,owner,task);val temporary=java.io.File(file.path+"."+java.util.UUID.randomUUID()+".tmp");fun write(){file.parentFile!!.mkdirs();temporary.outputStream().use{output->output.write(org.json.JSONObject(mapOf("owner" to owner,"taskId" to task,"state" to "stopped")).toString().toByteArray());output.fd.sync()};check(temporary.renameTo(file))};return try{write();true}catch(_:Exception){reserve(context).delete();runCatching{write();true}.getOrDefault(false)}}
    fun awaitStopped(owner:String,task:String){val id=key(owner,task);while((active[id]?.get()?:0)>0)Thread.sleep(50)}
    fun report(name:String,bytes:Long,total:Long?){current.get()?.let{id->progress[id]=mapOf("scope" to id,"name" to name,"bytes" to bytes,"total" to total,"state" to "copying")}}
    fun status()=progress.values.toList()
    fun copy(input:java.io.InputStream,output:java.io.OutputStream,name:String,total:Long?=null):Long{val buffer=ByteArray(65536);var count=0L;while(true){checkCurrent();val n=input.read(buffer);if(n<0)break;output.write(buffer,0,n);count+=n;report(name,count,total)};checkCurrent();return count}
}
