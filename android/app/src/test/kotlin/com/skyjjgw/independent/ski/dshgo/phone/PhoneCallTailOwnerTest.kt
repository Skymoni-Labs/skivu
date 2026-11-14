package com.skyjjgw.independent.ski.dshgo.phone

import java.time.ZoneId
import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.*
import org.junit.Test

/** Real worker and caller tails, gated by existing device/log interfaces, without timed sleeps. */
class PhoneCallTailOwnerTest {
    private class Fixture {
        val now = AtomicLong(1_000L)
        val tasks = PhoneTasks(clock = now::get, idleMs = 1_000L)
        val aTailEntered = CountDownLatch(1)
        val releaseATail = CountDownLatch(1)
        val bBodyEntered = CountDownLatch(1)
        val releaseBBody = CountDownLatch(1)
        val blockNextObservation = AtomicBoolean(false)
        val handoffs = mutableListOf<HandoffCause?>()
        private val logCalls = AtomicInteger()
        private val callers = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "phone-tail-caller").apply { isDaemon = true }
        }
        private val log = ActionLog(clock = {
            if (logCalls.getAndIncrement() == 0) {
                aTailEntered.countDown()
                awaitGate(releaseATail, "release A result bookkeeping")
            }
            now.get()
        })
        private val driver = object : PhoneDriver {
            override val screen = PhoneScreen.MAIN
            override fun availability() = Availability(true)
            override fun foregroundPackage() = "example.app"
            override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot {
                if (blockNextObservation.compareAndSet(true, false)) {
                    bBodyEntered.countDown()
                    awaitGate(releaseBBody, "release B observation")
                }
                return ScreenSnapshot("s1", "Example screen", "Example", "example.app")
            }
            override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = error("unexpected collect")
            override fun target(screenId: String, elementId: Int) = error("unexpected target")
            override fun perform(action: PhoneAction) = error("unexpected action")
            override fun open(target: PhoneAppIdentity) = error("unexpected background open")
        }
        val core = PhoneCore(object : PhoneEnv {
            override fun enabled() = true
            override fun policies() = PhonePolicies(denyPackages = listOf("blocked.app"))
            override fun isLocked() = false
            override fun gate() = object : UserGate {
                override fun confirm(request: ConfirmRequest) = error("unexpected confirmation")
                override fun handoff(reason: String, timeoutMs: Long) = error("the core passes a cause")
                override fun handoff(reason: String, timeoutMs: Long, cause: HandoffCause?): HandoffResult {
                    handoffs += cause
                    return HandoffResult.CONTINUE
                }
                override fun status(text: String?) {}
            }
            override fun driver(screen: PhoneScreen) = if (screen == PhoneScreen.MAIN) driver else null
            override fun a11yState() = A11yState.CONNECTED
            override fun backgroundUnavailable() = "unavailable"
            override fun zone() = ZoneId.of("UTC")
            override fun notifyFix(kind: String) {}
            override fun sleep(ms: Long) {}
            override fun system() = object : SystemApi {
                override fun apps() = listOf(AppEntry("Blocked", PhoneAppIdentity("blocked.app", 10123)))
                override fun isInstalled(pkg: String) = true
                override fun prepareLaunch(app: AppEntry): Either<String, SystemLaunch> = Either.Right(TestSystemLaunch(SystemTarget.Known(app)))
                override fun launch(plan: SystemLaunch, dispatch: PhoneTasks.SystemDispatch) = error("the deny list must prevent launch")
                override fun prepareUrl(url: String): Either<String, SystemLaunch> = error("unexpected URL")
                override fun prepareIntent(spec: IntentSpec, selectedApp: AppEntry?): Either<String, SystemLaunch> = error("unexpected intent")
                override fun notify(title: String, text: String) = error("unexpected notification")
                override fun clipboardSet(text: String) = error("unexpected clipboard")
                override fun clipboardGet() = error("unexpected clipboard")
            }
        }, tasks, log)

        fun oldRefusal(): Future<ToolOutput> = callers.submit(Callable {
            core.call(PhoneToolCatalog.OPEN, mapOf("app" to "blocked.app"))
        })

        fun handoff() = core.call(PhoneToolCatalog.HANDOFF, mapOf("reason" to "User input"))

        fun replaceWhileATailWaits(): Pair<ToolOutput, ToolOutput> {
            val a = oldRefusal()
            awaitGate(aTailEntered, "A body finished and reached the caller log")
            val oldId = tasks.snapshot().id
            assertEquals(1, tasks.callsInFlight)
            tasks.stop("replace old task")
            tasks.clearStop()
            blockNextObservation.set(true)
            val b = callers.submit(Callable { core.call(PhoneToolCatalog.SCREEN, emptyMap()) })
            awaitGate(bBodyEntered, "B began its own task")
            assertNotEquals(oldId, tasks.snapshot().id)
            assertEquals(2, tasks.callsInFlight)
            tasks.interject("only-for-B")
            // B's body does not use ActionLog while A owns its entries lock.
            releaseATail.countDown()
            val aResult = a.get(5, TimeUnit.SECONDS)
            releaseBBody.countDown()
            val bResult = b.get(5, TimeUnit.SECONDS)
            assertEquals(0, tasks.callsInFlight)
            return aResult to bResult
        }

        fun close() {
            releaseATail.countDown()
            releaseBBody.countDown()
            callers.shutdownNow()
            core.worker.shutdown()
        }
    }

    @Test fun anOldCallCannotConsumeItsSuccessorsInterjection() {
        val f = Fixture()
        try {
            val (a, b) = f.replaceWhileATailWaits()
            assertTrue(a.isError)
            assertFalse(b.isError)
            assertFalse("A must not consume B's text", a.text.contains("only-for-B"))
            assertTrue("B must receive its own text", b.text.contains("only-for-B"))
        } finally { f.close() }
    }

    @Test fun anOldRefusalCannotBeRelabelledAsItsSuccessorsHandoffCause() {
        val f = Fixture()
        try {
            f.replaceWhileATailWaits()
            assertFalse(f.handoff().isError)
            assertEquals(listOf<HandoffCause?>(null), f.handoffs)
        } finally { f.close() }
    }

    @Test fun anOldCallEndingDoesNotRestartItsSuccessorsIdleClock() {
        val f = Fixture()
        try {
            val a = f.oldRefusal()
            awaitGate(f.aTailEntered, "A result bookkeeping")
            val oldId = f.tasks.snapshot().id
            f.tasks.endTask()
            // A malformed OPEN still begins B, but has no summary and therefore no log wait.
            assertTrue(f.core.call(PhoneToolCatalog.OPEN, emptyMap()).isError)
            assertNotEquals(oldId, f.tasks.snapshot().id)
            assertEquals(1, f.tasks.callsInFlight)
            f.now.addAndGet(f.tasks.idleMs + 1)
            assertFalse("A is still counted until its result returns", f.tasks.expireIdle())
            f.releaseATail.countDown()
            assertTrue(a.get(5, TimeUnit.SECONDS).isError)
            assertEquals(0, f.tasks.callsInFlight)
            assertTrue("A must not refresh B's activity time", f.tasks.expireIdle())
        } finally { f.close() }
    }

    @Test fun aCurrentCallStillReturnsItsInterjectionAndNamesItsRefusal() {
        val f = Fixture()
        try {
            val a = f.oldRefusal()
            awaitGate(f.aTailEntered, "current call result bookkeeping")
            f.tasks.interject("only-for-A")
            f.releaseATail.countDown()
            assertTrue(a.get(5, TimeUnit.SECONDS).text.contains("only-for-A"))
            assertEquals(0, f.tasks.callsInFlight)
            assertFalse(f.handoff().isError)
            assertEquals(listOf(HandoffCause.DENY_LIST), f.handoffs)
        } finally { f.close() }
    }

    private companion object {
        fun awaitGate(gate: CountDownLatch, message: String) {
            assertTrue(message, gate.await(5, TimeUnit.SECONDS))
        }
    }
}
