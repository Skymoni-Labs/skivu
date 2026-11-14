package com.skyjjgw.independent.ski.dshgo.phone

import com.skyjjgw.independent.ski.dshgo.phone.a11y.MainScreenDriver
import org.junit.Assert.*
import org.junit.Test

class PhoneTaskObservationsTest {
    private class Driver : PhoneDriver {
        var replayPlan: SkillReplayPlan? = null
        override fun prepareSkillReplayStep(step: SkillReplayStep): Either<String, SkillReplayPlan> =
            replayPlan?.let { Either.Right(it) } ?: Either.Left("unsupported")

        override val screen = PhoneScreen.MAIN
        var actions = 0
        var performedScreen: ScreenSnapshot? = null
        var scrollSourceGate: ((Set<String>) -> Boolean)? = null
        var duringScroll: () -> Unit = {}
        var capturedAdmission: ((() -> Boolean) -> Boolean)? = null
        var capturedAllowed: (() -> Boolean)? = null
        var scope: VisualScope? = null
        val imageCommits = mutableListOf<String>()
        override fun acceptVisualObservation(screenId: String) { imageCommits += screenId }
        val opens = mutableListOf<PhoneAppIdentity>()
        var duringOpen: () -> Unit = {}
        var collectBatchGate: ((Set<String>) -> Boolean)? = null
        var collectGate: (() -> Boolean)? = null
        var collectSourceGate: ((String?) -> Boolean)? = null
        var duringCollect: () -> Unit = {}
        var collected = CollectResult(emptyList(), 0, "done", null)
        var focusPreparations = 0
        var duringPrepareFocus: () -> Unit = {}
        var focusPlan: FocusInput? = null
        override fun prepareFocusInput(screenId: String): Either<String, FocusInput> {
            focusPreparations++
            duringPrepareFocus()
            return focusPlan?.let { Either.Right(it) } ?: Either.Left("unavailable")
        }
        override fun visualScope(screenId: String): VisualScope? = scope.takeIf { screenId == "s1" }
        override fun availability() = Availability(true)
        override fun observe(detail: Boolean, image: Boolean) = ScreenSnapshot("s1", "screen", "App", "app")
        override fun target(screenId: String, elementId: Int) = TargetInfo(screenId, elementId, "button", "send", "app", "App", false, false, false)
        override fun perform(action: PhoneAction): ActionResult { actions++; return ActionResult(true, "done", performedScreen) }
        override fun perform(action: PhoneAction, allowed: () -> Boolean,
                             coordinateAdmission: ((() -> Boolean) -> Boolean)?): ActionResult {
            capturedAdmission = coordinateAdmission
            capturedAllowed = allowed
            return if (allowed()) perform(action) else ActionResult(false, "stopped")
        }
        override fun perform(action: PhoneAction, allowed: () -> Boolean,
                             coordinateAdmission: ((() -> Boolean) -> Boolean)?,
                             actionSourcesAllowed: (Set<String>) -> Boolean): ActionResult {
            scrollSourceGate = actionSourcesAllowed
            if (action is PhoneAction.Scroll) duringScroll()
            return perform(action, allowed, coordinateAdmission)
        }
        override fun open(target: PhoneAppIdentity): ActionResult {
            opens += target
            duringOpen()
            return ActionResult(true, "opened", ScreenSnapshot("sOpen", "opened screen", "App", target.packageName))
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = collected
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?, allowed: () -> Boolean): CollectResult {
            collectGate = allowed
            duringCollect()
            return collected
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?,
                             allowed: () -> Boolean, canRead: (String?) -> Boolean): CollectResult {
            collectSourceGate = canRead
            return collect(screenId, listElementId, maxPages, until, allowed)
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?,
                             allowed: () -> Boolean, canRead: (String?) -> Boolean,
                             scrollSourcesAllowed: (Set<String>) -> Boolean): CollectResult {
            collectBatchGate = scrollSourcesAllowed
            return collect(screenId, listElementId, maxPages, until, allowed, canRead)
        }
        override fun foregroundPackage() = "app"
    }
    private fun owner(tasks: PhoneTasks) = (tasks.begin() as PhoneTasks.Begin.Go).owner

