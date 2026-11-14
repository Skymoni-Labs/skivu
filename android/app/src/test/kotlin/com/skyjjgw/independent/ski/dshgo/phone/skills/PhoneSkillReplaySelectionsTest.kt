package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.phone.PhoneCaller
import com.skyjjgw.independent.ski.dshgo.phone.PhoneScreen
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillBundleReader
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Real selection/claim state tests. Prepared inputs stand in for separately validated Reader/PM
 * results; no fixture is added to the production App registry and no device executor is faked. */
class PhoneSkillReplaySelectionsTest {
    private val request = PhoneSkillReplaySelections.Request("phone-task-${"1".repeat(32)}", "2".repeat(32), "s1", "fixture.app", 10001)
    private val route = PhoneSkillRoute.Route(request.name, request.revision, "fixture-only", listOf("app1"), emptyList(),
        listOf(PhoneSkillRoute.Step(PhoneSkillRoute.Op.OPEN_APP, "app1", PhoneScreen.MAIN,
            post = PhoneSkillRoute.Post.PageIs("home"))))
    private val bundle = PhoneSkillBundleReader.Read.Accepted(route, 2, "a".repeat(64), "b".repeat(64))
    private val app = PhoneSkillReplaySelections.App("fixture.app", 10001, 1, 2, "c".repeat(64))
    private val client = PhoneSkillDrafts().attachClient()
    private fun caller(run: String = "r1", session: String = "s1", lifecycle: Int = 1) = PhoneCaller(session, run, "c1", lifecycle)

