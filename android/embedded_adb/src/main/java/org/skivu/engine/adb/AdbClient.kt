// Adapted for Skivu from RikkaApps/Shizuku (Apache-2.0).
// Changes: own namespace, no key/payload logging, bounded sockets, and host integration.
package org.skivu.engine.adb

import android.util.Log
import org.skivu.engine.adb.AdbProtocol.ADB_AUTH_RSAPUBLICKEY
import org.skivu.engine.adb.AdbProtocol.ADB_AUTH_SIGNATURE
import org.skivu.engine.adb.AdbProtocol.ADB_AUTH_TOKEN
import org.skivu.engine.adb.AdbProtocol.A_AUTH
import org.skivu.engine.adb.AdbProtocol.A_CLSE
import org.skivu.engine.adb.AdbProtocol.A_CNXN
import org.skivu.engine.adb.AdbProtocol.A_MAXDATA
import org.skivu.engine.adb.AdbProtocol.A_OKAY
import org.skivu.engine.adb.AdbProtocol.A_OPEN
import org.skivu.engine.adb.AdbProtocol.A_STLS
import org.skivu.engine.adb.AdbProtocol.A_STLS_VERSION
import org.skivu.engine.adb.AdbProtocol.A_VERSION
import org.skivu.engine.adb.AdbProtocol.A_WRTE
import android.os.Build
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.net.ssl.SSLSocket

private const val TAG = "AdbClient"