    @Test fun boundOpenPassesTheOriginalNativeIdentityAndRecordsOnlyItsReturnedScreen() {
        val tasks = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(tasks).bind(physical, owner(tasks))
        val identity = PhoneAppIdentity("example.app", 1010123)
        val result = bound.open(identity)
        assertTrue(result.ok)
        assertSame(identity, physical.opens.single())
        assertNotNull(bound.target("sOpen", 1))
    }

    @Test fun staleBoundOpenCannotDispatchOrPublishIntoTheReplacementScope() {
        val tasks = PhoneTasks(); val physical = Driver(); val ledger = PhoneTaskObservations(tasks)
        val bound = ledger.bind(physical, owner(tasks))
        val identity = PhoneAppIdentity("example.app", 10123)
        physical.duringOpen = { tasks.stop("replaced"); tasks.clearStop(); tasks.begin() }
        assertThrows(InterruptedException::class.java) { bound.open(identity) }
        assertEquals(1, physical.opens.size)
        val replacement = ledger.bind(physical, checkNotNull(tasks.activeOwner()))
        assertNull(replacement.target("sOpen", 1))
        assertThrows(InterruptedException::class.java) { bound.open(identity) }
        assertEquals(1, physical.opens.size) // Rejected before calling the physical driver again.
    }

    @Test fun collectionPassesItsOwnLivePauseGateInsteadOfTheDisplayedTasksState() {
        val a = PhoneTasks(); val b = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(a).bind(physical, owner(a))
        owner(b); b.setPaused(true)
        bound.observe(false, false)
        bound.collect("s1", 1, 3, null)
        val allowed = checkNotNull(physical.collectGate)
        assertTrue(allowed()) // Pausing another task must not stop this collection.
        a.setPaused(true); assertFalse(allowed())
        b.setPaused(false); assertFalse(allowed())
        a.setPaused(false); assertTrue(allowed())
        a.stop("user"); a.clearStop(); a.begin()
        assertFalse(allowed()) // Resume/new scope cannot revive the old loop's permission.
    }

    @Test fun collectionFinishingAfterItsScopeWasReplacedCannotPublishAnObservation() {
        val tasks = PhoneTasks(); val ledger = PhoneTaskObservations(tasks); val physical = Driver()
        val bound = ledger.bind(physical, owner(tasks))
        bound.observe(false, false)
        physical.collected = CollectResult(listOf("synthetic"), 1, "done", ScreenSnapshot("sLate", "screen", "App", "app"))
        physical.duringCollect = { tasks.stop("user"); tasks.clearStop(); tasks.begin() }
        assertThrows(InterruptedException::class.java) { bound.collect("s1", 1, 3, null) }
        val fresh = ledger.bind(physical, checkNotNull(tasks.activeOwner()))
        assertNull(fresh.target("sLate", 1))
        assertFalse(checkNotNull(physical.collectGate)())
    }

    @Test fun anotherSessionCannotUseAnIdItNeverObservedEvenOnTheSamePhysicalDriver() {
        val physical = Driver()
        val a = PhoneTasks(); val b = PhoneTasks()
        val first = PhoneTaskObservations(a).bind(physical, owner(a))
        val second = PhoneTaskObservations(b).bind(physical, owner(b))
        first.observe(false, false)
        assertNull(second.target("s1", 1))
        assertFalse(second.perform(PhoneAction.Tap("s1", 1)).ok)
        assertEquals(0, physical.actions)
        assertTrue(first.perform(PhoneAction.Tap("s1", 1)).ok)
        assertEquals(1, physical.actions)
    }

