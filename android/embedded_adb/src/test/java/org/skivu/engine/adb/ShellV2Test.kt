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
    @Test fun combinedOutputBoundDoesNotDiscardExit() {
        val decoder = ShellV2Decoder(4)
        decoder.feed(shellFrame(1, "abc".toByteArray()) +
            shellFrame(2, "def".toByteArray()) + shellFrame(3, byteArrayOf(-1)))
        val result = decoder.result()
        assertEquals("abc", result.stdout)
        assertEquals("d", result.stderr)
        assertEquals(255, result.exitCode)
        assertTrue(result.truncated)
    }
    @Test fun incompleteOrOversizedFramesCannotBecomeReceipts() {
        val decoder = ShellV2Decoder()
        decoder.feed(shellFrame(1, "text".toByteArray()).copyOf(7))
        assertThrows(IllegalArgumentException::class.java) { decoder.result() }
        assertThrows(IllegalArgumentException::class.java) {
            ShellV2Decoder().feed(byteArrayOf(1, 0, 0, 2, 0))
        }
    }
}
