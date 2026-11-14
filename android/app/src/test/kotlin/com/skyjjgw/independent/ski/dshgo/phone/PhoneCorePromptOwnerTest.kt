package com.skyjjgw.independent.ski.dshgo.phone

import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillReplaySelections
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillOutcomes
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillDrafts
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillNavigationWitness
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillBundleReader
import java.time.ZoneId
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Actual PhoneCore -> worker -> gate -> driver path; Android device interfaces are fakes. */
class PhoneCorePromptOwnerTest {
    private val tasks = PhoneTasks()
    private var confirm: () -> Decision = { Decision.ALLOW_ONCE }
    private var handoff: () -> HandoffResult = { HandoffResult.CONTINUE }
    private val handoffCauses = mutableListOf<HandoffCause?>()
    private var gateAvailable = true
    private var reviewRequired = false
    private var beforeHandoff: (PhoneTasks.Owner) -> Unit = {}
    private var asked = 0
    private val focusRequests = mutableListOf<ConfirmRequest>()
    private val confirmedPackages = mutableListOf<String?>()
    private val statuses = mutableListOf<String?>()
    private var beforeStatus: () -> Unit = {}
    private var deferStatus = false
    private val queuedStatuses = mutableListOf<() -> Unit>()
    private var lookup: () -> Unit = {}
    private var beforeResolve: () -> Unit = {}
    private var freshApp: Either<String, AppEntry> = Either.Right(AppEntry("Example", PhoneAppIdentity("example.app", 10123)))
    private var prepareSystem: () -> Unit = {}
    private var afterRejectedStart: () -> Unit = {}
    private var afterStart: () -> Unit = {}
    private var settle: () -> Unit = {}
    private var launchResult = SysResult(true, "launched")
    private var preparedTarget: SystemTarget = SystemTarget.Known(AppEntry("Example", PhoneAppIdentity("example.app", 10123)))
    private var preparedPlan: SystemLaunch? = null
    private var startedPlan: SystemLaunch? = null
    private var policies = PhonePolicies()
    private var policyRead: (() -> PhonePolicies)? = null
    private var launches = 0
    private var urls = 0
    private var intents = 0
    private val main = Driver(PhoneScreen.MAIN)
    private val background = Driver(PhoneScreen.BACKGROUND)
    private var boundMain: PhoneDriver? = null
    private val core = PhoneCore(object : PhoneEnv {
        override fun enabled() = true
        override fun policies() = policyRead?.invoke() ?: policies
        override fun isLocked() = false
        override fun gate() = if (!gateAvailable) null else object : UserGate {
            override fun confirm(request: ConfirmRequest): Decision { focusRequests += request; asked++; confirmedPackages += request.packageName; return confirm() }
            override fun handoff(reason: String, timeoutMs: Long): HandoffResult { asked++; return handoff() }
            override fun handoff(reason: String, timeoutMs: Long, cause: HandoffCause?): HandoffResult {
                handoffCauses += cause
                return handoff(reason, timeoutMs)
            }
            override fun status(text: String?) { statuses += text }
            override fun status(text: String?, ifCurrent: (() -> Unit) -> Boolean) {
                beforeStatus()
                val apply = { if (ifCurrent {}) statuses += text; Unit }
                if (deferStatus) queuedStatuses += apply else apply()
            }
        }
        override fun driver(screen: PhoneScreen): PhoneDriver = if (screen == PhoneScreen.MAIN) boundMain ?: main else background
        override fun a11yState() = A11yState.CONNECTED
        override fun backgroundUnavailable() = "unavailable"
        override fun zone() = ZoneId.of("UTC")
        override fun notifyFix(kind: String) {}
        override fun beforeHandoff(screen: PhoneScreen, owner: PhoneTasks.Owner): String? { beforeHandoff(owner); return null }
        override fun sleep(ms: Long) { settle() }
        override fun system() = object : SystemApi {
            override fun apps(): List<AppEntry> { lookup(); return listOf(AppEntry("Example", PhoneAppIdentity("example.app", 10123))) }
            override fun isInstalled(pkg: String) = true
            override fun prepareLaunch(app: AppEntry): Either<String, SystemLaunch> {
                beforeResolve()
                return when (val resolved = freshApp) {
                    is Either.Left -> resolved
                    is Either.Right -> Either.Right(TestSystemLaunch(SystemTarget.Known(resolved.value)).also { preparedPlan = it })
                }
            }
            override fun prepareUrl(url: String): Either<String, SystemLaunch> {
                lookup()
                return Either.Right(TestSystemLaunch(preparedTarget, "url").also { preparedPlan = it })
            }
            override fun prepareIntent(spec: IntentSpec, selectedApp: AppEntry?): Either<String, SystemLaunch> =
                Either.Right(TestSystemLaunch(preparedTarget, "intent", spec).also { preparedPlan = it })
            override fun launch(plan: SystemLaunch, dispatch: PhoneTasks.SystemDispatch): SysResult {
                commit(dispatch)
                startedPlan = plan
                val fake = plan as TestSystemLaunch
                when (fake.kind) { "app" -> launches++; "url" -> urls++; "intent" -> intents++ }
                afterStart()
                val result = if (fake.kind == "app") launchResult else SysResult(true, "attempted")
                val needsReview = reviewRequired && result.ok && dispatch.commitNotice()
                return SysResult(result.ok, result.message, plan.target, requiresReview = needsReview)
            }
            override fun notify(title: String, text: String) = error("unexpected notification")
            override fun clipboardSet(text: String) = error("unexpected clipboard")
            override fun clipboardGet() = error("unexpected clipboard")
        }
    }, tasks, ActionLog())

    private class Driver(override val screen: PhoneScreen) : PhoneDriver {
        var replayPlan: SkillReplayPlan? = null
        override fun prepareSkillReplayStep(step: SkillReplayStep): Either<String, SkillReplayPlan> =
            replayPlan?.let { Either.Right(it) } ?: Either.Left("no compatible page")
        var focusEnabled = false
        var focusToken: FocusObservation? = null
        var focusPrepares = 0
        var focusInputs = 0
        var focusCloses = 0
        var focusSecret = false
        var focusMethod = FocusInput.Method.INPUT_METHOD
        var beforeFocusInput: () -> Unit = {}
        override fun prepareFocusInput(screenId: String): Either<String, FocusInput> {
            focusPrepares++
            if (!focusEnabled || focusToken?.committed != true) return Either.Left("original response not committed")
            return Either.Right(object : FocusInput {
                override val method = focusMethod
                override val target = TargetInfo(screenId, 1, "输入框", "Search", targetPackage,
                    "Example", false, focusSecret, true)
                override fun perform(text: String, allowed: () -> Boolean): ActionResult {
                    beforeFocusInput()
                    if (!allowed()) return ActionResult(false, "no input")
                    focusInputs++
                    return ActionResult(true, "one selection insertion")
                }
                override fun close() { focusCloses++ }
            })
        }
        var reads = 0
        var writes = 0
        var targetPackage = "example.app"
        var tapSources: Set<String>? = null
        var beforeTapSources: () -> Unit = {}
        var tapSourceCalls = 0
        var scrollSources: Set<String> = emptySet()
        var beforeScrollSources: () -> Unit = {}
        var afterScrollSources: () -> Unit = {}
        var scrollSourceCalls = 0
        var opens = 0
        val openedTargets = mutableListOf<PhoneAppIdentity>()
        var observing: () -> Unit = {}
        var observedText = "Example"
        var observedPackage: String? = "example.app"
        var observedImage: ByteArray? = null
        var collects = 0
        var simulateCollectScroll = false
        var collectScrollInputs = 0
        var collectBatchCalls = 0
        var collectBatchSources: Set<String> = linkedSetOf("other.app", "cover.app")
        var beforeCollectBatch: () -> Unit = {}
        var afterCollectBatch: () -> Unit = {}
        var collecting: () -> Unit = {}
        var collectItems = listOf("late collected item")
        var collectPages = 1
        var collectScreen = true
        var collectReadPackages: Set<String> = emptySet()
        var collectStopReason = "pageLimit"
        var collectAllowed: (() -> Boolean)? = null
        var collectSnapshot: ScreenSnapshot? = null
        val actions = mutableListOf<PhoneAction>()
        override fun availability() = Availability(true)
        override fun foregroundPackage() = "example.app"
        override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot {
            reads++
            observing()
            return ScreenSnapshot("${screen.prefix}1", observedText, "Example", observedPackage, image = observedImage,
                focus = if (focusEnabled) FocusObservation(1).also { focusToken = it } else null)
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?): CollectResult {
            collects++
            collecting()
            val snapshot = if (collectScreen) collectSnapshot ?: ScreenSnapshot("${screen.prefix}2", "late collected screen",
                "Example", "example.app", image = byteArrayOf(1, 2, 3), imageMime = "image/png") else null
            return CollectResult(collectItems, collectPages, collectStopReason, snapshot, readPackages = collectReadPackages)
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?, allowed: () -> Boolean): CollectResult {
            collectAllowed = allowed
            return collect(screenId, listElementId, maxPages, until)
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?,
                             allowed: () -> Boolean, canRead: (String?) -> Boolean): CollectResult {
            if (!simulateCollectScroll) return collect(screenId, listElementId, maxPages, until, allowed)
            collectAllowed = allowed
            check(allowed() && canRead("other.app"))
            beforeCollectBatch()
            collectScrollInputs++ // Old device path: no batch gate, but a real simulated input.
            afterCollectBatch()
            return collect(screenId, listElementId, maxPages, until)
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?,
                             allowed: () -> Boolean, canRead: (String?) -> Boolean,
                             scrollSourcesAllowed: (Set<String>) -> Boolean): CollectResult {
            if (!simulateCollectScroll) return collect(screenId, listElementId, maxPages, until, allowed, canRead)
            collectAllowed = allowed
            check(allowed() && canRead("other.app"))
            beforeCollectBatch()
            collectBatchCalls++
            val admitted = try { scrollSourcesAllowed(collectBatchSources) } finally { afterCollectBatch() }
            if (admitted) collectScrollInputs++
            // Return prior content even on refusal: the real Core must suppress it.
            return collect(screenId, listElementId, maxPages, until)
        }
        override fun target(screenId: String, elementId: Int) = TargetInfo(screenId, elementId,
            "按钮", "发送", targetPackage, "Example", false, false, false)
        override fun perform(action: PhoneAction): ActionResult { actions += action; writes++; return ActionResult(true, "done") }
        override fun perform(action: PhoneAction, allowed: () -> Boolean,
                             coordinateAdmission: ((() -> Boolean) -> Boolean)?,
                             actionSourcesAllowed: (Set<String>) -> Boolean): ActionResult {
            if (!allowed()) return ActionResult(false, PhoneTasks.STOPPED_MESSAGE)
            if (action is PhoneAction.Scroll) {
                beforeScrollSources()
                scrollSourceCalls++
                val accepted = try { actionSourcesAllowed(scrollSources) } finally { afterScrollSources() }
                if (!accepted) return ActionResult(false, "source refused")
            }
            if (action is PhoneAction.Tap && tapSources != null) {
                beforeTapSources()
                tapSourceCalls++
                if (!actionSourcesAllowed(checkNotNull(tapSources))) return ActionResult(false, "source refused")
            }
            return perform(action)
        }
        override fun open(target: PhoneAppIdentity): ActionResult { openedTargets += target; opens++; return ActionResult(true, "opened") }
    }