    @Test fun replacementDriverWithTheSameCounterDoesNotInheritAnOldObservation() {
        val tasks = PhoneTasks(); val ledger = PhoneTaskObservations(tasks); val owner = owner(tasks)
        ledger.bind(Driver(), owner).observe(false, false)
        val replacement = Driver(); val bound = ledger.bind(replacement, owner)
        assertNull(bound.target("s1", 1))
        assertFalse(bound.perform(PhoneAction.Tap("s1", 1)).ok)
        assertEquals(0, replacement.actions)
        bound.observe(false, false)
        assertTrue(bound.perform(PhoneAction.Tap("s1", 1)).ok)
    }

    @Test fun stopAndExplicitResumeCannotReviveTheOldBoundDriver() {
        val tasks = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(tasks).bind(physical, owner(tasks))
        bound.observe(false, false)
        tasks.stop("user"); tasks.clearStop(); tasks.begin()
        try { bound.perform(PhoneAction.Tap("s1", 1)); fail("old lifetime dispatched") } catch (_: InterruptedException) { }
        assertEquals(0, physical.actions)
    }
    @Test fun visualCommitRequiresThisOwnerAndTheSameObservedDriver() {
        val a = PhoneTasks(); val b = PhoneTasks(); val physical = Driver()
        val ledger = PhoneTaskObservations(a)
        val bound = ledger.bind(physical, owner(a))
        bound.observe(false, true)
        PhoneTaskObservations(b).bind(physical, owner(b)).acceptVisualObservation("s1")
        assertTrue(physical.imageCommits.isEmpty())
        val replacement = Driver()
        ledger.bind(replacement, checkNotNull(a.activeOwner())).acceptVisualObservation("s1")
        assertTrue(replacement.imageCommits.isEmpty())
        bound.acceptVisualObservation("s1")
        assertEquals(listOf("s1"), physical.imageCommits)
        a.stop("stop"); a.clearStop(); a.begin()
        assertThrows(InterruptedException::class.java) { bound.acceptVisualObservation("s1") }
        assertEquals(1, physical.imageCommits.size)
    }

    @Test fun actualWrapperCoordinateClaimCannotUseARetiredOrPausedOwner() {
        val tasks = PhoneTasks(); val physical = Driver()
        val owner = owner(tasks); val bound = PhoneTaskObservations(tasks).bind(physical, owner)
        bound.observe(false, false); bound.perform(PhoneAction.TapXY("s1", 1, 1))
        val admission = checkNotNull(physical.capturedAdmission)
        var claims = 0
        assertTrue(admission { claims++; true })
        tasks.setPaused(true)
        assertFalse(admission { claims++; true })
        tasks.setPaused(false); tasks.stop("stop"); tasks.clearStop(); tasks.begin()
        assertFalse(admission { claims++; true }); assertEquals(1, claims)
    }
    @Test fun pauseWhileTheMainDriverResolvesATargetRefusesItsPhysicalDispatch() {
        val tasks = PhoneTasks(); val physical = Driver(); val owner = owner(tasks)
        val bound = PhoneTaskObservations(tasks).bind(physical, owner)
        bound.observe(false, false); bound.perform(PhoneAction.Tap("s1", 1))
        val allowed = checkNotNull(physical.capturedAllowed)
        assertNull(MainScreenDriver.refuseHalted(allowed)) // Admitted before resolve() captures.
        assertTrue(tasks.setPausedIfCurrent(owner, true)) // The person pauses during that capture.
        val refused = checkNotNull(MainScreenDriver.refuseHalted(allowed))
        assertFalse(refused.ok); assertNull(refused.screen)
        assertTrue(tasks.setPausedIfCurrent(owner, false)); assertNull(MainScreenDriver.refuseHalted(allowed))
        tasks.stop("user"); tasks.clearStop(); tasks.begin()
        assertNotNull(MainScreenDriver.refuseHalted(allowed)) // A new lifetime cannot admit the old dispatch.
    }

