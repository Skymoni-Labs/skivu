package com.skyjjgw.independent.ski.dshgo.phone

import com.skyjjgw.independent.ski.dshgo.phone.a11y.StatusOwnership
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

/** Actual shared selection, Tasks and displayed-status ownership; no Android substitutes. */
class PhoneDisplaySelectionTest {
    private fun start(task: PhoneTasks) = (task.begin() as PhoneTasks.Begin.Go).owner

    @Test fun activeAStillCannotPublishAfterBWasSelected() {
        val selection = PhoneDisplaySelection()
        val a = PhoneTasks(); val b = PhoneTasks()
        val oa = start(a); val ob = start(b)
        val ta = selection.select(a, oa)!!
        val late = selection.scoped(a, selection.guard(ta))
        val tb = selection.select(b, ob)!!
        assertTrue(a.isCurrent(oa)) // A was NOT stopped; selection is a separate fact.
        assertFalse(selection.status("late A", late))
        assertTrue(selection.status("B", selection.guard(tb)))
        assertEquals("B", selection.view()!!.line)
        assertSame(b, selection.view()!!.task)
    }

    @Test fun sameOwnerABARejectsFirstExecutionEvenWhenStatusStartsLate() {
        val selection = PhoneDisplaySelection()
        val a = PhoneTasks(); val b = PhoneTasks()
        val oa = start(a); val ob = start(b)
        val first = selection.select(a, oa)!!
        val firstGuard = selection.guard(first)
        selection.select(b, ob)
        val last = selection.select(a, oa)!!
        assertNotSame(first, last)
        // Scoped entry occurs only now. It must preserve the original execution guard.
        assertFalse(selection.status("old A", selection.scoped(a, firstGuard)))
        assertTrue(selection.status("new A", selection.guard(last)))
        assertEquals("new A", selection.view()!!.line)
    }

    @Test fun appsOnlySelectionClearsOldLineAndRetiresDisplayedPill() {
        val selection = PhoneDisplaySelection(); val shown = StatusOwnership()
        val a = PhoneTasks(); val b = PhoneTasks()
        val ta = selection.select(a, start(a))!!
        selection.status("A", selection.guard(ta))
        assertTrue(shown.publish(selection.guard(ta)))
        selection.select(b, start(b)) // B never says anything.
        assertNull(selection.view()!!.line)
        assertSame(b, selection.view()!!.task)
        assertTrue(shown.takeStale())
    }

    @Test fun oldInactiveCleanupCannotRemoveNewStatusOrLine() {
        val selection = PhoneDisplaySelection(); val shown = StatusOwnership()
        val a = PhoneTasks(); val b = PhoneTasks()
        selection.select(a, start(a))
        a.stop("stop")
        val cleanup = selection.inactive(a, a.snapshot())
        val tb = selection.select(b, start(b))!!
        selection.status("B", selection.guard(tb)); shown.publish(selection.guard(tb))
        var cleared = false
        cleanup { cleared = true }
        assertFalse(cleared)
        assertFalse(shown.takeStale())
        assertEquals("B", selection.view()!!.line)
    }

    @Test fun replacementAndRetirementRejectCapturedSelection() {
        val selection = PhoneDisplaySelection(); val task = PhoneTasks()
        val old = start(task); val ticket = selection.select(task, old)!!
        task.stop("stop"); task.clearStop(); start(task)
        assertNull(selection.select(task, old))
        assertFalse(selection.guard(ticket).invoke { fail("retired publication") })
        assertNull(selection.view())
        val fresh = selection.select(task, task.activeOwner()!!)!!
        selection.clear()
        assertFalse(selection.guard(fresh).invoke { fail("cleared publication") })
    }

    @Test fun notificationsNeverCombineOldLineWithNewTaskSnapshot() {
        val selection = PhoneDisplaySelection(); val a = PhoneTasks(); val b = PhoneTasks()
        val ta = selection.select(a, start(a))!!
        a.setApp("App A"); selection.status("line A", selection.guard(ta))
        val snapshot = selection.view()!!
        val tb = selection.select(b, start(b))!!
        b.setApp("App B"); selection.status("line B", selection.guard(tb))
        assertEquals("line A", snapshot.line); assertEquals("App A", snapshot.state.app)
        assertEquals("line B", selection.view()!!.line); assertEquals("App B", selection.view()!!.state.app)
    }

