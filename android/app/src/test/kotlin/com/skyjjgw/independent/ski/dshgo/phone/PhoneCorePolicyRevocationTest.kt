package com.skyjjgw.independent.ski.dshgo.phone

import android.os.Bundle
import com.skyjjgw.independent.ski.dshgo.phone.background.BackgroundDisplay
import com.skyjjgw.independent.ski.dshgo.phone.background.BackgroundDisplayIo
import com.skyjjgw.independent.ski.dshgo.phone.background.PrivilegedCalls
import com.skyjjgw.independent.ski.dshgo.phone.background.PrivilegedChannel
import java.time.ZoneId
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Real Core, SafetyGate, worker, Tasks and observation ledger; only device boundaries are fakes. */
class PhoneCorePolicyRevocationTest {
    private val tasks = PhoneTasks()
    private val ledger = PhoneTaskObservations(tasks)
    @Volatile private var policies = PhonePolicies()
    private var confirm: (ConfirmRequest) -> Decision = { Decision.ALLOW_ONCE }
    private var asked = 0
    private val main = Driver(PhoneScreen.MAIN)
    private val background = Driver(PhoneScreen.BACKGROUND)
    private val core = PhoneCore(object : PhoneEnv {
        override fun enabled() = true
        override fun policies() = policies
        override fun isLocked() = false
        override fun gate() = object : UserGate {
            override fun confirm(request: ConfirmRequest): Decision { asked++; return this@PhoneCorePolicyRevocationTest.confirm(request) }
            override fun handoff(reason: String, timeoutMs: Long) = error("unexpected handoff")
            override fun status(text: String?) {}
        }
        override fun driver(screen: PhoneScreen) = if (screen == PhoneScreen.MAIN) main else background
        override fun driver(screen: PhoneScreen, owner: PhoneTasks.Owner) = ledger.bind(driver(screen), owner)
        override fun a11yState() = A11yState.CONNECTED
        override fun backgroundUnavailable() = "unavailable"
        override fun zone() = ZoneId.of("UTC")
        override fun notifyFix(kind: String) {}
        override fun sleep(ms: Long) {}
        override fun system() = object : SystemApi {
            override fun apps() = listOf(AppEntry("Example", PhoneAppIdentity("example.app", 10123)))
            override fun isInstalled(pkg: String) = true
            override fun prepareLaunch(app: AppEntry): Either<String, SystemLaunch> = Either.Right(object : SystemLaunch {
                override val target = SystemTarget.Known(app)
            })
            override fun prepareUrl(url: String): Either<String, SystemLaunch> = error("unused")
            override fun prepareIntent(spec: IntentSpec, selectedApp: AppEntry?): Either<String, SystemLaunch> = error("unused")
            override fun launch(plan: SystemLaunch, dispatch: PhoneTasks.SystemDispatch): SysResult = error("unused")
            override fun notify(title: String, text: String): SysResult = error("unused")
            override fun clipboardSet(text: String): SysResult = error("unused")
            override fun clipboardGet(): SysResult = error("unused")
        }
    }, tasks, ActionLog())

