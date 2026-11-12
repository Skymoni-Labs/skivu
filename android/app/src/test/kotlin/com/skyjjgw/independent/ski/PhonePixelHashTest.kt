package com.skyjjgw.independent.ski

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.security.MessageDigest

class PhonePixelHashTest {
    @Test fun chunkedHashMatchesOriginalCanonicalArgbIncludingPartialFinalChunk() {
        val hash = PhonePixelHash()
        for ((width, height) in listOf(1 to 1, 7 to 17, 13 to 47, 1080 to 53)) {
            val data = IntArray(width * height) { (it * 1199540897) xor 0xff007fee.toInt() }
            val bytes = ByteBuffer.allocate(data.size * 4).apply { asIntBuffer().put(data) }.array()
            val expected = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
            var largest = 0
            val actual = hash.hash(width, height) { target, top, count ->
                largest = maxOf(largest, target.size)
                data.copyInto(target, 0, top * width, (top + count) * width)
            }
            assertEquals(expected, actual)
            assertTrue(largest <= width * 16)
            data[data.lastIndex] = data.last() xor 1
            assertNotEquals(actual, hash.hash(width, height) { target, top, count ->
                data.copyInto(target, 0, top * width, (top + count) * width)
            })
        }
    }
}
