package com.skyjjgw.independent.ski

/** Byte-based transport windows preserve Unicode across continuation pages. */
object CloudRanges {
    fun read(input:java.io.InputStream,offset:Long,length:Int,total:Long,base64:Boolean=false):Map<String,Any?>{require(offset>=0&&length>0);var left=offset;val skip=ByteArray(65536);while(left>0){CloudOperations.checkCurrent();val n=input.read(skip,0,minOf(left,skip.size.toLong()).toInt());if(n<0)break;left-=n};val window=minOf(maxOf(4,length),1024*1024);val buffer=ByteArray(window+3);var n=0;while(n<buffer.size){CloudOperations.checkCurrent();val got=input.read(buffer,n,buffer.size-n);if(got<0)break;n+=got};var end=minOf(n,window);if(!base64&&offset+end<total)while(end>0&&end<n&&(buffer[end].toInt() and 0xc0)==0x80)end--;return mapOf("text" to if(base64)null else String(buffer,0,end,Charsets.UTF_8),"data" to if(base64)android.util.Base64.encodeToString(buffer.copyOf(end),android.util.Base64.NO_WRAP)else null,"offset" to offset,"nextOffset" to offset+end,"complete" to (offset+end>=total),"bytes" to total)}
    fun file(file:java.io.File,offset:Long,length:Int):Map<String,Any?> = file.inputStream().use{input-> // seek avoids rescanning large regular files on every page
        val start=minOf(offset,file.length());input.channel.position(start);read(input,0,length,file.length()-start).let{it+mapOf("offset" to start,"nextOffset" to (start+(it["nextOffset"] as Long)),"bytes" to file.length())}
    }
}