    @Test fun actualLedgerRevokesScopeOnTextOnlyObservationBeforeAComesBack() {
        val tasks = PhoneTasks(); val physical = Driver(); val owner = owner(tasks)
        val bound = PhoneTaskObservations(tasks).bind(physical, owner)
        val a = VisualScope.Main(Any(), Any(), 1, "app")
        physical.scope = a; bound.observe(false, false)
        assertTrue(tasks.confirmVisualIfCurrent(owner, a))
        physical.scope = null; bound.observe(false, false)
        assertFalse(tasks.confirmVisualIfCurrent(owner, a))
        physical.scope = a; bound.observe(false, false)
        assertFalse(tasks.hasVisualGrant(owner, a))
    }

    @Test fun additionalPolicyGateCannotBypassTheOriginalObservationOwner() {
        val physical = Driver(); val firstTasks = PhoneTasks(); val otherTasks = PhoneTasks()
        val first = PhoneTaskObservations(firstTasks).bind(physical, owner(firstTasks))
        val other = PhoneTaskObservations(otherTasks).bind(physical, owner(otherTasks))
        first.observe(false, false)
        assertFalse(other.perform(PhoneAction.Tap("s1", 1)) { true }.ok)
        assertEquals(0, physical.actions)
        var permitted = true
        assertTrue(first.perform(PhoneAction.Tap("s1", 1)) { permitted }.ok)
        val allowed = checkNotNull(physical.capturedAllowed)
        val claim = checkNotNull(physical.capturedAdmission)
        permitted = false
        assertFalse(allowed())
        var claimed = 0
        assertFalse(claim { claimed++; true }); assertEquals(0, claimed)
        permitted = true; firstTasks.setPaused(true)
        assertFalse(allowed()); assertFalse(claim { claimed++; true })
        assertEquals(1, physical.actions)
    }

    @Test fun fiveArgumentCollectionForwardsLiveCallerPermissionTogetherWithTaskPermission() {
        val tasks = PhoneTasks(); val physical = Driver()
        val original = owner(tasks)
        val bound = PhoneTaskObservations(tasks).bind(physical, original)
        bound.observe(false, false)
        var callerAllowed = true
        var entered = 0
        physical.duringCollect = {
            entered++
            val allowed = checkNotNull(physical.collectGate)
            assertTrue(allowed())
            callerAllowed = false
            assertFalse(allowed()) // Must remain live inside the real physical call.
        }
        bound.collect("s1", 1, 3, null) { callerAllowed }
        assertEquals(1, entered)
        val allowed = checkNotNull(physical.collectGate)
        assertFalse(allowed())
        callerAllowed = true
        assertTrue(allowed())
        tasks.setPaused(true); assertFalse(allowed())
        tasks.setPaused(false); assertTrue(allowed())
        tasks.stop("replacement"); tasks.clearStop(); tasks.begin()
        assertFalse(allowed())
        assertFalse(tasks.isCurrent(original))
    }
    @Test fun sixArgumentCollectionCarriesLiveSourceChecksAndTheOriginalTaskGate() {
        val tasks = PhoneTasks(); val physical = Driver()
        val original = owner(tasks)
        val bound = PhoneTaskObservations(tasks).bind(physical, original)
        bound.observe(false, false)
        var denied: String? = null
        val checked = mutableListOf<String?>()
        var entered = 0
        physical.collected = CollectResult(listOf("public"), 1, "partial", null,
            readPackages = setOf("app", "other.app"))
        physical.duringCollect = {
            entered++
            val source = checkNotNull(physical.collectSourceGate)
            assertTrue(checkNotNull(physical.collectGate)())
            assertTrue(source("other.app"))
            denied = "other.app"
            assertFalse(source("other.app"))
            assertTrue(source("app"))
        }
        val result = bound.collect("s1", 1, 3, null, { true }) { pkg ->
            checked += pkg
            pkg != denied
        }
        assertEquals(1, entered)
        assertEquals(listOf("other.app", "other.app", "app"), checked)
        assertEquals(setOf("app", "other.app"), result.readPackages)
        assertEquals(result.readPackages, result.copy(stopReason = "copied").readPackages)
        val allowed = checkNotNull(physical.collectGate)
        val source = checkNotNull(physical.collectSourceGate)
        val beforeBlocked = checked.size
        tasks.setPaused(true); assertFalse(allowed()); assertFalse(source("app"))
        assertEquals(beforeBlocked, checked.size)
        tasks.setPaused(false); assertTrue(allowed())
        tasks.stop("replacement"); tasks.clearStop(); tasks.begin()
        assertFalse(allowed()); assertFalse(source("app"))
        assertEquals(beforeBlocked, checked.size)
        assertThrows(InterruptedException::class.java) {
            bound.collect("s1", 1, 3, null, { true }) { true }
        }
        assertEquals(1, entered)
    }

