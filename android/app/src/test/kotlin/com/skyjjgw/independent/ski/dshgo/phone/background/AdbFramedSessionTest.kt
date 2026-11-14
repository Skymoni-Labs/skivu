package com.skyjjgw.independent.ski.dshgo.phone.background

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Real production Frames + session; no Android Bundle/transport substitute. */
class AdbFramedSessionTest {
    @After fun junitThreadIsNotInterrupted() { assertFalse(Thread.currentThread().isInterrupted) }

    private fun frame(value: ByteArray): ByteArray = ByteArrayOutputStream().also { Frames.write(it, value) }.toByteArray()
    private fun bytes(value: String) = value.toByteArray(Charsets.UTF_8)
    private fun await(latch: CountDownLatch) { assertTrue("latch did not complete", latch.await(3, TimeUnit.SECONDS)) }
    private fun join(thread: Thread) { thread.join(3000); assertFalse("worker did not finish", thread.isAlive) }
    private fun worker(block: () -> Unit) = Thread(block, "session-test").apply { isDaemon = true; start() }
    private fun expectIo(block: () -> Unit): IOException {
        try { block(); fail("expected IOException") } catch (error: IOException) { return error }
        error("unreachable")
    }

    private class CountingOutput : OutputStream() {
        private val data = ByteArrayOutputStream()
        @Synchronized override fun write(value: Int) { data.write(value) }
        @Synchronized override fun write(value: ByteArray, offset: Int, length: Int) { data.write(value, offset, length) }
        @Synchronized fun snapshot(): ByteArray = data.toByteArray()
    }

    /** Models the documented IOException(cause=InterruptedException) boundary, not an ADB implementation. */
    private class BlockingTail(prefix: ByteArray) : InputStream() {
        private val prefix = ByteArrayInputStream(prefix)
        val waiting = CountDownLatch(1)
        val finish = CountDownLatch(1)
        override fun read(): Int {
            val value = prefix.read()
            if (value >= 0) return value
            waiting.countDown()
            try { finish.await() } catch (cause: InterruptedException) { throw IOException("test read interrupted", cause) }
            return -1
        }
        override fun read(value: ByteArray, offset: Int, length: Int): Int {
            if (prefix.available() > 0) return prefix.read(value, offset, length)
            return read()
        }
    }

    @Test fun healthyMultipleRoundsKeepFramesPairedAndCloseWritesNoDestroy() {
        val output = CountingOutput(); val closed = CountDownLatch(1)
        val input = ByteArrayInputStream(bytes("startup noise") + Frames.MAGIC + frame(bytes("a")) + frame(bytes("b")))
        val session = AdbFramedSession(input, output, { true }, { closed.countDown() })
        assertArrayEquals(bytes("a"), session.exchange(bytes("one")))
        assertArrayEquals(bytes("b"), session.exchange(bytes("two")))
        assertTrue(session.alive())
        val written = output.snapshot(); val requests = ByteArrayInputStream(written)
        assertArrayEquals(bytes("one"), Frames.read(requests)); assertArrayEquals(bytes("two"), Frames.read(requests)); assertNull(Frames.read(requests))
        session.close(); await(closed)
        assertArrayEquals(written, output.snapshot()); assertFalse(session.alive())
    }

