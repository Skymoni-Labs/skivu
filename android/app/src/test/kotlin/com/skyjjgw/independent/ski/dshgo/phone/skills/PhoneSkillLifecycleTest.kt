package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.phone.PhoneScreen
import com.skyjjgw.independent.ski.dshgo.phone.PhoneTasks
import org.junit.Assert.*
import org.junit.Test

class PhoneSkillLifecycleTest {
    private class Fixture {
        val tasks = PhoneTasks(clock = { 1L })
        val trace = PhoneTaskTrace()
        val drafts = PhoneSkillDrafts()
        val lifecycle = PhoneSkillLifecycle(trace, drafts)
        init { tasks.addListener(lifecycle::changed); lifecycle.launched() }
        fun start(): PhoneTasks.Owner {
            val owner = (tasks.begin() as PhoneTasks.Begin.Go).owner
            tasks.runIfCurrent(owner) { trace.start(owner); lifecycle.started(owner) }
            return owner
        }
        fun returned(owner: PhoneTasks.Owner) {
            trace.finish(trace.beginOpen(owner, PhoneScreen.MAIN), true, false, true)
        }
    }

    @Test fun legacyFinishAndStopCannotPublishCandidatesEvenWithReturnedSteps() {
        for (stop in listOf(false, true)) {
            val f = Fixture(); val owner = f.start(); f.returned(owner)
            if (stop) f.tasks.stop("test") else assertNotNull(f.tasks.finishScope(owner.taskId))
            assertTrue(f.trace.snapshot(owner)!!.ended)
            assertFalse(f.trace.snapshot(owner)!!.canDraft); assertTrue(f.drafts.candidates().isEmpty())
        }
    }

    @Test fun nativeDrainedCompletionNeedsOriginalOwnerAndExplicitCompletedCategory() {
        for (completion in listOf("completed", "other", "unknown", "")) {
            val f = Fixture(); val owner = f.start(); val epoch = f.drafts.currentEpoch(); f.returned(owner)
            assertEquals(completion == "completed", f.lifecycle.completeDrained(owner, epoch, completion))
            assertEquals(if (completion == "completed") 1 else 0, f.drafts.candidates().size)
            if (completion == "completed") assertEquals(owner.lifecycle, f.drafts.candidates().single().owner.lifecycle)
        }
    }

    @Test fun retirementClearsPendingFactsAndLateBodyCannotRepopulateCandidates() {
        val f = Fixture(); val owner = f.start(); val epoch = f.drafts.currentEpoch()
        val ticket = f.trace.beginOpen(owner, PhoneScreen.MAIN)
        f.tasks.invalidateOwners(); f.lifecycle.retired()
        f.trace.finish(ticket, true, false, true)
        assertFalse(f.lifecycle.completeDrained(owner, epoch, "completed"))
        assertEquals(0, f.trace.reservedBytes()); assertTrue(f.drafts.candidates().isEmpty())
        // A body beginning after retirement is discarded, not attached to the next runtime epoch.
        val late = f.start(); assertNull(f.trace.snapshot(late))
    }

    @Test fun delayedOldStatusCannotCloseTheCurrentTrace() {
        val f = Fixture(); val old = f.start(); val oldStatus = f.tasks.snapshot()
        f.tasks.finishScope(old.taskId)
        val fresh = f.start(); f.returned(fresh)
        f.lifecycle.changed(oldStatus)
        assertFalse(f.trace.snapshot(fresh)!!.ended)
        assertTrue(f.lifecycle.completeDrained(fresh, f.drafts.currentEpoch(), "completed"))
    }

    @Test fun uncertainBodyIsNeverMadeEligibleByCompletionOrLateReturn() {
        val f = Fixture(); val owner = f.start(); val epoch = f.drafts.currentEpoch()
        val ticket = f.trace.beginOpen(owner, PhoneScreen.MAIN)
        assertFalse(f.lifecycle.completeDrained(owner, epoch, "completed"))
        f.trace.finish(ticket, true, false, true)
        assertFalse(f.trace.snapshot(owner)!!.canDraft)

    }
    @Test fun validOldSnapshotCannotBeOfferedAcrossRuntimeRetirement() {
        val f = Fixture(); val owner = f.start(); val epoch = f.drafts.currentEpoch(); f.returned(owner)
        f.trace.complete(owner, true)
        val snapshot = f.trace.snapshot(owner)!!; assertTrue(snapshot.canDraft)
        f.lifecycle.retired()
        assertFalse(f.drafts.offer(epoch, snapshot)); assertTrue(f.drafts.candidates().isEmpty())
    }

}
