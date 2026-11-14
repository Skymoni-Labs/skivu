package com.skyjjgw.independent.ski.dshgo.phone

import java.time.ZoneId
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

/** Real registry/Core/worker and owner ledger. Only device reads and strict cleanup are fixtures. */
class PhoneScreenWorkersTest {
    private class Fixture : AutoCloseable {
        val time = AtomicLong(1_000)
        private val ids = AtomicLong()
        val main = SerialWorker("screen-main", time::get) { false }
        val backgrounds = Collections.synchronizedList(mutableListOf<SerialWorker>())
        val pool = Executors.newCachedThreadPool()
        @Volatile var read: (String?, PhoneScreen) -> Unit = { _, _ -> }
        @Volatile var apps: (String?) -> Unit = {}
        @Volatile var clipboard: () -> SysResult = { error("unused") }
        @Volatile var cleanup: (Long) -> Unit = {}
        @Volatile var handoff: () -> Unit = {}
        @Volatile var changed: () -> Unit = {}
        @Volatile var settled: (PhoneTaskSessions.Task) -> Unit = {}
        @Volatile var bgClock: () -> Long = time::get
        private fun core(tasks: PhoneTasks, session: String?): PhoneCore {
            val ledger = PhoneTaskObservations(tasks)
            val drivers = PhoneScreen.entries.associateWith { which -> object : PhoneDriver {
                override val screen = which
                override fun availability() = Availability(true)
                override fun foregroundPackage(): String? = null
                override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot {
                    read(session, which)
                    return ScreenSnapshot("${which.prefix}1", "local fixture", null, null)
                }
                override fun open(target: PhoneAppIdentity) = ActionResult(true, "opened", backgroundOpenConfirmed = true)
                override fun target(screenId: String, elementId: Int): TargetInfo? = null
                override fun perform(action: PhoneAction) = error("unused")
                override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = error("unused")
            } }
            return PhoneCore(object : PhoneEnv {
                override fun enabled() = true
                override fun policies() = PhonePolicies(confirmMode = ConfirmMode.ALWAYS)
                override fun isLocked() = false
                override fun driver(screen: PhoneScreen) = drivers.getValue(screen)
                override fun driver(screen: PhoneScreen, owner: PhoneTasks.Owner) = ledger.bind(drivers.getValue(screen), owner)
                override fun gate() = object : UserGate {
                    override fun confirm(request: ConfirmRequest) = Decision.ALLOW_ONCE
                    override fun handoff(reason: String, timeoutMs: Long): HandoffResult {
                        this@Fixture.handoff(); return HandoffResult.CONTINUE
                    }
                    override fun status(text: String?) {}
                }
                override fun a11yState() = A11yState.CONNECTED
                override fun backgroundUnavailable() = "unavailable"
                override fun zone() = ZoneId.of("UTC")
                override fun notifyFix(kind: String) {}
                override fun system() = object : SystemApi {
                    override fun apps(): List<AppEntry> { this@Fixture.apps(session); return emptyList() }
                    override fun isInstalled(pkg: String) = false
                    override fun prepareLaunch(app: AppEntry): Either<String, SystemLaunch> = error("unused")
                    override fun prepareUrl(url: String): Either<String, SystemLaunch> = error("unused")
                    override fun prepareIntent(spec: IntentSpec, selectedApp: AppEntry?): Either<String, SystemLaunch> = error("unused")
                    override fun launch(plan: SystemLaunch, dispatch: PhoneTasks.SystemDispatch): SysResult = error("unused")
                    override fun notify(title: String, text: String): SysResult = error("unused")
                    override fun clipboardSet(text: String): SysResult = error("unused")
                    override fun clipboardGet(): SysResult = this@Fixture.clipboard()
                }
            }, tasks, ActionLog(), main)
        }
        val legacy = PhoneTasks(clock = time::get, idSource = ids::incrementAndGet)
        val sessions = PhoneTaskSessions(time::get, ids::incrementAndGet, ::core, legacy, core(legacy, null),
            changed = { changed() }, onSettled = { settled(it) }, settleResources = { cleanup(it) },
            createBackgroundWorker = { SerialWorker("screen-bg", { bgClock() }) { false }.also { backgrounds += it } })
        fun admit(session: String?) = sessions.admit(session?.let { PhoneCaller(it, "run", "call", runLifecycle = 1) })
        fun call(session: String?, background: Boolean? = null): ToolOutput = sessions.run(admit(session),
            if (background == null) PhoneToolCatalog.APPS else PhoneToolCatalog.SCREEN,
            if (background == null) emptyMap() else mapOf("background" to background))
        fun task(session: String?) = sessions.all().single { it.sessionId == session }
        fun end(session: String) { sessions.admitEnd(session, "run")?.let(sessions::settleEnd) }
        override fun close() { pool.shutdownNow(); main.shutdown(); backgrounds.toList().forEach { it.shutdown() } }
    }
    private fun waitFor(latch: CountDownLatch) { assertTrue(latch.await(5, TimeUnit.SECONDS)) }
    private fun hold(latch: CountDownLatch, interrupted: CountDownLatch? = null) {
        var cancelled = false
        try {
            while (true) try { check(latch.await(5, TimeUnit.SECONDS)); return }
            catch (_: InterruptedException) { cancelled = true; interrupted?.countDown() }
        } finally { if (cancelled) Thread.currentThread().interrupt() }
    }

