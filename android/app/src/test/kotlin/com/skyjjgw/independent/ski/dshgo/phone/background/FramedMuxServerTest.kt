package com.skyjjgw.independent.ski.dshgo.phone.background

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.io.FileDescriptor
import java.io.FileOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

class FramedMuxServerTest {
    private fun frames(vararg ids: Int) = ByteArrayOutputStream().also { out ->
        ids.forEach { Frames.write(out, byteArrayOf(it.toByte())) }
    }.toByteArray()

    @Test fun globalWaitsForCompleteReplyAndSuccessfulDestroyNeverAdmitsNextFrame() {
        val writing = CountDownLatch(1); val release = CountDownLatch(1)
        val globalRead = CountDownLatch(1); val readerThread = AtomicReference<Thread>()
        val globalCalls = AtomicInteger(); val decodes = AtomicInteger(); val aborts = AtomicInteger()
        val bytes = ByteArrayOutputStream()
        val output = object : OutputStream() {
            var first = true
            override fun write(b: Int) { bytes.write(b) }
            override fun flush() {
                if (first) { first = false; writing.countDown(); check(release.await(3, TimeUnit.SECONDS)) }
            }
        }
        val server = FramedMuxServer(ByteArrayInputStream(frames(1, 2, 3)), output,
            decode = { data -> val id = data.single().toLong(); decodes.incrementAndGet(); if (id == 2L) globalRead.countDown(); FramedMuxServer.Request(id, id, id == 2L) },
            handle = { id -> if (id == 2L) globalCalls.incrementAndGet(); id },
            encode = { _, value -> byteArrayOf(value.toByte()) }, terminal = { id, _ -> id == 2L },
            abort = { aborts.incrementAndGet() })
        val pool = Executors.newSingleThreadExecutor()
        try {
            val run = pool.submit { readerThread.set(Thread.currentThread()); server.run() }
            assertTrue(writing.await(3, TimeUnit.SECONDS)); assertTrue(globalRead.await(3, TimeUnit.SECONDS))
            val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
            while (readerThread.get().state != Thread.State.WAITING && System.nanoTime() < until) Thread.yield()
            assertEquals(Thread.State.WAITING, readerThread.get().state); assertEquals(0, globalCalls.get())
            release.countDown(); run.get(3, TimeUnit.SECONDS)
            assertEquals(1, globalCalls.get()); assertEquals(2, decodes.get()); assertEquals(0, aborts.get())
            val replies = ByteArrayInputStream(bytes.toByteArray())
            assertArrayEquals(byteArrayOf(1), Frames.read(replies)); assertArrayEquals(byteArrayOf(2), Frames.read(replies)); assertNull(Frames.read(replies))
        } finally { release.countDown(); pool.shutdownNow() }
    }

    @Test fun bodyFailureTriggersActualAbortCallbackOnce() {
        val abort = CountDownLatch(1); val aborts = AtomicInteger()
        val server = FramedMuxServer<Unit, Unit>(ByteArrayInputStream(frames(1)), ByteArrayOutputStream(),
            decode = { FramedMuxServer.Request(1, Unit, false) }, handle = { _: Unit -> throw IllegalStateException("device failure") },
            encode = { _: Long, _: Unit -> byteArrayOf() }, terminal = { _: Unit, _: Unit -> false },
            abort = { aborts.incrementAndGet(); abort.countDown() })
        server.run()
        assertTrue(abort.await(3, TimeUnit.SECONDS)); assertEquals(1, aborts.get())
    }

    @Test fun fileDescriptorWriteFailureAbortsBeforeTerminalOrNextFrame() {
        // Same throwing output class as Entry, without closing or writing the test runner's stdout.
        val output = FileOutputStream(FileDescriptor())
        val aborts = AtomicInteger(); val decodes = AtomicInteger(); val terminalCalls = AtomicInteger()
        val server = FramedMuxServer(ByteArrayInputStream(frames(1, 2)), output,
            decode = { data -> decodes.incrementAndGet(); FramedMuxServer.Request(data.single().toLong(), Unit, true) },
            handle = { Unit }, encode = { _, _ -> byteArrayOf(1) },
            terminal = { _, _ -> terminalCalls.incrementAndGet(); true },
            abort = { aborts.incrementAndGet() })
        try {
            server.run()
            assertEquals(1, aborts.get()); assertEquals(1, decodes.get()); assertEquals(0, terminalCalls.get())
        } finally { output.close() }
    }

}
