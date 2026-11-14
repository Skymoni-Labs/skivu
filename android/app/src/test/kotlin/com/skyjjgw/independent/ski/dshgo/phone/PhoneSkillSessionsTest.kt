package com.skyjjgw.independent.ski.dshgo.phone

import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillDrafts
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillLifecycle
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneTaskTrace
import java.time.ZoneId
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.*
import org.junit.Test

/** Actual registry/Core/worker/trace/draft lifecycle; only device calls and cleanup are fake. */
class PhoneSkillSessionsTest {
    private class Fixture(withJournal: Boolean = false) : AutoCloseable {
        val time = AtomicLong(1_000)
        val ids = AtomicLong()
        val trace = PhoneTaskTrace()
        val drafts = PhoneSkillDrafts()
        val lifecycle = PhoneSkillLifecycle(trace, drafts)
        val worker = SerialWorker("skill-sessions", time::get) { false }
        val pool = Executors.newCachedThreadPool()
        val starts = AtomicInteger()
        val completions = Collections.synchronizedList(mutableListOf<Pair<PhoneTaskTrace.OwnerKey, String>>())
        val completed = CountDownLatch(1)
        @Volatile var launch: () -> Unit = {}
        @Volatile var cleanup: (Long) -> Unit = {}
        val env = object : PhoneEnv {
            override fun enabled() = true
            override fun policies() = PhonePolicies(confirmMode = ConfirmMode.ASK)
            override fun isLocked() = false
            override fun gate() = object : UserGate {
                override fun confirm(request: ConfirmRequest) = Decision.ALLOW_ONCE
                override fun handoff(reason: String, timeoutMs: Long) = HandoffResult.CONTINUE
                override fun status(text: String?) {}
            }
            override fun driver(screen: PhoneScreen) = object : PhoneDriver {
                override val screen = screen
                override fun availability() = Availability(true)
                override fun foregroundPackage() = "example.app"
                override fun observe(detail: Boolean, image: Boolean) = ScreenSnapshot("${screen.prefix}1", "private", "Example", "example.app")
                override fun target(screenId: String, elementId: Int) = TargetInfo(screenId, elementId, "按钮", "搜索", "example.app", "Example", false, false, false)
                override fun perform(action: PhoneAction) = ActionResult(true, "done")
                override fun open(target: PhoneAppIdentity) = ActionResult(true, "opened")
                override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = error("unexpected collect")
            }
            override fun a11yState() = A11yState.CONNECTED
            override fun backgroundUnavailable() = "unavailable"
            override fun zone() = ZoneId.of("UTC")
            override fun notifyFix(kind: String) {}
            override fun system() = object : SystemApi {
                override fun apps() = listOf(AppEntry("Example", PhoneAppIdentity("example.app", 10123)))
                override fun isInstalled(pkg: String) = true
                override fun prepareLaunch(app: AppEntry): Either<String, SystemLaunch> = Either.Right(TestSystemLaunch(SystemTarget.Known(app)))
                override fun launch(plan: SystemLaunch, dispatch: PhoneTasks.SystemDispatch): SysResult {
                    check(dispatch.commitStart()); this@Fixture.launch(); return SysResult(true, "opened", plan.target)
                }
                override fun prepareUrl(url: String): Either<String, SystemLaunch> = error("unexpected url")
                override fun prepareIntent(spec: IntentSpec, selectedApp: AppEntry?): Either<String, SystemLaunch> = error("unexpected intent")
                override fun notify(title: String, text: String) = error("unexpected notify")
                override fun clipboardSet(text: String) = error("unexpected clipboard")
                override fun clipboardGet() = error("unexpected clipboard")
            }
        }
        var journalBytes: String? = null
        val journal = if (withJournal) PhoneTaskJournal({ journalBytes }, { journalBytes = it; true }) else null
        val legacy = PhoneTasks(clock = time::get, idSource = ids::incrementAndGet)
        val legacyCore = PhoneCore(env, legacy, ActionLog(), worker, skillTrace = trace)
        val sessions = PhoneTaskSessions(time::get, ids::incrementAndGet,
            { tasks, _ -> PhoneCore(env, tasks, ActionLog(), worker, skillTrace = trace) }, legacy, legacyCore,
            journal = journal, settleResources = { cleanup(it) }, startSkillScope = { owner -> starts.incrementAndGet(); lifecycle.startManaged(owner) },
            completeSkillScope = { owner, epoch, completion ->
                completions += PhoneTaskTrace.key(owner) to completion
                lifecycle.completeDrained(owner, epoch, completion).also { completed.countDown() }
            })
        init { lifecycle.launched() }
        fun call(session: String?, tool: String = PhoneToolCatalog.APPS, run: String = "1"): ToolOutput =
            sessions.run(sessions.admit(session?.let { PhoneCaller(it, run, "call", runLifecycle = 1) }), tool,
                if (tool == PhoneToolCatalog.OPEN) mapOf("app" to "example.app") else emptyMap())
        fun task(session: String?) = sessions.all().single { it.sessionId == session }
        fun owner(session: String?) = checkNotNull(task(session).skillScope).owner
        fun end(session: String, completion: String = "completed") { sessions.admitEnd(session, "1", completion)?.let(sessions::settleEnd) }
        override fun close() { pool.shutdownNow(); worker.shutdown() }
    }

