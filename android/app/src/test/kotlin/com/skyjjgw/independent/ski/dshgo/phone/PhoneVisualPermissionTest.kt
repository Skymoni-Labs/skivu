package com.skyjjgw.independent.ski.dshgo.phone

import java.time.ZoneId
import org.junit.Assert.*
import org.junit.Test

/** Core + real ledger, Tasks and SafetyGate. No Android screenshot or device is simulated as real. */
class PhoneVisualPermissionTest {
    private class Fixture : AutoCloseable {
        val tasks = PhoneTasks()
        val ledger = PhoneTaskObservations(tasks)
        var scope: VisualScope? = VisualScope.Background("display-a", PhoneAppIdentity("example.app", 10123), Any())
        var knownTarget = true
        var accepted = false
        var nextId = 0
        var id = "b0"
        var image: ByteArray? = byteArrayOf(1)
        var textCoordinates = false
        var coordinateCandidate = false
        var afterText: String? = null
        var afterImage: ByteArray? = null
        var afterCoordinates = false
        var imageRequest: Pair<Boolean, Boolean>? = null
        var screenText = "Details"
        var policy = PhonePolicies(confirmMode = ConfirmMode.ASK)
        var decision: (ConfirmRequest) -> Decision = { if (it.visualScope != null) Decision.ALLOW_VISUAL_FOR_TASK else Decision.ALLOW_APP_FOR_TASK }
        val asks = mutableListOf<ConfirmRequest>()
        var actions = 0
        var onAsk: () -> Unit = {}
        val target get() = TargetInfo(id, 1, "button", "Details", "example.app", "Example", false, false, false)
        private val physical = object : PhoneDriver {
            override val screen = PhoneScreen.BACKGROUND
            override fun availability() = Availability(true)
            override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot {
                id = "b${++nextId}"; accepted = false
                coordinateCandidate = this@Fixture.image != null || textCoordinates
                return ScreenSnapshot(id, screenText, "Example", "example.app", image = this@Fixture.image)
            }
            override fun observe(detail: Boolean, image: Boolean, automaticImage: Boolean): ScreenSnapshot {
                imageRequest = image to automaticImage
                return observe(detail, image)
            }
            override fun visualScope(screenId: String) = scope.takeIf { screenId == id }
            override fun acceptVisualObservation(screenId: String) { if (screenId == id && coordinateCandidate) accepted = true }
            override fun coordinateTarget(action: PhoneAction.TapXY) = scope?.takeIf { accepted && knownTarget && action.screenId == id }
                ?.let { VisualTarget(it, target) }
            override fun target(screenId: String, elementId: Int): TargetInfo? = null
            override fun perform(action: PhoneAction): ActionResult {
                if (!accepted) return ActionResult(false, "no image")
                accepted = false; actions++
                val text = afterText ?: return ActionResult(true, "test action")
                id = "b${++nextId}"
                coordinateCandidate = afterCoordinates || afterImage != null
                return ActionResult(true, "test action", ScreenSnapshot(id, text, "Example", "example.app", image = afterImage))
            }
            override fun foregroundPackage() = "example.app"
            override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = error("unused")
            override fun open(target: PhoneAppIdentity) = error("unused")
        }
        val core = PhoneCore(object : PhoneEnv {
            override fun enabled() = true
            override fun policies() = policy
            override fun isLocked() = false
            override fun gate() = object : UserGate {
                override fun confirm(request: ConfirmRequest): Decision {
                    asks += request; onAsk(); return decision(request)
                }
                override fun handoff(reason: String, timeoutMs: Long): HandoffResult = error("unused")
                override fun status(text: String?) {}
            }
            override fun driver(screen: PhoneScreen) = physical
            override fun driver(screen: PhoneScreen, owner: PhoneTasks.Owner) = ledger.bind(physical, owner)
            override fun a11yState() = A11yState.CONNECTED
            override fun backgroundUnavailable() = "unavailable"
            override fun system(): SystemApi = error("unused")
            override fun zone() = ZoneId.of("UTC")
            override fun notifyFix(kind: String) {}
            override fun sleep(ms: Long) {}
        }, tasks, ActionLog())
        fun read(image: Boolean = true) = core.call(PhoneToolCatalog.SCREEN, mapOf("background" to true, "image" to image))
        fun tap(gesture: String = "tap") = core.call(PhoneToolCatalog.TAP_XY,
            mapOf("observation" to id, "x" to 30, "y" to 40, "action" to gesture))
        override fun close() { core.worker.shutdown() }
    }