class AdbClient(private val host: String, private val port: Int, private val key: AdbKey,
                private val requireTls: Boolean = true) : Closeable {
    private val closed = java.util.concurrent.atomic.AtomicBoolean(false)

    private lateinit var socket: Socket
    private lateinit var plainInputStream: DataInputStream
    private lateinit var plainOutputStream: DataOutputStream

    private var useTls = false

    private lateinit var tlsSocket: SSLSocket
    private lateinit var tlsInputStream: DataInputStream
    private lateinit var tlsOutputStream: DataOutputStream

    private val inputStream get() = if (useTls) tlsInputStream else plainInputStream
    private val outputStream get() = if (useTls) tlsOutputStream else plainOutputStream

    fun connect() {
        check(!closed.get()) { "ADB connection cancelled" }
        socket = Socket()
        if (closed.get()) { socket.close(); error("ADB connection cancelled") }
        socket.connect(java.net.InetSocketAddress(host, port), 15000)
        socket.soTimeout = 30000
        socket.tcpNoDelay = true
        plainInputStream = DataInputStream(socket.getInputStream())
        plainOutputStream = DataOutputStream(socket.getOutputStream())

        write(A_CNXN, A_VERSION, A_MAXDATA, "host::")

        var message = read()
        if (message.command == A_STLS) {
            if (Build.VERSION.SDK_INT < 30) {
                error("Connect to adb with TLS is not supported before Android 9")
            }
            write(A_STLS, A_STLS_VERSION, 0)

            val sslContext = key.sslContext
            tlsSocket = sslContext.socketFactory.createSocket(socket, host, port, true) as SSLSocket
            tlsSocket.startHandshake()

            tlsInputStream = DataInputStream(tlsSocket.inputStream)
            tlsOutputStream = DataOutputStream(tlsSocket.outputStream)
            useTls = true

            message = read()
        } else if (requireTls) {
            error("Wireless ADB did not negotiate TLS")
        } else if (message.command == A_AUTH) {
            if (message.command != A_AUTH || message.arg0 != ADB_AUTH_TOKEN) error("not A_AUTH ADB_AUTH_TOKEN")
            write(A_AUTH, ADB_AUTH_SIGNATURE, 0, key.sign(message.data))

            message = read()
            if (message.command != A_CNXN) {
                write(A_AUTH, ADB_AUTH_RSAPUBLICKEY, 0, key.adbPublicKey)
                message = read()
            }
        }

        if (message.command != A_CNXN) error("not A_CNXN")
    }

    fun shellCommand(command: String, listener: ((ByteArray) -> Unit)?) {
        val localId = 1
        write(A_OPEN, localId, 0, "shell:$command")

        var message = read()
        when (message.command) {
            A_OKAY -> {
                while (true) {
                    message = read()
                    val remoteId = message.arg0
                    if (message.command == A_WRTE) {
                        if (message.data_length > 0) {
                            listener?.invoke(message.data!!)
                        }
                        write(A_OKAY, localId, remoteId)
                    } else if (message.command == A_CLSE) {
                        write(A_CLSE, localId, remoteId)
                        break
                    } else {
                        error("not A_WRTE or A_CLSE")
                    }
                }
            }
            A_CLSE -> {
                val remoteId = message.arg0
                write(A_CLSE, localId, remoteId)
            }
            else -> {
                error("not A_OKAY or A_CLSE")
            }
        }
    }

    /** Feed a script through stdin, not a shell-quoted command-line wrapper. */
    fun executeScript(command: String, timeoutMs: Int = 30000): ShellV2Result {
        require(command.toByteArray().size <= 32768 && !command.contains('\u0000'))
        require(timeoutMs in 1000..600000)
        socket.soTimeout = timeoutMs + 3000
        if (useTls) tlsSocket.soTimeout = timeoutMs + 3000
        val decoder = ShellV2Decoder()
        val script = (command + "\n").toByteArray(Charsets.UTF_8)
        val queue = java.util.ArrayDeque<ByteArray>()
        var offset = 0
        while (offset < script.size) {
            val end = (offset + A_MAXDATA - 5).coerceAtMost(script.size)
            queue.add(shellFrame(0, script.copyOfRange(offset, end)))
            offset = end
        }
        queue.add(shellFrame(4)) // close stdin, preserving actual process exit.
        val localId = 1
        write(A_OPEN, localId, 0, "shell,v2,raw:/system/bin/sh")
        var opened = false
        while (true) {
            val packet = read()
            val remoteId = packet.arg0
            when (packet.command) {
                A_OKAY -> {
                    opened = true
                    if (queue.isNotEmpty()) write(A_WRTE, localId, remoteId, queue.removeFirst())
                }
                A_WRTE -> {
                    require(opened && packet.arg1 == localId)
                    decoder.feed(packet.data ?: byteArrayOf())
                    write(A_OKAY, localId, remoteId)
                }
                A_CLSE -> {
                    write(A_CLSE, localId, remoteId)
                    return decoder.result()
                }
                else -> error("Unexpected ADB shell packet")
            }
        }
    }

    private fun write(command: Int, arg0: Int, arg1: Int, data: ByteArray? = null) = write(AdbMessage(command, arg0, arg1, data))

    private fun write(command: Int, arg0: Int, arg1: Int, data: String) = write(AdbMessage(command, arg0, arg1, data))

    private fun write(message: AdbMessage) {
        outputStream.write(message.toByteArray())
        outputStream.flush()
    }

    private fun read(): AdbMessage {
        val buffer = ByteBuffer.allocate(AdbMessage.HEADER_LENGTH).order(ByteOrder.LITTLE_ENDIAN)

        inputStream.readFully(buffer.array(), 0, 24)

        val command = buffer.int
        val arg0 = buffer.int
        val arg1 = buffer.int
        val dataLength = buffer.int
        val checksum = buffer.int
        val magic = buffer.int
        val data: ByteArray?
        require(dataLength in 0..A_MAXDATA) { "Invalid ADB frame size" }
        if (dataLength >= 0) {
            data = ByteArray(dataLength)
            inputStream.readFully(data, 0, dataLength)
        } else {
            data = null
        }
        val message = AdbMessage(command, arg0, arg1, dataLength, checksum, magic, data)
        message.validateOrThrow()
        return message
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        try {
            plainInputStream.close()
        } catch (e: Throwable) {
        }
        try {
            plainOutputStream.close()
        } catch (e: Throwable) {
        }
        try {
            socket.close()
        } catch (e: Exception) {
        }

        if (useTls) {
            try {
                tlsInputStream.close()
            } catch (e: Throwable) {
            }
            try {
                tlsOutputStream.close()
            } catch (e: Throwable) {
            }
            try {
                tlsSocket.close()
            } catch (e: Exception) {
            }
        }
    }
}