    @Test fun legacyJournalRolloverSettlesOnlyTheOriginalTraceAndKeepsTheNewTraceActive() {
        Fixture(withJournal = true).use { f ->
            assertFalse(f.call(null).isError); val previous = f.owner(null)
            f.time.addAndGet(f.legacy.idleMs + 1)
            assertFalse(f.call(null).isError); val next = f.owner(null)
            assertNotEquals(previous.taskId, next.taskId)
            assertTrue(f.trace.snapshot(previous)!!.ended)
            assertFalse(f.trace.snapshot(next)!!.ended)
            assertEquals(2, f.starts.get()); assertEquals(1, f.completions.size)
            assertEquals(1, ((Json.parse(f.journalBytes!!) as Map<*, *>)["records"] as List<*>).size)
        }
    }

    @Test fun independentManagedScopesUseSharedTraceAndOriginalOwnerForTheCandidate() {
        Fixture().use { f ->
            assertFalse(f.call("A").isError); val a = f.owner("A")
            assertFalse(f.call("B").isError); val b = f.owner("B")
            assertFalse(f.trace.snapshot(a)!!.ended); assertFalse(f.trace.snapshot(b)!!.ended)
            assertFalse(f.call("A", PhoneToolCatalog.OPEN).isError)
            assertEquals(2, f.starts.get())
            f.end("A")
            assertEquals(PhoneTaskTrace.key(a), f.drafts.candidates().single().owner)
            assertNotEquals(a.lifecycle, f.task("A").finished!!.lifecycle)
            assertFalse(f.trace.snapshot(b)!!.ended)
            assertFalse(f.call("B", PhoneToolCatalog.OPEN).isError); f.end("B")
            assertEquals(setOf(PhoneTaskTrace.key(a), PhoneTaskTrace.key(b)), f.drafts.candidates().map { it.owner }.toSet())
        }
    }

    @Test fun pureReadStopsCompleteWithoutScreenLeasesAndDoNotExhaustEightTraceSlots() {
        Fixture().use { f ->
            repeat(10) { n ->
                val session = "read-$n"; assertFalse(f.call(session).isError)
                val owner = f.owner(session); f.sessions.stop(f.task(session), "stop")
                assertTrue(f.trace.snapshot(owner)!!.ended); assertFalse(f.trace.snapshot(owner)!!.eligible)
            }
            assertEquals(10, f.starts.get()); assertEquals(10, f.completions.size)
            assertNotNull(f.trace.snapshot(f.owner("read-9"))); assertTrue(f.drafts.candidates().isEmpty())
        }
    }

    @Test fun firstEndClassificationIsImmutableAndLegacyNeverOffersSuccess() {
        for (classification in listOf("other", "unknown")) Fixture().use { f ->
            assertFalse(f.call("A", PhoneToolCatalog.OPEN).isError); val a = f.owner("A")
            f.end("A", classification); f.end("A", "completed")
            assertTrue(f.trace.snapshot(a)!!.ended); assertFalse(f.trace.snapshot(a)!!.eligible)
            assertEquals(1, f.completions.size); assertTrue(f.drafts.candidates().isEmpty())
        }
        Fixture().use { f ->
            repeat(10) {
                assertFalse(f.call(null).isError); val owner = f.owner(null)
                assertNotNull(f.sessions.finish(f.task(null)))
                assertTrue(f.trace.snapshot(owner)!!.ended); assertFalse(f.trace.snapshot(owner)!!.eligible)
            }
            assertTrue(f.drafts.candidates().isEmpty()); assertEquals(10, f.completions.size)
        }
    }

    @Test fun failedPhysicalCleanupRetainsTheOriginalScopeUntilOneSuccessfulRetry() {
        Fixture().use { f ->
            assertFalse(f.call("A", PhoneToolCatalog.OPEN).isError); val a = f.owner("A")
            f.cleanup = { error("release not confirmed") }; f.end("A")
            assertTrue(f.task("A").cleanupFailed); assertFalse(f.trace.snapshot(a)!!.ended)
            assertTrue(f.completions.isEmpty()); assertTrue(f.drafts.candidates().isEmpty())
            f.cleanup = {}; assertTrue(f.sessions.retryCleanup(a.taskId))
            assertEquals(PhoneTaskTrace.key(a), f.drafts.candidates().single().owner)
            assertFalse(f.sessions.retryCleanup(a.taskId)); f.sessions.settleInactive(f.task("A"))
            assertEquals(1, f.completions.size)
        }
    }