    @Test fun wrongSessionLegacyAndRetiredSourceNeverClaimAndDuplicateDoesNotStartAgain() {
        val selections = PhoneSkillReplaySelections { 0L }; var live = true
        val selected = selections.prepare(client, 1, { live }, request, bundle, app)!!
        assertSame(PhoneSkillReplaySelections.Claim.Refused, selections.claim(selected, caller(session = "other")))
        assertSame(PhoneSkillReplaySelections.Claim.Refused, selections.claim(selected, caller(lifecycle = 0)))
        live = false
        assertSame(PhoneSkillReplaySelections.Claim.Refused, selections.claim(selected, caller()))
        assertNull(selected.run)
        val current = selections.prepare(client, 1, { true }, request, bundle, app)!!
        assertTrue(selections.claim(current, caller()) is PhoneSkillReplaySelections.Claim.Start)
        assertTrue(selections.claim(current, caller()) is PhoneSkillReplaySelections.Claim.Existing)
        assertSame(PhoneSkillReplaySelections.Claim.Refused, selections.claim(current, caller("r2")))
    }
    @Test fun twoRunsCompetingForOneSelectionHaveExactlyOneFirstClaim() {
        val selections = PhoneSkillReplaySelections { 0L }
        val selected = selections.prepare(client, 1, { true }, request, bundle, app)!!
        val ready = CountDownLatch(2); val go = CountDownLatch(1)
        val workers = Executors.newFixedThreadPool(2)
        try {
            val calls = listOf("r1", "r2").map { run -> workers.submit<PhoneSkillReplaySelections.Claim> {
                ready.countDown(); check(go.await(2, TimeUnit.SECONDS)); selections.claim(selected, caller(run))
            } }
            assertTrue(ready.await(2, TimeUnit.SECONDS)); go.countDown()
            val results = calls.map { it.get(2, TimeUnit.SECONDS) }
            assertEquals(1, results.count { it is PhoneSkillReplaySelections.Claim.Start })
            assertEquals(1, results.count { it === PhoneSkillReplaySelections.Claim.Refused })
        } finally { go.countDown(); workers.shutdownNow() }
    }
    @Test fun replacementAndDiscardAffectOnlyOriginalUnclaimedSelection() {
        val selections = PhoneSkillReplaySelections { 0L }
        val old = selections.prepare(client, 1, { true }, request, bundle, app)!!
        val fresh = selections.prepare(client, 1, { true }, request, bundle, app)!!
        assertSame(PhoneSkillReplaySelections.Claim.Refused, selections.claim(old, caller()))
        assertFalse(selections.discard(client, old.invocation))
        assertTrue(selections.claim(fresh, caller()) is PhoneSkillReplaySelections.Claim.Start)
        assertFalse(selections.discard(client, fresh.invocation))
        assertNull(selections.control(fresh, caller("other"), true))
        assertEquals(true, selections.control(fresh, caller(), true)!!["cancelRequested"])
        assertFalse(selections.current(fresh))
        selections.retire(); assertNull(selections.find(fresh.invocation))
    }
    @Test fun identitiesMustMatchReadBundleAndChosenAppBeforeIssuingASelection() {
        val selections = PhoneSkillReplaySelections { 0L }
        assertNull(selections.prepare(client, 1, { true }, request, bundle.copy(route = route.copy(revision = "3".repeat(32))), app))
        assertNull(selections.prepare(client, 1, { true }, request, bundle, app.copy(uid = 10002)))
        assertNull(selections.prepare(client, 1, { false }, request, bundle, app))
    }
    /** Real reply work, MCP encoder, record and durable accounting; time is controlled, not slept. */
    private fun terminalTail(order: String, expected: PhoneSkillOutcomes.Outcome, expectedState: String) {
        var now = 1L
        val deadline = 10L
        val records = PhoneSkillReplaySelections { now }
        val selection = records.prepare(client, 1, { true }, request, bundle, app)!!
        assertTrue(records.claim(selection, caller()) is PhoneSkillReplaySelections.Claim.Start)
        var storage: String? = null
        val accounting = PhoneSkillOutcomes({ storage }, { storage = it; true }, "d".repeat(32))
        val key = PhoneSkillOutcomes.Key(request.name, request.revision, bundle.routeSha256)
        assertEquals(PhoneSkillOutcomes.Result.SAVED, accounting.begin(selection.invocation, key))
        val server = com.skyjjgw.independent.ski.dshgo.phone.McpServer(emptyList(), { _, _, _ -> error("unexpected") })
        var bodies = 0
        fun encode(value: Map<String, Any?>) = server.runCall(1L, "replay", emptyMap(), caller(),
            { _, _, _ -> PhoneSkillReplaySelections.output(value) })
        val work = com.skyjjgw.independent.ski.dshgo.phone.PhoneCallWork(invoke = {
            bodies++
            records.dispatched(selection)
            if (order == "failure_before") records.failedPost(selection)
            else { records.completed(selection); records.verified(selection) }
            if (order == "verified_before_freeze") now = deadline
            val terminal = records.finish(selection, order != "failure_before", deadline)
            assertEquals(expected, terminal)
            assertEquals(PhoneSkillOutcomes.Result.SAVED, accounting.settle(selection.invocation, terminal))
            // Actual disputed window: terminal/IO finished, normal reply has NOT committed yet.
            now = deadline
            encode(records.snapshot(selection))
        }, remainingMs = { (deadline - now).coerceAtLeast(0) }, expiredReply = {
            encode(records.expire(selection))
        })
        val early = if (order == "deadline_first") { now = deadline; work.expire() } else null
        val returned = work.run()
        val line = if (early != null) { assertNull(returned); early } else checkNotNull(returned)
        val envelope = com.skyjjgw.independent.ski.dshgo.phone.Json.parse(line) as Map<*, *>
        val result = envelope["result"] as Map<*, *>
        val content = (result["content"] as List<*>).single() as Map<*, *>
        val payload = com.skyjjgw.independent.ski.dshgo.phone.Json.parse(content["text"] as String) as Map<*, *>
        assertEquals(expectedState, payload["state"])
        assertEquals(expected != PhoneSkillOutcomes.Outcome.SUCCESS, result["isError"])
        assertEquals(expected, records.terminalOutcome(selection))
        assertEquals(PhoneSkillOutcomes.Result.UNCHANGED, accounting.settle(selection.invocation, expected))
        val counts = checkNotNull(accounting.counts(key))
        assertEquals(if (expected == PhoneSkillOutcomes.Outcome.SUCCESS) 1L else 0L, counts.successes)
        assertEquals(if (expected == PhoneSkillOutcomes.Outcome.FAILURE) 1L else 0L, counts.failures)
        assertEquals(expected, counts.last)
        assertTrue(records.claim(selection, caller()) is PhoneSkillReplaySelections.Claim.Existing)
        assertEquals(1, bodies) // Duplicate/query never re-enters the body.
    }
    @Test fun typedSuccessFrozenBeforeDeadlineSurvivesLateReplyWithConsistentWire() =
        terminalTail("success_before", PhoneSkillOutcomes.Outcome.SUCCESS, "succeeded")
    @Test fun deadlineWinnerCannotBePromotedByALaterTypedResult() =
        terminalTail("deadline_first", PhoneSkillOutcomes.Outcome.UNKNOWN, "unknown")
    @Test fun typedEvidenceBeforeDeadlineButFreezeAfterDeadlineIsUnknownEvenWithoutTimerDispatch() =
        terminalTail("verified_before_freeze", PhoneSkillOutcomes.Outcome.UNKNOWN, "unknown")
    @Test fun definiteFailureFrozenBeforeDeadlineSurvivesLateReplyAndCountsOnlyOnce() =
        terminalTail("failure_before", PhoneSkillOutcomes.Outcome.FAILURE, "failed")
    @Test fun frozenDebtSurvivesAnotherPendingWriteFifoAndLogicalRetirement() {
        val records = PhoneSkillReplaySelections { 1L }
        var live = true
        var sourceReads = 0
        fun selected(session: String): PhoneSkillReplaySelections.Selection {
            val value = records.prepare(client, 1, { sourceReads++; live }, request.copy(session = session), bundle, app)!!
            assertTrue(records.claim(value, caller(session = session)) is PhoneSkillReplaySelections.Claim.Start)
            return value
        }
        val a = selected("a"); val b = selected("b")
        var storage: String? = null
        var writable = true
        var commits = 0
        val outcomes = PhoneSkillOutcomes({ storage }, { commits++; if (writable) { storage = it; true } else false }, "d".repeat(32))
        val key = PhoneSkillOutcomes.Key(request.name, request.revision, bundle.routeSha256)
        assertEquals(PhoneSkillOutcomes.Result.SAVED, outcomes.begin(a.invocation, key))
        assertEquals(PhoneSkillOutcomes.Result.SAVED, outcomes.begin(b.invocation, key))
        records.verified(a)
        assertEquals(PhoneSkillOutcomes.Outcome.SUCCESS, records.finish(a, true, 10L))
        // Frozen responsibility must exist BEFORE the first accounting IO, not a later flag.
        assertTrue((records.snapshot(a)["reason"] as String).contains("计数落盘待确认"))
        writable = false
        records.retryAccounting(outcomes) // A owns the pending absolute storage snapshot.
        records.dispatched(b); records.failedPost(b)
        assertEquals(PhoneSkillOutcomes.Outcome.FAILURE, records.finish(b, false, 10L))
        records.retryAccounting(outcomes) // Retry A fails; B cannot yet enter settle.
        assertNull(outcomes.counts(key))
        repeat(64) { i ->
            assertNotNull(records.prepare(client, 1, { true }, request.copy(session = "fifo$i"), bundle, app))
        }
        assertNull(records.find(a.invocation)); assertNull(records.find(b.invocation))
        records.retire()
        live = false
        val readsBeforeRecovery = sourceReads
        writable = true
        val beforeRecovery = commits
        val work = com.skyjjgw.independent.ski.dshgo.phone.PhoneCallWork(invoke = {
            records.retryAccounting(outcomes)
            "rejected: original source remains unavailable"
        })
        assertEquals(beforeRecovery, commits) // No IO while constructing reply work.
        assertEquals("rejected: original source remains unavailable", work.run())
        assertEquals(readsBeforeRecovery, sourceReads) // No source callback, claim or action.
        val count = checkNotNull(outcomes.counts(key))
        assertEquals(1L, count.successes); assertEquals(1L, count.failures)
        assertEquals(PhoneSkillOutcomes.Outcome.FAILURE, count.last)
        val afterRecovery = commits
        records.retryAccounting(outcomes)
        assertEquals(afterRecovery, commits)
        assertEquals(count, outcomes.counts(key))
        assertSame(PhoneSkillReplaySelections.Claim.Refused, records.claim(b, caller(session = "b")))
        assertFalse((records.snapshot(b)["reason"] as String).contains("计数落盘待确认"))
    }

