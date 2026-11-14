package com.skyjjgw.independent.ski.dshgo.phone

import java.time.ZoneId
import org.junit.Assert.*
import org.junit.Test

/** Real Core/worker/safety flow; fake driver, not an Android stub. */
class PhoneStaleRefreshTest {
    private class Fixture : AutoCloseable {
        val tasks = PhoneTasks()
        var policy = PhonePolicies()
        var locked = false
        var asked = 0
        var reads = 0
        var writes = 0
        var available: () -> Unit = {}
        var onPerform: () -> Unit = {}
        var onObserve: () -> Unit = {}
        var failRead = false
        var missingTarget = false
        var result = ActionResult(false, REJECTION, staleSnapshot = true)
        var next = ScreenSnapshot("b2", "REFRESHED CONTENT", "Example", "example.app")
        private val driver = object : PhoneDriver {
            override val screen = PhoneScreen.BACKGROUND
            override fun availability(): Availability { available(); return Availability(true) }
            override fun foregroundPackage() = "example.app"
            override fun target(screenId: String, elementId: Int): TargetInfo? = if (missingTarget) null else
                TargetInfo(screenId, elementId, "按钮", "发送", "example.app", "Example", false, false, false)
            override fun perform(action: PhoneAction): ActionResult { writes++; onPerform(); return result }
            override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot {
                reads++
                assertFalse(detail)
                assertFalse(image)
                onObserve()
                if (failRead) throw IllegalStateException("READ FAILED")
                return next
            }
            override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = error("unused")
            override fun open(target: PhoneAppIdentity) = error("unused")
        }
        val core = PhoneCore(object : PhoneEnv {
            override fun enabled() = true
            override fun policies() = policy
            override fun isLocked() = locked
            override fun gate() = object : UserGate {
                override fun confirm(request: ConfirmRequest): Decision { asked++; return Decision.ALLOW_ONCE }
                override fun handoff(reason: String, timeoutMs: Long) = error("unused")
                override fun status(text: String?) {}
            }
            override fun driver(screen: PhoneScreen) = if (screen == PhoneScreen.BACKGROUND) driver else null
            override fun a11yState() = A11yState.CONNECTED
            override fun backgroundUnavailable() = "unavailable"
            override fun zone() = ZoneId.of("UTC")
            override fun notifyFix(kind: String) {}
            override fun sleep(ms: Long) {}
            override fun system(): SystemApi = error("unused")
        }, tasks, ActionLog())
        fun tap(sid: String = "b1") = core.call(PhoneToolCatalog.TAP, mapOf("screen" to sid, "id" to 1))
        fun replace() { tasks.endTask(); tasks.begin() }
        override fun close() { core.worker.shutdown() }
    }

    @Test fun explicitStaleRefreshesOnceWithoutReplayAndNextCallAsksAgain() {
        Fixture().use { f ->
            val out = f.tap()
            assertTrue(out.isError)
            assertTrue(out.text.startsWith(REJECTION))
            assertTrue(out.text.contains("REFRESHED CONTENT"))
            assertEquals(1, f.writes)
            assertEquals(1, f.reads)
            assertEquals(1, f.asked)
            f.result = ActionResult(true, "executed")
            assertFalse(f.tap("b2").isError)
            assertEquals(2, f.writes)
            assertEquals(1, f.reads)
            assertEquals(2, f.asked)
        }
    }

    @Test fun matchingMessageOrSuccessfulTypedFlagDoesNotRefresh() {
        Fixture().use { f ->
            f.result = ActionResult(false, REJECTION)
            assertTrue(f.tap().isError)
            assertEquals(0, f.reads)
            f.result = ActionResult(true, REJECTION, staleSnapshot = true)
            assertFalse(f.tap().isError)
            assertEquals(0, f.reads)
        }
    }

    @Test fun failedRefreshPreservesOriginalRefusal() {
        Fixture().use { f ->
            f.failRead = true
            val out = f.tap()
            assertTrue(out.isError)
            assertEquals(REJECTION, out.text)
            assertEquals(1, f.reads)
            assertEquals(1, f.writes)
        }
    }

    @Test fun cancellationOrReadRestrictionAfterRejectionSkipsRefresh() {
        for (kind in listOf("stop", "replace", "locked", "denied", "interrupt")) Fixture().use { f ->
            f.onPerform = {
                when (kind) {
                    "stop" -> f.tasks.stop("stop")
                    "replace" -> f.replace()
                    "locked" -> f.locked = true
                    "denied" -> f.policy = PhonePolicies(denyPackages = listOf("example.app"))
                    "interrupt" -> Thread.currentThread().interrupt()
                }
            }
            val out = f.tap()
            assertTrue(kind, out.isError)
            assertTrue(kind, out.text.startsWith(REJECTION))
            assertEquals(kind, 0, f.reads)
            assertEquals(kind, 1, f.writes)
        }
    }

    @Test fun replacementOrLockDuringReadSuppressesReturnedContent() {
        for (lock in listOf(false, true)) Fixture().use { f ->
            f.onObserve = { if (lock) f.locked = true else f.replace() }
            val out = f.tap()
            assertTrue(out.isError)
            assertEquals(REJECTION, out.text)
            assertEquals(1, f.reads)
        }
    }

    @Test fun actualReturnedPackageIsFilteredEvenWhenPreflightPackageWasAllowed() {
        Fixture().use { f ->
            f.policy = PhonePolicies(denyPackages = listOf("blocked.app"))
            f.next = ScreenSnapshot("b2", "PRIVATE CONTENT", "Blocked", "blocked.app")
            val out = f.tap()
            assertTrue(out.isError)
            assertTrue(out.text.startsWith(REJECTION))
            assertFalse(out.text.contains("PRIVATE CONTENT"))
            assertEquals(1, f.reads)
        }
    }

    @Test fun missingTargetCannotAdoptOwnerReplacedDuringAvailability() {
        Fixture().use { f ->
            f.missingTarget = true
            f.available = { f.replace() }
            val out = f.tap()
            assertTrue(out.isError)
            assertFalse(out.text.contains("按下面的新屏幕"))
            assertEquals(0, f.reads)
            assertEquals(0, f.writes)
        }
    }

    @Test fun interruptedReadUsesExistingStopPathWithoutReplay() {
        Fixture().use { f ->
            f.onObserve = { throw InterruptedException("cancel read") }
            val out = f.tap()
            assertTrue(out.isError)
            assertTrue(out.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
            assertEquals(1, f.reads)
            assertEquals(1, f.writes)
        }
    }

    private companion object { const val REJECTION = "后台屏快照已过期，请重新观察后再操作" }
}
