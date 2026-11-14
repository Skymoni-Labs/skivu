package com.skyjjgw.independent.ski.dshgo.phone.selfcheck

import org.junit.Assert.*
import org.junit.Test

class TargetStateTest {
    private val run = "12345678-1234-1234-1234-123456789abc"
    private fun started() = TargetState(run).also {
        assertTrue(it.schedule(7))
        assertTrue(it.attempt())
        it.launchReturned()
    }
    private fun empty(state: TargetState, task: Int = 12, marker: String = TargetContract.identifier(run)) =
        state.observeTask(state.taskReadStamp(), task, TargetContract.ACTIVITY_CLASS, marker, 7, false, 0, true)

    @Test fun queuedCancellationWaitsForOriginalLaunchJobToReturn() {
        val state = TargetState(run)
        assertTrue(state.schedule(7))
        state.seal()
        assertFalse(state.attempt())
        assertFalse(state.facts().closed)
        state.launchReturned()
        assertTrue(state.facts().closed)
        assertFalse(state.facts().launchAttempted)
    }

    @Test fun attemptedLaunchWithoutActivityRemainsUnknownEvenWithEmptyTask() {
        val state = started()
        state.seal()
        assertTrue(empty(state))
        assertFalse(state.facts().closed)
        assertTrue(state.facts().cleanupPending)
    }

    @Test fun lockTaskModeNeverAttemptsALaunchAndroidWouldSilentlyDrop() {
        val state = TargetState(run)
        assertTrue(state.schedule(7))
        assertFalse(state.attempt(lockTaskActive = true))
        state.launchReturned()
        state.seal()
        assertFalse(state.facts().launchAttempted)
        assertTrue(state.finishIfClosed())
    }

    @Test fun normalCloseNeedsOriginalDestroyAndStructuredEmptyTask() {
        val state = started()
        val activity = Any()
        assertTrue(state.register(activity, 7, 12))
        state.seal()
        state.destroyed(activity, finishing = true, changingConfiguration = false)
        state.teardownCompleted(activity)
        assertFalse(state.facts().closed)
        assertTrue(empty(state))
        assertTrue(state.finishIfClosed())
        assertNull(state.instance())
        assertTrue(state.facts().closed)
    }

    @Test fun emptyTaskDoesNotReplaceOriginalDestroyCallback() {
        val state = started()
        val activity = Any()
        state.register(activity, 7, 12)
        state.seal()
        empty(state)
        state.destroyed(Any(), finishing = true, changingConfiguration = false)
        assertFalse(state.facts().closed)
        state.destroyed(activity, finishing = true, changingConfiguration = false)
        state.teardownCompleted(activity)
        assertFalse(state.facts().closed)
        empty(state)
        assertTrue(state.facts().closed)
    }

    @Test fun wrongRunOrTaskCannotAcknowledgeCleanup() {
        val state = started()
        val activity = Any()
        state.register(activity, 7, 12)
        state.seal()
        state.destroyed(activity, true, false)
        state.teardownCompleted(activity)
        assertFalse(empty(state, task = 13))
        assertFalse(empty(state, marker = "dsh-selfcheck-c1:another-run"))
        assertFalse(state.observeTask(state.taskReadStamp(), 12, "another.Activity", TargetContract.identifier(run), 7, false, 0, true))
        assertFalse(state.facts().closed)
    }

    @Test fun configurationDestroyIsNotFinalClose() {
        val state = started()
        val activity = Any()
        state.register(activity, 7, 12)
        state.seal()
        state.destroyed(activity, finishing = true, changingConfiguration = true)
        state.teardownCompleted(activity)
        empty(state)
        assertFalse(state.facts().closed)
    }

    @Test fun configurationReplacementIsTrackedThroughFinalClose() {
        val state = started()
        val original = Any()
        assertTrue(state.register(original, 7, 12))
        state.destroyed(original, finishing = false, changingConfiguration = true)
        // The relaunch is still in flight: an empty read cannot stand in for the replacement.
        empty(state)
        assertTrue(state.facts().cleanupPending)
        val replacement = Any()
        assertFalse(state.register(replacement, 7, 12)) // Sealed: tracked, but it must not draw.
        assertSame(replacement, state.instance())
        assertFalse(state.register(Any(), 7, 12))
        assertSame(replacement, state.instance())
        assertTrue(state.destroyed(replacement, finishing = true, changingConfiguration = false))
        state.teardownCompleted(replacement)
        assertFalse(state.facts().closed)
        assertTrue(empty(state))
        assertTrue(state.finishIfClosed())
    }

    @Test fun lateCreationAfterSealIsRecordedAndMustFinish() {
        val state = started()
        state.seal()
        val activity = Any()
        assertFalse(state.register(activity, 7, 12))
        assertTrue(state.facts().created)
        empty(state)
        assertFalse(state.facts().closed)
        state.destroyed(activity, true, false)
        state.teardownCompleted(activity)
        empty(state)
        assertTrue(state.facts().closed)
    }

    @Test fun wrongMainRemainsObservedAfterSuccessfulLocalCleanup() {
        val state = started()
        val activity = Any()
        assertFalse(state.register(activity, 0, 12))
        state.destroyed(activity, true, false)
        state.teardownCompleted(activity)
        empty(state)
        assertTrue(state.facts().wrongMain)
        assertTrue(state.facts().closed)
    }