    @Test fun concurrentRequestsWaitForThePreviousResponse() {
        val input = PipedInputStream(1024); val peer = PipedOutputStream(input); val output = CountingOutput()
        peer.write(Frames.MAGIC); peer.flush()
        val firstWritten = CountDownLatch(1)
        val notifying = object : OutputStream() {
            override fun write(value: Int) { output.write(value) }
            override fun write(value: ByteArray, offset: Int, length: Int) { output.write(value, offset, length) }
            override fun flush() { firstWritten.countDown() }
        }
        val session = AdbFramedSession(input, notifying, { true }, { input.close() })
        val a = AtomicReference<ByteArray?>(); val b = AtomicReference<ByteArray?>(); val failure = AtomicReference<Throwable?>()
        // PipedInputStream remembers its last reader: keep it alive until the next read
        // takes ownership, otherwise the fixture itself reports "Read end dead".
        val firstReturned = CountDownLatch(1); val firstMayExit = CountDownLatch(1)
        val first = worker {
            try { a.set(session.exchange(bytes("A"))) } catch (e: Throwable) { failure.set(e) }
            finally { firstReturned.countDown() }
            firstMayExit.await()
        }
        await(firstWritten)
        val secondEntered = CountDownLatch(1)
        val second = worker { secondEntered.countDown(); try { b.set(session.exchange(bytes("B"))) } catch (e: Throwable) { failure.set(e) } }
        await(secondEntered)
        try {
            // The first exchange holds the monitor while the actual pipe has no response.
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
            while (second.state != Thread.State.BLOCKED && System.nanoTime() < deadline) Thread.yield()
            assertEquals(Thread.State.BLOCKED, second.state)
            assertArrayEquals(frame(bytes("A")), output.snapshot())
            peer.write(frame(bytes("response A"))); peer.flush(); await(firstReturned)
            peer.write(frame(bytes("response B"))); peer.flush(); join(second); firstMayExit.countDown(); join(first)
            assertNull(failure.get()); assertArrayEquals(bytes("response A"), a.get()); assertArrayEquals(bytes("response B"), b.get())
            assertArrayEquals(frame(bytes("A")) + frame(bytes("B")), output.snapshot())
        } finally { firstMayExit.countDown(); session.close(); peer.close(); input.close(); first.interrupt(); second.interrupt(); join(first); join(second) }
    }

    @Test fun muxRequestWithoutReplyRetiresAtItsDeadlineWhileTheStreamStaysOpen() {
        val input = PipedInputStream(1024); val peer = PipedOutputStream(input)
        peer.write(Frames.MAGIC + frame(bytes("probe reply"))); peer.flush()
        val retired = CountDownLatch(1); val closed = CountDownLatch(1)
        val session = AdbFramedSession(input, CountingOutput(), { true }, { closed.countDown() })
        assertArrayEquals(bytes("probe reply"), session.exchange(bytes("probe")))
        val mux = session.installMux("peer", { retired.countDown() }, deadlineMs = 100)
        val failure = AtomicReference<Throwable?>()
        // Binary request bytes stand in for the Bundle codec; no reply is ever written and the pipe stays open.
        val caller = worker { try { mux.exchange { id -> bytes("request $id") } } catch (error: Throwable) { failure.set(error) } }
        try {
            join(caller); assertTrue(failure.get() is IOException)
            await(retired); await(closed); assertFalse(session.alive()); assertFalse(mux.alive())
        } finally { session.close(); peer.close(); input.close(); join(caller) }
    }

    @Test fun eofBeforeMagicRetiresWithoutWriting() {
        val output = CountingOutput(); val session = AdbFramedSession(ByteArrayInputStream(bytes("noise")), output, { true }, {})
        assertNull(session.exchange(bytes("one"))); assertFalse(session.alive()); assertNull(session.exchange(bytes("two")))
        assertEquals(0, output.snapshot().size)
    }

    @Test fun cleanResponseEofRetiresAndNextExchangeDoesNotWrite() {
        val output = CountingOutput(); val session = AdbFramedSession(ByteArrayInputStream(Frames.MAGIC), output, { true }, {})
        assertNull(session.exchange(bytes("one"))); val before = output.snapshot()
        assertFalse(session.alive()); assertNull(session.exchange(bytes("two"))); assertArrayEquals(before, output.snapshot())
    }

    @Test fun partialHeaderEofRetires() { assertMalformed(Frames.MAGIC + byteArrayOf(0, 0)) }
    @Test fun partialBodyEofRetires() { assertMalformed(Frames.MAGIC + byteArrayOf(0, 0, 0, 4, 1, 2)) }
    @Test fun invalidFrameLengthRetires() { assertMalformed(Frames.MAGIC + byteArrayOf(0x7f, -1, -1, -1)) }

