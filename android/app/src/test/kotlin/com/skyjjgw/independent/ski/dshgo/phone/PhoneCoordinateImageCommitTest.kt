package com.skyjjgw.independent.ski.dshgo.phone

import com.skyjjgw.independent.ski.dshgo.phone.background.BackgroundCoordinateImage
import java.time.ZoneId
import org.junit.Assert.*
import org.junit.Test

/** Real Core + task ledger + candidate state; synthetic bytes are not a platform screenshot test. */
class PhoneCoordinateImageCommitTest {
    private class Fixture(val physicalScreen: PhoneScreen = PhoneScreen.BACKGROUND) : AutoCloseable {
        val tasks = PhoneTasks()
        val ledger = PhoneTaskObservations(tasks)
        val image = BackgroundCoordinateImage()
        var next = ScreenSnapshot("${physicalScreen.prefix}1", "canvas", "Example", "example.app", image = byteArrayOf(1), imageMime = "image/jpeg")
        var onObserve: () -> Unit = {}
        var acceptCalls = 0
        var textOnlyCandidate = false
        var confirmations = 0
        var performed = 0
        var policy = PhonePolicies(confirmMode = ConfirmMode.ALWAYS)
        private val physical = object : PhoneDriver {
            override val screen = physicalScreen
            override fun availability() = Availability(true)
            override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot {
                this@Fixture.image.candidate(next.id,
                    if (next.image == null && !textOnlyCandidate) null else BackgroundCoordinateImage.Receipt("nonce", 48, 48))
                onObserve()
                return next
            }
            override fun acceptVisualObservation(screenId: String) { acceptCalls++; image.accept(screenId) }
            override fun target(screenId: String, elementId: Int): TargetInfo? = null
            override fun perform(action: PhoneAction): ActionResult {
                performed++
                return ActionResult(image.take(action.screenId) != null, "synthetic action")
            }
            override fun foregroundPackage() = next.packageName
            override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = error("unused")
            override fun open(target: PhoneAppIdentity) = error("unused")
        }
        val core = PhoneCore(object : PhoneEnv {
            override fun enabled() = true
            override fun policies() = policy
            override fun isLocked() = false
            override fun gate() = object : UserGate {
                override fun confirm(request: ConfirmRequest): Decision {
                    confirmations++
                    assertFalse(request.offerTaskWaiver)
                    return Decision.ALLOW_ONCE
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
        fun read() = core.call(PhoneToolCatalog.SCREEN, mapOf("background" to (physicalScreen == PhoneScreen.BACKGROUND), "image" to true))
        fun tap() = core.call(PhoneToolCatalog.TAP_XY, mapOf("observation" to next.id, "x" to 10, "y" to 20))
        override fun close() { core.worker.shutdown() }
    }

    @Test fun retainedImageCommitsThroughRealOwnerLedgerAndBackgroundTapStillConfirms() {
        Fixture().use { f ->
            assertFalse(f.read().isError)
            assertEquals(1, f.acceptCalls)
            assertFalse(f.tap().isError)
            assertEquals(1, f.confirmations)
            assertTrue(f.tap().isError) // Same image cannot authorize a second action.
            assertEquals(2, f.confirmations)
        }
    }

    @Test fun finalFilteringOrMissingCandidateNeverAuthorizesCoordinates() {
        for (screen in PhoneScreen.entries) for (kind in listOf("card", "secure", "own", "deny", "missing")) Fixture(screen).use { f ->
            f.next = when (kind) {
                "card" -> f.next.copy(text = "«银行卡 ****1234»")
                "secure" -> f.next.copy(secure = true)
                "own" -> f.next.copy(packageName = SafetyRules.OWN_PACKAGE)
                "deny" -> f.next.copy(packageName = SafetyRules.DEFAULT_DENY.first())
                else -> f.next.copy(image = null, imageMime = null)
            }
            val output = f.read()
            val case = "$screen/$kind"
            assertNull(case, output.image)
            // Unchanged text-only output reaches the driver; a missing receipt still cannot commit.
            assertEquals(case, if (kind == "missing") 1 else 0, f.acceptCalls)
            assertNull(case, f.image.take(f.next.id))
        }
    }

    @Test fun retainedTextOnlyCandidateCommitsThroughTheRealOwnerLedger() {
        for (screen in PhoneScreen.entries) Fixture(screen).use { f ->
            // Models a driver's eligible OCR-only receipt, not SDK recognition or its privacy gates.
            f.textOnlyCandidate = true
            f.next = f.next.copy(image = null, imageMime = null)
            val output = f.read()
            assertFalse(screen.name, output.isError)
            assertNull(screen.name, output.image)
            assertEquals(screen.name, 1, f.acceptCalls)
            assertNotNull(screen.name, f.image.take(f.next.id))
            assertNull(screen.name, f.image.take(f.next.id))
        }
    }

    @Test fun stopDuringObservationCannotCommitIntoTheReplacementTask() {
        Fixture().use { f ->
            f.onObserve = { f.tasks.stop("synthetic stop"); f.tasks.clearStop(); f.tasks.begin() }
            assertTrue(f.read().isError)
            assertEquals(0, f.acceptCalls)
            assertNull(f.image.take("b1"))
        }
    }
}