    // Models the mandatory SystemApi ticket contract, not Android PM or Binder execution.
    private fun commit(dispatch: PhoneTasks.SystemDispatch) {
        prepareSystem()
        if (!dispatch.commitStart()) {
            afterRejectedStart()
            throw InterruptedException(PhoneTasks.STOPPED_MESSAGE)
        }
    }

    private fun replace() { tasks.endTask(); tasks.begin() }
    private fun handoffCall() = core.call(PhoneToolCatalog.HANDOFF, mapOf("reason" to "User input"))
    private fun tapCall() = core.call(PhoneToolCatalog.TAP, mapOf("screen" to "s1", "id" to 1))
    @After fun close() = core.worker.shutdown()

    private fun openApp() = core.call(PhoneToolCatalog.OPEN, mapOf("app" to "example.app"))
    private fun openUrl() = core.call(PhoneToolCatalog.OPEN, mapOf("url" to "https://example.com"))
    private fun shareIntent() = core.call(PhoneToolCatalog.INTENT,
        mapOf("kind" to "share", "app" to "example.app", "text" to "example"))

    @Test fun everySystemEntryUsesOneManualReviewAndNeverRepeatsTheLaunch() {
        reviewRequired = true
        for (call in listOf(::openApp, ::openUrl, ::shareIntent)) {
            val before = launches + urls + intents
            val beforeRead = main.reads
            handoff = {
                assertEquals(before + 1, launches + urls + intents)
                assertEquals(beforeRead, main.reads)
                HandoffResult.CONTINUE
            }
            val result = call()
            assertFalse(result.text, result.isError)
            assertEquals(before + 1, asked)
            assertEquals(before + 1, launches + urls + intents)
            assertEquals(beforeRead + 1, main.reads)
            assertTrue(result.text.contains(if (before == 0) "launched" else "attempted"))
        }
    }

    @Test fun manualReviewStopPreservesAttemptAndDoesNotReadOrRetry() {
        reviewRequired = true
        handoff = { HandoffResult.STOP }
        val result = openApp()
        assertTrue(result.isError)
        assertTrue(result.text.contains("launched"))
        assertEquals(1, launches)
        assertEquals(1, asked)
        assertEquals(0, main.reads)
        assertTrue(tasks.isStopped())
    }

    @Test fun manualReviewTimeoutPreservesAttemptAndDoesNotReadOrRetry() {
        reviewRequired = true
        handoff = { HandoffResult.TIMEOUT }
        val result = openApp()
        assertTrue(result.isError)
        assertTrue(result.text.contains("launched"))
        assertEquals(1, launches)
        assertEquals(1, asked)
        assertEquals(0, main.reads)
    }

    @Test fun interruptedManualReviewPreservesTheAttempt() {
        reviewRequired = true
        handoff = { throw InterruptedException("manual review interrupted") }
        val result = openApp()
        assertTrue(result.isError)
        assertTrue(result.text.contains("launched"))
        assertEquals(1, launches)
        assertEquals(1, asked)
        assertEquals(0, main.reads)
    }

    @Test fun anExemptOrFailedLaunchDoesNotAskForReview() {
        assertFalse(openApp().isError)
        reviewRequired = true
        launchResult = SysResult(false, "attempt failed")
        val result = openApp()
        assertTrue(result.isError)
        assertTrue(result.text.contains("attempt failed"))
        assertEquals(0, asked)
        assertEquals(2, launches)
        assertEquals(1, main.reads)
    }

    @Test fun unavailableManualReviewPreservesAttempt() {
        reviewRequired = true
        gateAvailable = false
        val result = openApp()
        assertTrue(result.isError)
        assertTrue(result.text.contains("launched"))
        assertEquals(1, launches)
        assertEquals(0, asked)
        assertEquals(0, main.reads)
    }

    @Test fun strictCleanupFailurePreservesAttemptWithoutOpeningAnotherPrompt() {
        reviewRequired = true
        beforeHandoff = { throw IllegalStateException("strict background release unconfirmed") }
        val result = openApp()
        assertTrue(result.isError)
        assertTrue(result.text.contains("launched"))
        assertFalse(result.text.contains("strict background release unconfirmed"))
        assertEquals(1, launches)
        assertEquals(0, asked)
        assertEquals(0, main.reads)
    }

    @Test fun replacementDuringManualReviewCannotReadOrStopTheSuccessor() {
        reviewRequired = true
        handoff = { replace(); HandoffResult.STOP }
        val result = openApp()
        assertTrue(result.isError)
        assertTrue(result.text.contains("launched"))
        assertEquals(1, launches)
        assertEquals(0, main.reads)
        assertTrue(tasks.isActive)
        assertFalse(tasks.isStopped())
    }

    @Test fun manualReviewStillFiltersTheFreshObservedScreen() {
        reviewRequired = true
        policies = PhonePolicies(denyPackages = listOf("blocked.screen"))
        main.observedPackage = "blocked.screen"
        main.observedText = "PRIVATE_BLOCKED_SCREEN"
        val result = openApp()
        assertFalse(result.text.contains("PRIVATE_BLOCKED_SCREEN"))
        assertTrue(result.text.contains("launched"))
        assertEquals(1, asked)
        assertEquals(1, launches)
        assertEquals(1, main.reads)
    }

    @Test fun stoppedWhileWaitingForManualReviewNeverReadsTheNextScreen() {
        reviewRequired = true
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val caller = Executors.newSingleThreadExecutor()
        handoff = {
            entered.countDown()
            assertTrue(release.await(5, TimeUnit.SECONDS))
            HandoffResult.CONTINUE
        }
        try {
            val reply = caller.submit<ToolOutput> { openApp() }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            assertEquals(1, launches)
            assertEquals(0, main.reads)
            tasks.stop("stopped during review")
            release.countDown()
            val result = reply.get(5, TimeUnit.SECONDS)
            assertTrue(result.isError)
            assertTrue(result.text.contains("launched"))
            assertEquals(1, launches)
            assertEquals(0, main.reads)
        } finally { release.countDown(); caller.shutdownNow() }
    }

    private fun collectCall(screen: String) = core.call(PhoneToolCatalog.COLLECT,
        mapOf("screen" to screen, "list" to 1, "max_pages" to 3))