    @Test fun readTaskCanRecordWrongMainBeforeOnCreateButCannotClaimCreated() {
        val state = started()
        assertTrue(state.observeTask(state.taskReadStamp(), 12, TargetContract.ACTIVITY_CLASS, TargetContract.identifier(run),
            0, true, 1, false))
        assertTrue(state.facts().wrongMain)
        assertFalse(state.facts().created)
        state.seal()
        assertFalse(state.facts().closed)
    }

    @Test fun oneLaunchAttemptAndClosedTicketCannotAcquireAnotherInstance() {
        val state = started()
        val activity = Any()
        assertFalse(state.schedule(8))
        assertFalse(state.attempt())
        state.register(activity, 7, 12)
        state.seal()
        state.destroyed(activity, true, false)
        state.teardownCompleted(activity)
        empty(state)
        assertTrue(state.finishIfClosed())
        assertFalse(state.register(Any(), 7, 14))
        assertTrue(state.facts().closed)
    }

    @Test fun oldRunDestructionCannotChangeNextRunsState() {
        val old = started()
        val fresh = TargetState("abcdefab-1234-1234-1234-123456789abc")
        fresh.schedule(9)
        fresh.attempt()
        fresh.launchReturned()
        val oldActivity = Any()
        val newActivity = Any()
        old.register(oldActivity, 7, 12)
        fresh.register(newActivity, 9, 13)
        old.seal()
        old.destroyed(oldActivity, true, false)
        old.teardownCompleted(oldActivity)
        empty(old)
        assertTrue(old.facts().closed)
        assertFalse(fresh.facts().closed)
        assertSame(newActivity, fresh.instance())
    }

    @Test fun queryStartedBeforeBarrierCannotCommitEmptyAfterBarrier() {
        val state = started()
        val activity = Any()
        state.register(activity, 7, 12)
        state.seal()
        state.destroyed(activity, true, false)
        val beforeBarrier = state.taskReadStamp()
        state.teardownCompleted(activity)
        assertTrue(state.observeTask(beforeBarrier, 12, TargetContract.ACTIVITY_CLASS,
            TargetContract.identifier(run), 7, false, 0, true))
        assertFalse(state.facts().closed)
        empty(state)
        assertTrue(state.facts().closed)
    }

    @Test fun onDestroyAloneCannotReleaseEvenWithEmptyTaskAndWrongMain() {
        val state = started()
        val activity = Any()
        state.register(activity, 0, 12)
        state.destroyed(activity, true, false)
        empty(state)
        assertTrue(state.facts().wrongMain)
        assertNull(state.taskReadStamp())
        assertFalse(state.facts().closed)
        state.teardownCompleted(activity)
        // The barrier also invalidates any pre-barrier structural result.
        assertFalse(state.facts().closed)
        empty(state)
        assertTrue(state.facts().closed)
    }

    @Test fun anotherInstanceCannotSupplyTeardownBarrier() {
        val state = started()
        val activity = Any()
        state.register(activity, 7, 12)
        state.seal()
        state.destroyed(activity, true, false)
        state.teardownCompleted(Any())
        empty(state)
        assertNull(state.taskReadStamp())
        assertFalse(state.facts().closed)
    }

    private fun c2(): Pair<TargetState, Any> {
        val state = TargetState(run, TargetContract.Profile.C2)
        val activity = Any()
        state.schedule(7)
        state.attempt()
        state.launchReturned()
        state.register(activity, 7, 12)
        return state to activity
    }

    @Test fun c1CannotEnablePatternStages() {
        val state = started()
        val activity = Any()
        state.register(activity, 7, 12)
        assertFalse(state.advance(activity, 7, TargetContract.FrameStage.CAPTURE))
    }

    @Test fun stagesAreOrderedAndCannotReplayOrWrap() {
        val (state, activity) = c2()
        assertFalse(state.advance(activity, 7, TargetContract.FrameStage.CONTINUITY_FIRST))
        for (stage in TargetContract.FrameStage.values()) {
            assertTrue(state.advance(activity, 7, stage))
            assertFalse(state.advance(activity, 7, stage))
        }
        assertFalse(state.advance(activity, 7, TargetContract.FrameStage.CAPTURE))
    }

    @Test fun aDifferentInstanceOrDisplayCannotAdvanceTheOriginalRun() {
        val (state, activity) = c2()
        assertFalse(state.advance(Any(), 7, TargetContract.FrameStage.CAPTURE))
        assertFalse(state.advance(activity, 0, TargetContract.FrameStage.CAPTURE))
        assertFalse(state.advance(activity, 8, TargetContract.FrameStage.CAPTURE))
        assertTrue(state.advance(activity, 7, TargetContract.FrameStage.CAPTURE))
    }

    @Test fun sealBeforeQueuedStageExecutionRejectsItsActualAdmission() {
        val (state, activity) = c2()
        state.seal()
        assertFalse(state.advance(activity, 7, TargetContract.FrameStage.CAPTURE))
        assertTrue(state.facts().cleanupPending)
    }

    @Test fun destructionPreventsLaterPhaseAdmissionWithoutInventingClosed() {
        val (state, activity) = c2()
        state.destroyed(activity, finishing = true, changingConfiguration = false)
        assertFalse(state.advance(activity, 7, TargetContract.FrameStage.CAPTURE))
        assertFalse(state.facts().closed)
    }

}
