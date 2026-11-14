package com.skyjjgw.independent.ski.dshgo.phone

import java.time.ZoneId
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.*
import org.junit.Test

/** Real parser, Core, Tasks and session admission; only native execution and UI are fakes. */
class PhoneAndroidShellTest {
    private class Fixture : AutoCloseable {
        val tasks = PhoneTasks()
        val log = ActionLog()
        var enabled = true
        var locked = false
        var gateAvailable = true
        var backendAvailable = true
        var backend = "shizuku"
        var uid = 2000
        var policies = PhonePolicies()
        var decision = Decision.ALLOW_ONCE
        var beforeConfirm: () -> Unit = {}
        var onConfirm: (ConfirmRequest) -> Unit = {}
        var afterConfirm: () -> Unit = {}
        var result: Map<String, Any?> = receipt()
        var executorCalls = 0
        var dispatches = 0
        var capturedOwner: Long? = null
        var capturedCommand: String? = null
        var capturedTimeout: Long? = null
        var capturedLive: (() -> Boolean)? = null
        val asks = mutableListOf<ConfirmRequest>()
        val statuses = mutableListOf<String?>()
        val executor = PhoneShellExecutor { ownerId, command, timeoutMs, stillWanted, confirm ->
            executorCalls++
            capturedOwner = ownerId
            capturedCommand = command
            capturedTimeout = timeoutMs
            capturedLive = stillWanted
            beforeConfirm()
            val decision = confirm(backend, uid)
            afterConfirm()
            val error = PhoneAndroidShell.confirmationError(decision)
            if (!stillWanted()) PhoneAndroidShell.failure("cancelled")
            else if (error != null) PhoneAndroidShell.failure(error)
            else { dispatches++; result }
        }
        val env = object : PhoneEnv {
            override fun enabled() = this@Fixture.enabled
            override fun policies() = this@Fixture.policies
            override fun isLocked() = locked
            override fun androidShell() = executor.takeIf { backendAvailable }
            override fun gate() = if (!gateAvailable) null else object : UserGate {
                override fun confirm(request: ConfirmRequest): Decision {
                    asks += request
                    onConfirm(request)
                    return decision
                }
                override fun handoff(reason: String, timeoutMs: Long): HandoffResult = error("unexpected handoff")
                override fun status(text: String?) { statuses += text }
            }
            override fun driver(screen: PhoneScreen): PhoneDriver? = error("shell must not read a screen")
            override fun a11yState(): A11yState = error("shell must not require accessibility")
            override fun backgroundUnavailable(): String = error("shell must not use a display backend")
            override fun system(): SystemApi = error("shell must not resolve an application")
            override fun zone() = ZoneId.of("UTC")
            override fun notifyFix(kind: String) = error("shell must not request accessibility")
        }
        val core = PhoneCore(env, tasks, log)
        fun call(command: String = "printf test", extra: Map<String, Any?> = emptyMap()) =
            core.call(PhoneToolCatalog.ANDROID_SHELL, mapOf("command" to command) + extra)
        fun direct(owner: PhoneTasks.Owner) = PhoneAndroidShell.run(
            PhoneAndroidShell.Request("printf test", 100), owner, tasks, SerialWorker.Scope(),
            env.androidShell(), env::enabled, env::isLocked, env::gate, PhoneUiText.DEFAULT)
        override fun close() { core.worker.shutdown() }
    }

    private fun parse(command: Any?, extra: Map<String, Any?> = emptyMap()) =
        PhoneAndroidShell.parse(Args(mapOf("command" to command) + extra))

    @Test fun parserPreservesTheEntireCommandAndUsesBoundedDefaultTimeout() {
        val command = " \tprintf '%s\n' 'a;b'\r\nprintf done\n "
        val request = checkNotNull(parse(command))
        assertEquals(command, request.command)
        assertEquals(30_000L, request.timeoutMs)
        assertEquals(100L, checkNotNull(parse("id", mapOf("timeout_ms" to 100))).timeoutMs)
        assertEquals(60_000L, checkNotNull(parse("id", mapOf("timeout_ms" to 60_000L))).timeoutMs)
    }

    @Test fun commandRequiresARealNonblankStringAndOnlyDocumentedKeys() {
        for (command in listOf(null, true, 1, 1L, listOf("id"), "", " \t\r\n"))
            assertNull("must reject command=$command", parse(command))
        assertNull(PhoneAndroidShell.parse(Args(emptyMap())))
        for (key in listOf("backend", "uid", "background", "screen", "max_output_bytes", "confirm"))
            assertNull("must reject extra key $key", parse("id", mapOf(key to null)))
    }