    @Test fun backgroundBodyAndUnrelatedMainBodyProgressButSameTaskWaits() = Fixture().use { f ->
        val bgEntered = CountDownLatch(1); val bgExit = CountDownLatch(1)
        val mainEntered = CountDownLatch(1); val mainExit = CountDownLatch(1)
        f.read = { session, screen ->
            if (session == "A") { assertEquals(PhoneScreen.BACKGROUND, screen); bgEntered.countDown(); hold(bgExit) }
            else { assertEquals(PhoneScreen.MAIN, screen); mainEntered.countDown(); hold(mainExit) }
        }
        val a = f.pool.submit<ToolOutput> { f.call("A", true) }
        try {
            waitFor(bgEntered)
            val b = f.pool.submit<ToolOutput> { f.call("B", false) }
            waitFor(mainEntered) // Old shared worker cannot reach this while A is held.
            assertSame(f.backgrounds.single(), f.task("A").activeWorker)
            assertSame(f.main, f.task("B").activeWorker)
            assertEquals(1, f.backgrounds.size)
            val next = f.pool.submit<ToolOutput> { f.call("A") }
            mainExit.countDown(); assertFalse(b.get(5, TimeUnit.SECONDS).isError)
            // The MAIN queue is now usable, but the same Task cannot leave its live BG body.
            try { next.get(100, TimeUnit.MILLISECONDS); fail("same task crossed its BG body") }
            catch (_: TimeoutException) { }
            bgExit.countDown(); assertFalse(a.get(5, TimeUnit.SECONDS).isError)
            assertFalse(next.get(5, TimeUnit.SECONDS).isError)
            assertEquals(1, f.backgrounds.size)
        } finally { bgExit.countDown(); mainExit.countDown() }
    }