    @Test fun fourArgumentScrollSourcesKeepTheActualOwnerGateAndCoordinateClaim() {
        val tasks = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(tasks).bind(physical, owner(tasks))
        bound.observe(false, false)
        val checked = mutableListOf<Set<String>>()
        var denied = false
        physical.duringScroll = {
            val source = checkNotNull(physical.scrollSourceGate)
            assertTrue(source(setOf("other.app")))
            denied = true
            assertFalse(source(setOf("other.app")))
            assertTrue(source(setOf("app")))
        }
        val result = bound.perform(PhoneAction.Scroll("s1", null, PhoneAction.Direction.DOWN), { true }, null) { sources ->
            checked += sources
            !denied || "other.app" !in sources
        }
        assertTrue(result.ok)
        assertEquals(listOf(setOf("other.app"), setOf("other.app"), setOf("app")), checked)
        val source = checkNotNull(physical.scrollSourceGate)
        val claim = checkNotNull(physical.capturedAdmission)
        var claims = 0
        assertTrue(claim { claims++; true })
        val calls = checked.size
        tasks.setPaused(true)
        assertFalse(source(setOf("app")))
        assertFalse(claim { claims++; true })
        assertEquals(calls, checked.size)
        tasks.setPaused(false); tasks.stop("replacement"); tasks.clearStop(); tasks.begin()
        assertFalse(source(setOf("app")))
        assertFalse(claim { claims++; true })
        assertEquals(calls, checked.size)
        assertEquals(1, claims)
        val actions = physical.actions
        assertThrows(InterruptedException::class.java) {
            bound.perform(PhoneAction.Scroll("s1", null, PhoneAction.Direction.DOWN), { true }, null) { true }
        }
        assertEquals(actions, physical.actions)
    }

    @Test fun sevenArgumentCollectBatchKeepsOwnerPauseAndObservationPublication() {
        val tasks = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(tasks).bind(physical, owner(tasks))
        bound.observe(false, false)
        val checked = mutableListOf<Set<String>>()
        var denied = false
        var entered = 0
        physical.collected = CollectResult(listOf("public"), 1, "partial",
            ScreenSnapshot("sBatch", "public screen", "App", "app"))
        physical.duringCollect = {
            entered++
            assertTrue(checkNotNull(physical.collectGate)())
            assertTrue(checkNotNull(physical.collectSourceGate)("other.app"))
            val batch = checkNotNull(physical.collectBatchGate)
            assertTrue(batch(linkedSetOf("other.app", "cover.app")))
            denied = true
            assertFalse(batch(linkedSetOf("other.app", "cover.app")))
        }
        val result = bound.collect("s1", 1, 3, null, { true }, { true }) { sources ->
            checked += sources
            !denied
        }
        assertEquals(1, entered)
        assertEquals(listOf(setOf("other.app", "cover.app"), setOf("other.app", "cover.app")), checked)
        assertSame(physical.collected, result)
        assertNotNull(bound.target("sBatch", 1))
        val batch = checkNotNull(physical.collectBatchGate)
        val calls = checked.size
        tasks.setPaused(true)
        assertFalse(batch(setOf("app"))); assertEquals(calls, checked.size)
        tasks.setPaused(false); tasks.stop("replacement"); tasks.clearStop(); tasks.begin()
        assertFalse(batch(setOf("app"))); assertEquals(calls, checked.size)
        assertThrows(InterruptedException::class.java) {
            bound.collect("sBatch", 1, 3, null, { true }, { true }) { true }
        }
        assertEquals(1, entered)
    }