    @Test fun timeoutRequiresAnActualIntegerWithinTheInclusiveRange() {
        for (timeout in listOf(null, true, "100", "[100]", " 100 ", 100.0, 100.5,
                Double.NaN, Double.POSITIVE_INFINITY, 99, 60_001, -1, 0, Long.MAX_VALUE))
            assertNull("must reject timeout=$timeout", parse("id", mapOf("timeout_ms" to timeout)))
    }

    @Test fun commandLimitCountsUtf8BytesRatherThanUtf16Characters() {
        assertNotNull(parse("x".repeat(2048)))
        assertNull(parse("x".repeat(2049)))
        assertNotNull(parse("\u00e9".repeat(1024)))
        assertNull(parse("\u00e9".repeat(1024) + "x"))
        val emoji = "\ud83d\ude00"
        assertNotNull(parse(emoji.repeat(512)))
        assertNull(parse(emoji.repeat(512) + "x"))
    }

    @Test fun hiddenControlAndBidiCharactersCannotChangeWhatThePersonApproves() {
        val forbidden = listOf(0x061c) + (0..31).filter { it !in listOf(9, 10, 13) } + (0x7f..0x9f) +
            (0x200e..0x200f) + (0x202a..0x202e) + (0x2066..0x2069)
        for (code in forbidden)
            assertNull("must reject U+${code.toString(16)}", parse("printf a" + code.toChar() + "b"))
        assertNotNull(parse("printf a\t\r\nprintf b\n"))
    }

    @Test fun invalidArgumentsNeverReachBackendOrConfirmation() {
        Fixture().use { f ->
            for (extra in listOf(mapOf("timeout_ms" to "100"), mapOf("timeout_ms" to null), mapOf("uid" to 0))) {
                val out = f.call(extra = extra)
                assertTrue(out.isError)
                assertEquals("invalidArguments", (Json.parse(out.text) as Map<*, *>)["errorCode"])
            }
            assertEquals(0, f.executorCalls)
            assertTrue(f.asks.isEmpty())
        }
    }

    @Test fun completeCommandBackendUidAndOriginalOwnerAppearInOneCommandPromptOnly() {
        Fixture().use { f ->
            val command = " \tprintf '%s\n' 'literal;command'\nprintf next\n "
            val out = f.call(command, mapOf("timeout_ms" to 100))
            assertFalse(out.isError)
            assertNull(out.image)
            assertNull(out.focusObservation)
            assertEquals(command, f.capturedCommand)
            assertEquals(100L, f.capturedTimeout)
            assertEquals(f.tasks.snapshot().id, f.capturedOwner)
            val ask = f.asks.single()
            assertTrue(ask.sentence.endsWith(command))
            assertTrue(ask.sentence.contains("shizuku"))
            assertTrue(ask.sentence.contains("2000"))
            assertTrue(f.tasks.isCurrent(checkNotNull(ask.owner)))
            assertFalse(ask.offerTaskWaiver)
            assertFalse(ask.firstInApp)
            assertNull(ask.packageName)
            assertNull(ask.appLabel)
            assertNull(ask.visualScope)
            assertEquals(1, f.dispatches)
        }
    }

    @Test fun onlyAllowOnceCanAuthorizeAShellCommand() {
        for (decision in Decision.entries) Fixture().use { f ->
            f.decision = decision
            val out = f.call()
            assertEquals("decision=$decision", decision != Decision.ALLOW_ONCE, out.isError)
            assertEquals("decision=$decision", if (decision == Decision.ALLOW_ONCE) 1 else 0, f.dispatches)
            assertEquals(1, f.asks.size)
            if (decision == Decision.STOP) assertTrue(f.tasks.isStopped())
        }
    }

    @Test fun taskAndAppWaiversAndAlwaysModeNeverSkipOrPersistShellConfirmation() {
        Fixture().use { f ->
            f.tasks.begin()
            f.tasks.waive()
            f.tasks.approve("example.app")
            f.policies = PhonePolicies(confirmMode = ConfirmMode.ALWAYS)
            repeat(2) { assertFalse(f.call().isError) }
            assertEquals(2, f.asks.size)
            assertEquals(2, f.dispatches)
            f.decision = Decision.ALLOW_ALL_FOR_TASK
            assertTrue(f.call().isError)
            assertEquals(2, f.dispatches)
            assertEquals(3, f.asks.size)
        }
    }