    @Test fun accountingReservationIsBoundedAcrossRetirementAndNoBeginSettlesWithoutCounts() {
        val records = PhoneSkillReplaySelections { 1L }
        var storage: String? = null
        val outcomes = PhoneSkillOutcomes({ storage }, { storage = it; true }, "d".repeat(32))
        repeat(64) { i ->
            val selection = records.prepare(client, 1, { true }, request.copy(session = "s$i"), bundle, app)!!
            assertTrue(records.claim(selection, caller(session = "s$i")) is PhoneSkillReplaySelections.Claim.Start)
            // Failed native admission, so Outcomes.begin was never called.
            assertEquals(PhoneSkillOutcomes.Outcome.NOT_STARTED, records.finish(selection, false, null))
            records.retire()
        }
        val blocked = records.prepare(client, 1, { true }, request, bundle, app)!!
        assertSame(PhoneSkillReplaySelections.Claim.Refused, records.claim(blocked, caller()))
        assertNull(blocked.run)
        records.retryAccounting(outcomes)
        assertNull(storage) // Absent active entries are not success/failure counters.
        assertNull(outcomes.counts(PhoneSkillOutcomes.Key(request.name, request.revision, bundle.routeSha256)))
        assertTrue(records.claim(blocked, caller()) is PhoneSkillReplaySelections.Claim.Start)
    }