    private class Driver(override val screen: PhoneScreen) : PhoneDriver {
        var writes = 0
        var opens = 0
        var openWithGate: ((PhoneAppIdentity, () -> Boolean) -> ActionResult)? = null
        var packageName = "example.app"
        var secret = false
        var scope: VisualScope? = null
        var beforeDispatch: () -> Unit = {}
        var performWithGate: ((() -> Boolean) -> ActionResult)? = null
        var capturedAllowed: (() -> Boolean)? = null
        var capturedAdmission: ((() -> Boolean) -> Boolean)? = null
        var returnedScreen: ScreenSnapshot? = null
        override fun availability() = Availability(true)
        override fun foregroundPackage() = packageName
        override fun observe(detail: Boolean, image: Boolean) = ScreenSnapshot("${screen.prefix}1", "screen", "Example", packageName)
        override fun target(screenId: String, elementId: Int) = TargetInfo(screenId, elementId,
            "button", "ordinary", packageName, "Example", secret, secret, secret)
        override fun visualScope(screenId: String) = scope
        override fun coordinateTarget(action: PhoneAction.TapXY) = scope?.let {
            VisualTarget(it, target(action.screenId, 1))
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?): CollectResult = error("unused")
        override fun open(target: PhoneAppIdentity): ActionResult = open(target) { true }
        override fun open(target: PhoneAppIdentity, allowed: () -> Boolean): ActionResult {
            openWithGate?.let { return it(target, allowed) }
            if (!allowed()) return ActionResult(false, "not admitted")
            opens++
            return ActionResult(true, "opened")
        }
        override fun perform(action: PhoneAction): ActionResult { writes++; return ActionResult(true, "done", returnedScreen) }
        override fun perform(action: PhoneAction, allowed: () -> Boolean,
                             coordinateAdmission: ((() -> Boolean) -> Boolean)?): ActionResult {
            capturedAllowed = allowed
            capturedAdmission = coordinateAdmission
            beforeDispatch()
            performWithGate?.let { return it(allowed) }
            val admitted = if (action is PhoneAction.TapXY) checkNotNull(coordinateAdmission).invoke { true }
                else allowed()
            return if (admitted) perform(action) else ActionResult(false, "not admitted")
        }
    }

    private fun observe(background: Boolean = false) {
        assertFalse(core.call(PhoneToolCatalog.SCREEN, mapOf("background" to background)).isError)
    }
    private fun tap(background: Boolean = false) = core.call(PhoneToolCatalog.TAP,
        mapOf("screen" to if (background) "b1" else "s1", "id" to 1))
    private fun coordinate() = core.call(PhoneToolCatalog.TAP_XY, mapOf("observation" to "s1", "x" to 2, "y" to 3))
    @After fun close() = core.worker.shutdown()