    @Test fun unavailableUserGateOrBackendDoesNotDispatch() {
        Fixture().use { f ->
            f.gateAvailable = false
            assertTrue(f.call().isError)
            assertEquals(0, f.dispatches)
            assertTrue(f.asks.isEmpty())
        }
        Fixture().use { f ->
            f.backendAvailable = false
            val out = f.call()
            assertTrue(out.isError)
            assertEquals("unsupported", (Json.parse(out.text) as Map<*, *>)["errorCode"])
            assertEquals(0, f.executorCalls)
        }
    }

    @Test fun unavailableConfirmationIsNotReportedAsAUserDenial() {
        for (available in listOf(false, true)) Fixture().use { f ->
            f.gateAvailable = available
            f.decision = Decision.UNAVAILABLE
            val out = f.call()
            assertTrue(out.isError)
            assertEquals("confirmationUnavailable", (Json.parse(out.text) as Map<*, *>)["errorCode"])
            assertEquals(0, f.dispatches)
        }
        Fixture().use { f ->
            f.decision = Decision.DENY
            val out = f.call()
            assertEquals("confirmationDenied", (Json.parse(out.text) as Map<*, *>)["errorCode"])
            assertEquals(0, f.dispatches)
        }
    }

    @Test fun shellStillRejectsEveryTaskWideWaiver() {
        for (decision in listOf(Decision.ALLOW_APP_FOR_TASK, Decision.ALLOW_ALL_FOR_TASK, Decision.ALLOW_VISUAL_FOR_TASK)) {
            assertEquals("confirmationDenied", PhoneAndroidShell.confirmationError(decision))
        }
        assertNull(PhoneAndroidShell.confirmationError(Decision.ALLOW_ONCE))
        assertEquals("cancelled", PhoneAndroidShell.confirmationError(Decision.STOP))
    }

    @Test fun backendAndActualUidMustBeRecognizedBeforeAsking() {
        for ((backend, uid) in listOf("adb" to 2000, "shizuku" to 0, "shizuku" to 2000,
                "adb" to 0, "adb" to 10000, "shizuku" to -1, "unknown" to 0)) Fixture().use { f ->
            f.backend = backend
            f.uid = uid
            val valid = (backend == "adb" && uid == 2000) || (backend == "shizuku" && uid in setOf(0, 2000))
            assertEquals(!valid, f.call().isError)
            assertEquals(if (valid) 1 else 0, f.asks.size)
            assertEquals(if (valid) 1 else 0, f.dispatches)
        }
    }

    @Test fun lockOrMasterOffBeforeInvocationNeverReachesBackend() {
        Fixture().use { f ->
            f.locked = true
            val out = f.call()
            assertTrue(out.isError)
            assertEquals("locked", (Json.parse(out.text) as Map<*, *>)["errorCode"])
            assertEquals(0, f.executorCalls)
        }
        Fixture().use { f ->
            f.enabled = false
            assertTrue(f.call().isError)
            assertEquals(0, f.executorCalls)
            assertFalse(f.tasks.isActive)
        }
    }

    @Test fun staleOwnerPausedTaskAndInterruptedThreadDoNotEnterNativeExecution() {
        Fixture().use { f ->
            val owner = (f.tasks.begin() as PhoneTasks.Begin.Go).owner
            f.tasks.endTask()
            f.tasks.begin()
            assertEquals("cancelled", f.direct(owner)["errorCode"])
            assertEquals(0, f.executorCalls)
        }
        Fixture().use { f ->
            val owner = (f.tasks.begin() as PhoneTasks.Begin.Go).owner
            f.tasks.setPaused(true)
            assertEquals("cancelled", f.direct(owner)["errorCode"])
            assertEquals(0, f.executorCalls)
        }
        Fixture().use { f ->
            val owner = (f.tasks.begin() as PhoneTasks.Begin.Go).owner
            Thread.currentThread().interrupt()
            try {
                assertEquals("cancelled", f.direct(owner)["errorCode"])
                assertEquals(0, f.executorCalls)
            } finally { Thread.interrupted() }
        }
    }

    @Test fun changedOwnerLockOrMasterBeforeConfirmationDoesNotAskOrDispatch() {
        assertRevocations(expectedAsks = 0) { f, revoke -> f.beforeConfirm = { revoke(f) } }
    }

    @Test fun changedOwnerLockOrMasterDuringConfirmationDoesNotDispatch() {
        assertRevocations { f, revoke -> f.onConfirm = { revoke(f) } }
    }