    @Test fun backgroundWaiterDoesNotCreateALaneAndMainLeaseStillSerializes() = Fixture().use { f ->
        assertFalse(f.call("A", true).isError)
        val waiting = CountDownLatch(1)
        f.changed = { if (f.sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForScreen"] == "background" }) waiting.countDown() }
        val b = f.pool.submit<ToolOutput> { f.call("B", true) }
        waitFor(waiting); assertEquals(1, f.backgrounds.size); assertNull(f.task("B").backgroundWorker)
        f.end("A"); assertFalse(b.get(5, TimeUnit.SECONDS).isError)
        assertEquals(2, f.backgrounds.size); f.end("B")
        assertFalse(f.call("M", false).isError)
        val mainWaiting = CountDownLatch(1)
        f.changed = { if (f.sessions.snapshot().any { it["sessionId"] == "N" && it["waitingForScreen"] == "main" }) mainWaiting.countDown() }
        val n = f.pool.submit<ToolOutput> { f.call("N", false) }
        waitFor(mainWaiting); assertNull(f.task("N").activeWorker)
        f.end("M"); assertFalse(n.get(5, TimeUnit.SECONDS).isError)
        assertEquals(2, f.backgrounds.size)
    }

    @Test fun backgroundHandoffKeepsBothLeasesOnItsOriginalBackgroundLane() = Fixture().use { f ->
        assertFalse(f.call("A", true).isError)
        val lane = checkNotNull(f.task("A").backgroundWorker)
        val entered = CountDownLatch(1); val exit = CountDownLatch(1)
        f.handoff = { entered.countDown(); hold(exit) }
        val handoff = f.pool.submit<ToolOutput> {
            f.sessions.run(f.admit("A"), PhoneToolCatalog.HANDOFF, mapOf("reason" to "local fixture"))
        }
        try {
            waitFor(entered); assertSame(lane, f.task("A").activeWorker)
            val waiting = CountDownLatch(1)
            f.changed = { if (f.sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForScreen"] == "main" }) waiting.countDown() }
            val b = f.pool.submit<ToolOutput> { f.call("B", false) }
            waitFor(waiting); assertEquals(1, f.backgrounds.size)
            exit.countDown(); assertFalse(handoff.get(5, TimeUnit.SECONDS).isError)
            // Handoff is not the special confirmed-open MAIN loan; its MAIN remains held.
            assertFalse(b.isDone)
            f.end("A"); assertFalse(b.get(5, TimeUnit.SECONDS).isError)
        } finally { exit.countDown() }
    }

    @Test fun stopAndHostEndInterruptOnlyTheOriginalBackgroundBody() {
        for (hostEnd in listOf(false, true)) Fixture().use { f ->
            val bgEntered = CountDownLatch(1); val bgExit = CountDownLatch(1); val bgInterrupted = CountDownLatch(1)
            val mainEntered = CountDownLatch(1); val mainExit = CountDownLatch(1); val mainInterrupted = CountDownLatch(1)
            f.read = { _, _ -> bgEntered.countDown(); hold(bgExit, bgInterrupted) }
            f.apps = { mainEntered.countDown(); hold(mainExit, mainInterrupted) }
            val a = f.pool.submit<ToolOutput> { f.call("A", true) }
            val b = f.pool.submit<ToolOutput> { f.call("B") }
            try {
                waitFor(bgEntered); waitFor(mainEntered)
                if (hostEnd) f.end("A") else assertTrue(f.sessions.stop(f.task("A"), "stop"))
                waitFor(bgInterrupted)
                assertEquals(1L, mainInterrupted.count)
                assertTrue(f.task("A").running); assertFalse(f.task("A").resourcesReleased)
                bgExit.countDown(); assertTrue(a.get(5, TimeUnit.SECONDS).isError)
                mainExit.countDown(); assertFalse(b.get(5, TimeUnit.SECONDS).isError)
                assertNull(f.task("A").backgroundWorker)
            } finally { bgExit.countDown(); mainExit.countDown() }
        }
    }

    @Test fun timedOutBackgroundBodyKeepsTaskSlotUntilActualThreadExit() = Fixture().use { f ->
        val entered = CountDownLatch(1); val exit = CountDownLatch(1)
        val body = AtomicReference<Thread>()
        f.read = { _, _ -> body.set(Thread.currentThread()); entered.countDown(); hold(exit) }
        val a = f.pool.submit<ToolOutput> { f.call("A", true) }
        try {
            waitFor(entered); f.time.addAndGet(20_000)
            assertTrue(a.get(5, TimeUnit.SECONDS).isError)
            assertTrue(f.task("A").running)
            assertSame(f.backgrounds.single(), f.task("A").activeWorker)
            assertFalse(f.call("B").isError) // Unrelated metadata still progresses on MAIN.
            val next = f.pool.submit<ToolOutput> { f.call("A") }
            try { next.get(100, TimeUnit.MILLISECONDS); fail("same task left a live timed-out body") }
            catch (_: TimeoutException) { }
            exit.countDown(); body.get().join(5_000); assertFalse(body.get().isAlive)
            assertFalse(next.get(5, TimeUnit.SECONDS).isError)
            assertNull(f.task("A").activeWorker)
        } finally { exit.countDown() }
    }

    @Test fun selectedButNotSubmittedLaneCannotRunAfterStopOrRetire() {
        for (retire in listOf(false, true)) Fixture().use { f ->
            val selected = CountDownLatch(1); val submit = CountDownLatch(1)
            val first = AtomicBoolean(true); val reads = AtomicLong()
            f.bgClock = { if (first.compareAndSet(true, false)) { selected.countDown(); hold(submit) }; f.time.get() }
            f.read = { _, _ -> reads.incrementAndGet() }
            val a = f.pool.submit<ToolOutput> { f.call("A", true) }
            try {
                waitFor(selected)
                assertSame(f.backgrounds.single(), f.task("A").activeWorker)
                if (retire) f.sessions.retire() else assertTrue(f.sessions.stop(f.task("A"), "stop"))
                submit.countDown(); assertTrue(a.get(5, TimeUnit.SECONDS).isError)
                assertEquals(0L, reads.get())
            } finally { submit.countDown() }
        }
    }

    @Test fun retirementReachesBothLanesWithoutReturningTheOldPhysicalFence() = Fixture().use { f ->
        val bgEntered = CountDownLatch(1); val bgExit = CountDownLatch(1); val bgInterrupted = CountDownLatch(1)
        val mainEntered = CountDownLatch(1); val mainExit = CountDownLatch(1); val mainInterrupted = CountDownLatch(1)
        f.read = { _, _ -> bgEntered.countDown(); hold(bgExit, bgInterrupted) }
        f.apps = { mainEntered.countDown(); hold(mainExit, mainInterrupted) }
        val a = f.pool.submit<ToolOutput> { f.call("A", true) }
        val b = f.pool.submit<ToolOutput> { f.call("B") }
        try {
            waitFor(bgEntered); waitFor(mainEntered)
            val old = f.task("A")
            val released = CountDownLatch(1)
            f.settled = { task ->
                if (task === old && task.resourcesReleased && task.backgroundWorker == null) released.countDown()
            }
            f.sessions.retire(); waitFor(bgInterrupted); waitFor(mainInterrupted)
            assertFalse(old.resourcesReleased); assertNotNull(old.backgroundWorker)
            assertNull(f.sessions.tryReserveSelfCheck())
            bgExit.countDown(); mainExit.countDown()
            assertTrue("Retired BACKGROUND screen read must return an error", a.get(5, TimeUnit.SECONDS).isError)
            assertTrue("Retired MAIN apps read must return an error", b.get(5, TimeUnit.SECONDS).isError)
            // A cancelled call returns before its physical-drain settlement callback.
            waitFor(released)
            assertTrue(old.resourcesReleased); assertNull(old.backgroundWorker)
            f.apps = {}; assertFalse(f.call("new").isError)
        } finally { bgExit.countDown(); mainExit.countDown() }
    }

    @Test fun retiredSessionDoesNotPublishReadTextWhenTheDeviceConsumesInterrupt() = Fixture().use { f ->
        val entered = CountDownLatch(1); val interrupted = CountDownLatch(1)
        val release = CountDownLatch(1); val drained = CountDownLatch(1)
        val marker = "retired-fixture-read-value"
        f.clipboard = {
            entered.countDown()
            hold(release, interrupted)
            Thread.interrupted() // Model a device call that consumes the stop signal.
            SysResult(true, marker)
        }
        val result = f.pool.submit<ToolOutput> {
            f.sessions.run(f.admit("read"), PhoneToolCatalog.CLIPBOARD, mapOf("get" to true))
        }
        try {
            waitFor(entered)
            val old = f.task("read")
            f.sessions.retire()
            waitFor(interrupted)
            f.main.afterDrained(old.tasks) { drained.countDown() }
            assertEquals(1L, drained.count)
            assertFalse(result.isDone)
            release.countDown()
            val output = result.get(5, TimeUnit.SECONDS)
            assertTrue("retired read must be an error even when the device returns success", output.isError)
            assertFalse("retired text must not reach ToolOutput", output.text.contains(marker))
            waitFor(drained)
            assertFalse(f.call("new").isError)
        } finally { release.countDown() }
    }

    @Test fun failedCleanupRetainsLaneAndSuccessfulRetryClosesOnlyThatLane() = Fixture().use { f ->
        assertFalse(f.call("A", true).isError)
        val task = f.task("A"); val old = checkNotNull(task.backgroundWorker)
        f.cleanup = { error("release unconfirmed") }
        f.end("A")
        assertTrue(task.cleanupFailed); assertSame(old, task.backgroundWorker)
        assertTrue(old.run(100, 100) { "still retained" } is SerialWorker.Outcome.Done)
        f.cleanup = {}; assertTrue(f.sessions.retryCleanup(task.tasks.snapshot().id))
        assertNull(task.backgroundWorker)
        assertTrue(old.run(100, 100) { error("closed lane ran") } is SerialWorker.Outcome.Failed)
        assertFalse(f.call("B").isError)
        assertFalse(f.call("B", true).isError)
        assertNotSame(old, f.task("B").backgroundWorker)
    }

    @Test fun legacyRolloverClosesOldLaneAndMetadataNeverCreatesOne() = Fixture().use { f ->
        assertFalse(f.call(null).isError); assertTrue(f.backgrounds.isEmpty())
        assertFalse(f.call(null, true).isError)
        val old = checkNotNull(f.task(null).backgroundWorker)
        // Delayed inactive listener: the actual run rollover must still clean the old resource.
        f.legacy.endTask()
        assertFalse(f.call(null).isError)
        assertNull(f.task(null).backgroundWorker); assertEquals(1, f.backgrounds.size)
        assertTrue(old.run(100, 100) { error("retired lane ran") } is SerialWorker.Outcome.Failed)
        assertFalse(f.call(null, true).isError)
        assertEquals(2, f.backgrounds.size)
        assertNotSame(old, f.task(null).backgroundWorker)
    }
}