    @Test fun everyDriverEntryPointHasAnExplicitOwnershipClassification() {
        // This inventories the interface, not the generated delegation class: Kotlin's
        // `by driver` emits methods even when the owner wrapper forgot an override.
        // Adding an entry requires a classification AND a real wrapper behavior test.
        val readOnlyCapabilities = setOf("getScreen()", "availability()")
        val ownerBoundEntries = setOf(
            "observe(boolean,boolean)",
            "observe(boolean,boolean,boolean)",
            "acceptVisualObservation(String)",
            "collect(String,int,int,String)",
            "collect(String,int,int,String,Function0)",
            "collect(String,int,int,String,Function0,Function1)",
            "collect(String,int,int,String,Function0,Function1,Function1)",
            "target(String,int)",
            "prepareFocusInput(String)",
            "prepareSkillReplayStep(SkillReplayStep)",
            "visualScope(String)",
            "coordinateTarget(TapXY)",
            "perform(PhoneAction)",
            "perform(PhoneAction,Function0)",
            "perform(PhoneAction,Function0,Function1)",
            "perform(PhoneAction,Function0,Function1,Function1)",
            "open(PhoneAppIdentity)",
            "open(PhoneAppIdentity,Function0)",
            "foregroundPackage()",
        )
        val actual = PhoneDriver::class.java.methods
            .filterNot { java.lang.reflect.Modifier.isStatic(it.modifiers) }
            .map { method ->
                "${method.name}(${method.parameterTypes.joinToString(",") { it.simpleName }})"
            }.toSet()
        assertTrue(readOnlyCapabilities.intersect(ownerBoundEntries).isEmpty())
        assertEquals("Review every new default entry for delegation bypass; arity alone is insufficient",
            readOnlyCapabilities + ownerBoundEntries, actual)
    }

    @Test fun directThreeArgumentPerformKeepsPublicationOwnerPauseAndTheOriginalClaim() {
        val tasks = PhoneTasks(); val physical = Driver(); val ledger = PhoneTaskObservations(tasks)
        val bound = ledger.bind(physical, owner(tasks))
        bound.observe(false, false)
        physical.performedScreen = ScreenSnapshot("sAfter", "after", "App", "app")
        var callerAllowed = true
        var outerAdmissions = 0
        var outerAllows = true
        val originalAdmission: (() -> Boolean) -> Boolean = { claim ->
            outerAdmissions++
            outerAllows && claim()
        }
        val result = bound.perform(PhoneAction.TapXY("s1", 1, 1), { callerAllowed }, originalAdmission)
        assertTrue(result.ok)
        assertNotNull("Direct perform3 must register the returned observation for this owner",
            bound.target("sAfter", 1))
        assertEquals(1, physical.actions)
        val allowed = checkNotNull(physical.capturedAllowed)
        val admission = checkNotNull(physical.capturedAdmission)
        var claims = 0
        assertTrue(admission { claims++; true })
        assertEquals(1, outerAdmissions); assertEquals(1, claims)
        outerAllows = false
        assertFalse(admission { claims++; true })
        assertEquals(2, outerAdmissions); assertEquals(1, claims)
        outerAllows = true
        callerAllowed = false
        assertFalse(allowed()); assertFalse(admission { claims++; true })
        assertEquals(2, outerAdmissions); assertEquals(1, claims)
        callerAllowed = true
        tasks.setPaused(true)
        assertFalse(allowed()); assertFalse(admission { claims++; true })
        assertEquals(2, outerAdmissions); assertEquals(1, claims)
        assertFalse(bound.perform(PhoneAction.TapXY("sAfter", 1, 1), { true }, originalAdmission).ok)
        assertEquals(1, physical.actions)
        tasks.setPaused(false)
        assertTrue(allowed())
        tasks.stop("replacement"); tasks.clearStop(); tasks.begin()
        assertFalse(allowed()); assertFalse(admission { claims++; true })
        assertEquals(2, outerAdmissions); assertEquals(1, claims)
        assertThrows(InterruptedException::class.java) {
            bound.perform(PhoneAction.TapXY("sAfter", 1, 1), { true }, originalAdmission)
        }
        assertEquals(1, physical.actions)
        val replacement = ledger.bind(physical, checkNotNull(tasks.activeOwner()))
        assertNull(replacement.target("sAfter", 1))
    }

