package com.skyjjgw.independent.ski

import java.security.MessageDigest

/** Exact canonical ARGB SHA-256 with bounded scratch space, independent of bitmap row padding. */
internal class PhonePixelHash {
    private var pixels = IntArray(0)
    private var bytes = ByteArray(0)

    fun hash(width: Int, height: Int, read: (IntArray, Int, Int) -> Unit): String {
        require(width > 0 && height > 0)
        val rows = minOf(16, height)
        if (pixels.size != width * rows) { pixels = IntArray(width * rows); bytes = ByteArray(pixels.size * 4) }
        val digest = MessageDigest.getInstance("SHA-256")
        var top = 0
        while (top < height) {
            val count = minOf(rows, height - top)
            read(pixels, top, count)
            for (i in 0 until width * count) {
                val p = pixels[i]; val offset = i * 4
                bytes[offset] = (p ushr 24).toByte(); bytes[offset + 1] = (p ushr 16).toByte()
                bytes[offset + 2] = (p ushr 8).toByte(); bytes[offset + 3] = p.toByte()
            }
            digest.update(bytes, 0, width * count * 4)
            top += count
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
