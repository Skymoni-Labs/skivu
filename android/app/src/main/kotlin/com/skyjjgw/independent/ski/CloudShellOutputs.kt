package com.skyjjgw.independent.ski

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** High-privilege transport logs remain app-owned data, separate from adbd's
 * authority. Reading/exporting an old log never reconnects or replays code. */
class CloudShellOutputs(private val context:Context) {
    private val root=File(context.filesDir,"cloud-shell-logs").apply{mkdirs()}
    private fun directory(id:String):File {require(Regex("shell_[a-f0-9]{64}").matches(id));return File(root,id)}
    private fun save(dir:File,row:JSONObject){val temp=File(dir,"metadata.tmp");temp.writeText(row.toString());check(temp.renameTo(File(dir,"metadata.json")))}
    fun execute(owner:String,request:String,run:(java.io.OutputStream,java.io.OutputStream)->Map<String,Any?>):Map<String,Any?> {
        val id="shell_"+TaskDatabase.digest("$owner:$request");val dir=directory(id).apply{check(mkdir()){ "原高权限执行已有日志，请读取原结果，不重新执行。" }}
        val row=JSONObject(mapOf("id" to id,"owner" to owner,"requestId" to request,"state" to "running","createdAt" to System.currentTimeMillis()))
        save(dir,row)
        try {
            val result=File(dir,"stdout").outputStream().use{out->File(dir,"stderr").outputStream().use{err->run(out,err)}}
            row.put("state","exited").put("exitCode",result["exitCode"]).put("uid",result["uid"]).put("endedAt",System.currentTimeMillis());save(dir,row)
            return result+mapOf("outputId" to id,"stdout" to page(owner,id,"stdout",0,48000),"stderr" to page(owner,id,"stderr",0,48000),"outputRetention" to "complete_disk_logs","truncated" to false)
        }catch(error:Exception){row.put("state","unknown").put("error",error.toString());runCatching{save(dir,row)};throw IllegalStateException("高权限执行中断；已有完整原始字节保留，先读取 outputId=$id，不能自动重跑。${error.message}",error)}
    }
    private fun own(owner:String,id:String):Pair<File,JSONObject>{val dir=directory(id);val row=JSONObject(File(dir,"metadata.json").readText());require(row.getString("owner")==owner){"日志不属于本会话。"};return dir to row}
    fun page(owner:String,id:String,stream:String,offset:Long,length:Int):Map<String,Any?>{require(stream in setOf("stdout","stderr"));val(dir,row)=own(owner,id);val file=File(dir,stream);return (if(file.exists())CloudRanges.file(file,offset,length)else mapOf("text" to "","offset" to 0L,"nextOffset" to 0L,"bytes" to 0L,"complete" to true))+mapOf("outputId" to id,"stream" to stream,"processState" to row.getString("state"),"exitCode" to row.opt("exitCode").let{if(it==JSONObject.NULL)null else it},"outputComplete" to (row.optString("state")=="exited"))}
    fun export(owner:String,id:String,stream:String):Map<String,Any?> {
        require(stream in setOf("stdout","stderr"));val(dir,row)=own(owner,id);val source=File(dir,stream);require(source.isFile)
        val contentId="content_"+UUID.randomUUID().toString().replace("-","");val base=File(context.filesDir,"cloud-home/cloud/content").apply{mkdirs()};val dest=File(base,"$contentId.bin");val sha=MessageDigest.getInstance("SHA-256")
        // Snapshot the length, so export also works while the process appends.
        val bytes=source.length();source.inputStream().use{input->dest.outputStream().use{output->val buffer=ByteArray(65536);var left=bytes;while(left>0){CloudOperations.checkCurrent();val count=input.read(buffer,0,minOf(left,buffer.size.toLong()).toInt());check(count>0);output.write(buffer,0,count);sha.update(buffer,0,count);left-=count}}}
        val digest=sha.digest().joinToString(""){"%02x".format(it)}
        File(base,"$contentId.json").writeText(JSONObject(mapOf("id" to contentId,"owner" to owner,"complete" to true,"bytes" to bytes,"sha256" to digest)).toString())
        return mapOf("contentId" to contentId,"bytes" to bytes,"sha256" to digest,"stream" to stream,"outputId" to id,"snapshotProcessState" to row.getString("state"),"use" to "coding.files.write(contentId) 后可显式交付完整日志")
    }
}