    @Test fun denyPublishedWhileTheRealConfirmationWaitsPreventsTheOriginalWrite() {
        observe()
        val owner = checkNotNull(tasks.activeOwner())
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        confirm = { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)); Decision.ALLOW_ONCE }
        val caller = Executors.newSingleThreadExecutor()
        try {
            val result = caller.submit<ToolOutput> { tap() }
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            policies = policies.copy(denyPackages = listOf("example.app"))
            release.countDown()
            assertTrue(result.get(3, TimeUnit.SECONDS).isError)
            assertEquals(0, main.writes)
            assertEquals(1, asked)
            assertTrue(tasks.isCurrent(owner)); assertFalse(tasks.isStopped())
        } finally { release.countDown(); caller.shutdownNow() }
    }

    @Test fun newHardRefusalsAfterConfirmationCannotUseTheOldUnlock() {
        val cases = listOf(
            Triple(SafetyRules.OWN_PACKAGE, false, PhoneUnlocks(ownApp = true)),
            Triple("com.android.settings", false, PhoneUnlocks(systemPages = true)),
            Triple("example.app", true, PhoneUnlocks(secretFields = true)),
        )
        for ((pkg, secret, unlocks) in cases) {
            main.packageName = pkg; main.secret = secret
            policies = PhonePolicies(denyPackages = emptyList(), unlocks = unlocks)
            observe()
            confirm = { policies = policies.copy(unlocks = PhoneUnlocks()); Decision.ALLOW_ONCE }
            assertTrue(tap().isError)
            assertEquals(0, main.writes)
        }
        assertEquals(3, asked)
    }

    @Test fun aVisualGrantCannotCoverANewOrdinaryConfirmationRequirement() {
        policies = PhonePolicies(confirmMode = ConfirmMode.ALWAYS)
        main.scope = VisualScope.Main(Any(), Any(), 1, "example.app")
        observe()
        confirm = { request ->
            assertNotNull(request.visualScope)
            policies = policies.copy(confirmMode = ConfirmMode.ASK,
                confirmEveryWritePackages = listOf("example.app"))
            Decision.ALLOW_VISUAL_FOR_TASK
        }
        val result = coordinate()
        assertTrue(result.isError)
        assertEquals(0, main.writes); assertEquals(1, asked)
    }

    @Test fun aRealOrdinaryOnceStillCoversThisActionWhenEveryWriteBecomesRequired() {
        observe()
        confirm = { policies = policies.copy(confirmEveryWritePackages = listOf("example.app")); Decision.ALLOW_ONCE }
        assertFalse(tap().isError)
        assertEquals(1, main.writes); assertEquals(1, asked)
    }

    @Test fun anUnrelatedPolicyChangeDoesNotDiscardAnExplicitCurrentAction() {
        observe()
        confirm = { policies = policies.copy(denyPackages = listOf("other.app")); Decision.ALLOW_ONCE }
        assertFalse(tap().isError)
        assertEquals(1, main.writes); assertEquals(1, asked)
    }

    @Test fun policyTighteningAfterCoreReturnsFromConfirmationIsStillInTheDriverGate() {
        for (isBackground in listOf(false, true)) {
            policies = PhonePolicies(); observe(isBackground)
            val driver = if (isBackground) background else main
            driver.beforeDispatch = { policies = policies.copy(denyPackages = listOf("example.app")) }
            assertTrue(tap(isBackground).isError)
            assertEquals(0, driver.writes)
            assertFalse(checkNotNull(driver.capturedAllowed)())
            assertTrue(tasks.isActive)
        }
    }

    @Test fun theQueuedCoordinateClaimAlsoChecksTheCurrentPolicy() {
        policies = PhonePolicies(confirmMode = ConfirmMode.ALWAYS)
        main.scope = VisualScope.Main(Any(), Any(), 1, "example.app")
        observe()
        confirm = { Decision.ALLOW_VISUAL_FOR_TASK }
        main.beforeDispatch = { policies = policies.copy(denyPackages = listOf("example.app")) }
        assertTrue(coordinate().isError)
        var claimed = 0
        assertFalse(checkNotNull(main.capturedAdmission).invoke { claimed++; true })
        assertEquals(0, claimed); assertEquals(0, main.writes)
    }

    @Test fun aPolicyRefusalAfterTheFirstSideEffectReportsUnknownPartialEffects() {
        observe()
        main.performWithGate = { allowed ->
            assertTrue(allowed())
            main.writes++ // Device already accepted the first part before the policy changed.
            policies = policies.copy(denyPackages = listOf("example.app"))
            if (allowed()) main.writes++ // The later submit must be refused.
            ActionResult(false, "first part accepted")
        }
        val result = tap()
        assertTrue(result.isError); assertEquals(1, main.writes)
        assertTrue(result.text.contains("可能已有部分效果"))
        assertTrue(result.text.contains("不要自动重试"))
    }

    @Test fun policyTighteningWhileTheActualBackgroundChannelWaitsSendsNothing() {
        val display = BackgroundDisplay(
            mayUse = { true }, admitUse = { action -> action(); true },
            channelProvider = { error("test owns the channel admission") },
        )
        val peer = object : PrivilegedChannel {
            override val backgroundLimit = 1
            override fun execute(request: Bundle, beforeSend: () -> Unit): Bundle = error("no Android Bundle exchange")
            override fun alive() = true
            override fun close() {}
        }
        @Suppress("UNCHECKED_CAST")
        val io = BackgroundDisplay::class.java.getDeclaredField("resourceIo")
            .apply { isAccessible = true }.get(display) as BackgroundDisplayIo<PrivilegedChannel>
        io.call { io.startResource(peer, { commit -> commit() }) { true } }
        val calls = PrivilegedCalls()
        val holding = CountDownLatch(1); val release = CountDownLatch(1); val waiting = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        try {
            val holder = pool.submit { calls.execute { holding.countDown(); check(release.await(3, TimeUnit.SECONDS)) } }
            assertTrue(holding.await(3, TimeUnit.SECONDS))
            background.performWithGate = { allowed ->
                val reply = display.dispatch(allowed) { beforeSend ->
                    waiting.countDown()
                    calls.execute(beforeSend = beforeSend) { background.writes++; "accepted" }
                }
                if (reply == null) ActionResult(false, "not admitted") else ActionResult(true, reply)
            }
            observe(true)
            val action = pool.submit<ToolOutput> { tap(true) }
            assertTrue(waiting.await(3, TimeUnit.SECONDS))
            policies = policies.copy(denyPackages = listOf("example.app"))
            release.countDown()
            assertTrue(action.get(3, TimeUnit.SECONDS).isError)
            holder.get(3, TimeUnit.SECONDS)
            assertEquals(0, background.writes)
            assertTrue(tasks.isActive)
            assertEquals("next", calls.execute { "next" })
        } finally { release.countDown(); calls.retire(); pool.shutdownNow() }
    }

    @Test fun aDeniedAppCannotMoveToTheBackgroundAfterItsOldConfirmation() {
        confirm = { policies = policies.copy(denyPackages = listOf("example.app")); Decision.ALLOW_ONCE }
        val result = core.call(PhoneToolCatalog.OPEN, mapOf("app" to "example.app", "background" to true))
        assertTrue(result.isError)
        assertEquals(1, asked); assertEquals(0, background.opens)
        assertTrue(tasks.isActive)
    }
    @Test fun denyWhileTheActualBackgroundLaunchChannelWaitsPreventsLaunch() {
        queuedBackgroundOpenPolicyChange(denyTarget = true)
    }

    @Test fun unrelatedPolicyChangeWhileBackgroundLaunchWaitsPreservesOriginalLaunch() {
        queuedBackgroundOpenPolicyChange(denyTarget = false)
    }

    private fun queuedBackgroundOpenPolicyChange(denyTarget: Boolean) {
        val display = BackgroundDisplay(
            mayUse = { true }, admitUse = { action -> action(); true },
            channelProvider = { error("test owns the channel admission") },
        )
        val peer = object : PrivilegedChannel {
            override val backgroundLimit = 1
            override fun execute(request: Bundle, beforeSend: () -> Unit): Bundle = error("no Android Bundle exchange")
            override fun alive() = true
            override fun close() {}
        }
        @Suppress("UNCHECKED_CAST")
        val io = BackgroundDisplay::class.java.getDeclaredField("resourceIo")
            .apply { isAccessible = true }.get(display) as BackgroundDisplayIo<PrivilegedChannel>
        io.call { io.startResource(peer, { commit -> commit() }) { true } }
        val calls = PrivilegedCalls()
        val holding = CountDownLatch(1); val release = CountDownLatch(1); val waiting = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        try {
            val holder = pool.submit { calls.execute { holding.countDown(); check(release.await(3, TimeUnit.SECONDS)) } }
            assertTrue(holding.await(3, TimeUnit.SECONDS))
            var original: PhoneAppIdentity? = null
            background.openWithGate = { target, allowed ->
                original = target
                val reply = display.dispatch(allowed) { beforeSend ->
                    waiting.countDown()
                    calls.execute(beforeSend = beforeSend) { background.opens++; "accepted" }
                }
                if (reply == null) ActionResult(false, "not admitted") else ActionResult(true, reply)
            }
            val action = pool.submit<ToolOutput> {
                core.call(PhoneToolCatalog.OPEN, mapOf("app" to "example.app", "background" to true))
            }
            assertTrue(waiting.await(3, TimeUnit.SECONDS))
            assertEquals(1, asked)
            policies = policies.copy(denyPackages = listOf(if (denyTarget) "example.app" else "other.app"))
            release.countDown()
            val output = action.get(3, TimeUnit.SECONDS)
            assertEquals(denyTarget, output.isError)
            if (denyTarget) {
                assertTrue(output.text.contains(SafetyGate.denied("Example")))
                assertFalse(output.text.contains(PhoneTasks.STOPPED_MESSAGE))
            }
            holder.get(3, TimeUnit.SECONDS)
            assertEquals(if (denyTarget) 0 else 1, background.opens)
            assertEquals(PhoneAppIdentity("example.app", 10123), original)
            assertSame(peer, io.peer()) // A refusal cannot prove or release the original resource.
            assertTrue(tasks.isActive)
            assertEquals("next", calls.execute { "next" })
        } finally { release.countDown(); calls.retire(); pool.shutdownNow() }
    }

}