    private val stop = { task: PhoneTasks, owner: PhoneTasks.Owner, reason: String -> task.stopIfCurrent(owner, reason) }

    @Test fun stoppingDisplayedADoesNotAnswerAPromptOwnedByB() {
        val selection = PhoneDisplaySelection()
        val a = PhoneTasks(); val b = PhoneTasks()
        val oa = start(a); val ob = start(b)
        val arbiter = PromptArbiter({ 1_000L }, { "nonce" })
        val prompt = arbiter.begin(null, b, PromptContent(PromptKind.REVIEW, "B"), 30_000) { b.isCurrent(ob) }!!
        val stopOwner = { task: PhoneTasks, owner: PhoneTasks.Owner, reason: String ->
            task.stopIfCurrent(owner, reason).also { accepted -> if (accepted) arbiter.cancelOwner(task) }
        }
        selection.select(a, oa)
        val forA = selection.controls(stopOwner)!!
        assertTrue(forA.stop("stop A"))
        assertTrue(prompt.live)
        selection.select(b, ob)
        assertTrue(selection.controls(stopOwner)!!.stop("stop B"))
        assertFalse(prompt.live)
    }

    @Test fun shownControlsActOnTheTaskTheyWereShownForAfterAnotherIsSelected() {
        val selection = PhoneDisplaySelection(); val shown = StatusOwnership()
        val a = PhoneTasks(); val b = PhoneTasks()
        val oa = start(a); val ob = start(b)
        val ta = selection.select(a, oa)!!
        assertTrue(shown.publish(selection.guard(ta)) { selection.controls(stop) })
        selection.select(b, ob) // B selected while A's pill (or a tap queued on it) is still there.
        val controls = shown.controls!!
        assertEquals(true, controls.setPaused(true))
        assertTrue(a.isPaused); assertFalse(b.isPaused); assertTrue(controls.isPaused())
        assertEquals(true, controls.interject("for A"))
        assertEquals(listOf("for A"), a.drainInterjections()); assertTrue(b.drainInterjections().isEmpty())
        controls.stop("stop A")
        assertFalse(a.isCurrent(oa)); assertTrue(b.isCurrent(ob))
    }

    @Test fun staleShownControlsReachNothing() {
        val selection = PhoneDisplaySelection(); val shown = StatusOwnership()
        val a = PhoneTasks(); val b = PhoneTasks()
        val oa = start(a); val ob = start(b)
        val ta = selection.select(a, oa)!!
        assertTrue(shown.publish(selection.guard(ta)) { selection.controls(stop) })
        val controls = shown.controls!!
        a.stop("stop"); a.clearStop(); val next = start(a) // The displayed owner is gone; A runs anew.
        assertEquals(false, controls.setPaused(true)); assertEquals(false, controls.interject("late")); controls.stop("late")
        assertFalse(a.isPaused); assertFalse(controls.isPaused()); assertTrue(a.drainInterjections().isEmpty())
        assertTrue(a.isCurrent(next))
        // A late status of the old ticket cannot hand its controls to the pill shown for B.
        val tb = selection.select(b, ob)!!
        assertTrue(shown.publish(selection.guard(tb)) { selection.controls(stop) })
        val forB = shown.controls
        assertFalse(shown.publish(selection.guard(ta)) { selection.controls(stop) })
        assertSame(forB, shown.controls)
        selection.clear()
        assertTrue(shown.takeStale()); assertNull(shown.controls)
    }

    @Test fun ownerAwareControlsRejectReusedTasksAndNotifyWithoutHoldingTaskLock() {
        val task = PhoneTasks(); val old = start(task)
        task.stop("stop"); task.clearStop(); val current = start(task)
        assertFalse(task.setPausedIfCurrent(old, true))
        assertFalse(task.interjectIfCurrent(old, "old"))
        assertFalse(task.isPaused); assertTrue(task.drainInterjections().isEmpty())
        val observerDone = CountDownLatch(1)
        var lockFree = false
        task.addListener {
            val reader = Thread { task.snapshot(); observerDone.countDown() }
            reader.start()
            lockFree = observerDone.await(1, TimeUnit.SECONDS)
        }
        assertTrue(task.setPausedIfCurrent(current, true))
        assertTrue(lockFree) // Would fail if fire() were nested in runIfCurrent's lock.
        assertTrue(task.interjectIfCurrent(current, "new"))
        assertEquals(listOf("new"), task.drainInterjections())
    }
}
