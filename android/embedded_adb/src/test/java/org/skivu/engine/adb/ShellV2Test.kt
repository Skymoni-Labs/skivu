package org.skivu.engine.adb

import org.junit.Assert.*
import org.junit.Test

class ShellV2Test {
    @Test fun fragmentedUtf8AndSeparateErrorKeepRealExitCode() {
        val bytes = shellFrame(1, "你好".toByteArray()) +
            shellFrame(2, "problem".toByteArray()) + shellFrame(3, byteArrayOf(7))
        val decoder = ShellV2Decoder()
        bytes.forEach { decoder.feed(byteArrayOf(it)) }
        val result = decoder.result()
        assertEquals("你好", result.stdout)
        assertEquals("problem", result.stderr)
        assertEquals(7, result.exitCode)
        assertFalse(result.truncated)
    }
    @Test fun printedSuccessCannotReplaceMissingExit() {
        val decoder = ShellV2Decoder()
        decoder.feed(shellFrame(1, "exitCode=0".toByteArray()))
        assertThrows(IllegalArgumentException::class.java) { decoder.result() }
    }
    @Test fun malformedDuplicateOrPostExitFramesAreRejected() {
        for (bytes in listOf(shellFrame(8), shellFrame(3),
            shellFrame(3, byteArrayOf(0)) + shellFrame(3, byteArrayOf(0)),
            shellFrame(3, byteArrayOf(0)) + shellFrame(1, byteArrayOf(1)))) {
            assertThrows(IllegalArgumentException::class.java) { ShellV2Decoder().feed(bytes) }
        }
    }
    @Test fun combinedOutputIsPreservedWithRealExit() {
        val decoder = ShellV2Decoder()
        decoder.feed(shellFrame(1, "abc".toByteArray()) +
            shellFrame(2, "def".toByteArray()) + shellFrame(3, byteArrayOf(-1)))
        val result = decoder.result()
        assertEquals("abc", result.stdout)
        assertEquals("def", result.stderr)
        assertEquals(255, result.exitCode)
        assertFalse(result.truncated)
    }
    @Test fun incompleteFramesCannotBecomeReceipts() {
        val decoder = ShellV2Decoder()
        decoder.feed(shellFrame(1, "text".toByteArray()).copyOf(7))
        assertThrows(IllegalArgumentException::class.java) { decoder.result() }
        val large=ShellV2Decoder()
        large.feed(byteArrayOf(1, 0, 0, 2, 0))
        assertThrows(IllegalArgumentException::class.java) { large.result() }
    }
    @Test fun largeFrameStreamsWithoutAccumulatingOrTruncating() {
        var bytes=0L
        val digest=java.security.MessageDigest.getInstance("SHA-256")
        val sink=object:java.io.OutputStream(){override fun write(value:Int){bytes++;digest.update(value.toByte())};override fun write(value:ByteArray,offset:Int,length:Int){bytes+=length;digest.update(value,offset,length)}}
        val decoder=ShellV2Decoder(sink,sink)
        val size=18*1024*1024+7
        val header=java.nio.ByteBuffer.allocate(5).order(java.nio.ByteOrder.LITTLE_ENDIAN).put(1).putInt(size).array()
        decoder.feed(header)
        val chunk=ByteArray(8191){(it%251).toByte()};val expected=java.security.MessageDigest.getInstance("SHA-256")
        var remaining=size
        while(remaining>0){val part=chunk.copyOf(minOf(remaining,chunk.size));decoder.feed(part);expected.update(part);remaining-=part.size}
        decoder.feed(shellFrame(3,byteArrayOf(0)))
        assertEquals(size.toLong(),bytes);assertArrayEquals(expected.digest(),digest.digest());assertEquals(0,decoder.result().exitCode)
    }
}