    private fun assertMalformed(data: ByteArray) {
        val output = CountingOutput(); val session = AdbFramedSession(ByteArrayInputStream(data), output, { true }, {})
        expectIo { session.exchange(bytes("one")) }; val before = output.snapshot()
        assertFalse(session.alive()); assertNull(session.exchange(bytes("two"))); assertArrayEquals(before, output.snapshot())
    }

    @Test fun writeFailureIsRethrownUnchangedAndCannotBeRetried() {
        val original = IOException("deliberate output failure"); val calls = AtomicInteger()
        val output = object : OutputStream() { override fun write(value: Int) { calls.incrementAndGet(); throw original } }
        val session = AdbFramedSession(ByteArrayInputStream(Frames.MAGIC), output, { true }, {})
        assertSame(original, expectIo { session.exchange(bytes("one")) }); val count = calls.get()
        assertFalse(session.alive()); assertNull(session.exchange(bytes("two"))); assertEquals(count, calls.get())
    }

    @Test fun wrappedReadInterruptionRestoresWorkerFlagAndRetires() { interruptAt(Frames.MAGIC) }
    @Test fun interruptionAfterPartialHeaderCannotReusePosition() { interruptAt(Frames.MAGIC + byteArrayOf(0, 0)) }
    @Test fun interruptionAfterPartialBodyCannotReusePosition() { interruptAt(Frames.MAGIC + byteArrayOf(0, 0, 0, 4, 1, 2)) }

    private fun interruptAt(prefix: ByteArray) {
        val input = BlockingTail(prefix); val output = CountingOutput(); val closed = CountDownLatch(1)
        val session = AdbFramedSession(input, output, { true }, { closed.countDown() })
        val thrown = AtomicReference<Throwable?>(); val interrupted = AtomicBoolean()
        val reader = worker { try { session.exchange(bytes("A")) } catch (error: Throwable) { thrown.set(error); interrupted.set(Thread.currentThread().isInterrupted) } }
        val successorEntered = CountDownLatch(1); val successorResult = AtomicReference<ByteArray?>()
        val successorFailure = AtomicReference<Throwable?>(); var successor: Thread? = null
        try {
            await(input.waiting); val before = output.snapshot()
            // A cleanup caller may have observed alive=true before A handles interruption.
            // Its B exchange must recheck logical liveness after acquiring A's monitor.
            successor = worker {
                successorEntered.countDown()
                try { successorResult.set(session.exchange(bytes("B"))) } catch (error: Throwable) { successorFailure.set(error) }
            }
            await(successorEntered)
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
            while (successor.state != Thread.State.BLOCKED && System.nanoTime() < deadline) Thread.yield()
            assertEquals(Thread.State.BLOCKED, successor.state)
            reader.interrupt(); join(reader); join(successor); await(closed)
            assertTrue(thrown.get() is IOException); assertTrue(thrown.get()?.cause is InterruptedException); assertTrue(interrupted.get())
            assertFalse(session.alive()); assertNull(successorFailure.get()); assertNull(successorResult.get())
            assertArrayEquals(before, output.snapshot())
            assertNull(session.exchange(bytes("C"))); assertArrayEquals(before, output.snapshot())
        } finally { input.finish.countDown(); reader.interrupt(); successor?.interrupt(); join(reader); successor?.let(::join) }
    }

    @Test fun actualPipedReadInterruptedCannotBeReused() {
        val input = PipedInputStream(1024); val peer = PipedOutputStream(input); peer.write(Frames.MAGIC); peer.flush()
        val output = CountingOutput(); val session = AdbFramedSession(input, output, { true }, { input.close() })
        val thrown = AtomicReference<Throwable?>()
        val reader = worker { try { session.exchange(bytes("A")) } catch (error: Throwable) { thrown.set(error) } }
        try {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
            while (output.snapshot().isEmpty() && System.nanoTime() < deadline) Thread.yield()
            assertFalse(output.snapshot().isEmpty()); reader.interrupt(); join(reader)
            assertTrue(thrown.get() is IOException); assertFalse(session.alive())
            val before = output.snapshot(); assertNull(session.exchange(bytes("B"))); assertArrayEquals(before, output.snapshot())
        } finally { peer.close(); input.close(); reader.interrupt(); join(reader) }
    }

