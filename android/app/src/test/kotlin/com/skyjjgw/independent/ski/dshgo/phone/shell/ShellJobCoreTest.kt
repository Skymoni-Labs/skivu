package com.skyjjgw.independent.ski.dshgo.phone.shell

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class ShellJobCoreTest {
    private class Child(out: ByteArray = byteArrayOf(), err: ByteArray = byteArrayOf(), val exit: Int = 0,
                        val waitUntilKilled: Boolean = false) : ShellOwnedProcess {
        val killed = CountDownLatch(1)
        val drained = CountDownLatch(2)
        val prepared = CountDownLatch(1)
        val prepareCalls = AtomicInteger()
        val outBytes = AtomicInteger()
        val errBytes = AtomicInteger()
        val closed = AtomicInteger()
        private fun stream(bytes: ByteArray, counter: AtomicInteger) = object : ByteArrayInputStream(bytes) {
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                val n = super.read(b, off, len)
                if (n < 0) drained.countDown() else counter.addAndGet(n)
                return n
            }
        }
        override val stdout = stream(out, outBytes)
        override val stderr = stream(err, errBytes)
        override fun prepare(): Boolean { prepareCalls.incrementAndGet(); prepared.countDown(); return true }
        override fun waitFor(): Int {
            if (waitUntilKilled) check(killed.await(5, TimeUnit.SECONDS))
            else check(drained.await(5, TimeUnit.SECONDS))
            return exit
        }
        override fun terminate() { killed.countDown() }
        override fun close() { closed.incrementAndGet() }
    }

    private fun finished(core: ShellJobCore, id: String = "job"): Map<String, Any?> {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (System.nanoTime() < deadline) {
            val result = core.poll(id)
            if (result["done"] == true) return result
            Thread.sleep(5)
        }
        fail("job did not finish")
        return emptyMap()
    }

    @Test fun preservesBothStreamsAndNonzeroExit() {
        val child = Child("hello".toByteArray(), "failure".toByteArray(), exit = 7)
        val core = ShellJobCore { _, _ -> child }
        try {
            core.start("job", "command", 1000)
            val result = finished(core)
            assertEquals("hello", result["stdout"])
            assertEquals("failure", result["stderr"])
            assertEquals(7, result["exitCode"])
            assertEquals(true, result["started"])
            assertEquals(false, result["truncated"])
        } finally { core.destroy() }
    }

    @Test fun sharedOutputBudgetStillDrainsBothStreams() {
        val child = Child(ByteArray(100_000) { 65 }, ByteArray(100_000) { 66 })
        val core = ShellJobCore { _, _ -> child }
        try {
            core.start("job", "command", 2000)
            val result = finished(core)
            assertEquals(ShellProtocol.MAX_OUTPUT_BYTES, (result["stdout"] as String).length + (result["stderr"] as String).length)
            assertEquals(true, result["truncated"])
            assertEquals(100_000, child.outBytes.get())
            assertEquals(100_000, child.errBytes.get())
        } finally { core.destroy() }
    }

    @Test fun invalidUtf8DoesNotExpandTheByteBudget() {
        val child = Child(ByteArray(70_000) { 0xff.toByte() })
        val core = ShellJobCore { _, _ -> child }
        try {
            core.start("job", "command", 2000)
            val text = finished(core)["stdout"] as String
            assertEquals(65_536, text.toByteArray(Charsets.UTF_8).size)
            assertFalse(text.contains('\ufffd'))
        } finally { core.destroy() }
    }

    @Test fun onlyOneOwnedJobAtATime() {
        val child = Child(waitUntilKilled = true)
        val core = ShellJobCore { _, _ -> child }
        try {
            core.start("job", "command", 2000)
            assertTrue(child.prepared.await(1, TimeUnit.SECONDS))
            assertEquals("busy", core.start("other", "command", 1000)["errorCode"])
            core.cancel("job")
            assertEquals(true, finished(core)["cancelled"])
        } finally { core.destroy() }
    }

    @Test fun cancelReallyTerminatesTheOwnedProcess() {
        val child = Child(waitUntilKilled = true)
        val core = ShellJobCore { _, _ -> child }
        try {
            core.start("job", "command", 2000)
            assertTrue(child.prepared.await(1, TimeUnit.SECONDS))
            core.cancel("job")
            assertTrue(child.killed.await(1, TimeUnit.SECONDS))
            val result = finished(core)
            assertEquals(true, result["cancelled"])
            assertEquals("cancelled", result["errorCode"])
            assertEquals(false, result["timedOut"])
        } finally { core.destroy() }
    }

    @Test fun cancelAnotherIdDoesNotKillCurrentProcess() {
        val child = Child(waitUntilKilled = true)
        val core = ShellJobCore { _, _ -> child }
        try {
            core.start("job", "command", 2000)
            assertTrue(child.prepared.await(1, TimeUnit.SECONDS))
            core.cancel("other")
            assertEquals(1L, child.killed.count)
            core.cancel("job")
            finished(core)
        } finally { core.destroy() }
    }

    @Test fun timeoutTerminatesInsteadOfOnlyDroppingTheReply() {
        val child = Child(waitUntilKilled = true)
        val core = ShellJobCore { _, _ -> child }
        try {
            core.start("job", "command", 150)
            val result = finished(core)
            assertEquals(0L, child.killed.count)
            assertEquals(true, result["timedOut"])
            assertEquals("timeout", result["errorCode"])
        } finally { core.destroy() }
    }

    @Test fun replayOfTheSameJobIdDoesNotExecuteAgain() {
        val launches = AtomicInteger()
        val core = ShellJobCore { _, _ -> launches.incrementAndGet(); Child() }
        try {
            core.start("job", "command", 1000)
            finished(core)
            core.start("job", "different command", 1000)
            assertEquals(1, launches.get())
        } finally { core.destroy() }
    }

    @Test fun cancelBeforeStartRejectsLateRequest() {
        val launches = AtomicInteger()
        val core = ShellJobCore { _, _ -> launches.incrementAndGet(); Child() }
        try {
            core.cancel("job")
            assertEquals("cancelled", core.start("job", "command", 1000)["errorCode"])
            assertEquals(0, launches.get())
        } finally { core.destroy() }
    }

    @Test fun cancellationDuringLaunchNeverApprovesPrepare() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val child = Child(waitUntilKilled = true)
        val core = ShellJobCore { _, _ -> entered.countDown(); check(release.await(2, TimeUnit.SECONDS)); child }
        try {
            core.start("job", "command", 2000)
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            core.cancel("job")
            release.countDown()
            val result = finished(core)
            assertEquals(false, result["started"])
            assertEquals(0, child.prepareCalls.get())
            assertEquals(0L, child.killed.count)
        } finally { release.countDown(); core.destroy() }
    }

    @Test fun destroyCancelsAndRejectsNewWork() {
        val child = Child(waitUntilKilled = true)
        val core = ShellJobCore { _, _ -> child }
        core.start("job", "command", 2000)
        assertTrue(child.prepared.await(1, TimeUnit.SECONDS))
        core.destroy()
        assertEquals(true, finished(core)["cancelled"])
        assertEquals("notConnected", core.start("new", "command", 1000)["errorCode"])
    }

    @Test fun launchFailureIsSafeAndReleasesSingleJobSlot() {
        val core = ShellJobCore { _, _ -> throw IllegalStateException("sensitive command not returned") }
        try {
            core.start("job", "command", 1000)
            val result = finished(core)
            assertEquals("executionFailed", result["errorCode"])
            assertEquals(false, result["started"])
            assertEquals("", result["stderr"])
            assertEquals(true, core.start("next", "command", 1000)["ok"])
            finished(core, "next")
        } finally { core.destroy() }
    }

    @Test fun invalidInputsNeverReachLauncher() {
        val launches = AtomicInteger()
        val core = ShellJobCore { _, _ -> launches.incrementAndGet(); Child() }
        try {
            assertEquals("invalidArguments", core.start("../bad", "command", 1000)["errorCode"])
            assertEquals("invalidCommand", core.start("job", "\u0000", 1000)["errorCode"])
            assertEquals("invalidTimeout", core.start("job", "command", 60_001)["errorCode"])
            assertEquals(0, launches.get())
        } finally { core.destroy() }
    }

    @Test fun completedSnapshotIsStable() {
        val core = ShellJobCore { _, _ -> Child("done".toByteArray()) }
        try {
            core.start("job", "command", 1000)
            val first = finished(core)
            assertEquals(first, core.poll("job"))
            core.cancel("job")
            assertEquals(first, core.poll("job"))
        } finally { core.destroy() }
    }

    @Test fun unfinishedPipeIsReportedAndCannotMutateDoneSnapshot() {
        val release = CountDownLatch(1)
        val lateRead = CountDownLatch(1)
        val child = object : ShellOwnedProcess {
            override val stdout = object : InputStream() {
                override fun read(): Int = -1
                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    release.await()
                    b[off] = 65
                    lateRead.countDown()
                    return 1
                }
            }
            override val stderr = ByteArrayInputStream(byteArrayOf())
            override fun waitFor(): Int = 0
            override fun terminate() {}
            override fun close() {}
        }
        val core = ShellJobCore { _, _ -> child }
        try {
            core.start("job", "command", 3000)
            val result = finished(core)
            assertEquals("outputIncomplete", result["errorCode"])
            assertEquals(true, result["truncated"])
            release.countDown()
            assertTrue(lateRead.await(1, TimeUnit.SECONDS))
            assertEquals(result, core.poll("job"))
            assertEquals("notConnected", core.start("new", "command", 1000)["errorCode"])
        } finally { release.countDown(); core.destroy() }
    }

    @Test fun unknownJobHasStableError() {
        val core = ShellJobCore { _, _ -> Child() }
        try { assertEquals("jobNotFound", core.poll("unknown")["errorCode"]) }
        finally { core.destroy() }
    }
}
