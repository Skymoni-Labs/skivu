package com.skyjjgw.independent.ski

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/** Large task records live in immutable, hashed segments. SQLite rows only hold
 * references, avoiding CursorWindow's per-row memory boundary. No total cap. */
class TaskBlobStore(context:Context){
    private val root=File(context.filesDir,"task-records").apply{mkdirs()}
    fun encode(raw:String):String{
        if(raw.length<=16384)return raw
        val bytes=raw.toByteArray(Charsets.UTF_8);val hash=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString(""){"%02x".format(it)}
        val directory=File(root,hash);val manifest=File(directory,"manifest.json")
        synchronized(lock){if(!manifest.exists()){
            directory.mkdirs();var index=0;var at=0
            while(at<bytes.size){val size=minOf(262144,bytes.size-at);val file=File(directory,"$index.part");val tmp=File(directory,"$index.tmp");tmp.outputStream().use{it.write(bytes,at,size);it.fd.sync()};check(tmp.renameTo(file));at+=size;index++}
            val temp=File(directory,"manifest.tmp");temp.writeText(JSONObject(mapOf("sha256" to hash,"bytes" to bytes.size,"parts" to index)).toString());check(temp.renameTo(manifest))
        }}
        return JSONObject(mapOf(REF to hash)).toString()
    }
    fun decode(raw:String):String{
        if(!raw.startsWith("{\"$REF\":"))return raw
        val ref=JSONObject(raw);if(ref.length()!=1)return raw
        val hash=ref.getString(REF);require(Regex("[a-f0-9]{64}").matches(hash));val directory=File(root,hash);val meta=JSONObject(File(directory,"manifest.json").readText());val digest=MessageDigest.getInstance("SHA-256")
        val out=java.io.ByteArrayOutputStream();for(i in 0 until meta.getInt("parts")){File(directory,"$i.part").inputStream().use{input->val buffer=ByteArray(65536);while(true){val n=input.read(buffer);if(n<0)break;digest.update(buffer,0,n);out.write(buffer,0,n)}}}
        require(out.size().toLong()==meta.getLong("bytes")&&digest.digest().joinToString(""){"%02x".format(it)}==hash){"任务记录完整性核对失败；原始分段保留。"}
        return out.toString("UTF-8")
    }
    fun saveCheckpoint(run:String,raw:String){require(Regex("run_[a-f0-9]{64}").matches(run));val file=File(root,"checkpoint-$run.json");val tmp=File(root,"checkpoint-$run.tmp");tmp.writeText(encode(raw));check(tmp.renameTo(file))}
    fun checkpoint(run:String):String?{require(Regex("run_[a-f0-9]{64}").matches(run));val file=File(root,"checkpoint-$run.json");return if(file.isFile)decode(file.readText())else null}
    companion object{private const val REF="_skivu_record_ref";private val lock=Any()}
}
