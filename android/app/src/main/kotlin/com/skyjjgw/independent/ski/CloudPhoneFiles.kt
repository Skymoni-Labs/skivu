package com.skyjjgw.independent.ski

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/** Public phone copies are separate from immutable conversation versions.
 * A durable URI receipt resumes our own pending row; a lost insert receipt is
 * uncertain and is never turned into an automatic second file. */
class CloudPhoneFiles(private val context:Context) {
    companion object { private val lock=Any() }
    private val resolver get()=context.contentResolver
    private fun receipt(id:String):File {
        require(Regex("artifact_[a-f0-9]{32}").matches(id))
        return File(context.filesDir,"cloud-artifacts/exports/$id.json").also{it.parentFile!!.mkdirs()}
    }
    private fun read(id:String)=receipt(id).let{if(it.exists())JSONObject(it.readText())else null}
    private fun save(id:String,value:JSONObject){val file=receipt(id);val temp=File(file.path+".tmp");temp.writeText(value.toString());check(temp.renameTo(file))}
    private fun hash(uri:Uri):Pair<String,Long>{
        val digest=MessageDigest.getInstance("SHA-256");var bytes=0L
        (resolver.openInputStream(uri)?:error("手机文件无法读取。")).use{input->val buffer=ByteArray(65536);while(true){val n=input.read(buffer);if(n<0)break;bytes+=n;require(bytes<=200L*1024*1024);digest.update(buffer,0,n)}}
        return digest.digest().joinToString(""){"%02x".format(it)} to bytes
    }
    private fun row(uri:Uri):Map<String,Any?>? {
        val fields=arrayOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE,MediaStore.MediaColumns.RELATIVE_PATH,MediaStore.MediaColumns.IS_PENDING)
        return resolver.query(uri,fields,null,null,null)?.use{cursor->if(!cursor.moveToFirst())null else mapOf("name" to cursor.getString(0),"bytes" to cursor.getLong(1),"relativePath" to cursor.getString(2),"pending" to (cursor.getInt(3)==1))}
    }
    fun inspect(id:String):Map<String,Any?> = synchronized(lock) {
        val receipt=read(id)?:return@synchronized mapOf("phoneSaveState" to "not_saved")
        val text=receipt.optString("uri")
        if(text.isBlank())return@synchronized mapOf("phoneSaveState" to if(receipt.optString("state")=="prepared")"unknown" else "failed","phoneSaveError" to receipt.optString("error"))
        try{
            val uri=Uri.parse(text);val row=row(uri)?:return@synchronized mapOf("phoneSaveState" to "missing","phoneSaveError" to "手机下载副本已删除，原始成果仍保留。")
            if(row["pending"]==true)return@synchronized mapOf("phoneSaveState" to "pending")
            val (sha,bytes)=hash(uri)
            mapOf("phoneSaveState" to if(sha==receipt.optString("sha256")&&bytes==receipt.optLong("bytes"))"saved" else "changed","phoneUri" to text,"phoneName" to row["name"],"phonePath" to "${row["relativePath"]}${row["name"]}","phoneBytes" to bytes)
        }catch(_:Exception){mapOf("phoneSaveState" to "unavailable","phoneSaveError" to "暂时无法读取手机副本；原始成果仍保留。")}
    }
    fun export(file:File,id:String,sha:String,mime:String):Map<String,Any?> = synchronized(lock) {
        if(Build.VERSION.SDK_INT<29)return@synchronized mapOf("phoneSaveState" to "needs_location","phoneSaveError" to "此系统需要通过“另存为”选择手机文件位置。")
        var receipt=read(id)
        if(receipt!=null)require(receipt.optString("sha256")==sha&&receipt.optLong("bytes")==file.length()){"原手机副本对应其他内容，未覆盖已有文件。"}
        var uri=receipt?.optString("uri")?.takeIf{it.isNotBlank()}?.let(Uri::parse)
        if(uri!=null){
            val existing=row(uri)?:error("手机下载副本已删除；请用“另存为”保存，未重复创建文件。")
            if(existing["pending"]!=true)return@synchronized inspect(id)
        }else{
            require(receipt?.optString("state")!="prepared"){"上次手机文件保存结果需要核对，未自动创建第二份。请用“另存为”明确保存副本。"}
            receipt=JSONObject(mapOf("state" to "prepared","sha256" to sha,"bytes" to file.length()));save(id,receipt)
            try{
                uri=resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,ContentValues().apply{
                    put(MediaStore.MediaColumns.DISPLAY_NAME,file.name);put(MediaStore.MediaColumns.MIME_TYPE,mime)
                    put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_DOWNLOADS+"/Skivu/");put(MediaStore.MediaColumns.IS_PENDING,1)
                })?:error("无法在手机下载目录创建文件。")
                receipt.put("uri",uri.toString()).put("state","copying");save(id,receipt)
            }catch(e:Exception){if(uri==null){receipt.put("state","failed").put("error",e.message);save(id,receipt)};throw e}
        }
        val destination=uri!!;val record=receipt!!
        try{
            (resolver.openOutputStream(destination,"w")?:error("手机下载文件无法写入。")).use{output->file.inputStream().use{it.copyTo(output)}}
            val actual=hash(destination);require(actual.first==sha&&actual.second==file.length()){"写入手机后回读核对未通过。"}
            check(resolver.update(destination,ContentValues().apply{put(MediaStore.MediaColumns.IS_PENDING,0)},null,null)==1)
            record.put("state","saved").put("savedAt",System.currentTimeMillis());save(id,record)
            inspect(id).also{require(it["phoneSaveState"]=="saved"){"手机文件尚未完成核对。"}}
        }catch(e:Exception){
            // Never remove a published phone file, including one the user edited.
            if(runCatching{row(destination)?.get("pending")==true}.getOrDefault(false)){
                if(runCatching{resolver.delete(destination,null,null)>0}.getOrDefault(false))record.remove("uri")
            }
            record.put("state",if(record.has("uri"))"unknown" else "failed").put("error",e.message);save(id,record);throw e
        }
    }
    fun verifySavedCopy(uri:Uri,file:File):Boolean {val actual=hash(uri);val digest=MessageDigest.getInstance("SHA-256");file.inputStream().use{input->val buffer=ByteArray(65536);while(true){val n=input.read(buffer);if(n<0)break;digest.update(buffer,0,n)}};val sha=digest.digest().joinToString(""){"%02x".format(it)};return actual.first==sha&&actual.second==file.length()}
}
