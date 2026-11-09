package com.skyjjgw.independent.ski

import android.content.Context
import android.util.Base64
import org.json.JSONObject
import java.io.*
import java.security.MessageDigest
import java.util.UUID

/** Sealed, owner-scoped content. Fixed transport pages are independently checked
 * against a streamed block index, without re-hashing the whole file per page. */
class CloudNativeContents(private val context:Context) {
    companion object { private const val BLOCK=1024*1024;private const val INDEX_RECORD=65;private val indexLock=Any() }
    private val directory=File(context.filesDir,"cloud-home/cloud/content").apply{mkdirs()}
    private fun hex(bytes:ByteArray)=bytes.joinToString(""){"%02x".format(it)}
    private fun load(owner:String,id:String):Pair<File,JSONObject>{
        require(Regex("content_[a-f0-9]{32}").matches(id))
        val meta=JSONObject(File(directory,"$id.json").readText())
        require(meta.getString("owner")==owner&&meta.getBoolean("complete")){"内容引用不属于当前调用方。"}
        val file=File(directory,"$id.bin");require(file.isFile&&file.length()==meta.getLong("bytes")){"内容文件大小已变化。"}
        return file to meta
    }
    private fun writeIndex(input:InputStream,index:OutputStream,guard:()->Unit={},copy:OutputStream?=null):Pair<Long,String>{
        val whole=MessageDigest.getInstance("SHA-256");val block=MessageDigest.getInstance("SHA-256")
        var total=0L;var inBlock=0;val buffer=ByteArray(65536)
        while(true){guard();val n=input.read(buffer);if(n<0)break
            copy?.write(buffer,0,n);whole.update(buffer,0,n);total+=n
            var offset=0
            while(offset<n){val size=minOf(n-offset,BLOCK-inBlock);block.update(buffer,offset,size);inBlock+=size;offset+=size
                if(inBlock==BLOCK){index.write((hex(block.digest())+"\n").toByteArray(Charsets.US_ASCII));inBlock=0}}
        }
        if(inBlock>0)index.write((hex(block.digest())+"\n").toByteArray(Charsets.US_ASCII))
        return total to hex(whole.digest())
    }
    fun import(owner:String,input:InputStream,guard:()->Unit={}):Map<String,Any?>{
        val id="content_"+UUID.randomUUID().toString().replace("-","")
        val file=File(directory,"$id.bin");val temporary=File(directory,"$id.tmp")
        val index=File(directory,"$id.blocks");val pendingIndex=File(directory,"$id.blocks.tmp")
        val checked=temporary.outputStream().use{output->pendingIndex.outputStream().use{hashes->
            val value=writeIndex(input,hashes,guard,output);output.fd.sync();hashes.fd.sync();value
        }}
        check(temporary.renameTo(file));check(pendingIndex.renameTo(index))
        val row=mapOf("id" to id,"contentId" to id,"owner" to owner,"complete" to true,"bytes" to checked.first,"sha256" to checked.second,"blockIndexVersion" to 1,"blockSourceSha256" to checked.second)
        val meta=File(directory,"$id.json.tmp");meta.writeText(JSONObject(row).toString());check(meta.renameTo(File(directory,"$id.json")));return row
    }
    fun file(owner:String,id:String):File{
        val (file,meta)=load(owner,id)
        val sha=MessageDigest.getInstance("SHA-256");file.inputStream().use{input->val b=ByteArray(65536);while(true){val n=input.read(b);if(n<0)break;sha.update(b,0,n)}}
        require(hex(sha.digest())==meta.getString("sha256")){"内容文件完整性核对失败。"};return file
    }
    private fun blockIndex(file:File,id:String,meta:JSONObject):File=synchronized(indexLock){
        val index=File(directory,"$id.blocks");val size=((file.length()+BLOCK-1)/BLOCK)*INDEX_RECORD
        if(meta.optInt("blockIndexVersion")==1&&meta.optString("blockSourceSha256")==meta.getString("sha256")&&index.isFile&&index.length()==size)return@synchronized index
        // Legacy references are upgraded only after checking their original full
        // hash; the original content object and identity remain unchanged.
        val pending=File(directory,"$id.blocks.tmp")
        val checked=file.inputStream().use{input->pending.outputStream().use{output->val value=writeIndex(input,output);output.fd.sync();value}}
        require(checked.first==meta.getLong("bytes")&&checked.second==meta.getString("sha256")){"旧内容文件完整性核对失败。"}
        check(pending.renameTo(index));meta.put("blockIndexVersion",1).put("blockSourceSha256",checked.second)
        val temp=File(directory,"$id.json.tmp");temp.writeText(meta.toString());check(temp.renameTo(File(directory,"$id.json")));index
    }
    fun read(owner:String,id:String,offset:Long,length:Int):Map<String,Any?>{
        require(offset>=0&&length>0)
        val (file,meta)=load(owner,id);val index=blockIndex(file,id,meta);val total=file.length()
        val start=minOf(offset,total);val end=start+minOf((maxOf(4,length).coerceAtMost(BLOCK)).toLong(),total-start)
        val output=ByteArrayOutputStream((end-start).toInt())
        if(end>start)RandomAccessFile(file,"r").use{input->RandomAccessFile(index,"r").use{hashes->
            for(number in start/BLOCK..(end-1)/BLOCK){val base=number*BLOCK;val bytes=ByteArray(minOf(BLOCK.toLong(),total-base).toInt());input.seek(base);input.readFully(bytes)
                hashes.seek(number*INDEX_RECORD);val encoded=ByteArray(INDEX_RECORD);hashes.readFully(encoded)
                require(encoded.last()==10.toByte()&&hex(MessageDigest.getInstance("SHA-256").digest(bytes))==String(encoded,0,64,Charsets.US_ASCII)){"内容分块完整性核对失败。"}
                val from=maxOf(start,base);val to=minOf(end,base+bytes.size);output.write(bytes,(from-base).toInt(),(to-from).toInt())
            }
        }}
        return mapOf("contentId" to id,"offset" to start,"nextOffset" to end,"bytes" to total,"text" to null,"data" to Base64.encodeToString(output.toByteArray(),Base64.NO_WRAP),"complete" to (end>=total))
    }
    fun readText(owner:String,id:String,offset:Long,length:Int):Map<String,Any?>{
        require(length>0)
        val window=maxOf(4,length).coerceAtMost(BLOCK-3)
        val page=read(owner,id,offset,window+3)
        val data=Base64.decode(page["data"] as String,Base64.DEFAULT)
        var end=minOf(window,data.size)
        if(offset+end<(page["bytes"] as Number).toLong())while(end>0&&end<data.size&&(data[end].toInt() and 0xc0)==0x80)end--
        return page+mapOf("data" to null,"text" to String(data,0,end,Charsets.UTF_8),"nextOffset" to offset+end,"complete" to (offset+end>=(page["bytes"] as Number).toLong()))
    }
}
