package com.skyjjgw.independent.ski.dshgo.phone

import java.time.ZoneId
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Real Core -> SerialWorker -> captured display guard -> gate; platform drivers are test doubles. */
class PhoneDisplayExecutionTest {
    private val selection = PhoneDisplaySelection()
    private val cores = mutableListOf<PhoneCore>()
    private val queued = mutableListOf<() -> Boolean>()
    private var beforeDriver: () -> Unit = {}
    private var beforeSelect: (PhoneTasks, PhoneTasks.Owner) -> Unit = { _, _ -> }
    private var reads = 0

    private val driver = object : PhoneDriver {
        override val screen = PhoneScreen.MAIN
        override fun availability() = Availability(true)
        override fun foregroundPackage() = "example.fixture"
        override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot {
            reads++
            return ScreenSnapshot("s1", "synthetic", "Fixture", "example.fixture")
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?): CollectResult = error("unused")
        override fun target(screenId: String, elementId: Int): TargetInfo? = error("unused")
        override fun perform(action: PhoneAction): ActionResult = error("unused")
        override fun open(target: PhoneAppIdentity): ActionResult = error("unused")
    }

    private fun core(task: PhoneTasks): PhoneCore {
        val env = object : PhoneEnv {
            override fun enabled() = true
            override fun policies() = PhonePolicies()
            override fun isLocked() = false
            override fun gate() = object : UserGate {
                override fun confirm(request: ConfirmRequest) = Decision.DENY
                override fun handoff(reason: String, timeoutMs: Long) = HandoffResult.STOP
                override fun status(text: String?) = error("Core must keep its guard")
                override fun status(text: String?, ifCurrent: (() -> Unit) -> Boolean) {
                    // Same production scoping used by PhonePrompts, deferred like its overlay leaf.
                    val scoped = selection.scoped(task, ifCurrent)
                    queued += { selection.status(text, scoped) }
                }
            }
            override fun driver(screen: PhoneScreen): PhoneDriver { beforeDriver(); return this@PhoneDisplayExecutionTest.driver }
            override fun a11yState() = A11yState.CONNECTED
            override fun backgroundUnavailable() = "unused"
            override fun system(): SystemApi = error("unused")
            override fun zone() = ZoneId.of("UTC")
            override fun notifyFix(kind: String) {}
        }
        return PhoneCore(env, task, ActionLog(), onExecution = { owner ->
            beforeSelect(task, owner)
            selection.select(task, owner)?.let(selection::guard)
        }).also { cores += it }
    }

    @After fun close() { cores.forEach { it.worker.shutdown() } }

    @Test fun queuedStatusCannotReviveAfterAnotherActiveTaskSelection() {
        val a = PhoneTasks(); val b = PhoneTasks()
        val ca = core(a); val cb = core(b)
        assertFalse(ca.call("screen", emptyMap()).isError)
        assertFalse(cb.call("screen", emptyMap()).isError)
        assertTrue(a.isActive); assertTrue(b.isActive)
        assertFalse(queued[0]()); assertTrue(queued[1]())
        assertSame(b, selection.view()!!.task)
    }

    @Test fun abandonedBodyCannotCaptureNewASerialAtFirstSay() {
        val a = PhoneTasks(); val b = PhoneTasks()
        val cbOwner = (b.begin() as PhoneTasks.Begin.Go).owner
        val ca = core(a)
        beforeDriver = {
            val original = a.activeOwner()!!
            selection.select(b, cbOwner)
            selection.select(a, original)
            beforeDriver = {}
        }
        assertFalse(ca.call("screen", emptyMap()).isError)
        assertTrue(a.isActive)
        assertEquals(1, reads)
        assertFalse(queued.single()()) // A fresh guard at say() would incorrectly pass.
        assertNull(selection.view()!!.line)
    }

    @Test fun stopBetweenCoreCurrentCheckAndSelectionPreventsDriverEntry() {
        val task = PhoneTasks(); val core = core(task)
        beforeSelect = { t, _ -> t.stop("stop at selection") }
        assertTrue(core.call("screen", emptyMap()).isError)
        assertEquals(0, reads)
        assertTrue(queued.isEmpty())
        assertNull(selection.ticket())
    }
}