    @Test fun changedOwnerLockOrMasterAfterConfirmationIsStillRejectedAtDispatch() {
        assertRevocations { f, revoke -> f.afterConfirm = { revoke(f) } }
    }

    private fun assertRevocations(expectedAsks: Int = 1, install: (Fixture, (Fixture) -> Unit) -> Unit) {
        val revocations: List<(Fixture) -> Unit> = listOf(
            { it.enabled = false }, { it.locked = true }, { it.tasks.stop("test stop") },
            { it.tasks.endTask(); it.tasks.begin(); Unit }, { it.tasks.setPaused(true) })
        for ((index, revoke) in revocations.withIndex()) Fixture().use { f ->
            install(f, revoke)
            assertTrue("revocation=$index", f.call().isError)
            assertEquals("revocation=$index", 0, f.dispatches)
            assertEquals("revocation=$index", expectedAsks, f.asks.size)
            assertFalse(checkNotNull(f.capturedLive).invoke())
        }
    }

    @Test fun nonzeroOrMissingExitAndFailureFlagsAreNeverReportedAsSuccess() {
        val failures = listOf(mapOf("exitCode" to 9), mapOf("exitCode" to null),
            mapOf("exitCode" to "0"), mapOf("exitCode" to 0.5), mapOf("exitCode" to 4_294_967_296L),
            mapOf("started" to false), mapOf("timedOut" to true),
            mapOf("cancelled" to true), mapOf("errorCode" to "connectionLost"))
        for (changes in failures) Fixture().use { f ->
            f.result = receipt() + changes
            val out = f.call()
            assertTrue("receipt=$changes", out.isError)
            assertEquals(Json.write(f.result), out.text)
        }
        Fixture().use { f ->
            f.result = receipt() + mapOf("exitCode" to 0L, "truncated" to true)
            assertFalse(f.call().isError)
        }
    }

    @Test fun commandAndOutputAreNeverWrittenToActionLogOrStatus() {
        Fixture().use { f ->
            val command = "printf secret-command-marker"
            f.result = receipt() + mapOf("stdout" to "private-output-marker", "stderr" to "private-error-marker")
            assertFalse(f.call(command).isError)
            f.decision = Decision.DENY
            assertTrue(f.call(command).isError)
            val recorded = Json.write(f.log.toMaps(100)) + f.statuses.toString()
            for (privateText in listOf(command, "secret-command-marker", "private-output-marker", "private-error-marker"))
                assertFalse(recorded.contains(privateText))
            assertEquals(listOf("Android Shell", "Android Shell"), f.log.toMaps(100).map { it["summary"] })
        }
    }

    @Test fun shellUsesMainAndGlobalUnknownAppLeaseWithoutAccessibilityOrAnAppLookup() {
        Fixture().use { f ->
            val owner = (f.tasks.begin() as PhoneTasks.Begin.Go).owner
            val prepared = f.core.prepareCall(PhoneToolCatalog.ANDROID_SHELL, mapOf("command" to "id"), owner)
            assertTrue(prepared is Either.Right)
            val call = (prepared as Either.Right).value
            assertEquals(listOf(PhoneScreen.MAIN), call.screens)
            assertTrue(call.unknownApp)
            assertNull(call.knownApp)
            val ids = AtomicLong()
            val sessions = PhoneTaskSessions(System::currentTimeMillis, ids::incrementAndGet,
                { tasks, _ -> PhoneCore(f.env, tasks, f.log, f.core.worker) }, f.tasks, f.core)
            try {
                val admission = sessions.admit(PhoneCaller("session-shell", "run", "call", 1))
                assertFalse(sessions.run(admission, PhoneToolCatalog.ANDROID_SHELL, mapOf("command" to "id")).isError)
                val task = sessions.all().single { it.sessionId == "session-shell" }
                assertTrue(task.holdsUnknownApp)
                assertTrue(task.heldApps.isEmpty())
                assertFalse(sessions.snapshot().single { it["sessionId"] == "session-shell" }["backgroundSlot"] as Boolean)
                assertEquals(1, f.dispatches)
            } finally { sessions.retire() }
        }
    }

    companion object {
        private fun receipt(): Map<String, Any?> = linkedMapOf(
            "started" to true, "backend" to "shizuku", "uid" to 2000, "exitCode" to 0,
            "stdout" to "test", "stderr" to "", "timedOut" to false, "cancelled" to false,
            "truncated" to false, "errorCode" to null)
    }
}