    @Test fun timerFrozenDebtCannotAcknowledgeAbsentBeginBeforeOriginalPreparationReturns() {
        val records = PhoneSkillReplaySelections { 10L }
        val selection = records.prepare(client, 1, { true }, request, bundle, app)!!
        assertTrue(records.claim(selection, caller()) is PhoneSkillReplaySelections.Claim.Start)
        var storage: String? = null
        val outcomes = PhoneSkillOutcomes({ storage }, { storage = it; true }, "d".repeat(32))
        records.expire(selection)
        records.retire()
        records.retryAccounting(outcomes) // begin may still be about to run on the original body.
        assertNull(storage)
        val key = PhoneSkillOutcomes.Key(request.name, request.revision, bundle.routeSha256)
        assertEquals(PhoneSkillOutcomes.Result.SAVED, outcomes.begin(selection.invocation, key))
        assertEquals(PhoneSkillOutcomes.Outcome.UNKNOWN, records.finish(selection, false, 10L))
        records.retryAccounting(outcomes)
        val count = checkNotNull(outcomes.counts(key))
        assertEquals(PhoneSkillOutcomes.Outcome.UNKNOWN, count.last)
        assertEquals(0L, count.successes); assertEquals(0L, count.failures)
        assertEquals(PhoneSkillOutcomes.Result.INVALID, outcomes.markDispatch(selection.invocation))
    }

    @Test fun retireBeforeBodyFinallyKeepsOriginalReservationForItsFrozenOutcome() {
        val records = PhoneSkillReplaySelections { 1L }
        val selection = records.prepare(client, 1, { true }, request, bundle, app)!!
        assertTrue(records.claim(selection, caller()) is PhoneSkillReplaySelections.Claim.Start)
        var storage: String? = null
        val outcomes = PhoneSkillOutcomes({ storage }, { storage = it; true }, "d".repeat(32))
        val key = PhoneSkillOutcomes.Key(request.name, request.revision, bundle.routeSha256)
        assertEquals(PhoneSkillOutcomes.Result.SAVED, outcomes.begin(selection.invocation, key))
        records.dispatched(selection)
        records.retire()
        assertEquals(PhoneSkillOutcomes.Outcome.UNKNOWN, records.finish(selection, false, 10L))
        records.retryAccounting(outcomes)
        assertEquals(PhoneSkillOutcomes.Outcome.UNKNOWN, outcomes.counts(key)!!.last)
        assertEquals(PhoneSkillOutcomes.Result.INVALID, outcomes.markDispatch(selection.invocation))
        assertNull(records.find(selection.invocation))
    }

    @Test fun uncertainDispatchKeepsFinishResponsibleAndCannotRewriteExistingTerminal() {
        val records = PhoneSkillReplaySelections { 0L }
        val selected = records.prepare(client, 1, { true }, request, bundle, app)!!
        assertTrue(records.claim(selected, caller()) is PhoneSkillReplaySelections.Claim.Start)
        records.dispatchUncertain(selected)
        assertNull(records.terminalOutcome(selected))
        assertFalse(selected.attempted)
        records.control(selected, caller(), true)
        assertEquals(PhoneSkillOutcomes.Outcome.UNKNOWN, records.finish(selected, false, 1L))
        assertEquals("unknown", records.snapshot(selected)["stepDispatch"])
        val finished = records.prepare(client, 1, { true }, request, bundle, app)!!
        assertTrue(records.claim(finished, caller()) is PhoneSkillReplaySelections.Claim.Start)
        assertEquals(PhoneSkillOutcomes.Outcome.NOT_STARTED, records.finish(finished, false, 1L))
        records.dispatchUncertain(finished)
        assertEquals(PhoneSkillOutcomes.Outcome.NOT_STARTED, records.finish(finished, false, 1L))
    }

}
