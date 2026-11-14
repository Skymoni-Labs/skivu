package com.skyjjgw.independent.ski.dshgo.phone

import java.time.ZoneId
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.*
import org.junit.Test

/** Actual Sessions -> Core -> owner ledger -> driver; only device services are synthetic. */
class PhoneMainLoanTest {
    private class Fixture : AutoCloseable {
        val time = AtomicLong(1_000)
        private val ids = AtomicLong()
        val worker = SerialWorker("main-loan", time::get) { false }
        private val backgroundWorkers = java.util.Collections.synchronizedList(mutableListOf<SerialWorker>())
        val pool = Executors.newCachedThreadPool()
        val a = PhoneAppIdentity("sample.a", 10123)
        val b = PhoneAppIdentity("sample.b", 10124)
        @Volatile var open: (PhoneAppIdentity) -> ActionResult = { ActionResult(true, "opened", backgroundOpenConfirmed = true) }
        @Volatile var changed: () -> Unit = {}
        @Volatile var onTask: (PhoneTasks, PhoneTasks.Snapshot) -> Unit = { _, _ -> }
        @Volatile var cleanup: (Long) -> Unit = {}
        private fun core(tasks: PhoneTasks): PhoneCore {
            val ledger = PhoneTaskObservations(tasks)
            val drivers = PhoneScreen.entries.associateWith { screen -> object : PhoneDriver {
                override val screen = screen
                override fun availability() = Availability(true)
                override fun foregroundPackage(): String? = null
                override fun observe(detail: Boolean, image: Boolean) = ScreenSnapshot("${screen.prefix}1", "synthetic", null, null)
                override fun open(target: PhoneAppIdentity) = this@Fixture.open(target)
                override fun target(screenId: String, elementId: Int): TargetInfo? = null
                override fun perform(action: PhoneAction) = error("unused")
                override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = error("unused")
            } }
            tasks.addListener { onTask(tasks, it) }
            return PhoneCore(object : PhoneEnv {
                override fun enabled() = true
                override fun policies() = PhonePolicies(confirmMode = ConfirmMode.ALWAYS)
                override fun isLocked() = false
                override fun driver(screen: PhoneScreen) = drivers.getValue(screen)
                override fun driver(screen: PhoneScreen, owner: PhoneTasks.Owner) = ledger.bind(drivers.getValue(screen), owner)
                override fun gate(): UserGate? = null
                override fun a11yState() = A11yState.CONNECTED
                override fun backgroundUnavailable() = "unavailable"
                override fun notifyFix(kind: String) {}
                override fun zone() = ZoneId.of("UTC")
                override fun sleep(ms: Long) {}
                override fun system() = object : SystemApi {
                    override fun apps() = listOf(AppEntry("A", a), AppEntry("B", b))
                    override fun isInstalled(pkg: String) = true
                    override fun prepareLaunch(app: AppEntry): Either<String, SystemLaunch> = Either.Right(TestSystemLaunch(SystemTarget.Known(app)))
                    override fun prepareUrl(url: String): Either<String, SystemLaunch> = error("unused")
                    override fun prepareIntent(spec: IntentSpec, selectedApp: AppEntry?): Either<String, SystemLaunch> = error("unused")
                    override fun launch(plan: SystemLaunch, dispatch: PhoneTasks.SystemDispatch): SysResult = error("unused")
                    override fun notify(title: String, text: String): SysResult = error("unused")
                    override fun clipboardSet(text: String): SysResult = error("unused")
                    override fun clipboardGet(): SysResult = error("unused")
                }
            }, tasks, ActionLog(), worker)
        }
        private val legacy = PhoneTasks(clock = time::get, idSource = ids::incrementAndGet)
        val sessions = PhoneTaskSessions(time::get, ids::incrementAndGet,
            { tasks, _ -> core(tasks) }, legacy, core(legacy), { changed() }, settleResources = { cleanup(it) },
            createBackgroundWorker = { SerialWorker("loan-background", time::get) { false }.also { backgroundWorkers += it } })
        fun task(session: String) = sessions.all().single { it.sessionId == session }
        fun open(session: String, target: PhoneAppIdentity = a): ToolOutput = sessions.run(
            sessions.admit(PhoneCaller(session, "run", "call", runLifecycle = 1)), PhoneToolCatalog.OPEN,
            mapOf("app" to target.packageName, "background" to true))
        fun screen(session: String) = sessions.run(
            sessions.admit(PhoneCaller(session, "run", "call", runLifecycle = 1)), PhoneToolCatalog.SCREEN, emptyMap())
        fun waitFor(session: String, screen: String): CountDownLatch {
            val latch = CountDownLatch(1)
            changed = { if (sessions.snapshot().any { it["sessionId"] == session && it["waitingForScreen"] == screen }) latch.countDown() }
            return latch
        }
        fun end(session: String) { sessions.admitEnd(session, "run")?.let(sessions::settleEnd) }
        override fun close() { pool.shutdownNow(); worker.shutdown(); backgroundWorkers.toList().forEach { it.shutdown() } }
    }