    @Test fun firstTwoQuestionsAreIndependentAndSecondImageReusesBothPermissions() {
        Fixture().use { f ->
            f.read(); assertFalse(f.tap().isError)
            assertEquals(2, f.asks.size)
            assertTrue(f.asks[0].firstInApp); assertNull(f.asks[0].visualScope)
            assertNotNull(f.asks[1].visualScope); assertFalse(f.asks[1].offerTaskWaiver)
            f.read(); assertFalse(f.tap().isError)
            assertEquals(2, f.asks.size); assertEquals(2, f.actions)
        }
    }
    @Test fun ordinaryAlwaysDoesNotGrantVisualAndAllowOnceNeverPersistsIt() {
        Fixture().use { f ->
            f.policy = PhonePolicies(confirmMode = ConfirmMode.ALWAYS)
            f.decision = { Decision.ALLOW_ONCE }
            repeat(2) { f.read(); assertFalse(f.tap().isError) }
            assertEquals(2, f.asks.size); assertTrue(f.asks.all { it.visualScope != null })
            assertFalse(f.tasks.isApproved("example.app")); assertFalse(f.tasks.isWaived)
        }
    }
    @Test fun textOnlyVisualPointsStillRequireConfirmationForEveryUnknownTarget() {
        Fixture().use { f ->
            f.image = null; f.textCoordinates = true; f.knownTarget = false
            f.screenText = "V1 \"Details\" box=[20,30,50,60) point=(30,40)"
            f.policy = PhonePolicies(confirmMode = ConfirmMode.ALWAYS)
            f.decision = { Decision.ALLOW_ONCE }
            repeat(2) {
                assertFalse(f.read(image = false).isError)
                assertTrue(f.accepted)
                assertFalse(f.tap().isError)
            }
            assertEquals(2, f.actions); assertEquals(2, f.asks.size)
            assertTrue(f.asks.all { it.visualScope == null && !it.offerTaskWaiver })
            assertFalse(f.tasks.isApproved("example.app")); assertFalse(f.tasks.isWaived)
            assertFalse(f.tasks.hasVisualGrant(f.tasks.activeOwner()!!, f.scope!!))
        }
    }
    @Test fun imagePresenceModesReachTheDriverWithoutSkippingTheTaskObservationLedger() {
        val cases = listOf(
            emptyMap<String, Any?>() to (false to true),
            mapOf<String, Any?>("image" to false) to (false to false),
            mapOf<String, Any?>("image" to true) to (true to false),
            mapOf<String, Any?>("image" to null) to (false to false),
            mapOf<String, Any?>("image" to "true") to (false to false),
            mapOf<String, Any?>("image" to "yes") to (false to false),
            mapOf<String, Any?>("image" to 1) to (false to false),
        )
        for ((args, expected) in cases) Fixture().use { f ->
            f.image = null; f.textCoordinates = true
            val result = f.core.call(PhoneToolCatalog.SCREEN, mapOf("background" to true) + args)
            assertFalse(result.isError)
            assertEquals(expected, f.imageRequest)
            // accept reaches the physical driver only when the wrapper remembered this owner/id.
            assertTrue(f.accepted)
        }
    }
    @Test fun textOnlyScreenWithoutDriverCandidateCannotAuthorizeCoordinates() {
        Fixture().use { f ->
            f.image = null; f.knownTarget = false; f.decision = { Decision.ALLOW_ONCE }
            assertFalse(f.read(image = false).isError)
            assertFalse(f.accepted)
            assertTrue(f.tap().isError); assertEquals(0, f.actions)
        }
    }
    @Test fun finalReadRefusalDoesNotAcceptEvenAnAvailableTextCandidate() {
        Fixture().use { f ->
            f.image = null; f.textCoordinates = true
            f.policy = PhonePolicies(denyPackages = listOf("example.app"))
            assertTrue(f.read(image = false).isError)
            assertFalse(f.accepted); assertEquals(0, f.actions)
        }
    }
    @Test fun returnedTextCandidateIsAcceptedOnlyAfterTheActionAndNeedsItsOwnConfirmation() {
        Fixture().use { f ->
            f.image = null; f.textCoordinates = true; f.knownTarget = false
            f.afterText = "V1 \"Next\" box=[20,30,50,60) point=(30,40)"; f.afterCoordinates = true
            f.policy = PhonePolicies(confirmMode = ConfirmMode.ALWAYS)
            f.decision = { Decision.ALLOW_ONCE }
            f.read(image = false)
            val before = f.id
            assertFalse(f.tap().isError)
            assertNotEquals(before, f.id); assertTrue(f.accepted)
            assertFalse(f.tap().isError)
            assertEquals(2, f.actions); assertEquals(2, f.asks.size)
            assertTrue(f.asks.all { it.visualScope == null && !it.offerTaskWaiver })
            assertFalse(f.tasks.hasVisualGrant(f.tasks.activeOwner()!!, f.scope!!))
        }
    }
    @Test fun filteredPostActionImageKeepsTheActionFactButDoesNotAcceptItsCandidate() {
        Fixture().use { f ->
            f.knownTarget = false; f.decision = { Decision.ALLOW_ONCE }
            f.afterText = "«银行卡 ****1234»"; f.afterImage = byteArrayOf(1); f.afterCoordinates = true
            f.read()
            val result = f.tap()
            assertFalse(result.isError); assertEquals(1, f.actions)
            assertNull(result.image); assertFalse(f.accepted)
            assertTrue(f.tap().isError); assertEquals(1, f.actions)
        }
    }
    @Test fun unknownEveryWriteAndLongTapNeverOfferOrUseVisualGrant() {
        Fixture().use { f ->
            f.read(); f.tap(); f.asks.clear(); f.decision = { Decision.ALLOW_ONCE }
            f.knownTarget = false; f.read(); f.tap()
            f.knownTarget = true; f.read(); f.tap("long")
            f.policy = PhonePolicies(confirmMode = ConfirmMode.ALWAYS, confirmEveryWritePackages = listOf("example.app"))
            f.read(); f.tap()
            assertEquals(3, f.asks.size); assertTrue(f.asks.all { it.visualScope == null && !it.offerTaskWaiver })
        }
    }
    @Test fun scopeTransitionsViaScreensWithoutCoordinatesRevokeBeforeReturningToA() {
        Fixture().use { f ->
            f.read(); f.tap(); val a = f.scope
            f.scope = VisualScope.Background("display-b", PhoneAppIdentity("example.app", 1010123), Any()); f.image = null; f.read()
            f.scope = a; f.image = byteArrayOf(1); f.read(); f.tap()
            assertEquals(3, f.asks.size)
            f.scope = null; f.read(); f.scope = a; f.read(); f.tap()
            assertEquals(4, f.asks.size)
        }
    }
    @Test fun filteredImageAndLateOwnerCannotAuthorizeAnAction() {
        Fixture().use { f ->
            f.screenText = "«银行卡 ****1234»"; f.read()
            assertFalse(f.accepted); f.decision = { Decision.ALLOW_ONCE }
            assertTrue(f.tap().isError); assertEquals(0, f.actions)
        }
        Fixture().use { f ->
            f.policy = PhonePolicies(confirmMode = ConfirmMode.ALWAYS); f.read()
            f.onAsk = { f.tasks.stop("stop"); f.tasks.clearStop(); f.tasks.begin() }
            assertTrue(f.tap().isError); assertEquals(0, f.actions)
        }
    }
    @Test fun ordinaryAllowAppCannotAnswerVisualQuestion() {
        Fixture().use { f ->
            f.policy = PhonePolicies(confirmMode = ConfirmMode.ALWAYS)
            f.decision = { Decision.ALLOW_APP_FOR_TASK }; f.read()
            assertTrue(f.tap().isError); assertEquals(0, f.actions)
            assertFalse(f.tasks.isApproved("example.app"))
        }
    }
    @Test fun policyChangedDuringOrdinaryConfirmationCannotOfferVisualPermission() {
        Fixture().use { f ->
            f.decision = { Decision.ALLOW_ONCE }
            f.onAsk = {
                if (f.asks.size == 1) f.policy = PhonePolicies(confirmMode = ConfirmMode.ALWAYS,
                    confirmEveryWritePackages = listOf("example.app"))
            }
            f.read(); assertFalse(f.tap().isError)
            assertEquals(2, f.asks.size)
            assertTrue(f.asks.all { it.visualScope == null })
            assertFalse(f.asks.last().offerTaskWaiver)
            assertEquals(1, f.actions)
            val owner = f.tasks.activeOwner()!!
            assertFalse(f.tasks.hasVisualGrant(owner, f.scope!!))
        }
    }
}
