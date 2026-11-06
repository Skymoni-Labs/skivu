package org.skivu.engine.adb

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Android shell,v2 framing: stdout/stderr and a real process exit packet. */
class ShellV2Decoder(private val outputLimit: Int = 65536) {
    private var pending = byteArrayOf()
    private val out = ByteArrayOutputStream()
    private val err = ByteArrayOutputStream()
    var exitCode: Int? = null
        private set
    var truncated = false
        private set

    fun feed(bytes: ByteArray) {
        require(pending.size + bytes.size <= 131072) { "Oversized shell frame" }
        pending += bytes
        while (pending.size >= 5) {
            val kind = pending[0].toInt() and 255
            val size = ByteBuffer.wrap(pending, 1, 4).order(ByteOrder.LITTLE_ENDIAN).int
            require(size in 0..65536 && kind in 1..3) { "Invalid shell,v2 frame" }
            if (pending.size < size + 5) return
            require(exitCode == null) { "Data after shell exit receipt" }
            val payload = pending.copyOfRange(5, size + 5)
            pending = pending.copyOfRange(size + 5, pending.size)
            when (kind) {
                1, 2 -> {
                    val stream = if (kind == 1) out else err
                    val remaining = (outputLimit - out.size() - err.size()).coerceAtLeast(0)
                    stream.write(payload, 0, payload.size.coerceAtMost(remaining))
                    if (payload.size > remaining) truncated = true
                }
                3 -> {
                    require(size == 1 && exitCode == null) { "Invalid shell exit frame" }
                    exitCode = payload[0].toInt() and 255
                }
            }
        }
    }
    fun result(): ShellV2Result {
        require(pending.isEmpty() && exitCode != null) { "Shell ended without a complete exit receipt" }
        return ShellV2Result(exitCode!!, out.toString("UTF-8"), err.toString("UTF-8"), truncated)
    }
}

data class ShellV2Result(val exitCode: Int, val stdout: String, val stderr: String, val truncated: Boolean)

internal fun shellFrame(kind: Int, payload: ByteArray = byteArrayOf()): ByteArray =
    ByteBuffer.allocate(payload.size + 5).order(ByteOrder.LITTLE_ENDIAN)
        .put(kind.toByte()).putInt(payload.size).put(payload).array()
