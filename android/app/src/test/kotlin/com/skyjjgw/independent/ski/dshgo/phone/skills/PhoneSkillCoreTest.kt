package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.phone.*
import java.time.ZoneId
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.*
import org.junit.Test

/** Real Core, worker and safety boundary with contract fakes; no Android stubs or log parsing. */
class PhoneSkillCoreTest {
    private class Fixture(worker: SerialWorker = SerialWorker("skill-core-test")) : AutoCloseable {
        val tasks = PhoneTasks()
        var approve = true
        var field = TargetInfo("b1", 1, "按钮", "搜索", "example.app", "PRIVATE_APP", false, false, false)
        var result = ActionResult(true, "PRIVATE_RESULT", ScreenSnapshot("b2", "PRIVATE_SCREEN", "PRIVATE_APP", "example.app"))
        var perform: () -> Unit = {}
        var failRead = false
        var writes = 0
        var opens = 0
        val driver = object : PhoneDriver {
            override val screen = PhoneScreen.BACKGROUND
            override fun availability() = Availability(true)
            override fun foregroundPackage() = "example.app"
            override fun target(screenId: String, elementId: Int) = field
            override fun perform(action: PhoneAction): ActionResult { writes++; perform(); return result }
            override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot {
                if (failRead) throw IllegalStateException("PRIVATE_READ_FAILURE")
                return result.screen!!
            }
            override fun open(target: PhoneAppIdentity): ActionResult { opens++; return result }
            override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) =
                CollectResult(listOf("PRIVATE_CONTENT"), 1, "PRIVATE_REASON", result.screen)
        }
        val system = object : SystemApi {
            override fun apps() = listOf(AppEntry("PRIVATE_APP", PhoneAppIdentity("example.app", 10123)))
            override fun isInstalled(pkg: String) = true
            override fun prepareLaunch(app: AppEntry): Either<String, SystemLaunch> = Either.Right(TestSystemLaunch(SystemTarget.Known(app)))
            override fun prepareUrl(url: String): Either<String, SystemLaunch> = Either.Right(TestSystemLaunch(SystemTarget.UserChoice, "url"))
            override fun prepareIntent(spec: IntentSpec, selectedApp: AppEntry?): Either<String, SystemLaunch> =
                Either.Right(TestSystemLaunch(SystemTarget.UserChoice, "intent", spec))
            override fun launch(plan: SystemLaunch, dispatch: PhoneTasks.SystemDispatch): SysResult {
                check(dispatch.commitStart())
                if ((plan as TestSystemLaunch).kind == "app") opens++
                return SysResult(true, "PRIVATE_RESULT", plan.target)
            }
            override fun notify(title: String, text: String) = SysResult(true, "PRIVATE_RESULT")
            override fun clipboardSet(text: String) = SysResult(true, "PRIVATE_RESULT")
            override fun clipboardGet() = SysResult(true, "PRIVATE_CLIPBOARD")
        }
        val core = PhoneCore(object : PhoneEnv {
            override fun enabled() = true
            override fun policies() = PhonePolicies(confirmMode = ConfirmMode.ASK)
            override fun isLocked() = false
            override fun gate() = object : UserGate {
                override fun confirm(request: ConfirmRequest) = if (approve) Decision.ALLOW_ONCE else Decision.DENY
                override fun handoff(reason: String, timeoutMs: Long) = HandoffResult.CONTINUE
                override fun status(text: String?) {}
            }
            override fun driver(screen: PhoneScreen) = if (screen == PhoneScreen.BACKGROUND) driver else null
            override fun a11yState() = A11yState.CONNECTED
            override fun backgroundUnavailable() = "unavailable"
            override fun zone() = ZoneId.of("UTC")
            override fun notifyFix(kind: String) {}
            override fun sleep(ms: Long) {}
            override fun system() = system
        }, tasks, ActionLog(), worker)
        fun tap() = core.call(PhoneToolCatalog.TAP, mapOf("screen" to "b1", "id" to 1))
        fun snapshot() = core.skillTrace.snapshot(tasks.activeOwner()!!)!!
        override fun close() { core.worker.shutdown() }
    }

    @Test fun safetyRefusalProducesNoCalledActionAndSuccessIsNotTaskCompletion() {
        Fixture().use { f ->
            f.approve = false; assertTrue(f.tap().isError)
            assertEquals(0, f.writes); assertTrue(f.snapshot().steps.isEmpty())
            f.approve = true; assertFalse(f.tap().isError)
            val snapshot = f.snapshot()
            assertEquals(1, f.writes)
            assertEquals(PhoneTaskTrace.Receipt.RETURNED_OK, snapshot.steps.single().receipt)
            assertTrue(snapshot.steps.single().postObservationAvailable)
            assertFalse(snapshot.canDraft)
        }
    }

    @Test fun actualTypeArgumentsAndResultScreenNeverEnterTraceOrDraft() {
        Fixture().use { f ->
            f.field = f.field.copy(role = "输入框", label = "张三", isEditable = true)
            assertFalse(f.core.call(PhoneToolCatalog.TYPE,
                mapOf("screen" to "b1", "id" to 1, "text" to "PRIVATE_INPUT https://example.com/?secret=foo")).isError)
            val owner = f.tasks.activeOwner()!!
            f.core.skillTrace.complete(owner, true)
            val trace = f.core.skillTrace.snapshot(owner)!!
            val result = PhoneSkillDraft.render(trace, NAME, true) as PhoneSkillDraft.Ready
            assertFalse(result.markdown.contains("PRIVATE_")); assertFalse(result.markdown.contains("张三"))
            assertFalse(trace.toString().contains("PRIVATE_")); assertTrue(result.markdown.contains("{{input_1}}"))
        }
    }

    @Test fun backgroundAndMainAppOpenHaveRealProducerBoundaries() {
        for (background in listOf(true, false)) Fixture().use { f ->
            assertFalse(f.core.call(PhoneToolCatalog.OPEN, mapOf("app" to "example.app", "background" to background)).isError)
            assertEquals(1, f.opens)
            val step = f.snapshot().steps.single()
            assertEquals(PhoneTaskTrace.Action.OPEN_APP, step.action)
            assertEquals(if (background) PhoneScreen.BACKGROUND else PhoneScreen.MAIN, step.screen)
            assertEquals(PhoneTaskTrace.Receipt.RETURNED_OK, step.receipt)
        }
    }

    @Test fun readsDoNotInventGapsButUnrepresentedEffectsDo() {
        Fixture().use { f ->
            f.core.call(PhoneToolCatalog.APPS, emptyMap())
            f.core.call(PhoneToolCatalog.SCREEN, mapOf("background" to true))
            f.core.call(PhoneToolCatalog.CLIPBOARD, mapOf("get" to true))
            f.tap(); assertNull(f.snapshot().gap)
            f.core.call(PhoneToolCatalog.COLLECT, mapOf("screen" to "b1", "list" to 1))
            assertEquals(PhoneTaskTrace.Gap.UNSUPPORTED_EFFECT, f.snapshot().gap)
        }
        for ((tool, args) in listOf(
            PhoneToolCatalog.NOTIFY to mapOf("title" to "PRIVATE_TITLE", "text" to "PRIVATE_BODY"),
            PhoneToolCatalog.CLIPBOARD to mapOf("set" to "PRIVATE_CLIPBOARD"),
            PhoneToolCatalog.OPEN to mapOf("url" to "https://example.com/PRIVATE_URL"))) Fixture().use { f ->
            f.core.call(tool, args)
            assertEquals(PhoneTaskTrace.Gap.UNSUPPORTED_EFFECT, f.snapshot().gap)
            assertFalse(f.snapshot().toString().contains("PRIVATE_"))
        }
    }

    @Test fun thrownDriverAndExplicitStaleCannotBecomeAnAcceptedRoute() {
        Fixture().use { f ->
            f.perform = { throw IllegalStateException("PRIVATE_THROWABLE") }
            assertTrue(f.tap().isError)
            assertEquals(PhoneTaskTrace.Receipt.UNCERTAIN, f.snapshot().steps.single().receipt)
            assertEquals(PhoneTaskTrace.Gap.UNCERTAIN_RESULT, f.snapshot().gap)
            assertFalse(f.snapshot().toString().contains("PRIVATE_"))
        }
        Fixture().use { f ->
            f.result = f.result.copy(ok = false, staleSnapshot = true)
            assertTrue(f.tap().isError)
            assertEquals(PhoneTaskTrace.Receipt.STALE_REJECTED, f.snapshot().steps.single().receipt)
            assertEquals(1, f.writes)
        }
    }

    @Test fun aPureReadExceptionDoesNotClaimAnUncertainWrite() {
        Fixture().use { f ->
            f.tap(); f.failRead = true
            assertTrue(f.core.call(PhoneToolCatalog.SCREEN, mapOf("background" to true)).isError)
            assertNull(f.snapshot().gap)
            assertEquals(PhoneTaskTrace.Receipt.RETURNED_OK, f.snapshot().steps.single().receipt)
        }
    }

    @Test fun actualCoreTimeoutCannotBeWashedAwayByALateDriverReturn() {
        val clock = AtomicLong(1000)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val worker = SerialWorker("skill-timeout", clock::get) { false }
        // Force one real Future timeout at a controlled clock; no sleeping or Android stubs.
        val original = object : ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, LinkedBlockingQueue<Runnable>()) {
            override fun <T> newTaskFor(callable: Callable<T>): RunnableFuture<T> = object : FutureTask<T>(callable) {
                override fun get(timeout: Long, unit: TimeUnit): T {
                    assertTrue(entered.await(5, TimeUnit.SECONDS))
                    clock.set(1_000_000)
                    throw TimeoutException("controlled deadline")
                }
            }
        }
        val field = SerialWorker::class.java.getDeclaredField("executor").apply { isAccessible = true }
        (field.get(worker) as ExecutorService).shutdownNow()
        field.set(worker, original)
        Fixture(worker).use { f ->
            f.perform = {
                entered.countDown()
                while (release.count != 0L) {
                    try { release.await() } catch (_: InterruptedException) { /* controlled late driver */ }
                }
            }
            try {
                assertTrue(f.tap().isError)
                assertEquals(PhoneTaskTrace.Gap.UNCERTAIN_RESULT, f.snapshot().gap)
                release.countDown()
                assertTrue(original.awaitTermination(5, TimeUnit.SECONDS))
                assertEquals(PhoneTaskTrace.Receipt.RETURNED_OK, f.snapshot().steps.single().receipt)
                assertEquals(PhoneTaskTrace.Gap.UNCERTAIN_RESULT, f.snapshot().gap)
                val owner = f.tasks.activeOwner()!!
                f.core.skillTrace.complete(owner, true)
                assertFalse(f.core.skillTrace.snapshot(owner)!!.canDraft)
            } finally {
                release.countDown()
                original.shutdownNow()
            }
        }
    }

    @Test fun completionDuringAnActualDriverCallRejectsItsLateResult() {
        Fixture().use { f ->
            var captured: PhoneTasks.Owner? = null
            f.perform = {
                val owner = f.tasks.activeOwner()!!; captured = owner
                f.core.skillTrace.complete(owner, false)
                f.tasks.stop("stop")
            }
            f.tap()
            val trace = f.core.skillTrace.snapshot(captured!!)!!
            assertTrue(trace.ended); assertFalse(trace.canDraft)
            assertEquals(PhoneTaskTrace.Receipt.CALLED, trace.steps.single().receipt)
            assertEquals(PhoneTaskTrace.Gap.UNCERTAIN_RESULT, trace.gap)
        }
    }

    private companion object { const val NAME = "phone-task-0123456789abcdef0123456789abcdef" }
}
