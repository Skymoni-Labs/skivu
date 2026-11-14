package com.skyjjgw.independent.ski.dshgo.phone.shell

import android.os.Bundle
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

internal object ShellWire {
    val magic = "DSH_ANDROID_SHELL_V1\n".toByteArray(Charsets.US_ASCII)
    const val MAX_FRAME = 512 * 1024

    fun write(output: OutputStream, bytes: ByteArray) {
        require(bytes.size <= MAX_FRAME)
        val n = bytes.size
        output.write(byteArrayOf((n ushr 24).toByte(), (n ushr 16).toByte(), (n ushr 8).toByte(), n.toByte()))
        output.write(bytes)
        output.flush()
    }

    fun read(input: InputStream): ByteArray? {
        val first = input.read()
        if (first < 0) return null
        val header = ByteArray(4)
        header[0] = first.toByte()
        fully(input, header, 1)
        val n = ((header[0].toInt() and 255) shl 24) or ((header[1].toInt() and 255) shl 16) or
            ((header[2].toInt() and 255) shl 8) or (header[3].toInt() and 255)
        if (n !in 0..MAX_FRAME) throw IOException("protocolMismatch")
        return ByteArray(n).also { fully(input, it, 0) }
    }

    private fun fully(input: InputStream, bytes: ByteArray, start: Int) {
        var offset = start
        while (offset < bytes.size) {
            val n = input.read(bytes, offset, bytes.size - offset)
            if (n < 0) throw EOFException("transportLost")
            offset += n
        }
    }

    fun sync(input: InputStream) {
        var matched = 0
        repeat(4096) {
            val b = input.read()
            if (b < 0) throw EOFException("transportLost")
            matched = if (b.toByte() == magic[matched]) matched + 1 else if (b.toByte() == magic[0]) 1 else 0
            if (matched == magic.size) return
        }
        throw IOException("protocolMismatch")
    }
}

internal fun shellBundle(values: Map<String, Any?>): Bundle = Bundle().apply {
    values.forEach { (key, value) -> when (value) {
        null -> putString(key, null)
        is Boolean -> putBoolean(key, value)
        is Int -> putInt(key, value)
        is Long -> putLong(key, value)
        is String -> putString(key, value)
        else -> throw IllegalArgumentException("invalidArguments")
    } }
}

internal fun Bundle.shellMap(): Map<String, Any?> = keySet().associateWith { get(it) }