    @Test fun cancelledRpcDoesNotCompleteTraceBeforeTheActualBodyAndCleanup() {
        Fixture().use { f ->
            val entered = CountDownLatch(1); val reply = CountDownLatch(1)
            f.launch = {
                entered.countDown()
                while (true) try { check(reply.await(5, TimeUnit.SECONDS)); break } catch (_: InterruptedException) { }
            }
            val call = f.pool.submit<ToolOutput> { f.call("A", PhoneToolCatalog.OPEN) }
            try {
                assertTrue(entered.await(5, TimeUnit.SECONDS)); val owner = f.owner("A")
                f.time.addAndGet(1_000_000)
                assertTrue(call.get(5, TimeUnit.SECONDS).isError)
                f.end("A")
                assertFalse(f.trace.snapshot(owner)!!.ended); assertTrue(f.completions.isEmpty())
                reply.countDown(); assertTrue(f.completed.await(5, TimeUnit.SECONDS))
                assertTrue(f.trace.snapshot(owner)!!.ended); assertFalse(f.trace.snapshot(owner)!!.canDraft)
                assertTrue(f.drafts.candidates().isEmpty())
            } finally { reply.countDown() }
        }
    }

    @Test fun stoppedScopeCannotBeUpgradedAndExplicitResumeStartsANewNativeOwner() {
        Fixture().use { f ->
            assertFalse(f.call("A", PhoneToolCatalog.OPEN).isError); val old = f.owner("A")
            val task = f.task("A"); f.sessions.stop(task, "stop")
            val oldStopped = task.tasks.snapshot()
            assertTrue(f.trace.snapshot(old)!!.ended); assertFalse(f.trace.snapshot(old)!!.eligible)
            assertTrue(f.sessions.resume(task))
            assertFalse(f.call("A", PhoneToolCatalog.OPEN).isError); val fresh = f.owner("A")
            assertNotEquals(PhoneTaskTrace.key(old), PhoneTaskTrace.key(fresh))
            assertFalse(f.sessions.stop(task, old, "late old button"))
            assertFalse(f.sessions.onInactive(task, oldStopped))
            assertFalse(checkNotNull(task.skillScope).cancelled)
            f.end("A")
            assertEquals(PhoneTaskTrace.key(fresh), f.drafts.candidates().single().owner)
            assertEquals(2, f.completions.size)
        }
    }

    @Test fun legacyIdleRolloverSettlesTheOldTraceBeforeReplacingItsOwner() {
        Fixture().use { f ->
            assertFalse(f.call(null, PhoneToolCatalog.OPEN).isError); val old = f.owner(null)
            f.time.addAndGet(1_000_000); assertTrue(f.legacy.expireIdle())
            val cleaned = mutableListOf<Long>(); f.cleanup = { cleaned += it }
            assertFalse(f.call(null, PhoneToolCatalog.OPEN).isError); val fresh = f.owner(null)
            assertNotEquals(old.taskId, fresh.taskId)
            assertEquals(listOf(old.taskId), cleaned)
            assertTrue(f.trace.snapshot(old)!!.ended); assertFalse(f.trace.snapshot(old)!!.eligible)
            assertFalse(f.trace.snapshot(fresh)!!.ended); assertTrue(f.drafts.candidates().isEmpty())
        }
    }

    @Test fun discardedTraceIsNotRecreatedByAnotherCallInTheSameScope() {
        Fixture().use { f ->
            assertFalse(f.call("A").isError); val owner = f.owner("A")
            f.trace.discard(PhoneTaskTrace.key(owner))
            assertFalse(f.call("A", PhoneToolCatalog.OPEN).isError)
            assertNull(f.trace.snapshot(owner)); assertEquals(1, f.starts.get())
            f.end("A"); assertTrue(f.drafts.candidates().isEmpty())
        }
    }

    @Test fun stopWinningDuringCleanupPreventsSuccessfulOffer() {
        Fixture().use { f ->
            assertFalse(f.call("A", PhoneToolCatalog.OPEN).isError); val owner = f.owner("A")
            f.cleanup = { f.sessions.stop(f.task("A"), "stop while cleaning") }
            f.end("A")
            assertTrue(f.trace.snapshot(owner)!!.ended); assertFalse(f.trace.snapshot(owner)!!.eligible)
            assertEquals(1, f.completions.size); assertTrue(f.drafts.candidates().isEmpty())
        }
    }

    @Test fun retirementRejectsLateStartAndLateCleanupFromThePreviousEpoch() {
        Fixture().use { f ->
            assertFalse(f.call("A", PhoneToolCatalog.OPEN).isError); val old = f.owner("A")
            f.cleanup = { f.lifecycle.retired(); f.sessions.retire(); f.lifecycle.launched() }
            f.end("A")
            assertNull(f.trace.snapshot(old)); assertTrue(f.drafts.candidates().isEmpty())
            f.cleanup = {}; assertFalse(f.call("B", PhoneToolCatalog.OPEN).isError)
            f.end("B"); assertEquals(PhoneTaskTrace.key(f.owner("B")), f.drafts.candidates().single().owner)
            f.lifecycle.retired()
            val separate = PhoneTasks(); val late = (separate.begin() as PhoneTasks.Begin.Go).owner
            assertNull(f.lifecycle.startManaged(late)); assertNull(f.trace.snapshot(late))
        }
    }
}
