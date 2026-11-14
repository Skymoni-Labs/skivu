package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class RootBackendTest {
    @Test fun commandHasOneShellArgumentAndFixedEntrypoint() {
        val argv = RootCommands.appProcess("/data/app/base.apk", listOf("/data/app/split.apk"))
        assertEquals(3, argv.size)
        assertEquals(listOf("su", "-c"), argv.take(2))
        assertEquals("CLASSPATH='/data/app/base.apk:/data/app/split.apk' exec /system/bin/app_process /system/bin com.skyjjgw.independent.ski.dshgo.phone.background.PrivilegedDisplayMain", argv[2])
    }
    @Test fun shellQuotesOsPathsWithoutExecutingTheirContents() {
        val marker = File("root-command-${System.nanoTime()}.must-not-exist")
        val path = "/data/a' b\$(touch ${marker.path})`touch ${marker.path}`.apk"
        val assignment = PrivilegedCommands.appProcess(path).substringBefore(" exec ")
        // stdin keeps the same POSIX script intact through Windows CreateProcess quoting.
        val process = ProcessBuilder(System.getProperty("dshgo.test.shell", "/bin/sh")).start()
        process.outputStream.bufferedWriter().use { it.write("$assignment; printf '%s' \"\$CLASSPATH\"\n") }
        assertEquals(path, process.inputStream.bufferedReader().readText())
        assertEquals(0, process.waitFor())
        assertFalse(marker.exists())
    }
    @Test fun rejectsNonClasspathPaths() {
        for (path in listOf("relative.apk", "/data/a:b.apk", "/data/a\u0000b.apk")) {
            try { PrivilegedCommands.appProcess(path); fail(path) } catch (_: IllegalArgumentException) { }
        }
    }
    @Test fun rootProbeRequiresAllThreeFacts() {
        assertTrue(RootProbe.accepted(true, 0, "v1", "v1"))
        assertFalse(RootProbe.accepted(false, 0, "v1", "v1"))
        assertFalse(RootProbe.accepted(true, 2000, "v1", "v1"))
        assertFalse(RootProbe.accepted(true, 0, "old", "v1"))
        assertFalse(RootProbe.accepted(true, 0, null, "v1"))
    }
    @Test fun statusStartsUnknownAndReadDoesNotInitiatePreparation() {
        val state = RootState()
        repeat(3) { assertEquals(RootStatus(), state.status()) }
        assertNull(state.status().map()["available"])
        assertEquals(false, state.status().map()["starting"])
    }
    @Test fun cancelledQueuedActionCannotCreateStartupTicket() {
        val state = RootState()
        var gate = 1L
        val queuedTicket = gate
        gate++ // UI off runs after the caller's earlier check but before root admission.
        state.disconnect()
        assertNull(state.beginIfAllowed { queuedTicket == gate })
        assertEquals(RootStatus(), state.status())
    }
    @Test fun gateReadAndTicketCreationExcludeConcurrentDisconnect() {
        val state = RootState()
        val insidePredicate = java.util.concurrent.CountDownLatch(1)
        val allowAdmission = java.util.concurrent.CountDownLatch(1)
        val cancelStarted = java.util.concurrent.CountDownLatch(1)
        val ticket = AtomicReference<Long>()
        val starter = Thread {
            ticket.set(state.beginIfAllowed {
                insidePredicate.countDown()
                check(allowAdmission.await(2, TimeUnit.SECONDS))
                true
            })
        }
        starter.start(); assertTrue(insidePredicate.await(2, TimeUnit.SECONDS))
        val canceller = Thread { cancelStarted.countDown(); state.disconnect() }
        canceller.start(); assertTrue(cancelStarted.await(2, TimeUnit.SECONDS))
        allowAdmission.countDown(); starter.join(2000); canceller.join(2000)
        assertFalse(starter.isAlive); assertFalse(canceller.isAlive)
        assertNotNull(ticket.get())
        assertFalse(state.current(ticket.get()))
        assertFalse(state.finish(ticket.get(), null))
        assertFalse(state.status().connected)
    }
    @Test fun explicitStartSuccessAndDisconnectNeverReconnect() {
        val state = RootState(); val ticket = state.begin()
        assertTrue(state.status().starting)
        assertTrue(state.finish(ticket, null))
        assertEquals(RootStatus(checked = true, available = true, connected = true), state.status())
        state.disconnect()
        repeat(3) { assertFalse(state.status().connected); assertEquals("rootDisconnected", state.status().reasonCode) }
        assertEquals(true, state.status().available)
    }
    @Test fun lateProbeCannotResurrectCancelledStartup() {
        val state = RootState(); val first = state.begin(); state.disconnect()
        assertFalse(state.current(first)); assertFalse(state.finish(first, null))
        val second = state.begin()
        assertFalse(state.finish(first, null))
        assertTrue(state.finish(second, "rootTimeout"))
        assertEquals(false, state.status().available)
    }
    @Test fun grantFailureDoesNotInventLostRootPermission() {
        val state = RootState(); state.finish(state.begin(), null); state.note("rootGrantFailed")
        assertTrue(state.status().connected); assertEquals(true, state.status().available)
    }
    @Test fun actualJvmProcessExchangesBinaryFramesAndDrainsStderr() {
        val captured = AtomicReference<Process>()
        val channel = launch("echo", captured)
        val payload = ByteArray(4096) { it.toByte() }
        try {
            assertArrayEquals(payload, channel.exchange(payload, 3000))
            assertArrayEquals(byteArrayOf(0, 10, 13, -1), channel.exchange(byteArrayOf(0, 10, 13, -1), 3000))
            assertTrue(channel.alive())
        } finally { channel.close() }
        awaitExit(captured.get())
    }
    @Test fun actualJvmTimeoutReturnsBoundedlyAndDestroysChild() {
        val captured = AtomicReference<Process>(); val channel = launch("hang", captured)
        val started = System.nanoTime()
        try { channel.exchange(byteArrayOf(1), 120); fail() }
        catch (error: IOException) { assertEquals("rootTimeout", error.message) }
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 2000)
        assertFalse(channel.alive()); awaitExit(captured.get())
    }
    @Test fun realInvalidFrameClosesWithoutExposingChildOutput() {
        val captured = AtomicReference<Process>(); val channel = launch("bad-frame", captured)
        try { channel.exchange(byteArrayOf(1), 3000); fail() }
        catch (error: IOException) { assertEquals("rootStartFailed", error.message); assertNull(error.cause) }
        awaitExit(captured.get())
    }
    @Test fun missingExecutableBecomesFixedReasonOnly() {
        try { RootProcess.launch(listOf("/synthetic/does-not-exist")); fail() }
        catch (error: IOException) { assertEquals("rootStartFailed", error.message); assertNull(error.cause) }
    }
    @Test fun explicitCloseUnblocksPendingReadWithoutWaitingForDeadline() {
        val captured = AtomicReference<Process>(); val channel = launch("hang", captured)
        val failure = AtomicReference<Exception>()
        val reader = Thread { try { channel.exchange(byteArrayOf(1), 5000) } catch (e: Exception) { failure.set(e) } }
        reader.start(); Thread.sleep(100); channel.close(); reader.join(2000)
        assertFalse(reader.isAlive); assertNotNull(failure.get()); awaitExit(captured.get())
    }
    @Test fun interruptionReturnsCancelledAndClosesActualChild() {
        val captured = AtomicReference<Process>(); val channel = launch("hang", captured)
        val reason = AtomicReference<String>(); val interrupted = AtomicReference<Boolean>()
        val reader = Thread {
            try { channel.exchange(byteArrayOf(1), 5000) }
            catch (error: IOException) { reason.set(error.message); interrupted.set(Thread.currentThread().isInterrupted) }
        }
        reader.start(); Thread.sleep(100); reader.interrupt(); reader.join(2000)
        assertFalse(reader.isAlive); assertEquals("rootCancelled", reason.get()); assertEquals(true, interrupted.get())
        awaitExit(captured.get())
    }
    private fun launch(mode: String, captured: AtomicReference<Process> = AtomicReference()): RootProcess =
        RootProcess.launch(childCommand(mode)) { ProcessBuilder(it).start().also(captured::set) }
    private fun childCommand(mode: String): List<String> = listOf(
        File(System.getProperty("java.home"), if(System.getProperty("os.name").startsWith("Windows")) "bin/java.exe" else "bin/java").path,
        "-cp", listOf(RootProcessChild::class.java,Frames::class.java,kotlin.Unit::class.java)
            .map{File(it.protectionDomain.codeSource.location.toURI()).path}.distinct().joinToString(File.pathSeparator),
        RootProcessChild::class.java.name, mode,
    )
    private fun awaitExit(process: Process) { assertTrue("owned child must exit", process.waitFor(3, TimeUnit.SECONDS)) }
}

/** A real JVM subprocess. It uses the exact production Frames class, never a Python stand-in. */
object RootProcessChild {
    @JvmStatic fun main(args: Array<String>) {
        when (args.single()) {
            "hang" -> Thread.sleep(60_000)
            "echo" -> {
                System.err.write(ByteArray(256 * 1024) { 'S'.code.toByte() }); System.err.flush()
                System.out.write(Frames.MAGIC); System.out.flush()
                while (true) { val value = Frames.read(System.`in`) ?: break; Frames.write(System.out, value) }
            }
            "bad-frame" -> {
                System.err.print("PRIVATE_DIAGNOSTIC_NOT_A_REASON")
                System.out.write(Frames.MAGIC); System.out.write(byteArrayOf(-1, -1, -1, -1)); System.out.flush()
            }
        }
    }
}