    private fun awaitUninterruptibly(latch: CountDownLatch) {
        var interrupted = false
        try {
            while (true) try { check(latch.await(5, TimeUnit.SECONDS)); return }
            catch (_: InterruptedException) { interrupted = true }
        } finally { if (interrupted) Thread.currentThread().interrupt() }
    }

    @Test fun confirmedOpenDropsOnlyNewMainAndPreservesBackgroundAndApp() {
        Fixture().use { f ->
            assertFalse(f.open("A").isError)
            val original = f.task("A")
            assertEquals(setOf(f.a), original.heldApps)
            assertFalse(original.resourcesReleased)
            val waiting = f.waitFor("B", "background")
            val b = f.pool.submit<ToolOutput> { f.open("B", f.b) }
            assertTrue(waiting.await(5, TimeUnit.SECONDS))
            assertFalse(b.isDone)
            assertEquals(setOf(f.a), original.heldApps)
            f.end("A")
            assertFalse(b.get(5, TimeUnit.SECONDS).isError)
        }
    }

    @Test fun oldMainAndFailedOpenMainAreNeverReclassifiedAsNewLoans() {
        for (existingMain in listOf(true, false)) Fixture().use { f ->
            if (existingMain) assertFalse(f.screen("A").isError)
            else {
                f.open = { ActionResult(false, "unconfirmed") }
                assertTrue(f.open("A").isError)
            }
            f.open = { ActionResult(true, "opened", backgroundOpenConfirmed = true) }
            assertFalse(f.open("A").isError)
            val waiting = f.waitFor("B", "main")
            val b = f.pool.submit<ToolOutput> { f.open("B", f.b) }
            assertTrue(waiting.await(5, TimeUnit.SECONDS))
            f.end("A")
            assertFalse(b.get(5, TimeUnit.SECONDS).isError)
        }
    }

    @Test fun ordinarySuccessWithoutNewEvidenceKeepsMain() {
        Fixture().use { f ->
            f.open = { ActionResult(true, "legacy success") }
            assertFalse(f.open("A").isError)
            val waiting = f.waitFor("B", "main")
            val b = f.pool.submit<ToolOutput> { f.open("B", f.b) }
            assertTrue(waiting.await(5, TimeUnit.SECONDS))
            f.end("A")
            assertFalse(b.get(5, TimeUnit.SECONDS).isError)
        }
    }

    @Test fun recordedFactWaitsForActualBodyExitAndTheNextOpenReacquiresMain() {
        Fixture().use { f ->
            val recorded = CountDownLatch(1); val exit = CountDownLatch(1)
            // setApp is the real Core boundary AFTER recording the driver's confirmed fact.
            f.onTask = { _, state -> if (state.app == "A" && recorded.count > 0L) { recorded.countDown(); awaitUninterruptibly(exit) } }
            val a = f.pool.submit<ToolOutput> { f.open("A") }
            try {
                assertTrue(recorded.await(5, TimeUnit.SECONDS))
                assertSame(f.task("A").backgroundWorker, f.task("A").activeWorker)
                assertNotSame(f.worker, f.task("A").activeWorker)
                val waiting = f.waitFor("B", "main")
                val b = f.pool.submit<ToolOutput> { f.open("B", f.b) }
                assertTrue(waiting.await(5, TimeUnit.SECONDS))
                val bgWaiting = f.waitFor("B", "background")
                exit.countDown()
                assertFalse(a.get(5, TimeUnit.SECONDS).isError)
                assertTrue(bgWaiting.await(5, TimeUnit.SECONDS))
                f.onTask = { _, _ -> }
                // A's next open has to borrow MAIN again; a no-evidence reply keeps this new loan.
                f.open = { ActionResult(true, "old peer") }
                assertFalse(f.open("A").isError)
                assertEquals("main", f.sessions.snapshot().single { it["sessionId"] == "B" }["waitingForScreen"])
                f.end("A")
                assertFalse(b.get(5, TimeUnit.SECONDS).isError)
            } finally { exit.countDown() }
        }
    }

    @Test fun callerTimeoutDoesNotDrainAndRealLedgerRejectsInterruptedLateReceipt() {
        Fixture().use { f ->
            val entered = CountDownLatch(1); val exit = CountDownLatch(1); val drained = CountDownLatch(1)
            f.open = { entered.countDown(); awaitUninterruptibly(exit); ActionResult(true, "late", backgroundOpenConfirmed = true) }
            val a = f.pool.submit<ToolOutput> { f.open("A") }
            try {
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                f.time.addAndGet(100_000)
                assertTrue(a.get(5, TimeUnit.SECONDS).isError)
                val original = f.task("A")
                assertTrue(original.running)
                checkNotNull(original.activeWorker).afterDrained(original.tasks) { drained.countDown() }
                val waiting = f.waitFor("B", "main")
                val b = f.pool.submit<ToolOutput> { f.open("B", f.b) }
                assertTrue(waiting.await(5, TimeUnit.SECONDS))
                exit.countDown(); assertTrue(drained.await(5, TimeUnit.SECONDS))
                assertEquals("main", f.sessions.snapshot().single { it["sessionId"] == "B" }["waitingForScreen"])
                f.open = { ActionResult(true, "opened", backgroundOpenConfirmed = true) }
                f.end("A")
                assertFalse(b.get(5, TimeUnit.SECONDS).isError)
            } finally { exit.countDown() }
        }
    }