    private fun assertCollectStopped(result: ToolOutput) {
        assertTrue(result.text, result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertFalse(result.text.contains("late collected item"))
        assertFalse(result.text.contains("late collected screen"))
        assertNull(result.image)
        assertEquals("stopped", core.log.last()?.decision)
    }

    @Test fun backgroundOpenUsesFreshIdentityBeforeApprovalAndNeverEmitsUid() {
        val identity = PhoneAppIdentity("example.app", 1010123)
        freshApp = Either.Right(AppEntry("Fresh label", identity))
        var resolved = false
        beforeResolve = { resolved = true }
        confirm = { assertTrue(resolved); Decision.ALLOW_ONCE }
        val output = core.call(PhoneToolCatalog.OPEN, mapOf("app" to "example.app", "background" to true))
        assertFalse(output.text, output.isError)
        assertEquals(listOf(identity), background.openedTargets)
        assertFalse(output.text.contains(identity.uid.toString()))
    }

    @Test fun unavailableFreshIdentityNeverFallsBackToTheCachedApp() {
        freshApp = Either.Left("identity unavailable")
        val output = core.call(PhoneToolCatalog.OPEN, mapOf("app" to "example.app", "background" to true))
        assertTrue(output.isError)
        assertEquals(0, background.opens)
        assertEquals(0, asked)
    }

    @Test fun stopDuringNativeIdentityRefreshCannotDispatchTheOldScope() {
        beforeResolve = { tasks.stop("stop during PM") }
        assertTrue(core.call(PhoneToolCatalog.OPEN, mapOf("app" to "example.app", "background" to true)).isError)
        assertEquals(0, background.opens)
    }

    @Test fun aStopDuringCollectDiscardsItsPartialItemsAndScreen() {
        background.collecting = { tasks.stop("stopped while collecting") }
        assertCollectStopped(collectCall("b1"))
        assertEquals(1, background.collects)
        assertTrue(tasks.isStopped())
    }

    @Test fun aReplacedCollectCannotPublishItsContentToTheSuccessor() {
        main.collecting = { replace(); tasks.setApp("successor") }
        assertCollectStopped(collectCall("s1"))
        assertEquals(1, main.collects)
        assertEquals("successor", tasks.snapshot().app)
        assertTrue(tasks.isActive)
        assertFalse(tasks.isStopped())
    }

    @Test fun clearingAStopDoesNotReviveTheOldCollectResult() {
        background.collecting = { tasks.stop("stop"); tasks.clearStop(); tasks.begin() }
        assertCollectStopped(collectCall("b1"))
        assertEquals(1, background.collects)
        assertTrue(tasks.isActive)
        assertFalse(tasks.isStopped())
    }

    @Test fun aCurrentCollectKeepsItsItemsAndOptionalScreen() {
        val mainResult = collectCall("s1")
        assertFalse(mainResult.text, mainResult.isError)
        assertTrue(mainResult.text.contains("late collected item"))
        assertTrue(mainResult.text.contains("late collected screen"))
        assertArrayEquals(byteArrayOf(1, 2, 3), mainResult.image)
        assertEquals("ok", core.log.last()?.decision)
        background.collectScreen = false
        val backgroundResult = collectCall("b1")
        assertFalse(backgroundResult.text, backgroundResult.isError)
        assertTrue(backgroundResult.text.contains("late collected item"))
        assertNull(backgroundResult.image)
        assertEquals(1, main.collects)
        assertEquals(1, background.collects)
    }

    @Test fun replacedTaskCannotLaunchAnApplicationAfterLookupReturns() {
        lookup = ::replace
        val result = openApp()
        assertTrue(result.text, result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertEquals(0, launches)
        assertTrue(tasks.isActive)
    }

    @Test fun clearingAStopDoesNotLetTheOldUrlLookupLaunchUnderANewTask() {
        lookup = { tasks.stop("stop"); tasks.clearStop(); tasks.begin() }
        val result = openUrl()
        assertTrue(result.text, result.isError)
        assertEquals(0, urls)
        assertTrue(tasks.isActive)
        assertFalse(tasks.isStopped())
    }

    @Test fun aStopDuringAppLookupPreventsTheIntentDispatch() {
        lookup = { tasks.stop("stop") }
        val result = shareIntent()
        assertTrue(result.text, result.isError)
        assertEquals(0, intents)
        assertTrue(tasks.isStopped())
    }

    @Test fun anInterruptedLookupCannotDispatchEvenWhileItsOwnerIsCurrent() {
        lookup = { Thread.currentThread().interrupt() }
        val result = shareIntent()
        assertTrue(result.text, result.isError)
        assertEquals(0, intents)
        assertTrue(tasks.isActive)
        assertFalse(tasks.isStopped())
    }

    @Test fun originalOwnerReachesAllThreeFinalSystemEntries() {
        prepareSystem = ::replace
        assertTrue(openApp().isError)
        assertTrue(openUrl().isError)
        assertTrue(shareIntent().isError)
        assertEquals(0, launches + urls + intents)
    }

    @Test fun aCommittedLateStartCannotRenameOrReadTheSuccessor() {
        afterStart = { replace(); tasks.setApp("successor") }
        assertTrue(openApp().isError)
        assertEquals(1, launches)
        assertEquals("successor", tasks.snapshot().app)
        assertEquals(0, main.reads)
    }

    @Test fun successfulSystemActionsPublishControlStatusBeforeTheirObservation() {
        main.observing = { assertTrue("Control status must be published before post-launch observation", statuses.any { !it.isNullOrBlank() }) }
        for (call in listOf(::openApp, ::openUrl, ::shareIntent)) {
            statuses.clear()
            assertFalse(call().isError)
            assertEquals(1, statuses.size)
            assertFalse(statuses.single()!!.contains("example.app"))
            assertFalse(statuses.single()!!.contains("https://"))
        }
        assertEquals(3, main.reads)
    }

    @Test fun aFailedSystemLaunchDoesNotPublishAnActiveControl() {
        launchResult = SysResult(false, "rejected")
        assertTrue(openApp().isError)
        assertTrue(statuses.isEmpty())
        assertEquals(0, main.reads)
    }

    @Test fun listingAppsDoesNotCreateAScreenControl() {
        assertFalse(core.call(PhoneToolCatalog.APPS, emptyMap()).isError)
        assertTrue(statuses.isEmpty())
        assertEquals(0, main.reads)
    }

    @Test fun stoppingAtTheStatusBoundaryCannotPublishOrReadForTheOldOwner() {
        beforeStatus = { tasks.stop("stop before status publication") }
        val result = openApp()
        assertTrue(result.isError)
        assertEquals(1, launches) // The already-returned system effect is not retracted.
        assertEquals(0, main.reads)
        assertTrue(statuses.isEmpty())
    }

    @Test fun delayedStatusIsRejectedAfterStopOrReplacementButCurrentStatusApplies() {
        deferStatus = true
        assertFalse(openApp().isError)
        val stopped = queuedStatuses.removeAt(0)
        tasks.stop("stop before UI application")
        stopped()
        assertTrue(statuses.isEmpty())
        tasks.clearStop()

        assertFalse(openApp().isError)
        val replaced = queuedStatuses.removeAt(0)
        replace()
        replaced()
        assertTrue(statuses.isEmpty())

        assertFalse(openApp().isError)
        queuedStatuses.removeAt(0)()
        assertEquals(1, statuses.size)
    }

    @Test fun currentSystemLaunchesStillDispatchExactlyOnce() {
        assertFalse(openApp().isError)
        assertFalse(openUrl().isError)
        assertFalse(shareIntent().isError)
        assertEquals(1, launches)
        assertEquals(1, urls)
        assertEquals(1, intents)
    }

    @Test fun currentHandoffContinuesAndReadsTheCurrentScreen() {
        assertFalse(handoffCall().isError)
        assertEquals(1, asked)
        assertEquals(1, main.reads)
    }

    @Test fun replacedTaskCannotContinueOldHandoffOrReadItsSuccessor() {
        handoff = { replace(); HandoffResult.CONTINUE }
        assertTrue(handoffCall().isError)
        assertEquals(0, main.reads)
        assertTrue(tasks.isActive)
    }

    @Test fun oldHandoffStopCannotStopItsSuccessor() {
        handoff = { replace(); HandoffResult.STOP }
        assertTrue(handoffCall().isError)
        assertTrue(tasks.isActive)
        assertFalse(tasks.isStopped())
    }

    @Test fun replacementDuringBeforeHandoffCannotAskUnderNewTask() {
        beforeHandoff = { replace() }
        assertTrue(handoffCall().isError)
        assertEquals(0, asked)
    }

    @Test fun handoffCleanupReceivesTheOriginalOwnerEvenWhenTheTaskIsReplacedInsideTheHook() {
        val original = (tasks.begin() as PhoneTasks.Begin.Go).owner
        var cleanupOwner: PhoneTasks.Owner? = null
        var successor: PhoneTasks.Owner? = null
        beforeHandoff = { captured ->
            replace()
            successor = tasks.activeOwner()
            cleanupOwner = captured // The real hook does not read the task's new activeOwner.
        }
        assertTrue(handoffCall().isError)
        assertEquals(original.taskId, cleanupOwner!!.taskId)
        assertEquals(original.lifecycle, cleanupOwner!!.lifecycle)
        assertNotEquals(successor!!.taskId, cleanupOwner!!.taskId)
        assertTrue(tasks.isCurrent(successor!!))
        assertEquals(0, asked)
        assertEquals(0, main.reads)
    }

    @Test fun lateConfirmationCannotWriteIntoSuccessor() {
        confirm = { replace(); Decision.ALLOW_ONCE }
        assertTrue(tapCall().isError)
        assertEquals(1, asked)
        assertEquals(0, main.writes)
        assertTrue(tasks.isActive)
    }

    @Test fun lateBackgroundMoveConfirmationCannotMoveApplication() {
        confirm = { replace(); Decision.ALLOW_ONCE }
        assertTrue(core.call(PhoneToolCatalog.OPEN, mapOf("app" to "example.app", "background" to true)).isError)
        assertEquals(1, asked)
        assertEquals(0, background.opens)
        assertTrue(tasks.isActive)
    }

    @Test fun currentConfirmedWriteStillExecutesExactlyOnce() {
        assertFalse(tapCall().isError)
        assertEquals(1, asked)
        assertEquals(1, main.writes)
    }

    @Test fun missingTapXYObservationNamesTheActualRequiredParameter() {
        val result = core.call(PhoneToolCatalog.TAP_XY, mapOf("x" to 1, "y" to 2))
        assertTrue(result.isError)
        assertEquals("缺少 observation（屏幕号，如 s7）。先调用 screen 拿到屏幕号。", result.text)
        assertEquals(0, asked)
        assertEquals(0, main.writes)
    }

    @Test fun screenIsNotAnAliasForTapXYObservation() {
        val result = core.call(PhoneToolCatalog.TAP_XY, mapOf("screen" to "s1", "x" to 1, "y" to 2))
        assertTrue(result.isError)
        assertEquals("缺少 observation（屏幕号，如 s7）。先调用 screen 拿到屏幕号。", result.text)
        assertEquals(0, asked)
        assertEquals(0, main.writes)
    }

    @Test fun otherRequiredScreenArgumentsKeepTheirExistingName() {
        for (tool in listOf(PhoneToolCatalog.TAP, PhoneToolCatalog.TYPE, PhoneToolCatalog.SCROLL, PhoneToolCatalog.COLLECT)) {
            val result = core.call(tool, mapOf("observation" to "s1"))
            assertTrue(result.isError)
            assertEquals("缺少 screen（屏幕号，如 s7）。先调用 screen 拿到屏幕号。", result.text)
        }
        assertEquals(0, asked)
        assertEquals(0, main.writes)
    }

    @Test fun validObservationKeepsScreenRoutingCoordinatesAndConfirmation() {
        for ((sid, driver) in listOf("s1" to main, "b1" to background)) {
            val before = asked
            val result = core.call(PhoneToolCatalog.TAP_XY, mapOf("observation" to sid, "x" to 11, "y" to 22))
            assertFalse(result.isError)
            assertEquals(before + 1, asked)
            assertEquals(listOf(PhoneAction.TapXY(sid, 11, 22)), driver.actions)
            assertEquals(1, driver.writes)
        }
    }
    private fun replaceDuringNextBegin() {
        var armed = true
        tasks.addListener { snapshot ->
            if (armed && snapshot.active) {
                armed = false
                tasks.stop("listener replaced the original begin")
                tasks.clearStop()
                tasks.begin()
                tasks.setApp("successor")
            }
        }
    }

    @Test fun beginListenerCannotLendSuccessorOwnerToOldLaunch() {
        replaceDuringNextBegin()
        val result = openApp()
        assertTrue(result.text, result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertEquals(0, launches)
        assertEquals(0, main.reads)
        assertEquals("successor", tasks.snapshot().app)
    }

    @Test fun beginListenerCannotLendSuccessorOwnerToOldWrite() {
        replaceDuringNextBegin()
        val result = tapCall()
        assertTrue(result.text, result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertEquals(0, asked)
        assertEquals(0, main.writes)
        assertEquals("successor", tasks.snapshot().app)
    }

    @Test fun launchObservationStoppedWhileReadingDiscardsOldScreen() {
        main.observedText = "late private screen"
        main.observedImage = byteArrayOf(1, 2, 3)
        main.observing = { tasks.stop("stopped while observing") }
        val result = openApp()
        assertTrue(result.text, result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertFalse(result.text.contains("late private screen"))
        assertTrue(result.text.contains("launched"))
        assertNull(result.image)
        assertEquals("stopped", core.log.last()!!.decision)
        assertTrue(core.log.last()!!.summary.contains("已尝试"))
        assertEquals(1, launches)
        assertEquals(1, main.reads)
    }

    @Test fun lateScreenCannotRenameReplacementTaskOrReturnItsContent() {
        main.observedText = "late private screen"
        main.observing = { replace(); tasks.setApp("successor") }
        val result = core.call(PhoneToolCatalog.SCREEN, emptyMap())
        assertTrue(result.text, result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertFalse(result.text.contains("late private screen"))
        assertEquals("successor", tasks.snapshot().app)
        assertEquals(1, main.reads)
    }

    @Test fun appLabelListenerReplacementPreventsPostLaunchObservation() {
        var armed = true
        tasks.addListener { snapshot ->
            if (armed && snapshot.app == "Example") {
                armed = false
                replace()
                tasks.setApp("successor")
            }
        }
        val result = openApp()
        assertTrue(result.text, result.isError)
        assertEquals(1, launches)
        assertEquals(0, main.reads)
        assertEquals("successor", tasks.snapshot().app)
        assertTrue("The app-label listener retired this owner before status publication", statuses.isEmpty())
    }

    @Test fun stoppingDuringSettlePreservesTheReturnedSystemResultWithoutReading() {
        settle = { tasks.stop("stop during settle") }
        val result = openApp()
        assertTrue(result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertTrue(result.text.contains("launched"))
        assertNull(result.image)
        assertEquals(1, launches)
        assertEquals(0, main.reads)
        assertEquals("stopped", core.log.last()!!.decision)
        assertTrue(core.log.last()!!.summary.contains("已尝试"))
        assertFalse(core.log.last()!!.summary.contains("launched"))
    }

    @Test fun interruptedSettlePreservesTheReturnedSystemResult() {
        settle = { throw InterruptedException("settle interrupted") }
        val result = openApp()
        assertTrue(result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertTrue(result.text.contains("launched"))
        assertEquals(1, launches)
        assertEquals(0, main.reads)
        assertEquals("stopped", core.log.last()!!.decision)
        assertTrue(core.log.last()!!.summary.contains("已尝试"))
    }

    @Test fun aFailedSystemReturnIsPreservedWhenItsOwnerWasReplaced() {
        launchResult = SysResult(false, "platform rejected private payload")
        afterStart = { replace(); tasks.setApp("successor") }
        val result = openApp()
        assertTrue(result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertTrue(result.text.contains(launchResult.message))
        assertEquals("successor", tasks.snapshot().app)
        assertEquals(0, main.reads)
        assertEquals(1, launches)
        assertEquals("stopped", core.log.last()!!.decision)
        assertTrue(core.log.last()!!.summary.contains("已尝试"))
        assertFalse(core.log.last()!!.summary.contains("private payload"))
    }

    @Test fun everySystemEntrySubmitsTheExactPreparedObject() {
        for (call in listOf(::openApp, ::openUrl, ::shareIntent)) {
            assertFalse(call().isError)
            assertNotNull(preparedPlan)
            assertSame(preparedPlan, startedPlan)
        }
    }

    @Test fun freshMainAppIdentityIsCheckedInsteadOfTheCachedApp() {
        policies = PhonePolicies(denyPackages = listOf("blocked.handler"))
        freshApp = Either.Right(AppEntry("Handler", PhoneAppIdentity("blocked.handler", 20234)))
        assertTrue(openApp().isError)
        assertEquals(0, launches)
        assertNull(startedPlan)
    }

    @Test fun urlAndFixedIntentCheckTheActualPreparedHandler() {
        policies = PhonePolicies(denyPackages = listOf("blocked.handler"))
        preparedTarget = SystemTarget.Known(AppEntry("Handler", PhoneAppIdentity("blocked.handler", 20234)))
        assertTrue(openUrl().isError)
        assertTrue(core.call(PhoneToolCatalog.INTENT, mapOf("kind" to "settings", "page" to "wifi")).isError)
        assertEquals(0, urls + intents)
        assertNull(startedPlan)
    }

    @Test fun settingsSubjectIsNotUsedAsTheHandlerAndChooserHasNoInventedApp() {
        policies = PhonePolicies(denyPackages = listOf("example.app"))
        preparedTarget = SystemTarget.Known(AppEntry("Settings handler", PhoneAppIdentity("vendor.settings", 1000)))
        assertFalse(core.call(PhoneToolCatalog.INTENT,
            mapOf("kind" to "settings", "page" to "app_notifications", "app" to "example.app")).isError)
        assertEquals(1, intents)
        assertEquals("Settings handler", tasks.snapshot().app)
        replace() // A chooser cannot invent a handler for this new task.
        preparedTarget = SystemTarget.UserChoice
        assertFalse(openUrl().isError)
        assertNull(tasks.snapshot().app)
        assertSame(SystemTarget.UserChoice, startedPlan!!.target)
    }

    @Test fun mismatchedPostObservationIsAttachedWithoutRelabelingOrRetryingThePlan() {
        main.observedPackage = "another.app"
        main.observedText = "ACTUAL_OTHER_SCREEN"
        val result = openApp()
        assertFalse(result.isError)
        assertTrue(result.text.contains("ACTUAL_OTHER_SCREEN"))
        assertTrue(result.text.contains("未确认原处理应用"))
        assertEquals(1, launches)
        assertEquals(1, main.reads)
        assertEquals("example.app", (startedPlan!!.target as SystemTarget.Known).app.packageName)
    }


    @Test fun lateHandlerDenyBeforeSystemCommitBlocksEveryEntryWithoutStoppingItsOwner() {
        for (call in listOf(::openApp, ::openUrl, ::shareIntent)) {
            policies = PhonePolicies()
            prepareSystem = { policies = PhonePolicies(denyPackages = listOf("example.app")) }
            val result = call()
            assertTrue(result.text, result.isError)
            assertEquals(0, launches + urls + intents)
            assertNull(startedPlan)
            assertTrue(tasks.isActive)
            assertFalse(tasks.isStopped())
            assertFalse(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
            assertNotEquals("stopped", core.log.last()!!.decision)
        }
    }

    @Test fun lateShareSubjectDenyStillBlocksWhenItsHandlerIsDifferent() {
        preparedTarget = SystemTarget.Known(AppEntry("Other handler", PhoneAppIdentity("other.handler", 20234)))
        prepareSystem = { policies = PhonePolicies(denyPackages = listOf("example.app")) }
        val result = shareIntent()
        assertTrue(result.text, result.isError)
        assertEquals(0, intents)
        assertNull(startedPlan)
        assertTrue(tasks.isActive)
        assertFalse(tasks.isStopped())
        assertFalse(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertNotEquals("stopped", core.log.last()!!.decision)
    }

    @Test fun lateSystemDenyNamesTheFollowingHandoffWithoutChangingFailedDispatchFacts() {
        for (call in listOf(::openApp, ::openUrl, ::shareIntent)) {
            policies = PhonePolicies()
            prepareSystem = { policies = PhonePolicies(denyPackages = listOf("example.app")) }
            val result = call()
            assertTrue(result.text, result.isError)
            assertEquals("failed", core.log.last()!!.decision)
            assertEquals(0, launches + urls + intents)
            assertNull(startedPlan)
            assertTrue(tasks.isActive)
            assertFalse(tasks.isStopped())
            policies = PhonePolicies()
            assertFalse(handoffCall().isError)
            assertEquals(HandoffCause.DENY_LIST, handoffCauses.last())
        }
        assertEquals(3, handoffCauses.size)
    }

    @Test fun anUnclassifiedLateSystemRefusalClearsTheSameOwnersEarlierCause() {
        policies = PhonePolicies(denyPackages = listOf("example.app"))
        assertTrue(openApp().isError)
        assertEquals("refused:deny-list", core.log.last()!!.decision)
        val owner = checkNotNull(tasks.activeOwner())
        policies = PhonePolicies(unlocks = PhoneUnlocks(ownApp = true))
        preparedTarget = SystemTarget.Known(AppEntry("DSH", PhoneAppIdentity(SafetyRules.OWN_PACKAGE, 10123)))
        prepareSystem = { policies = PhonePolicies() }
        val result = openUrl()
        assertTrue(result.text, result.isError)
        assertEquals("failed", core.log.last()!!.decision)
        assertTrue(tasks.isCurrent(owner))
        assertEquals(0, launches + urls + intents)
        assertNull(startedPlan)
        assertFalse(handoffCall().isError)
        assertEquals(listOf<HandoffCause?>(null), handoffCauses)
    }

    @Test fun aLateRefusalFromAnOldOwnerCannotClearTheSuccessorsOwnCause() {
        val successorWorker = SerialWorker("successor-refusal")
        try {
            policies = PhonePolicies(unlocks = PhoneUnlocks(ownApp = true))
            preparedTarget = SystemTarget.Known(AppEntry("DSH", PhoneAppIdentity(SafetyRules.OWN_PACKAGE, 10123)))
            prepareSystem = { policies = PhonePolicies() }
            afterRejectedStart = {
                // The old platform start was denied; before its exception reaches Core,
                // another owner establishes its own refusal on the real prepared-call API.
                replace()
                afterRejectedStart = {}
                policies = PhonePolicies(denyPackages = listOf("example.app"))
                val successor = checkNotNull(tasks.activeOwner())
                tasks.callStarted()
                try {
                    val prepared = when (val next = core.prepareCall(PhoneToolCatalog.OPEN,
                        mapOf("app" to "example.app"), successor)) {
                        is Either.Left -> error("Expected a prepared successor: ${next.value.text}")
                        is Either.Right -> next.value
                    }
                    assertTrue(core.call(prepared, successorWorker).isError)
                    assertEquals("refused:deny-list", core.log.last()!!.decision)
                } finally { tasks.callEnded(successor) }
            }
            assertTrue(openUrl().isError)
            assertEquals("stopped", core.log.last()!!.decision)
            assertEquals(0, launches + urls + intents)
            assertNull(startedPlan)
            assertTrue(tasks.isActive)
            assertFalse(tasks.isStopped())
            policies = PhonePolicies()
            assertFalse(handoffCall().isError)
            assertEquals(listOf(HandoffCause.DENY_LIST), handoffCauses)
        } finally { successorWorker.shutdown() }
    }

    @Test fun unrelatedLateDenyDoesNotCancelAnySystemEntry() {
        for (call in listOf(::openApp, ::openUrl, ::shareIntent)) {
            policies = PhonePolicies()
            prepareSystem = { policies = PhonePolicies(denyPackages = listOf("unrelated.app")) }
            val before = launches + urls + intents
            val result = call()
            assertFalse(result.text, result.isError)
            assertEquals(before + 1, launches + urls + intents)
            assertSame(preparedPlan, startedPlan)
            assertTrue(tasks.isActive)
            assertFalse(tasks.isStopped())
        }
        assertEquals(1, launches)
        assertEquals(1, urls)
        assertEquals(1, intents)
    }

    @Test fun policyTighteningAfterSystemStartPreservesAttemptWithoutRedispatch() {
        for (call in listOf(::openApp, ::openUrl, ::shareIntent)) {
            policies = PhonePolicies()
            afterStart = { policies = PhonePolicies(denyPackages = listOf("example.app")) }
            val before = launches + urls + intents
            val result = call()
            assertEquals(before + 1, launches + urls + intents)
            assertSame(preparedPlan, startedPlan)
            assertTrue(result.text, result.text.contains(if (before == 0) "launched" else "attempted"))
            assertFalse(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
            assertNotEquals("stopped", core.log.last()!!.decision)
            assertTrue(tasks.isActive)
            assertFalse(tasks.isStopped())
        }
        assertEquals(1, launches)
        assertEquals(1, urls)
        assertEquals(1, intents)
    }

    @Test fun lateCollectTargetDenialDiscardsItemsAndOptionalScreenWithoutStoppingOwner() {
        for (driver in listOf(main, background)) for (withScreen in listOf(true, false)) {
            policies = PhonePolicies()
            driver.collectScreen = withScreen
            val before = driver.collects
            var original: PhoneTasks.Owner? = null
            driver.collecting = {
                original = checkNotNull(tasks.activeOwner())
                policies = PhonePolicies(denyPackages = listOf("example.app"))
            }
            val result = collectCall("${driver.screen.prefix}1")
            assertTrue(result.text, result.isError)
            assertFalse(result.text.contains("late collected item"))
            assertFalse(result.text.contains("late collected screen"))
            assertNull(result.image)
            assertEquals("refused:deny-list", core.log.last()!!.decision)
            assertFalse(tasks.isStopped())
            assertTrue(tasks.isCurrent(checkNotNull(original)))
            assertEquals(before + 1, driver.collects)
        }
    }

    @Test fun unrelatedCollectDenialKeepsItemsAndOptionalScreenForOriginalOwner() {
        for (driver in listOf(main, background)) for (withScreen in listOf(true, false)) {
            policies = PhonePolicies()
            driver.collectScreen = withScreen
            val before = driver.collects
            var original: PhoneTasks.Owner? = null
            driver.collecting = {
                original = checkNotNull(tasks.activeOwner())
                policies = PhonePolicies(denyPackages = listOf("unrelated.app"))
            }
            val result = collectCall("${driver.screen.prefix}1")
            assertFalse(result.text, result.isError)
            assertTrue(result.text.contains("late collected item"))
            assertEquals(withScreen, result.text.contains("late collected screen"))
            if (withScreen) assertArrayEquals(byteArrayOf(1, 2, 3), result.image)
            else assertNull(result.image)
            assertEquals("ok", core.log.last()!!.decision)
            assertFalse(tasks.isStopped())
            assertTrue(tasks.isCurrent(checkNotNull(original)))
            assertEquals(before + 1, driver.collects)
        }
    }
    @Test fun observedCollectDenialRemainsRefusedAfterThePolicyIsRestored() {
        for (driver in listOf(main, background)) {
            policies = PhonePolicies()
            driver.collecting = {
                val allowed = checkNotNull(driver.collectAllowed)
                assertTrue(allowed())
                policies = PhonePolicies(denyPackages = listOf("example.app"))
                assertFalse(allowed())
                policies = PhonePolicies()
                assertFalse(allowed())
            }
            val result = collectCall("${driver.screen.prefix}1")
            assertTrue(result.isError)
            assertFalse(result.text.contains("late collected item"))
            assertFalse(result.text.contains("late collected screen"))
            assertNull(result.image)
            assertEquals("refused:deny-list", core.log.last()!!.decision)
            assertFalse(tasks.isStopped())
            assertEquals(1, driver.collects)
        }
    }

    @Test fun collectChecksBothItsOriginalPackageAndTheReturnedPackage() {
        for (driver in listOf(main, background)) for (denied in listOf("example.app", "other.app")) {
            policies = PhonePolicies()
            driver.collectSnapshot = ScreenSnapshot("${driver.screen.prefix}2", "late collected screen",
                "Other", "other.app", image = byteArrayOf(1), imageMime = "image/png")
            driver.collecting = { policies = PhonePolicies(denyPackages = listOf(denied)) }
            val before = driver.collects
            val result = collectCall("${driver.screen.prefix}1")
            assertTrue(result.isError)
            assertFalse(result.text.contains("late collected item"))
            assertFalse(result.text.contains("late collected screen"))
            assertNull(result.image)
            assertEquals("refused:deny-list", core.log.last()!!.decision)
            assertFalse(tasks.isStopped())
            assertEquals(before + 1, driver.collects)
        }
    }

    @Test fun secureCollectedScreenCannotExposeTheSeparatelyReturnedItems() {
        for (driver in listOf(main, background)) {
            driver.collectSnapshot = ScreenSnapshot("${driver.screen.prefix}2", "late collected screen",
                "Example", "example.app", secure = true, image = byteArrayOf(1), imageMime = "image/png")
            val result = collectCall("${driver.screen.prefix}1")
            assertTrue(result.isError)
            assertFalse(result.text.contains("late collected item"))
            assertFalse(result.text.contains("late collected screen"))
            assertNull(result.image)
            assertNotEquals("stopped", core.log.last()!!.decision)
            assertFalse(tasks.isStopped())
            assertEquals(1, driver.collects)
        }
    }

    @Test fun imageOnlyCollectionFilteringKeepsTheReadablePartialText() {
        for (driver in listOf(main, background)) {
            driver.collectStopReason = "页面只读了一部分，无法确认列表是否到底"
            driver.collectSnapshot = ScreenSnapshot("${driver.screen.prefix}2", "late collected screen «银行卡 ****1234»",
                "Example", "example.app", image = byteArrayOf(1), imageMime = "image/png")
            val result = collectCall("${driver.screen.prefix}1")
            assertFalse(result.text, result.isError)
            assertTrue(result.text.contains("late collected item"))
            assertTrue(result.text.contains("late collected screen"))
            assertTrue(result.text.contains("«银行卡 ****1234»"))
            assertTrue(result.text.contains(driver.collectStopReason))
            assertNull(result.image)
            assertEquals("ok", core.log.last()!!.decision)
            assertFalse(tasks.isStopped())
            assertEquals(1, driver.collects)
        }
    }
    @Test fun accumulatedCollectionSourcesCannotBeHiddenByTheFinalScreenOrItsAbsence() {
        for (driver in listOf(main, background)) for (withScreen in listOf(true, false)) {
            policies = PhonePolicies(denyPackages = listOf("other.app"))
            driver.collectReadPackages = setOf("example.app", "other.app")
            driver.collectScreen = withScreen
            var original: PhoneTasks.Owner? = null
            driver.collecting = { original = checkNotNull(tasks.activeOwner()) }
            val before = driver.collects
            val result = collectCall("${driver.screen.prefix}1")
            assertTrue(result.isError)
            assertFalse(result.text.contains("late collected item"))
            assertFalse(result.text.contains("late collected screen"))
            assertNull(result.image)
            assertEquals("refused:deny-list", core.log.last()!!.decision)
            assertTrue(tasks.isCurrent(checkNotNull(original)))
            assertFalse(tasks.isStopped())
            assertEquals(before + 1, driver.collects)
        }
    }

    @Test fun allowedAccumulatedCollectionSourcesKeepTheOriginalPartialResult() {
        for (driver in listOf(main, background)) for (withScreen in listOf(true, false)) {
            policies = PhonePolicies(denyPackages = listOf("unrelated.app"))
            driver.collectReadPackages = setOf("example.app", "other.app")
            driver.collectScreen = withScreen
            val before = driver.collects
            val result = collectCall("${driver.screen.prefix}1")
            assertFalse(result.text, result.isError)
            assertTrue(result.text.contains("late collected item"))
            assertEquals(withScreen, result.text.contains("late collected screen"))
            if (withScreen) assertArrayEquals(byteArrayOf(1, 2, 3), result.image)
            else assertNull(result.image)
            assertEquals("ok", core.log.last()!!.decision)
            assertFalse(tasks.isStopped())
            assertEquals(before + 1, driver.collects)
        }
    }
    @Test fun finalCollectionSourcesCannotCombinePermissionsFromDifferentPolicySnapshots() {
        for (driver in listOf(main, background)) {
            policyRead = null
            policies = PhonePolicies()
            driver.collectScreen = false
            driver.collectReadPackages = linkedSetOf("example.app", "other.app")
            var finalReads = 0
            var original: PhoneTasks.Owner? = null
            driver.collecting = {
                original = checkNotNull(tasks.activeOwner())
                // All entry/live checks have already happened. Arm only the final result check.
                policyRead = {
                    finalReads++
                    PhonePolicies(denyPackages = listOf(if (finalReads <= 2) "other.app" else "example.app"))
                }
            }
            val result = collectCall("${driver.screen.prefix}1")
            assertTrue(result.isError)
            assertFalse(result.text.contains("late collected item"))
            assertNull(result.image)
            assertEquals("refused:deny-list", core.log.last()!!.decision)
            assertEquals(1, finalReads)
            assertTrue(tasks.isCurrent(checkNotNull(original)))
            assertFalse(tasks.isStopped())
            assertEquals(1, driver.collects)
        }
    }
    @Test fun finalCollectionBatchAndAttachedScreenUseTheSamePolicySnapshot() {
        for (driver in listOf(main, background)) {
            policyRead = null
            policies = PhonePolicies()
            driver.collectReadPackages = linkedSetOf("example.app", "other.app")
            driver.collectSnapshot = ScreenSnapshot("${driver.screen.prefix}2", "late collected screen",
                "Example", "example.app", image = byteArrayOf(1, 2, 3), imageMime = "image/png",
                readPackages = linkedSetOf("example.app", "other.app"))
            var finalReads = 0
            var original: PhoneTasks.Owner? = null
            driver.collecting = {
                original = checkNotNull(tasks.activeOwner())
                policyRead = {
                    finalReads++
                    if (finalReads == 1) PhonePolicies()
                    else PhonePolicies(denyPackages = listOf("other.app"))
                }
            }
            val result = collectCall("${driver.screen.prefix}1")
            assertFalse(result.text, result.isError)
            assertTrue(result.text.contains("late collected item"))
            assertTrue(result.text.contains("late collected screen"))
            assertArrayEquals(byteArrayOf(1, 2, 3), result.image)
            assertEquals("ok", core.log.last()!!.decision)
            assertEquals(1, finalReads)
            assertTrue(tasks.isCurrent(checkNotNull(original)))
            assertFalse(tasks.isStopped())
            assertEquals(1, driver.collects)
        }
    }

    @Test fun actualScrollSourcesDenyLateWithoutStoppingTheOriginalOwner() {
        for (sources in listOf(setOf("other.app"), linkedSetOf("example.app", "other.app"))) {
            policies = PhonePolicies()
            main.scrollSources = sources
            var original: PhoneTasks.Owner? = null
            main.beforeScrollSources = {
                original = checkNotNull(tasks.activeOwner())
                policies = PhonePolicies(denyPackages = listOf("other.app"))
            }
            val beforeWrites = main.writes
            val beforeChecks = main.scrollSourceCalls
            val result = core.call(PhoneToolCatalog.SCROLL, mapOf("screen" to "s1", "direction" to "down"))
            assertTrue(result.isError)
            assertEquals(beforeWrites, main.writes)
            assertEquals(beforeChecks + 1, main.scrollSourceCalls)
            assertEquals("refused:deny-list", core.log.last()!!.decision)
            assertFalse(tasks.isStopped())
            assertTrue(tasks.isCurrent(checkNotNull(original)))
        }
    }

    @Test fun unrelatedScrollSourceDenyKeepsOnePhysicalInputAndTheCurrentOwner() {
        for (sources in listOf(setOf("other.app"), linkedSetOf("example.app", "other.app"))) {
            policies = PhonePolicies()
            main.scrollSources = sources
            var original: PhoneTasks.Owner? = null
            beforeStatus = { original = checkNotNull(tasks.activeOwner()) }
            main.beforeScrollSources = {
                policies = PhonePolicies(denyPackages = listOf("unrelated.app"))
            }
            val beforeWrites = main.writes
            val result = core.call(PhoneToolCatalog.SCROLL, mapOf("screen" to "s1", "direction" to "down"))
            assertFalse(result.text, result.isError)
            assertEquals(beforeWrites + 1, main.writes)
            assertTrue(tasks.isCurrent(checkNotNull(original)))
            assertFalse(tasks.isStopped())
        }
    }

    @Test fun scrollSourcesUseOnePolicySnapshotIncludingTheOriginalPackage() {
        main.scrollSources = linkedSetOf("other.app")
        var reads = 0
        var readsAtGate = -1
        main.beforeScrollSources = {
            policyRead = {
                reads++
                PhonePolicies(denyPackages = listOf(if (reads == 1) "other.app" else "example.app"))
            }
        }
        main.afterScrollSources = { readsAtGate = reads; policyRead = null }
        val result = core.call(PhoneToolCatalog.SCROLL, mapOf("screen" to "s1", "direction" to "down"))
        assertTrue(result.isError)
        assertEquals(0, main.writes)
        assertEquals("refused:deny-list", core.log.last()!!.decision)
        assertEquals(1, readsAtGate)
        assertFalse(tasks.isStopped())
    }

    @Test fun originalScrollPackageCannotBeOmittedFromTheActualSourceBatch() {
        main.scrollSources = setOf("other.app")
        main.beforeScrollSources = { policies = PhonePolicies(denyPackages = listOf("example.app")) }
        val result = core.call(PhoneToolCatalog.SCROLL, mapOf("screen" to "s1", "direction" to "down"))
        assertTrue(result.isError)
        assertEquals(0, main.writes)
        assertEquals("refused:deny-list", core.log.last()!!.decision)
        assertFalse(tasks.isStopped())
    }

    @Test fun lateCollectScrollCoverDenialSuppressesPriorContentWithoutStoppingOwner() {
        for (restore in listOf(false, true)) for (withScreen in listOf(false, true)) {
            policies = PhonePolicies()
            main.simulateCollectScroll = true
            main.collectScreen = withScreen
            var original: PhoneTasks.Owner? = null
            beforeStatus = { original = checkNotNull(tasks.activeOwner()) }
            main.beforeCollectBatch = { policies = PhonePolicies(denyPackages = listOf("cover.app")) }
            main.afterCollectBatch = { if (restore) policies = PhonePolicies() }
            val inputs = main.collectScrollInputs
            val batches = main.collectBatchCalls
            val result = collectCall("s1")
            assertTrue(result.isError)
            assertEquals(inputs, main.collectScrollInputs)
            assertEquals(batches + 1, main.collectBatchCalls)
            assertFalse(result.text.contains("late collected item"))
            assertFalse(result.text.contains("late collected screen"))
            assertNull(result.image)
            assertEquals("refused:deny-list", core.log.last()!!.decision)
            assertTrue(tasks.isCurrent(checkNotNull(original)))
            assertFalse(tasks.isStopped())
        }
    }

    @Test fun collectScrollBatchCannotOmitTheOriginalForegroundPackage() {
        main.simulateCollectScroll = true
        main.beforeCollectBatch = { policies = PhonePolicies(denyPackages = listOf("example.app")) }
        main.afterCollectBatch = { policies = PhonePolicies() }
        val result = collectCall("s1")
        assertTrue(result.isError)
        assertEquals(0, main.collectScrollInputs)
        assertFalse(result.text.contains("late collected item"))
        assertNull(result.image)
        assertEquals("refused:deny-list", core.log.last()!!.decision)
        assertFalse(tasks.isStopped())
    }

    @Test fun collectScrollBatchUsesOnePolicyForOriginalAndAllActualSources() {
        main.simulateCollectScroll = true
        var reads = 0
        var readsAtBatch = -1
        main.beforeCollectBatch = {
            policyRead = {
                reads++
                PhonePolicies(denyPackages = listOf(if (reads == 1) "cover.app" else "example.app"))
            }
        }
        main.afterCollectBatch = { readsAtBatch = reads; policyRead = null }
        val result = collectCall("s1")
        assertTrue(result.isError)
        assertEquals(0, main.collectScrollInputs)
        assertFalse(result.text.contains("late collected item"))
        assertFalse(result.text.contains("late collected screen"))
        assertNull(result.image)
        assertEquals("refused:deny-list", core.log.last()!!.decision)
        assertEquals(1, readsAtBatch)
        assertFalse(tasks.isStopped())
    }

    @Test fun unrelatedCollectScrollDenialKeepsOneInputAndOriginalPartialOutput() {
        for (withScreen in listOf(false, true)) {
            policies = PhonePolicies()
            main.simulateCollectScroll = true
            main.collectScreen = withScreen
            main.collectReadPackages = setOf("other.app", "cover.app")
            main.beforeCollectBatch = { policies = PhonePolicies(denyPackages = listOf("unrelated.app")) }
            var original: PhoneTasks.Owner? = null
            beforeStatus = { original = checkNotNull(tasks.activeOwner()) }
            val inputs = main.collectScrollInputs
            val result = collectCall("s1")
            assertFalse(result.text, result.isError)
            assertEquals(inputs + 1, main.collectScrollInputs)
            assertTrue(result.text.contains("late collected item"))
            assertEquals(withScreen, result.text.contains("late collected screen"))
            if (withScreen) assertArrayEquals(byteArrayOf(1, 2, 3), result.image) else assertNull(result.image)
            assertEquals("ok", core.log.last()!!.decision)
            assertTrue(tasks.isCurrent(checkNotNull(original)))
            assertFalse(tasks.isStopped())
        }
    }

    @Test fun confirmedTapStillRejectsLateDeniedActionSourceWithoutStoppingOwner() {
        for (long in listOf(false, true)) {
            policies = PhonePolicies(confirmEveryWritePackages = listOf("other.app"))
            main.targetPackage = "other.app"
            main.tapSources = linkedSetOf("other.app", "cover.app")
            val confirmations = asked
            var original: PhoneTasks.Owner? = null
            beforeStatus = { original = checkNotNull(tasks.activeOwner()) }
            main.beforeTapSources = {
                assertEquals(confirmations + 1, asked)
                assertEquals("other.app", confirmedPackages.last())
                policies = policies.copy(denyPackages = listOf("cover.app"))
            }
            val writes = main.writes
            val checks = main.tapSourceCalls
            val result = core.call(PhoneToolCatalog.TAP, mapOf("screen" to "s1", "id" to 1, "long" to long))
            assertTrue(result.isError)
            assertEquals(writes, main.writes)
            assertEquals(checks + 1, main.tapSourceCalls)
            assertEquals(confirmations + 1, asked)
            assertEquals("refused:deny-list", core.log.last()!!.decision)
            assertTrue(tasks.isCurrent(checkNotNull(original)))
            assertFalse(tasks.isStopped())
        }
    }

    @Test fun confirmedTapKeepsOneInputWhenOnlyAnUnrelatedSourceIsDenied() {
        for (long in listOf(false, true)) {
            policies = PhonePolicies(confirmEveryWritePackages = listOf("other.app"))
            main.targetPackage = "other.app"
            main.tapSources = linkedSetOf("other.app", "cover.app")
            val confirmations = asked
            var original: PhoneTasks.Owner? = null
            beforeStatus = { original = checkNotNull(tasks.activeOwner()) }
            main.beforeTapSources = {
                assertEquals(confirmations + 1, asked)
                assertEquals("other.app", confirmedPackages.last())
                policies = policies.copy(denyPackages = listOf("unrelated.app"))
            }
            val writes = main.writes
            val checks = main.tapSourceCalls
            val result = core.call(PhoneToolCatalog.TAP, mapOf("screen" to "s1", "id" to 1, "long" to long))
            assertFalse(result.text, result.isError)
            assertEquals(writes + 1, main.writes)
            assertEquals(PhoneAction.Tap("s1", 1, long), main.actions.last())
            assertEquals(checks + 1, main.tapSourceCalls)
            assertEquals(confirmations + 1, asked)
            assertEquals("confirmed", core.log.last()!!.decision)
            assertTrue(tasks.isCurrent(checkNotNull(original)))
            assertFalse(tasks.isStopped())
        }
    }

    @Test fun confirmedTapDoesNotUnlockAnOwnAppActionSource() {
        for (unlocked in listOf(false, true)) for (long in listOf(false, true)) {
            policies = PhonePolicies(confirmEveryWritePackages = listOf("other.app"),
                unlocks = PhoneUnlocks(ownApp = unlocked))
            main.targetPackage = "other.app"
            main.tapSources = linkedSetOf("other.app", SafetyRules.OWN_PACKAGE)
            val confirmations = asked
            var original: PhoneTasks.Owner? = null
            beforeStatus = { original = checkNotNull(tasks.activeOwner()) }
            main.beforeTapSources = {
                assertEquals(confirmations + 1, asked)
                assertEquals("other.app", confirmedPackages.last())
            }
            val writes = main.writes
            val checks = main.tapSourceCalls
            val result = core.call(PhoneToolCatalog.TAP, mapOf("screen" to "s1", "id" to 1, "long" to long))
            assertEquals(!unlocked, result.isError)
            assertEquals(writes + if (unlocked) 1 else 0, main.writes)
            assertEquals(checks + 1, main.tapSourceCalls)
            assertEquals(confirmations + 1, asked)
            assertEquals(if (unlocked) "confirmed" else "refused:own-app", core.log.last()!!.decision)
            assertTrue(tasks.isCurrent(checkNotNull(original)))
            assertFalse(tasks.isStopped())
        }
    }

    /** Real Core/filter -> MCP encoding -> original CallWork normal-result winner. No Android IME fake ACK. */
    private fun committedFocusScreen(expireAfterEncoding: Boolean = false, expectedCommit: Boolean = !expireAfterEncoding) {
        main.focusEnabled = true
        val ticket = PhoneReplyCommit()
        val server = McpServer(emptyList(), { name, args, _ -> core.call(name, args) })
        val call = server.dispatch("""{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"screen","arguments":{"image":false}}}""") as McpServer.Dispatch.Call
        var remaining = 1L
        val work = PhoneCallWork({ call.runWithCommit(ticket) { name, args, _ -> core.call(name, args) }
            .also { if (expireAfterEncoding) remaining = 0L } }, { remaining }, { "expired" }, ticket)
        assertNotNull(work.run())
        assertEquals(expectedCommit, checkNotNull(main.focusToken).committed)
    }

    private fun focusCall(text: Any? = "hello", extra: Map<String, Any?> = emptyMap()) =
        core.call(PhoneCore.FOCUS_TEXT, mapOf("observation" to "s1", "text" to text) + extra)

    @Test fun focusUsesOriginalEncodedNormalReplyAndAlwaysAsksOnce() {
        policies = PhonePolicies(confirmMode = ConfirmMode.ALWAYS)
        committedFocusScreen()
        tasks.approve("example.app")
        tasks.waive()
        val out = focusCall()
        assertFalse(out.text, out.isError)
        assertEquals(1, asked)
        assertEquals(1, main.focusInputs)
        assertEquals(1, main.focusCloses)
        assertFalse(focusRequests.single().offerTaskWaiver)
        assertFalse(focusRequests.single().firstInApp)
        assertNull(focusRequests.single().visualScope)
    }

    @Test fun focusCannotUseDirectOrExpiredObservationResponse() {
        main.focusEnabled = true
        core.call(PhoneToolCatalog.SCREEN, emptyMap())
        assertFalse(checkNotNull(main.focusToken).committed)
        assertTrue(focusCall().isError)
        committedFocusScreen(expireAfterEncoding = true)
        assertTrue(focusCall().isError)
        assertEquals(0, asked)
        assertEquals(0, main.focusInputs)
    }

    @Test fun focusRejectsBroadConsentAndClosesCapturedPlan() {
        committedFocusScreen()
        confirm = { Decision.ALLOW_ALL_FOR_TASK }
        assertTrue(focusCall().isError)
        assertEquals(0, main.focusInputs)
        assertEquals(1, main.focusCloses)
        assertFalse(tasks.isStopped())
    }

    @Test fun focusDeniesSecretAndLatePolicyWithoutRetargetOrStop() {
        committedFocusScreen()
        main.focusSecret = true
        assertTrue(focusCall().isError)
        assertEquals(0, asked)
        main.focusSecret = false
        confirm = { policies = policies.copy(denyPackages = listOf("example.app")); Decision.ALLOW_ONCE }
        val refused = focusCall()
        assertTrue(refused.isError)
        assertEquals(1, asked)
        assertEquals(0, main.focusInputs)
        assertEquals(2, main.focusCloses)
        assertFalse(tasks.isStopped())
    }

    @Test fun focusChecksLatestPolicyAtActualInputAndClipboardConsentIsSpecific() {
        committedFocusScreen()
        main.focusMethod = FocusInput.Method.CLIPBOARD
        main.beforeFocusInput = { policies = policies.copy(denyPackages = listOf("example.app")) }
        assertTrue(focusCall().isError)
        assertEquals(0, main.focusInputs)
        assertEquals(1, main.focusCloses)
        assertTrue(focusRequests.single().sentence.contains("覆盖系统剪贴板"))
        assertTrue(focusRequests.single().sentence.contains("不备份、不恢复"))
        assertFalse(tasks.isStopped())
    }

    @Test fun focusStrictArgumentsAndBackgroundNeverFallBackToMain() {
        committedFocusScreen()
        for (value in listOf(null, 123, "", "a\nb", "\uD800", "x".repeat(501))) {
            assertTrue(focusCall(value).isError)
        }
        assertTrue(focusCall(extra = mapOf("submit" to false)).isError)
        assertEquals(0, main.focusPrepares)
        val backgroundResult = core.call(PhoneCore.FOCUS_TEXT, mapOf("observation" to "b1", "text" to "hello"))
        assertTrue(backgroundResult.isError)
        assertEquals(1, background.focusPrepares)
        assertEquals(0, main.focusPrepares)
        assertEquals(0, asked)
        assertEquals(0, main.focusInputs)
    }

    @Test fun focusRefusedScreenCannotBindItsHiddenCandidate() {
        policies = PhonePolicies(denyPackages = listOf("example.app"))
        committedFocusScreen(expectedCommit = false)
        policies = policies.copy(denyPackages = emptyList())
        assertTrue(focusCall().isError)
        assertEquals(0, asked)
        assertEquals(0, main.focusInputs)
    }


    /** Fake only the platform's typed step; real Core/worker/SafetyGate and outcomes are exercised. */
    private fun replayFixture(already: Boolean = false, witness: Boolean = true,
        beforeAttempt: () -> Unit = {}, preparedRoute: PhoneSkillRoute.Route? = null): Triple<PhoneSkillReplaySelections, PhoneSkillReplaySelections.Selection, PhoneSkillOutcomes> {
        val registry = PhoneSkillReplaySelections { 0L }
        val app = PhoneSkillReplaySelections.App("example.app", 10123, 1, 2, "c".repeat(64))
        val route = preparedRoute ?: PhoneSkillRoute.Route("phone-task-" + "1".repeat(32), "2".repeat(32), "markor-navigation-v1", listOf("app1"), emptyList(),
            listOf(PhoneSkillRoute.Step(PhoneSkillRoute.Op.SELECT_OPTION, "app1", PhoneScreen.MAIN,
                "navigation", "bottom-tabs", PhoneSkillRoute.Value.OptionLiteral("more"), PhoneSkillRoute.Post.OptionSelected)))
        val request = PhoneSkillReplaySelections.Request(route.skillName, route.revision, "session", app.packageName, app.uid)
        val selected = registry.prepare(PhoneSkillDrafts().attachClient(), 1, { true }, request,
            PhoneSkillBundleReader.Read.Accepted(route, 2, "a".repeat(64), "b".repeat(64)), app)!!
        assertTrue(registry.claim(selected, PhoneCaller("session", "run", "call", 1)) is PhoneSkillReplaySelections.Claim.Start)
        var stored: String? = null
        val outcomes = PhoneSkillOutcomes({ stored }, { stored = it; true }, "d".repeat(32))
        main.replayPlan = object : SkillReplayPlan {
            override val before = ScreenSnapshot("sReplayBefore", "navigation", "Example", "example.app", readPackages = setOf("example.app"))
            override val target = if (already) null else TargetInfo("sReplayBefore", 1, "button", "more", "example.app", "Example", false, false, false)
            override val alreadySatisfied = already
            override var attempted = false
            override var post = SkillReplayPost.UNKNOWN
            override fun perform(allowed: () -> Boolean): ActionResult {
                beforeAttempt()
                if (!allowed()) return ActionResult(false, "denied")
                if (!already) { attempted = true; main.writes++ }
                post = SkillReplayPost.SATISFIED
                return ActionResult(true, "local state", before.copy(id = "sReplayAfter"),
                    navigationWitness = if (witness) PhoneSkillNavigationWitness(app.uid, app.version, app.updated, app.signers) else null)
            }
            override fun close() { }
        }
        return Triple(registry, selected, outcomes)
    }
    private fun executeReplay(fixture: Triple<PhoneSkillReplaySelections, PhoneSkillReplaySelections.Selection, PhoneSkillOutcomes>,
        bind: Boolean = false): ToolOutput {
        val owner = (tasks.begin() as PhoneTasks.Begin.Go).owner
        if (bind) boundMain = PhoneTaskObservations(tasks).bind(main, owner)
        val call = (core.prepareReplayCall(fixture.second, fixture.first, fixture.third, owner) as Either.Right).value
        assertTrue("MAIN must retain unknown window UID exclusion", call.unknownApp)
        return core.call(call, core.worker)
    }
    @Test fun replayReturnedOkWithoutNativePostWitnessNeverCountsSuccessOrRetries() {
        val fixture = replayFixture(witness = false)
        assertTrue(executeReplay(fixture).isError)
        assertEquals(1, main.writes)
        assertEquals(0, fixture.first.snapshot(fixture.second)["completedSteps"])
        assertEquals(PhoneSkillOutcomes.Outcome.UNKNOWN, fixture.first.finish(fixture.second, false, 1L))
        assertTrue(fixture.first.claim(fixture.second, PhoneCaller("session", "run", "again", 1)) is PhoneSkillReplaySelections.Claim.Existing)
        assertEquals(1, main.writes)
    }
    @Test fun replayAlreadySelectedVerifiesWithoutClickAndRealOutcomeSettlesOnce() {
        val fixture = replayFixture(already = true)
        val out = executeReplay(fixture)
        assertFalse(out.text, out.isError)
        assertEquals(0, main.writes)
        val terminal = fixture.first.finish(fixture.second, true, 1L)
        assertEquals(PhoneSkillOutcomes.Outcome.SUCCESS, terminal)
        assertEquals(PhoneSkillOutcomes.Result.SAVED, fixture.third.settle(fixture.second.invocation, terminal))
        assertEquals(PhoneSkillOutcomes.Result.UNCHANGED, fixture.third.settle(fixture.second.invocation, terminal))
        val key = PhoneSkillOutcomes.Key(fixture.second.request.name, fixture.second.request.revision, fixture.second.bundle.routeSha256)
        assertEquals(1L, fixture.third.counts(key)!!.successes)
    }
    @Test fun replayLatePolicyDenialStopsTheOriginalSingleAttempt() {
        val fixture = replayFixture(beforeAttempt = { policies = PhonePolicies(denyPackages = listOf("example.app")) })
        assertTrue(executeReplay(fixture).isError)
        assertEquals(0, main.writes)
        assertFalse(tasks.isStopped())
        assertEquals(PhoneSkillOutcomes.Outcome.NOT_STARTED, fixture.first.finish(fixture.second, false, 1L))
    }
    @Test fun replayCancelledBetweenPrepareAndDispatchNeverStartsAndDoesNotClaimDrain() {
        lateinit var fixture: Triple<PhoneSkillReplaySelections, PhoneSkillReplaySelections.Selection, PhoneSkillOutcomes>
        fixture = replayFixture(beforeAttempt = { fixture.first.control(fixture.second, PhoneCaller("session", "run", "cancel", 1), true) })
        assertTrue(executeReplay(fixture).isError)
        assertEquals(0, main.writes)
        assertEquals(PhoneSkillOutcomes.Outcome.CANCEL, fixture.first.finish(fixture.second, false, 1L))
    }

    @Test fun replayDeadlineWinnerPreventsLaterCoreReturnFromPromotingTheTerminal() {
        lateinit var fixture: Triple<PhoneSkillReplaySelections, PhoneSkillReplaySelections.Selection, PhoneSkillOutcomes>
        lateinit var work: PhoneCallWork
        var remaining = 1L
        var timeoutReply: String? = null
        fixture = replayFixture(beforeAttempt = {
            remaining = 0L
            timeoutReply = work.expire()
        })
        work = PhoneCallWork(invoke = {
            val result = executeReplay(fixture)
            fixture.first.finish(fixture.second, !result.isError, 1L)
            Json.write(fixture.first.snapshot(fixture.second))
        }, remainingMs = { remaining }, expiredReply = {
            Json.write(fixture.first.expire(fixture.second))
        })
        assertNull(work.run()) // Actual PhoneCallWork already committed its timeout reply.
        assertEquals("unknown", (Json.parse(checkNotNull(timeoutReply)) as Map<*, *>)["state"])
        assertEquals(0, main.writes)
        fixture.first.verified(fixture.second)
        assertEquals(PhoneSkillOutcomes.Outcome.UNKNOWN, fixture.first.finish(fixture.second, true, 1L))
        assertEquals("unknown", fixture.first.snapshot(fixture.second)["state"])
    }
    @Test fun foreignObservationCollectIsARealLedgerRefusalWithoutPhysicalCollectionOrStop() {
        val owner = (tasks.begin() as PhoneTasks.Begin.Go).owner
        boundMain = PhoneTaskObservations(tasks).bind(main, owner)
        boundMain!!.observe(false, false)
        val result = collectCall("s999")
        assertTrue(result.text, result.isError)
        assertTrue(result.text.contains("屏幕编号不属于本任务"))
        assertFalse(result.text.contains("收集到"))
        assertEquals(0, main.collects)
        assertTrue(tasks.isCurrent(owner))
        assertFalse(tasks.isStopped())
        assertEquals("refused:collect", core.log.last()!!.decision)
    }

    @Test fun currentLedgerAllowsAnActuallyEmptyCollectionAndKeepsNormalPartialResults() {
        val owner = (tasks.begin() as PhoneTasks.Begin.Go).owner
        boundMain = PhoneTaskObservations(tasks).bind(main, owner)
        boundMain!!.observe(false, false)
        main.collectScreen = false
        main.collectItems = emptyList()
        main.collectPages = 0
        main.collectStopReason = "empty list"
        val empty = collectCall("s1")
        assertFalse(empty.text, empty.isError)
        assertTrue(empty.text.contains("收集到 0 条"))
        assertEquals(1, main.collects)
        assertEquals("ok", core.log.last()!!.decision)
        main.collectItems = listOf("partial prefix")
        main.collectPages = 1
        main.collectStopReason = "list lost after readable page"
        val partial = collectCall("s1")
        assertFalse(partial.text, partial.isError)
        assertTrue(partial.text.contains("partial prefix"))
        assertEquals(2, main.collects)
        assertTrue(tasks.isCurrent(owner))
        assertFalse(tasks.isStopped())
    }

    /** Only the transport boundary is fake; Core, owner proxy and accounting are real. */
    private fun lostReplayReply(mode: String) {
        val fixture = replayFixture()
        val original = checkNotNull(main.replayPlan)
        main.replayPlan = object : SkillReplayPlan by original {
            override var dispatchUncertain = false
            override val post get() = if (mode == "untrusted-ok") SkillReplayPost.SATISFIED else SkillReplayPost.UNKNOWN
            override fun perform(allowed: () -> Boolean): ActionResult {
                check(allowed())
                dispatchUncertain = true // Simulated sent write, not a NODE attempt receipt.
                if (mode == "cancel") fixture.first.control(fixture.second,
                    PhoneCaller("session", "run", "cancel", 1), true)
                if (mode == "throw") throw IllegalStateException("transport reply missing")
                if (mode == "untrusted-ok") return ActionResult(true, "untrusted success", before,
                    navigationWitness = PhoneSkillNavigationWitness(10123, 1, 2, "c".repeat(64)))
                return ActionResult(false, "transport reply missing")
            }
        }
        assertTrue(executeReplay(fixture, bind = true).isError)
        assertFalse(main.replayPlan!!.attempted)
        assertEquals(0, main.writes)
        assertEquals("unknown", fixture.first.snapshot(fixture.second)["stepDispatch"])
        assertEquals(PhoneSkillOutcomes.Outcome.UNKNOWN, fixture.first.finish(fixture.second, false, 1L))
        fixture.first.retryAccounting(fixture.third)
        val key = PhoneSkillOutcomes.Key(fixture.second.request.name, fixture.second.request.revision, fixture.second.bundle.routeSha256)
        assertEquals(PhoneSkillOutcomes.Outcome.UNKNOWN, fixture.third.counts(key)!!.last)
        assertEquals(0L, fixture.third.counts(key)!!.successes)
        assertTrue(fixture.first.claim(fixture.second, PhoneCaller("session", "run", "again", 1)) is PhoneSkillReplaySelections.Claim.Existing)
        assertFalse(tasks.isStopped())
    }
    @Test fun replayLostWriteReplyBeforeDeadlineIsUnknownThroughRealOwnerProxy() = lostReplayReply("reply")
    @Test fun replayThrownTransportFailureStillFreezesUnknownInFinally() = lostReplayReply("throw")
    @Test fun replayCancellationCannotTurnMissingWriteReplyIntoKnownNoAttempt() = lostReplayReply("cancel")

    @Test fun replayUnresolvedDispatchCannotContributeVerifiedSuccess() = lostReplayReply("untrusted-ok")

    @Test fun replayActualAttemptTakesPriorityOverConservativeTransportUncertainty() {
        val fixture = replayFixture()
        val original = checkNotNull(main.replayPlan)
        main.replayPlan = object : SkillReplayPlan by original {
            override val dispatchUncertain = true
        }
        assertFalse(executeReplay(fixture, bind = true).isError)
        assertTrue(original.attempted)
        assertEquals(1, main.writes)
        assertEquals(PhoneSkillOutcomes.Outcome.SUCCESS, fixture.first.finish(fixture.second, true, 1L))
    }
    @Test fun replayReadOnlyFailureWithNoWriteUncertaintyRemainsNotStarted() {
        val fixture = replayFixture(already = true)
        val original = checkNotNull(main.replayPlan)
        main.replayPlan = object : SkillReplayPlan by original {
            override fun perform(allowed: () -> Boolean) = ActionResult(false, "inspect unavailable")
        }
        assertTrue(executeReplay(fixture, bind = true).isError)
        assertFalse(main.replayPlan!!.dispatchUncertain)
        assertEquals(0, main.writes)
        assertEquals(PhoneSkillOutcomes.Outcome.NOT_STARTED, fixture.first.finish(fixture.second, false, 1L))
    }


    /** Parse an explicitly permitted test relation; never mutate the production registry. */
    private fun extraReplayRelation(tail: String, extra: PhoneSkillRoute.Step,
        slots: List<String> = listOf("app1"), parameters: List<PhoneSkillRoute.Parameter> = emptyList(),
        parameterJson: String = "[]"): PhoneSkillRoute.Route {
        val name = "phone-task-" + "1".repeat(32)
        val revision = "2".repeat(32)
        val more = PhoneSkillRoute.Step(PhoneSkillRoute.Op.SELECT_OPTION, "app1", PhoneScreen.MAIN,
            "navigation", "bottom-tabs", PhoneSkillRoute.Value.OptionLiteral("more"), PhoneSkillRoute.Post.OptionSelected)
        val slotJson = Json.write(slots.map { mapOf("key" to it, "kind" to "user_selected_app") })
        val bytes = """{"schema":1,"skillName":"$name","bundleRevision":"$revision",
            "descriptorSet":"markor-navigation-v1","appSlots":$slotJson,"parameters":$parameterJson,
            "steps":[{"op":"select_option","appSlot":"app1","screen":"main","pageKey":"navigation",
            "targetKey":"bottom-tabs","value":{"literal":"more"},"post":{"kind":"option_selected"}},$tail]}""".toByteArray()
        val descriptor = PhoneSkillRoute.Descriptor("markor-navigation-v1", slots.toSet(), parameters, setOf(more, extra))
        val parsed = PhoneSkillRoute.parse(bytes, name, revision, mapOf("markor-navigation-v1" to descriptor))
        assertTrue("The fixture must pass the real complete-relation parser", parsed is PhoneSkillRoute.Read.Accepted)
        return (parsed as PhoneSkillRoute.Read.Accepted).route.also { assertEquals(2, it.steps.size) }
    }
    private fun rejectsWholeReplay(route: PhoneSkillRoute.Route) {
        val fixture = replayFixture(preparedRoute = route)
        val owner = (tasks.begin() as PhoneTasks.Begin.Go).owner
        val prepared = core.prepareReplayCall(fixture.second, fixture.first, fixture.third, owner)
        assertTrue("Unsupported tail must be rejected before preparing any route", prepared is Either.Left)
        assertTrue((prepared as Either.Left).value.isError)
        assertEquals(0, main.writes)
        assertEquals(0, fixture.first.snapshot(fixture.second)["completedSteps"])
        assertFalse(tasks.isStopped())
    }
    @Test fun replayWholeRouteRejectsParsedUnsupportedOperationBeforeItsValidPrefix() {
        rejectsWholeReplay(extraReplayRelation(
            """{"op":"open_app","appSlot":"app1","screen":"main","post":{"kind":"page_is","pageKey":"home"}}""",
            PhoneSkillRoute.Step(PhoneSkillRoute.Op.OPEN_APP, "app1", PhoneScreen.MAIN, post = PhoneSkillRoute.Post.PageIs("home"))))
    }
    @Test fun replayWholeRouteRejectsParsedSecondAppSlotBeforeItsValidPrefix() {
        rejectsWholeReplay(extraReplayRelation(
            """{"op":"select_option","appSlot":"app2","screen":"main","pageKey":"navigation","targetKey":"bottom-tabs","value":{"literal":"more"},"post":{"kind":"option_selected"}}""",
            PhoneSkillRoute.Step(PhoneSkillRoute.Op.SELECT_OPTION, "app2", PhoneScreen.MAIN, "navigation", "bottom-tabs",
                PhoneSkillRoute.Value.OptionLiteral("more"), PhoneSkillRoute.Post.OptionSelected), slots = listOf("app1", "app2")))
    }
    @Test fun replayWholeRouteRejectsParsedParametersBeforeItsValidPrefix() {
        rejectsWholeReplay(extraReplayRelation(
            """{"op":"set_checked","appSlot":"app1","screen":"main","pageKey":"settings","targetKey":"compact","value":{"parameter":"desired"},"post":{"kind":"checked_equals_value"}}""",
            PhoneSkillRoute.Step(PhoneSkillRoute.Op.SET_CHECKED, "app1", PhoneScreen.MAIN, "settings", "compact",
                PhoneSkillRoute.Value.Reference("desired"), PhoneSkillRoute.Post.CheckedEqualsValue),
            parameters = listOf(PhoneSkillRoute.Parameter("desired", PhoneSkillRoute.ParameterKind.BOOLEAN)),
            parameterJson = """[{"key":"desired","kind":"boolean","required":true}]"""))
    }
    @Test fun replayWholeRouteRejectsParsedMixedScreensBeforeItsValidPrefix() {
        rejectsWholeReplay(extraReplayRelation(
            """{"op":"select_option","appSlot":"app1","screen":"background","pageKey":"navigation","targetKey":"bottom-tabs","value":{"literal":"more"},"post":{"kind":"option_selected"}}""",
            PhoneSkillRoute.Step(PhoneSkillRoute.Op.SELECT_OPTION, "app1", PhoneScreen.BACKGROUND, "navigation", "bottom-tabs",
                PhoneSkillRoute.Value.OptionLiteral("more"), PhoneSkillRoute.Post.OptionSelected)))
    }
}