    @Test fun closeDoesNotWaitForReaderAndLateResponseIsDiscarded() {
        val waiting = CountDownLatch(1); val allow = CountDownLatch(1)
        val all = ByteArrayInputStream(Frames.MAGIC + frame(bytes("late A")))
        val input = object : InputStream() {
            var readCount = 0
            override fun read(): Int {
                if (readCount++ == Frames.MAGIC.size) { waiting.countDown(); allow.await() }
                return all.read()
            }
        }
        val session = AdbFramedSession(input, CountingOutput(), { true }, {})
        val response = AtomicReference<ByteArray?>(); val failure = AtomicReference<Throwable?>()
        val reader = worker { try { response.set(session.exchange(bytes("A"))) } catch (e: Throwable) { failure.set(e) } }
        try {
            await(waiting)
            val done = CountDownLatch(1); val closer = worker { session.close(); done.countDown() }
            await(done); join(closer); assertFalse(session.alive()); assertTrue(reader.isAlive)
            allow.countDown(); join(reader); assertNull(failure.get()); assertNull(response.get())
            assertNull(session.exchange(bytes("B")))
        } finally { allow.countDown(); reader.interrupt(); join(reader) }
    }

    @Test fun slowTransportCloseRunsOnceOnDaemonWithoutBlockingCaller() {
        val entered = CountDownLatch(1); val allow = CountDownLatch(1); val finished = CountDownLatch(1)
        val closes = AtomicInteger(); val daemon = AtomicBoolean()
        val session = AdbFramedSession(ByteArrayInputStream(byteArrayOf()), CountingOutput(), { true }, {
            closes.incrementAndGet(); daemon.set(Thread.currentThread().isDaemon); entered.countDown()
            try { allow.await() } finally { finished.countDown() }
        })
        val returned = CountDownLatch(1); val closer = worker { repeat(20) { session.close() }; returned.countDown() }
        try {
            await(entered); await(returned); join(closer)
            assertEquals(1, closes.get()); assertTrue(daemon.get()); assertFalse(session.alive()); assertEquals(1L, finished.count)
            assertNull(session.exchange(bytes("never written")))
        } finally { allow.countDown(); await(finished) }
    }

    @Test fun deadTransportSkipsAllReadsAndWritesAndClosesOnce() {
        val reads = AtomicInteger(); val writes = AtomicInteger(); val closes = AtomicInteger(); val closed = CountDownLatch(1)
        val input = object : InputStream() { override fun read(): Int { reads.incrementAndGet(); error("read dead transport") } }
        val output = object : OutputStream() { override fun write(value: Int) { writes.incrementAndGet(); error("write dead transport") } }
        val session = AdbFramedSession(input, output, { false }, { closes.incrementAndGet(); closed.countDown() })
        assertNull(session.exchange(bytes("A"))); await(closed); session.close(); assertNull(session.exchange(bytes("B")))
        assertEquals(0, reads.get()); assertEquals(0, writes.get()); assertEquals(1, closes.get())
    }

    @Test fun explicitCloseBeforeFirstExchangeSkipsTransportAndBytes() {
        val reads = AtomicInteger(); val input = object : InputStream() { override fun read(): Int { reads.incrementAndGet(); return -1 } }
        val output = CountingOutput(); val session = AdbFramedSession(input, output, { true }, {})
        session.close(); assertFalse(session.alive()); assertNull(session.exchange(bytes("A")))
        assertEquals(0, reads.get()); assertEquals(0, output.snapshot().size)
    }
}