    @Test fun focusPreparationCannotBorrowAnotherTasksObservation() {
        val physical = Driver(); val firstTasks = PhoneTasks(); val otherTasks = PhoneTasks()
        val first = PhoneTaskObservations(firstTasks).bind(physical, owner(firstTasks))
        val other = PhoneTaskObservations(otherTasks).bind(physical, owner(otherTasks))
        first.observe(false, false)
        assertTrue(other.prepareFocusInput("s1") is Either.Left)
        assertEquals(0, physical.focusPreparations)
        assertTrue(first.prepareFocusInput("s1") is Either.Left) // Physical driver is unavailable.
        assertEquals(1, physical.focusPreparations)
    }

    @Test fun focusPlanIsClosedWhenTheOwnerRetiresWhileNativePreparationReturns() {
        val tasks = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(tasks).bind(physical, owner(tasks))
        bound.observe(false, false)
        var closed = 0
        physical.focusPlan = object : FocusInput {
            override val target = TargetInfo("s1", 1, "输入框", "Search", "app", "App", false, false, true)
            override fun perform(text: String, allowed: () -> Boolean): ActionResult = error("retired plan dispatched")
            override fun close() { closed++ }
        }
        physical.duringPrepareFocus = { tasks.stop("old"); tasks.clearStop(); tasks.begin() }
        assertThrows(InterruptedException::class.java) { bound.prepareFocusInput("s1") }
        assertEquals(1, physical.focusPreparations)
        assertEquals(1, closed)
    }

    @Test fun focusPlanKeepsItsOriginalTaskAndLivePolicyGateThroughNativeAdmission() {
        val tasks = PhoneTasks(); val other = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(tasks).bind(physical, owner(tasks))
        owner(other); other.setPaused(true)
        bound.observe(false, false)
        var physicalInputs = 0
        var admission: (() -> Boolean)? = null
        physical.focusPlan = object : FocusInput {
            override val target = TargetInfo("s1", 1, "输入框", "Search", "app", "App", false, false, true)
            override fun perform(text: String, allowed: () -> Boolean): ActionResult {
                admission = allowed
                if (!allowed()) return ActionResult(false, "refused")
                physicalInputs++
                return ActionResult(true, "local readback")
            }
            override fun close() {}
        }
        val plan = (bound.prepareFocusInput("s1") as Either.Right).value
        var policy = true
        try {
            assertTrue(plan.perform(" x ") { policy }.ok)
            assertEquals(1, physicalInputs)
            val allowed = checkNotNull(admission)
            assertTrue(allowed()) // Another displayed task's pause does not select the owner.
            policy = false; assertFalse(allowed())
            policy = true; tasks.setPaused(true); assertFalse(allowed())
            tasks.setPaused(false); tasks.stop("old"); tasks.clearStop(); tasks.begin()
            assertFalse(allowed())
        } finally { plan.close() }
    }

