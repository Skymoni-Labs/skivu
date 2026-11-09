package org.skivu.engine.adb

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Incremental shell,v2 parser. A transport packet need not contain a whole
 * shell frame. Production sinks persist every payload byte to owned log files. */
class ShellV2Decoder(private val stdout: java.io.OutputStream? = null,
                     private val stderr: java.io.OutputStream? = null) {
    private val header = ByteArray(5)
    private var headerBytes = 0
    private var remaining = 0L
    private var kind = 0
    private val out = ByteArrayOutputStream()
    private val err = ByteArrayOutputStream()
    var exitCode: Int? = null
        private set
    fun feed(bytes: ByteArray) {
        var offset = 0
        while (offset < bytes.size) {
            require(exitCode == null) { "Data after shell exit receipt" }
            if (headerBytes < 5) {
                val count = minOf(5-headerBytes, bytes.size-offset)
                bytes.copyInto(header,headerBytes,offset,offset+count)
                headerBytes += count; offset += count
                if(headerBytes < 5)continue
                kind=header[0].toInt() and 255
                remaining=ByteBuffer.wrap(header,1,4).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xffffffffL
                require(kind in 1..3 && (kind != 3 || remaining == 1L)) { "Invalid shell,v2 frame" }
                if(remaining==0L){headerBytes=0;continue}
            }
            val count=minOf(remaining,(bytes.size-offset).toLong()).toInt()
            when (kind) {
                1 -> (stdout ?: out).write(bytes,offset,count)
                2 -> (stderr ?: err).write(bytes,offset,count)
                3 -> if(count==1)exitCode=bytes[offset].toInt() and 255
            }
            offset+=count;remaining-=count
            if(remaining==0L)headerBytes=0
        }
    }
    fun result(): ShellV2Result {
        require(headerBytes==0 && exitCode != null) { "Shell ended without a complete exit receipt" }
        stdout?.flush();stderr?.flush()
        return ShellV2Result(exitCode!!, out.toString("UTF-8"), err.toString("UTF-8"), false)
    }
}

data class ShellV2Result(val exitCode: Int, val stdout: String, val stderr: String, val truncated: Boolean)

internal fun shellFrame(kind: Int, payload: ByteArray = byteArrayOf()): ByteArray =
    ByteBuffer.allocate(payload.size + 5).order(ByteOrder.LITTLE_ENDIAN)
        .put(kind.toByte()).putInt(payload.size).put(payload).array()
