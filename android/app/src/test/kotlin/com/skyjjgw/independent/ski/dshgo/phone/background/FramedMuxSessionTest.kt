package com.skyjjgw.independent.ski.dshgo.phone.background

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

/** Tests production framing/reader/pending state. This binary test codec is not an Android Bundle stub. */
class FramedMuxSessionTest {
    private fun encode(id: Long, text: String): ByteArray = ByteArrayOutputStream().also { out ->
        DataOutputStream(out).apply { writeLong(id); writeUTF(text) }
    }.toByteArray()
    private fun decode(bytes: ByteArray): FramedMuxSession.Reply<String> = DataInputStream(ByteArrayInputStream(bytes)).let {
        FramedMuxSession.Reply(it.readLong(), it.readUTF())
    }
    private class Pipes : AutoCloseable {
        val requests = PipedInputStream(4096); val output = PipedOutputStream(requests)
        val input = PipedInputStream(4096); val replies = PipedOutputStream(input)
        override fun close() { runCatching { requests.close() }; runCatching { output.close() }; runCatching { input.close() }; runCatching { replies.close() } }
    }
    @Test(timeout = 10_000) fun actualSingleReaderCorrelatesOutOfOrderReplies() {
        Pipes().use { p ->
            val closed = CountDownLatch(1)
            val session = FramedMuxSession(p.input, p.output, ::decode, { p.close(); closed.countDown() })
            val pool = Executors.newFixedThreadPool(2); session.start()
            try {
                val a = pool.submit<String> { session.exchange { encode(it, "A") } }
                val b = pool.submit<String> { session.exchange { encode(it, "B") } }
                val first = decode(Frames.read(p.requests)!!); val second = decode(Frames.read(p.requests)!!)
                Frames.write(p.replies, encode(second.id, second.value + " reply"))
                Frames.write(p.replies, encode(first.id, first.value + " reply"))
                assertEquals("A reply", a.get(3, TimeUnit.SECONDS)); assertEquals("B reply", b.get(3, TimeUnit.SECONDS))
                assertTrue(session.alive())
            } finally { session.close(); pool.shutdownNow(); assertTrue(closed.await(3, TimeUnit.SECONDS)) }
        }
    }

    @Test(timeout = 10_000) fun unknownReplyRetiresAllPendingWithoutReplay() {
        Pipes().use { p ->
            val session = FramedMuxSession(p.input, p.output, ::decode, p::close)
            val pool = Executors.newFixedThreadPool(2); session.start()
            try {
                val calls = (1..2).map { n -> pool.submit<Boolean> {
                    try { session.exchange { encode(it, "$n") }; false } catch (_: IOException) { true }
                } }
                repeat(2) { assertNotNull(Frames.read(p.requests)) }
                Frames.write(p.replies, encode(999, "unknown"))
                calls.forEach { assertTrue(it.get(3, TimeUnit.SECONDS)) }; assertFalse(session.alive())
            } finally { session.close(); pool.shutdownNow() }
        }
    }

    @Test(timeout = 10_000) fun interruptedCallerDrainsItsSameReplyAndRestoresInterrupt() {
        Pipes().use { p ->
            val session = FramedMuxSession(p.input, p.output, ::decode, p::close); session.start()
            val result = AtomicReference<String>(); val interrupted = AtomicBoolean()
            val caller = Thread { result.set(session.exchange { encode(it, "one") }); interrupted.set(Thread.currentThread().isInterrupted) }
            try {
                caller.start(); val request = decode(Frames.read(p.requests)!!)
                caller.interrupt(); Frames.write(p.replies, encode(request.id, "actual reply"))
                caller.join(3000); assertFalse(caller.isAlive)
                assertEquals("actual reply", result.get()); assertTrue(interrupted.get()); assertTrue(session.alive())
            } finally { session.close(); caller.join(3000) }
        }
    }

    @Test(timeout = 10_000) fun blockedWriterDoesNotPreventCloseOrPendingFailure() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val output = object : OutputStream() { override fun write(b: Int) { entered.countDown(); release.await() } }
        val input = PipedInputStream(1024); val peer = PipedOutputStream(input)
        val session = FramedMuxSession(input, output, ::decode, { input.close(); release.countDown() }); session.start()
        val pool = Executors.newSingleThreadExecutor()
        try {
            val call = pool.submit<Boolean> { try { session.exchange { encode(it, "one") }; false } catch (_: IOException) { true } }
            assertTrue(entered.await(3, TimeUnit.SECONDS)); session.close()
            assertTrue(call.get(3, TimeUnit.SECONDS)); assertFalse(session.alive())
        } finally { release.countDown(); session.close(); peer.close(); pool.shutdownNow() }
    }
}
