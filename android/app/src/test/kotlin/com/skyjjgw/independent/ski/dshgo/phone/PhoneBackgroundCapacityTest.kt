package com.skyjjgw.independent.ski.dshgo.phone

import java.time.ZoneId
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.*
import org.junit.Test

/** Actual registry, preparation, Core, owner ledger and workers; only device services are fake. */
class PhoneBackgroundCapacityTest {
    private class Fixture : AutoCloseable {
        val time = AtomicLong(1_000)
        private val ids = AtomicLong()
        val worker = SerialWorker("capacity-main", time::get) { false }
        private val backgroundWorkers = java.util.Collections.synchronizedList(mutableListOf<SerialWorker>())
        val pool = Executors.newCachedThreadPool()
        val a = PhoneAppIdentity("sample.a", 10123)
        val b = PhoneAppIdentity("sample.b", 10124)
        val c = PhoneAppIdentity("sample.c", 10125)
        val d = PhoneAppIdentity("sample.d", 10126)
        @Volatile var limit = 1
        @Volatile var prepare: (PhoneTaskSessions.Task, PhoneTasks.Owner) -> String? = { _, _ -> null }
        @Volatile var onDriver: (PhoneScreen) -> Unit = {}
        @Volatile var read: (PhoneScreen) -> Unit = {}
        @Volatile var apps: List<AppEntry> = listOf(AppEntry("A", a), AppEntry("B", b), AppEntry("C", c), AppEntry("D", d))
        @Volatile var open: (PhoneAppIdentity) -> ActionResult = { ActionResult(true, "opened", backgroundOpenConfirmed = true) }
        @Volatile var changed: () -> Unit = {}
        @Volatile var cleanup: (Long) -> Unit = {}
        private fun core(tasks: PhoneTasks): PhoneCore {
            val ledger = PhoneTaskObservations(tasks)
            val drivers = PhoneScreen.entries.associateWith { screen -> object : PhoneDriver {
                override val screen = screen
                override fun availability() = Availability(true)
                override fun foregroundPackage(): String? = null
                override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot { read(screen); return ScreenSnapshot("${screen.prefix}1", "synthetic", null, null) }
                override fun open(target: PhoneAppIdentity) = this@Fixture.open(target)
                override fun target(screenId: String, elementId: Int): TargetInfo? = null
                override fun perform(action: PhoneAction) = error("unused")
                override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = error("unused")
            } }
            return PhoneCore(object : PhoneEnv {
                override fun enabled() = true
                override fun policies() = PhonePolicies(confirmMode = ConfirmMode.ALWAYS)
                override fun isLocked() = false
                override fun driver(screen: PhoneScreen) = drivers.getValue(screen)
                override fun driver(screen: PhoneScreen, owner: PhoneTasks.Owner): PhoneDriver { onDriver(screen); return ledger.bind(drivers.getValue(screen), owner) }
                override fun gate(): UserGate? = null
                override fun a11yState() = A11yState.CONNECTED
                override fun backgroundUnavailable() = "unavailable"
                override fun notifyFix(kind: String) {}
                override fun zone() = ZoneId.of("UTC")
                override fun sleep(ms: Long) {}
                override fun system() = object : SystemApi {
                    override fun apps() = this@Fixture.apps
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
            createBackgroundWorker = { SerialWorker("capacity-background", time::get) { false }.also { backgroundWorkers += it } },
            backgroundCapacity = { limit }, prepareBackground = { task, owner -> prepare(task, owner) })
        fun task(session: String) = sessions.all().single { it.sessionId == session }
        fun open(session: String, target: PhoneAppIdentity = a): ToolOutput = sessions.run(
            sessions.admit(PhoneCaller(session, "run", "call", runLifecycle = 1)), PhoneToolCatalog.OPEN,
            mapOf("app" to target.packageName, "background" to true))
        fun screen(session: String, background: Boolean = false) = sessions.run(
            sessions.admit(PhoneCaller(session, "run", "call", runLifecycle = 1)), PhoneToolCatalog.SCREEN, mapOf("background" to background))
        fun waitFor(session: String, screen: String): CountDownLatch {
            val latch = CountDownLatch(1)
            changed = { if (sessions.snapshot().any { it["sessionId"] == session && it["waitingForScreen"] == screen }) latch.countDown() }
            return latch
        }
        fun capacity(value: Int) { limit = value; sessions.backgroundCapacityChanged() }
        fun view(session: String) = sessions.snapshot().single { it["sessionId"] == session }
        fun holdWaiting(session: String, screen: String, release: CountDownLatch): CountDownLatch {
            val entered = CountDownLatch(1)
            val claimed = java.util.concurrent.atomic.AtomicBoolean()
            changed = {
                if (sessions.snapshot().any { it["sessionId"] == session && it["waitingForScreen"] == screen } && claimed.compareAndSet(false, true)) {
                    entered.countDown()
                    var interrupted = false
                    try {
                        while (true) try { check(release.await(5, TimeUnit.SECONDS)); break }
                        catch (_: InterruptedException) { interrupted = true }
                    } finally { if (interrupted) Thread.currentThread().interrupt() }
                }
            }
            return entered
        }
        fun end(session: String) { sessions.admitEnd(session, "run")?.let(sessions::settleEnd) }
        override fun close() { pool.shutdownNow(); worker.shutdown(); backgroundWorkers.toList().forEach { it.shutdown() } }
    }

    @Test fun threeAppOpensKeepThreeOriginalLanesAndFourthWaitsWithoutTakingMain() {
        Fixture().use { f ->
            f.capacity(3)
            assertFalse(f.open("A", f.a).isError); assertFalse(f.open("B", f.b).isError); assertFalse(f.open("C", f.c).isError)
            assertEquals(3, f.sessions.backgroundHeldSlots())
            assertEquals(3, listOf("A", "B", "C").map { f.task(it).backgroundWorker }.distinct().size)
            assertTrue(listOf("A", "B", "C").all { f.view(it)["backgroundSlot"] == true })
            val waiting = f.waitFor("D", "background")
            val d = f.pool.submit<ToolOutput> { f.open("D", f.d) }
            assertTrue(waiting.await(5, TimeUnit.SECONDS)); assertFalse(d.isDone)
            // D did not take MAIN while waiting for BG. An existing holder can open again.
            assertFalse(f.open("A", f.a).isError)
            f.end("B")
            assertFalse(d.get(5, TimeUnit.SECONDS).isError); assertEquals(3, f.sessions.backgroundHeldSlots())
        }
    }

    @Test fun downshiftKeepsOriginalHoldersAndDoesNotRevokeAnAcquiredButUnbuiltDriver() {
        Fixture().use { f ->
            f.capacity(3); assertFalse(f.screen("A", true).isError); assertFalse(f.screen("B", true).isError)
            val entered = CountDownLatch(1); val proceed = CountDownLatch(1)
            f.onDriver = { if (it == PhoneScreen.BACKGROUND) { entered.countDown(); check(proceed.await(5, TimeUnit.SECONDS)) } }
            val c = f.pool.submit<ToolOutput> { f.screen("C", true) }
            try {
                assertTrue(entered.await(5, TimeUnit.SECONDS)); assertEquals(3, f.sessions.backgroundHeldSlots())
                f.capacity(1); proceed.countDown(); assertFalse(c.get(5, TimeUnit.SECONDS).isError)
                f.onDriver = {}; assertFalse(f.screen("A", true).isError)
                val waiting = f.waitFor("D", "background")
                val d = f.pool.submit<ToolOutput> { f.screen("D", true) }
                assertTrue(waiting.await(5, TimeUnit.SECONDS))
                f.end("A"); f.end("B"); assertFalse(d.isDone); assertEquals(1, f.sessions.backgroundHeldSlots())
                f.end("C"); assertFalse(d.get(5, TimeUnit.SECONDS).isError)
                } finally { proceed.countDown() }
        }
    }

    @Test fun increasingLimitWakesTheActualWaiter() {
        Fixture().use { f ->
                assertFalse(f.screen("A", true).isError)
                val waiting = f.waitFor("B", "background")
                val b = f.pool.submit<ToolOutput> { f.screen("B", true) }
                assertTrue(waiting.await(5, TimeUnit.SECONDS)); f.capacity(2)
                assertFalse(b.get(5, TimeUnit.SECONDS).isError); assertEquals(2, f.sessions.backgroundHeldSlots())
        }
    }

    @Test fun unavailableRejectsNewSlotsWakesWaitersAndDoesNotRevokeAnExistingSlot() {
        Fixture().use { f ->
                assertFalse(f.screen("A", true).isError)
                val waiting = f.waitFor("B", "background")
                val b = f.pool.submit<ToolOutput> { f.screen("B", true) }
                assertTrue(waiting.await(5, TimeUnit.SECONDS)); f.capacity(0)
                val failure = b.get(5, TimeUnit.SECONDS)
                assertTrue(failure.isError); assertFalse(failure.text.contains("等待环"))
                assertFalse(f.screen("A", true).isError); assertEquals(1, f.sessions.backgroundHeldSlots())
                assertTrue(f.screen("C", true).isError); assertFalse(f.view("C")["backgroundSlot"] as Boolean)
        }
    }

    @Test fun preparationIsBeforeLeasesOutsideWorkersAndSkipsMainCalls() {
        Fixture().use { f ->
                val entered = CountDownLatch(1); val proceed = CountDownLatch(1); val preparations = AtomicLong()
                f.prepare = { task, owner ->
                preparations.incrementAndGet(); assertTrue(task.tasks.isCurrent(owner))
                assertEquals(0, f.sessions.backgroundHeldSlots()); assertNull(task.activeWorker)
                entered.countDown(); check(proceed.await(5, TimeUnit.SECONDS)); null
                }
                val bg = f.pool.submit<ToolOutput> { f.screen("B", true) }
            try {
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                assertFalse(f.screen("A").isError); assertEquals(1L, preparations.get())
                f.sessions.stop(f.task("B"), "stop preparing")
                proceed.countDown(); assertTrue(bg.get(5, TimeUnit.SECONDS).isError)
                assertEquals(0, f.sessions.backgroundHeldSlots())
                } finally { proceed.countDown() }
        }
    }

    @Test fun backgroundPreparationConsumesTheOriginalAdmissionDeadlineBeforeAnyLease() {
        Fixture().use { f ->
            val reads = AtomicLong()
            f.read = { reads.incrementAndGet() }
            f.prepare = { _, _ -> f.time.addAndGet(PhoneCore.MAX_TOTAL_MS); null }
            val result = f.screen("expired", true)
            assertTrue(result.isError)
            assertTrue(result.text.contains("总期限"))
            assertEquals(0L, reads.get())
            assertEquals(0, f.sessions.backgroundHeldSlots())
            assertTrue(f.task("expired").resourcesReleased)
            assertNull(f.task("expired").backgroundWorker)
        }
    }

    @Test fun freeingABackgroundSlotCannotAdmitAnExpiredOriginalCall() {
        Fixture().use { f ->
            assertFalse(f.screen("holder", true).isError)
            val admission = f.sessions.admit(PhoneCaller("waiter", "run", "call", runLifecycle = 1))
            f.time.addAndGet(PhoneCore.MAX_TOTAL_MS - 1_000)
            val reads = AtomicLong(); f.read = { reads.incrementAndGet() }
            val waiting = f.waitFor("waiter", "background")
            val result = f.pool.submit<ToolOutput> {
                f.sessions.run(admission, PhoneToolCatalog.SCREEN, mapOf("background" to true))
            }
            try {
                assertTrue(waiting.await(5, TimeUnit.SECONDS))
                f.time.addAndGet(1_000)
                f.end("holder")
                val output = result.get(5, TimeUnit.SECONDS)
                assertTrue(output.isError); assertTrue(output.text.contains("总期限"))
                assertEquals(0L, reads.get())
                assertEquals(0, f.sessions.backgroundHeldSlots())
                assertTrue(f.task("waiter").resourcesReleased)
                assertNull(f.task("waiter").backgroundWorker)
            } finally { f.end("holder"); f.end("waiter") }
        }
    }

    @Test fun capacityChangesDoNotResetTheSingleResourceWaitBudget() {
        Fixture().use { f ->
                f.capacity(3)
                for (s in listOf("A", "B", "C")) assertFalse(f.screen(s, true).isError)
                val waiting = f.waitFor("D", "background")
                val d = f.pool.submit<ToolOutput> { f.screen("D", true) }
                assertTrue(waiting.await(5, TimeUnit.SECONDS))
                f.time.addAndGet(15_000); f.capacity(2)
                f.time.addAndGet(15_001); f.capacity(3)
                val result = d.get(5, TimeUnit.SECONDS)
                assertTrue(result.isError); assertTrue(result.text.contains("30 秒"))
                assertEquals(3, f.sessions.backgroundHeldSlots())
        }
    }

    @Test fun anExternalBackgroundHolderCanFreeEitherSlotWithoutAFakeAndCycle() {
        Fixture().use { f ->
                f.capacity(2); assertFalse(f.screen("B", true).isError); assertFalse(f.screen("C", true).isError)
                assertFalse(f.screen("A").isError)
                val bWaiting = f.waitFor("B", "main")
                val b = f.pool.submit<ToolOutput> { f.screen("B") }
                assertTrue(bWaiting.await(5, TimeUnit.SECONDS))
                val aWaiting = f.waitFor("A", "background")
                val a = f.pool.submit<ToolOutput> { f.screen("A", true) }
                assertTrue(aWaiting.await(5, TimeUnit.SECONDS)); assertFalse(a.isDone)
                f.end("C"); assertFalse(a.get(5, TimeUnit.SECONDS).isError)
                f.end("A"); assertFalse(b.get(5, TimeUnit.SECONDS).isError)
        }
    }

    @Test fun oneSlotDetectsTheRealClosedMainBackgroundWait() {
        Fixture().use { f ->
                assertFalse(f.screen("B", true).isError); assertFalse(f.screen("A").isError)
                val releaseWaiter = CountDownLatch(1)
                val waiting = f.holdWaiting("B", "main", releaseWaiter)
                val b = f.pool.submit<ToolOutput> { f.screen("B") }
            try {
                assertTrue(waiting.await(5, TimeUnit.SECONDS))
                val a = f.screen("A", true)
                assertTrue(a.isError); assertTrue(a.text.contains("等待环"))
                releaseWaiter.countDown(); f.end("A"); assertFalse(b.get(5, TimeUnit.SECONDS).isError)
            } finally { releaseWaiter.countDown() }
        }
    }

    @Test fun downshiftNeedsEnoughExternalReleasesNotMerelyOneExternalHolder() {
        Fixture().use { f ->
            f.capacity(3); for (s in listOf("B", "C", "D")) assertFalse(f.screen(s, true).isError)
            assertFalse(f.screen("A").isError)
            val releaseWaiter = CountDownLatch(1)
            val waiting = f.holdWaiting("B", "main", releaseWaiter)
            val b = f.pool.submit<ToolOutput> { f.screen("B") }
            try {
                assertTrue(waiting.await(5, TimeUnit.SECONDS)); f.capacity(1)
                val a = f.screen("A", true)
                assertTrue(a.isError); assertTrue(a.text.contains("等待环"))
                // Even releasing C and D leaves B occupying the only allowed slot.
                f.end("C"); f.end("D"); assertEquals(1, f.sessions.backgroundHeldSlots())
                releaseWaiter.countDown(); f.end("A"); assertFalse(b.get(5, TimeUnit.SECONDS).isError)
            } finally { releaseWaiter.countDown() }
        }
    }

    @Test fun stoppedWaitingOwnerIsNotAClosedWaitMemberAndCleanupFailureStillHoldsCapacity() {
        Fixture().use { f ->
            assertFalse(f.screen("B", true).isError); assertFalse(f.screen("A").isError)
            val releaseWaiter = CountDownLatch(1)
            val waiting = f.holdWaiting("B", "main", releaseWaiter)
            val b = f.pool.submit<ToolOutput> { f.screen("B") }
            try {
                assertTrue(waiting.await(5, TimeUnit.SECONDS))
                f.cleanup = { error("release unconfirmed") }
                assertTrue(f.sessions.stop(f.task("B"), "stop"))
                // B is still inside its real wait callback and has not cleared waitingOwner.
                assertNotNull(f.task("B").waitingOwner)
                assertEquals(1, f.sessions.backgroundHeldSlots()); assertNull(f.sessions.tryReserveSelfCheck())
                val aWaiting = f.waitFor("A", "background")
                val a = f.pool.submit<ToolOutput> { f.screen("A", true) }
                assertTrue(aWaiting.await(5, TimeUnit.SECONDS)); assertFalse(a.isDone)
                releaseWaiter.countDown(); assertTrue(b.get(5, TimeUnit.SECONDS).isError)
                assertTrue(f.task("B").cleanupFailed)
                f.cleanup = {}; assertTrue(f.sessions.retryCleanup(f.task("B").tasks.snapshot().id))
                assertFalse(a.get(5, TimeUnit.SECONDS).isError)
            } finally { releaseWaiter.countDown() }
        }
    }

    @Test fun pausedResourceWaiterRetainsItsOwnerAndParticipatesInARealCycle() {
        Fixture().use { f ->
            assertFalse(f.screen("B", true).isError); assertFalse(f.screen("A").isError)
            val releaseWaiter = CountDownLatch(1)
            val waiting = f.holdWaiting("B", "main", releaseWaiter)
            val b = f.pool.submit<ToolOutput> { f.screen("B") }
            try {
                assertTrue(waiting.await(5, TimeUnit.SECONDS))
                val owner = f.task("B").tasks.activeOwner()!!
                assertTrue(f.task("B").tasks.setPausedIfCurrent(owner, true))
                val a = f.screen("A", true)
                assertTrue(a.isError); assertTrue(a.text.contains("等待环"))
                assertTrue(f.task("B").tasks.isCurrent(owner))
                f.task("B").tasks.setPausedIfCurrent(owner, false)
                releaseWaiter.countDown(); f.end("A"); assertFalse(b.get(5, TimeUnit.SECONDS).isError)
            } finally { releaseWaiter.countDown() }
        }
    }

    @Test fun anAbandonedBodyKeepsItsSlotAcrossRetirementUntilItsRealExit() {
        Fixture().use { f ->
            val entered = CountDownLatch(1); val exit = CountDownLatch(1); val cleaned = CountDownLatch(1)
            f.read = { if (it == PhoneScreen.BACKGROUND) { entered.countDown(); awaitUninterruptibly(exit) } }
            f.cleanup = { cleaned.countDown() }
            val a = f.pool.submit<ToolOutput> { f.screen("A", true) }
            try {
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                // Retirement only interrupts a running body. First exercise the real budget
                // abandonment path while this fixture deliberately retains that body.
                f.time.addAndGet(PhoneCore.budgetMs(PhoneToolCatalog.SCREEN) + 1)
                assertTrue(a.get(5, TimeUnit.SECONDS).isError)
                assertTrue(f.task("A").running)
                f.sessions.retire(); assertEquals(1, f.sessions.backgroundHeldSlots())
                assertNull(f.sessions.tryReserveSelfCheck())
                exit.countDown(); assertTrue(cleaned.await(5, TimeUnit.SECONDS))
                // Registry removal follows the cleanup callback; a status callback observes that commit.
                val released = CountDownLatch(1)
                f.changed = { if (f.sessions.backgroundHeldSlots() == 0) released.countDown() }
                if (f.sessions.backgroundHeldSlots() == 0) released.countDown()
                assertTrue(released.await(5, TimeUnit.SECONDS))
                } finally { exit.countDown() }
        }
    }

    @Test fun freeBackgroundSlotsDoNotBypassPackageUidOrUnknownAppHolders() {
        for (second in listOf(PhoneAppIdentity("alias.app", 10123), PhoneAppIdentity("sample.a", 20123))) Fixture().use { f ->
            f.capacity(3); assertFalse(f.open("A", f.a).isError)
            f.apps = listOf(AppEntry("Alias", second), AppEntry("C", f.c))
            val waiting = CountDownLatch(1)
            f.changed = { if (f.sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForApp"] != null }) waiting.countDown() }
            val b = f.pool.submit<ToolOutput> { f.open("B", second) }
            assertTrue(waiting.await(5, TimeUnit.SECONDS)); assertEquals(1, f.sessions.backgroundHeldSlots())
            assertEquals(mapOf("kind" to "known", "packageName" to second.packageName), f.view("B")["waitingForApp"])
            assertFalse(f.open("C", f.c).isError); assertEquals(2, f.sessions.backgroundHeldSlots())
            val unknownWaiting = CountDownLatch(1)
            f.changed = { if (f.sessions.snapshot().any { it["sessionId"] == "D" && it["waitingForApp"] != null }) unknownWaiting.countDown() }
            val d = f.pool.submit<ToolOutput> { f.screen("D") }
            assertTrue(unknownWaiting.await(5, TimeUnit.SECONDS))
            f.end("A"); assertFalse(b.get(5, TimeUnit.SECONDS).isError); assertFalse(d.isDone)
            f.end("B"); assertFalse(d.isDone)
            f.end("C"); assertFalse(d.get(5, TimeUnit.SECONDS).isError)
        }
    }

    @Test fun aSeparateAppWaitClosureDoesNotRejectAWaiterThatCanUseAnExternalSlot() {
        Fixture().use { f ->
            f.capacity(3)
            assertFalse(f.open("A", f.a).isError); assertFalse(f.open("B", f.b).isError)
            assertFalse(f.screen("C", true).isError)
            val aWaiting = CountDownLatch(1); val bWaiting = CountDownLatch(1); val releaseWaiters = CountDownLatch(1)
            val captured = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
            f.changed = {
                for ((name, latch) in listOf("A" to aWaiting, "B" to bWaiting)) {
                    if (f.sessions.snapshot().any { it["sessionId"] == name && it["waitingForApp"] != null } && captured.add(name)) {
                        latch.countDown(); awaitUninterruptibly(releaseWaiters)
                    }
                }
            }
            val a = f.pool.submit<ToolOutput> { f.open("A", f.b) }
            try {
                assertTrue(aWaiting.await(5, TimeUnit.SECONDS))
                val b = f.pool.submit<ToolOutput> { f.open("B", f.a) }
                assertTrue(bWaiting.await(5, TimeUnit.SECONDS))
                val dWaiting = f.waitFor("D", "background")
                val d = f.pool.submit<ToolOutput> { f.screen("D", true) }
                assertTrue(dWaiting.await(5, TimeUnit.SECONDS)); assertFalse(d.isDone)
                f.end("C"); assertFalse(d.get(5, TimeUnit.SECONDS).isError)
                // End the two genuine callers without allowing either to act on the other's app.
                f.sessions.stop(f.task("A"), "test done"); f.sessions.stop(f.task("B"), "test done")
                releaseWaiters.countDown()
                assertTrue(a.get(5, TimeUnit.SECONDS).isError); assertTrue(b.get(5, TimeUnit.SECONDS).isError)
            } finally { releaseWaiters.countDown() }
        }
    }

    @Test fun threeBackgroundBodiesCanRunWhileTheSameTaskAndFourthTaskStayQueued() {
        Fixture().use { f ->
            f.capacity(3)
            val entered = CountDownLatch(3); val exit = CountDownLatch(1); val reads = AtomicLong()
            f.read = { if (it == PhoneScreen.BACKGROUND) { reads.incrementAndGet(); entered.countDown(); awaitUninterruptibly(exit) } }
            val running = listOf("A", "B", "C").map { name -> f.pool.submit<ToolOutput> { f.screen(name, true) } }
            try {
                assertTrue(entered.await(5, TimeUnit.SECONDS)); assertEquals(3L, reads.get())
                val secondA = f.pool.submit<ToolOutput> { f.screen("A", true) }
                val dWaiting = f.waitFor("D", "background")
                val d = f.pool.submit<ToolOutput> { f.screen("D", true) }
                assertTrue(dWaiting.await(5, TimeUnit.SECONDS)); assertNull(f.task("D").activeWorker)
                assertFalse(secondA.isDone); assertEquals(3L, reads.get())
                exit.countDown(); running.forEach { assertFalse(it.get(5, TimeUnit.SECONDS).isError) }
                assertFalse(secondA.get(5, TimeUnit.SECONDS).isError); assertFalse(d.isDone)
                f.end("C"); assertFalse(d.get(5, TimeUnit.SECONDS).isError)
            } finally { exit.countDown() }
        }
    }

    private fun awaitUninterruptibly(latch: CountDownLatch) {
        var interrupted = false
        try {
                while (true) try { check(latch.await(5, TimeUnit.SECONDS)); return }
                catch (_: InterruptedException) { interrupted = true }
        } finally { if (interrupted) Thread.currentThread().interrupt() }
    }
}