    @Test fun focusPlanCannotUseAnObservationReplacedAfterPreparation() {
        val tasks = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(tasks).bind(physical, owner(tasks))
        bound.observe(false, false)
        var called = 0
        var closed = 0
        physical.focusPlan = object : FocusInput {
            override val target = TargetInfo("s1", 1, "输入框", "Search", "app", "App", false, false, true)
            override fun perform(text: String, allowed: () -> Boolean): ActionResult { called++; return ActionResult(true, "unexpected") }
            override fun close() { closed++ }
        }
        val plan = (bound.prepareFocusInput("s1") as Either.Right).value
        try {
            bound.open(PhoneAppIdentity("app", 10001)) // The same task now owns sOpen, not s1.
            assertFalse(plan.perform("x") { true }.ok)
            assertEquals(0, called)
        } finally { plan.close() }
        assertEquals(1, closed)
    }

    @Test fun focusActionRecordsItsOwnReturnedObservationThroughTheRealLedger() {
        val tasks = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(tasks).bind(physical, owner(tasks))
        bound.observe(false, false)
        physical.focusPlan = object : FocusInput {
            override val target = TargetInfo("s1", 1, "输入框", "Search", "app", "App", false, false, true)
            override fun perform(text: String, allowed: () -> Boolean) =
                ActionResult(allowed(), "after", ScreenSnapshot("sAfter", "new INPUT", "App", "app"))
            override fun close() {}
        }
        val plan = (bound.prepareFocusInput("s1") as Either.Right).value
        try { assertTrue(plan.perform("x") { true }.ok) } finally { plan.close() }
        assertNotNull(bound.target("sAfter", 1))
        assertNull(bound.target("s1", 1))
    }


    @Test fun replayPlanKeepsPrivateBeforeOutOfLedgerAndGuardsOriginalOwnerAtPerform() {
        val tasks = PhoneTasks(); val original = owner(tasks); val physical = Driver()
        var closed = 0; var writes = 0; var externalChecks = 0
        physical.replayPlan = object : SkillReplayPlan {
            override val before = ScreenSnapshot("sPrivate", "private before", "App", "app")
            override val target: TargetInfo? = null
            override val alreadySatisfied = false
            override val attempted get() = writes > 0
            override val post = SkillReplayPost.UNKNOWN
            override fun perform(allowed: () -> Boolean): ActionResult {
                if (!allowed()) return ActionResult(false, "paused")
                writes++
                return ActionResult(true, "one", before.copy(id = "sAfter"))
            }
            override fun close() { closed++ }
        }
        val bound = PhoneTaskObservations(tasks).bind(physical, original)
        val app = com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillReplaySelections.App("app", 1, 1, 1, "a".repeat(64))
        val step = com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute.Step(
            com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute.Op.OPEN_APP, "app1", PhoneScreen.MAIN,
            post = com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute.Post.PageIs("fixture"))
        val plan = (bound.prepareSkillReplayStep(SkillReplayStep(app, step)) as Either.Right).value
        assertNull(bound.target("sPrivate", 1))
        tasks.setPaused(true)
        assertFalse(plan.perform { externalChecks++; true }.ok)
        assertEquals(0, externalChecks); assertEquals(0, writes)
        tasks.setPaused(false)
        assertTrue(plan.perform { externalChecks++; true }.ok)
        assertNull("private after is not a returned model observation", bound.target("sAfter", 1))
        tasks.stop("test"); tasks.clearStop(); owner(tasks)
        assertThrows(InterruptedException::class.java) { plan.perform { externalChecks++; true } }
        assertEquals(1, writes); assertEquals(1, externalChecks)
        plan.close(); assertEquals(1, closed)
    }
}