    @Test fun stopAfterFactCannotReleaseBeforeStrictCleanupOrEraseTheSuccessor() {
        Fixture().use { f ->
            val recorded = CountDownLatch(1); val exit = CountDownLatch(1)
            val cleaning = CountDownLatch(1); val cleanExit = CountDownLatch(1)
            f.onTask = { _, state -> if (state.app == "A" && recorded.count > 0L) { recorded.countDown(); awaitUninterruptibly(exit) } }
            f.cleanup = { cleaning.countDown(); awaitUninterruptibly(cleanExit) }
            val a = f.pool.submit<ToolOutput> { f.open("A") }
            try {
                assertTrue(recorded.await(5, TimeUnit.SECONDS))
                val original = f.task("A")
                assertTrue(f.sessions.stop(original, original.tasks.activeOwner()!!, "stop"))
                val waiting = f.waitFor("B", "main")
                val b = f.pool.submit<ToolOutput> { f.open("B", f.b) }
                assertTrue(waiting.await(5, TimeUnit.SECONDS))
                exit.countDown(); assertTrue(cleaning.await(5, TimeUnit.SECONDS))
                assertEquals("main", f.sessions.snapshot().single { it["sessionId"] == "B" }["waitingForScreen"])
                f.onTask = { _, _ -> }; f.cleanup = {}
                // B deliberately keeps its own new MAIN. No old A callback may remove it.
                f.open = { ActionResult(true, "old peer") }
                cleanExit.countDown(); assertTrue(a.get(5, TimeUnit.SECONDS).isError)
                assertFalse(b.get(5, TimeUnit.SECONDS).isError)
                val cWaiting = f.waitFor("C", "main")
                val c = f.pool.submit<ToolOutput> { f.open("C", f.a) }
                assertTrue(cWaiting.await(5, TimeUnit.SECONDS))
                f.end("B"); assertFalse(c.get(5, TimeUnit.SECONDS).isError)
            } finally { exit.countDown(); cleanExit.countDown() }
        }
    }
    @Test fun unknownMainAppRequestStillWaitsAfterTheScreenLoanWasReturned() {
        Fixture().use { f ->
            assertFalse(f.open("A").isError)
            val waiting = CountDownLatch(1)
            f.changed = {
                if (f.sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForApp"] != null }) waiting.countDown()
            }
            val b = f.pool.submit<ToolOutput> { f.screen("B") }
            assertTrue(waiting.await(5, TimeUnit.SECONDS))
            val state = f.sessions.snapshot().single { it["sessionId"] == "B" }
            assertNull(state["waitingForScreen"])
            assertEquals(mapOf("kind" to "unknown"), state["waitingForApp"])
            f.end("B")
            assertTrue(b.get(5, TimeUnit.SECONDS).isError)
            f.end("A")
        }
    }

    @Test fun endAndLaunchRetirementAfterTheFactKeepMainThroughOriginalCleanup() {
        for (retire in listOf(false, true)) Fixture().use { f ->
            val recorded = CountDownLatch(1); val exit = CountDownLatch(1)
            val cleaning = CountDownLatch(1); val cleanExit = CountDownLatch(1)
            f.onTask = { _, state -> if (state.app == "A" && recorded.count > 0L) { recorded.countDown(); awaitUninterruptibly(exit) } }
            f.cleanup = { cleaning.countDown(); awaitUninterruptibly(cleanExit) }
            val a = f.pool.submit<ToolOutput> { f.open("A") }
            try {
                assertTrue(recorded.await(5, TimeUnit.SECONDS))
                val old = f.task("A")
                if (retire) f.sessions.retire() else f.end("A")
                val waiting = f.waitFor("B", "main")
                val b = f.pool.submit<ToolOutput> { f.open("B", f.b) }
                assertTrue(waiting.await(5, TimeUnit.SECONDS))
                exit.countDown(); assertTrue(cleaning.await(5, TimeUnit.SECONDS))
                assertFalse(old.resourcesReleased)
                assertEquals("main", f.sessions.snapshot().single { it["sessionId"] == "B" }["waitingForScreen"])
                f.onTask = { _, _ -> }; f.cleanup = {}; cleanExit.countDown()
                assertTrue(a.get(5, TimeUnit.SECONDS).isError)
                assertFalse(b.get(5, TimeUnit.SECONDS).isError)
            } finally { exit.countDown(); cleanExit.countDown() }
        }
    }
}
