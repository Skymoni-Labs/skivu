package com.skyjjgw.independent.ski

import android.os.Build
import androidx.test.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject
import java.io.*
import java.security.MessageDigest

class CloudContentAcceptanceTest {
    private val context get()=InstrumentationRegistry.getTargetContext()
    private fun guard(){check(context.packageName.endsWith(".engineqa")&&Build.HARDWARE in setOf("ranchu","goldfish"))}
    private fun source(size:Int)=object:InputStream(){var at=0;override fun read():Int=if(at<size)((at++*31L)%251).toInt()else -1;override fun read(b:ByteArray,off:Int,len:Int):Int{if(at>=size)return -1;val n=minOf(len,size-at);for(i in 0 until n)b[off+i]=((at++*31L)%251).toByte();return n}}
    @Test fun largeContentUsesVerifiedBlocksAcrossUnalignedPagesAndRejectsChangedChunks(){
        guard();val contents=CloudNativeContents(context);val bytes=9*1024*1024+53;val ref=source(bytes).use{contents.import("plugin:blocks",it)};val id=ref["contentId"] as String
        val digest=MessageDigest.getInstance("SHA-256");var offset=0L;var pages=0
        while(true){val page=contents.read("plugin:blocks",id,offset,333333);val data=android.util.Base64.decode(page["data"] as String,android.util.Base64.DEFAULT);digest.update(data);offset=(page["nextOffset"] as Number).toLong();pages++;if(page["complete"]==true)break}
        assertEquals(bytes.toLong(),offset);assertTrue(pages>20);assertEquals(ref["sha256"],digest.digest().joinToString(""){"%02x".format(it)})
        try{contents.read("plugin:other",id,0,100);fail("wrong owner read content")}catch(_:IllegalArgumentException){}
        RandomAccessFile(File(context.filesDir,"cloud-home/cloud/content/$id.bin"),"rw").use{it.seek(2L*1024*1024+77);it.write(255)}
        try{contents.read("plugin:blocks",id,2L*1024*1024,100);fail("changed block accepted")}catch(_:IllegalArgumentException){}
    }
    @Test fun legacyReferenceBuildsIndexOnlyAfterCheckingOriginalWholeHash(){
        guard();val contents=CloudNativeContents(context);val ref=source(3*1024*1024+9).use{contents.import("plugin:legacy-blocks",it)};val id=ref["contentId"] as String
        val meta=File(context.filesDir,"cloud-home/cloud/content/$id.json");val row=JSONObject(meta.readText());row.remove("blockIndexVersion");row.remove("blockSourceSha256");meta.writeText(row.toString())
        val page=contents.read("plugin:legacy-blocks",id,1024*1024-3L,21);assertEquals(1024*1024+18L,page["nextOffset"])
        assertEquals(1,JSONObject(meta.readText()).getInt("blockIndexVersion"));assertEquals(row.getString("sha256"),JSONObject(meta.readText()).getString("blockSourceSha256"))
        assertEquals(ref["bytes"],contents.file("plugin:legacy-blocks",id).length())
    }
    @Test fun textContinuationsPreserveUnicodeAtUnalignedBlockAndPageBoundaries(){
        guard();val contents=CloudNativeContents(context);val text="中文🙂line\n".repeat(200000);val ref=text.byteInputStream().use{contents.import("plugin:unicode-pages",it)};val id=ref["contentId"] as String
        var offset=0L;val full=StringBuilder();var pages=0
        while(true){val page=contents.readText("plugin:unicode-pages",id,offset,333331);full.append(page["text"] as String);offset=(page["nextOffset"] as Number).toLong();pages++;if(page["complete"]==true)break}
        assertTrue(pages>5);assertEquals(text,full.toString());assertEquals(text.toByteArray().size.toLong(),offset)
    }
    @Test fun realSystemPickerReferenceRemainsCompleteAfterApplicationUpdate(){
        guard();val directory=File(context.filesDir,"cloud-home/cloud/content")
        val row=directory.listFiles().orEmpty().filter{it.extension=="json"}.mapNotNull{runCatching{JSONObject(it.readText())}.getOrNull()}.lastOrNull{it.optString("owner").startsWith("plugin:saf_qa_")&&it.optLong("bytes")>8*1024*1024}
        org.junit.Assume.assumeNotNull(row)
        val data=row!!;val contents=CloudNativeContents(context);val digest=MessageDigest.getInstance("SHA-256");var offset=0L;var pages=0;val started=android.os.SystemClock.elapsedRealtime()
        while(true){val page=contents.read(data.getString("owner"),data.getString("id"),offset,1024*1024);digest.update(android.util.Base64.decode(page["data"] as String,android.util.Base64.DEFAULT));offset=(page["nextOffset"] as Number).toLong();pages++;if(page["complete"]==true)break}
        val sha=digest.digest().joinToString(""){"%02x".format(it)};assertEquals(data.getString("sha256"),sha);assertEquals(data.getLong("bytes"),offset)
        File(context.filesDir,"qa-native-content-blocks.json").writeText(JSONObject(mapOf("source" to "real-system-picker","bytes" to offset,"sha256" to sha,"pages" to pages,"elapsedMs" to android.os.SystemClock.elapsedRealtime()-started,"wholeFileRehashedPerPage" to false)).toString())
    }
}
