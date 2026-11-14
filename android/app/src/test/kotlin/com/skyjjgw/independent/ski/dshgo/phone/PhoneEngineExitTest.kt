package com.skyjjgw.independent.ski.dshgo.phone

import java.time.ZoneId
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/**
 * Stopping the engine (PhoneControl.onEngineStopped: invalidate owners, close the bridge, retire
 * the worker, end the task) on the actual PhoneCore -> SerialWorker path; Android sides are fakes.
 */
class PhoneEngineExitTest {
    private val tasks = PhoneTasks()
    private val scrolls = AtomicInteger()
    private val notifications = AtomicInteger()
    private val workerThreads = mutableListOf<String>()
    private val scrolling = CountDownLatch(1)
    private val core = PhoneCore(object : PhoneEnv {
        override fun enabled() = true
        override fun policies() = PhonePolicies()
        override fun isLocked() = false
        override fun gate() = object : UserGate {
            override fun confirm(request: ConfirmRequest) = Decision.ALLOW_ONCE
            override fun handoff(reason: String, timeoutMs: Long) = HandoffResult.CONTINUE
            override fun status(text: String?) {}
        }
        override fun driver(screen: PhoneScreen): PhoneDriver = listDriver
        override fun a11yState() = A11yState.CONNECTED
        override fun backgroundUnavailable() = "unavailable"
        override fun zone() = ZoneId.of("UTC")
        override fun notifyFix(kind: String) {}
        override fun beforeHandoff(screen: PhoneScreen, owner: PhoneTasks.Owner): String? = null
        override fun sleep(ms: Long) {}
        override fun system() = object : SystemApi {
            override fun apps() = listOf(AppEntry("Example", PhoneAppIdentity("example.app", 10123)))
            override fun isInstalled(pkg: String) = true
            override fun prepareLaunch(app: AppEntry): Either<String, SystemLaunch> = Either.Right(TestSystemLaunch(SystemTarget.Known(app)))
            override fun launch(plan: SystemLaunch, dispatch: PhoneTasks.SystemDispatch) = error("unexpected launch")
            override fun prepareUrl(url: String): Either<String, SystemLaunch> = error("unexpected URL")
            override fun prepareIntent(spec: IntentSpec, selectedApp: AppEntry?): Either<String, SystemLaunch> = error("unexpected intent")
            override fun notify(title: String, text: String): SysResult {
                notifications.incrementAndGet()
                synchronized(workerThreads) { workerThreads += Thread.currentThread().name }
                return SysResult(true, "sent")
            }
            override fun clipboardSet(text: String) = error("unexpected clipboard")
            override fun clipboardGet() = error("unexpected clipboard")
        }
    }, tasks, ActionLog())

    /** Like MainScreenDriver.collect: scroll a page, wait for it to settle (interruptible), repeat. */
    private val listDriver = object : PhoneDriver {
        override val screen = PhoneScreen.MAIN
        override fun availability() = Availability(true)
        override fun foregroundPackage() = "example.app"
        override fun observe(detail: Boolean, image: Boolean) = ScreenSnapshot("s1", "Example", "Example", "example.app")
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?): CollectResult {
            synchronized(workerThreads) { workerThreads += Thread.currentThread().name }
            for (page in 1..maxPages) {
                if (Thread.currentThread().isInterrupted) return CollectResult(emptyList(), page - 1, "已停止", null)
                scrolls.incrementAndGet()
                scrolling.countDown()
                CountDownLatch(1).await(700, TimeUnit.MILLISECONDS) // settle
            }
            return CollectResult(listOf("item"), maxPages, "达到页数上限", null)
        }
        override fun target(screenId: String, elementId: Int): TargetInfo? = null
        override fun perform(action: PhoneAction) = error("unexpected action")
        override fun open(target: PhoneAppIdentity) = error("unexpected open")
    }

    private fun collect() = core.call(PhoneToolCatalog.COLLECT, mapOf("screen" to "s1", "list" to 1, "max_pages" to 3))
    private fun notifyCall() = core.call(PhoneToolCatalog.NOTIFY, mapOf("title" to "t", "text" to "x"))

    private fun call(name: String, block: () -> ToolOutput): Pair<Thread, AtomicReference<ToolOutput>> {
        val out = AtomicReference<ToolOutput>()
        return thread(name) { out.set(block()) } to out
    }

    private fun thread(name: String, block: () -> Unit) = Thread(block, name).apply { isDaemon = true; start() }

    /** What PhoneControl.onEngineStopped does to the core (the bridge and status are Android-side). */
    private fun engineStopped() {
        tasks.invalidateOwners()
        core.worker.retire()
        tasks.endTask()
    }

    private fun awaitQueued(t: Thread) {
        // Blocked in SerialWorker.run's poll: admitted under the old engine, waiting behind collect.
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (t.state != Thread.State.TIMED_WAITING) {
            assertTrue("call never queued", System.nanoTime() < deadline)
            Thread.sleep(5)
        }
    }

    @After fun close() = core.worker.shutdown()

    @Test fun engineExitStopsARunningCollectAndAQueuedOldCall() {
        val (collector, collected) = call("collect", ::collect)
        assertTrue(scrolling.await(5, TimeUnit.SECONDS))
        val (notifier, notified) = call("notify", ::notifyCall)
        awaitQueued(notifier)

        engineStopped()
        collector.join(5_000)
        notifier.join(5_000)

        assertEquals("no page after the engine stopped", 1, scrolls.get())
        assertTrue(collected.get().isError)
        assertTrue(collected.get().text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertEquals("the old engine's queued call never ran", 0, notifications.get())
        assertTrue(notified.get().isError)
        assertTrue(notified.get().text.startsWith(PhoneTasks.STOPPED_MESSAGE))
    }

    @Test fun aCallAfterTheEngineRestartsRunsOnTheSameWorker() {
        val (collector, _) = call("collect", ::collect)
        assertTrue(scrolling.await(5, TimeUnit.SECONDS))
        engineStopped()
        collector.join(5_000)

        val fresh = notifyCall()
        assertFalse(fresh.text, fresh.isError)
        assertEquals(1, notifications.get())
        // Retiring is not abandoning: the new call runs on the same worker thread.
        synchronized(workerThreads) { assertEquals(1, workerThreads.distinct().size) }
    }
}
