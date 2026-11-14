package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

class PhoneTaskReturnTest {
    private var now = 0L
    private var current = true
    private var visible = false
    private var accepted = true
    private var notificationAvailable = true
    private var starts = 0
    private var notices = 0
    private val queue = mutableListOf<Pair<Long, () -> Unit>>()
    private val results = mutableListOf<Map<String, Any?>>()
    private fun flow(launch: () -> Boolean = { starts++; accepted }) = PhoneTaskReturn(
        { current }, { visible }, launch, { notices++; notificationAvailable },
        { delay, block -> queue += now + delay to block }, { now })
    private fun run(closed: Boolean = true, busy: Boolean = false, reopen: Boolean = true, flow: PhoneTaskReturn = flow()) {
        flow.start(closed, busy, reopen) { results += it }
    }
    private fun advance(ms: Long) {
        val end = now + ms
        while (queue.any { it.first <= end }) {
            val next = queue.minBy { it.first }; queue.remove(next); now = next.first; next.second()
        }
        now = end
    }

    @Test fun rejectedActivityStartStillPostsResultNotification() {
        accepted = false; run()
        assertEquals(1, starts); assertEquals(1, notices)
        assertEquals(true, results.single()["closed"]); assertEquals(false, results.single()["launched"])
        assertEquals(true, results.single()["notified"]); assertEquals(false, results.single()["opened"])
    }
    @Test fun thrownActivityStartStillPostsResultNotification() {
        run(flow = flow { throw IllegalStateException("OS refused") })
        assertEquals(1, notices); assertEquals(true, results.single()["notified"])
    }
    @Test fun silentlyBlockedStartWaitsForRealResumeThenNotifies() {
        run(); advance(2999); assertEquals(0, notices); assertTrue(results.isEmpty())
        advance(1); assertEquals(1, notices); assertEquals(true, results.single()["launched"])
        assertEquals(false, results.single()["opened"])
    }
    @Test fun realResumeSuppressesFallback() {
        run(); advance(500); visible = true; advance(100)
        assertEquals(0, notices); assertEquals(true, results.single()["opened"])
    }
    @Test fun retiredBeforeLaunchKeepsClosedFactButDoesNoMoreWork() {
        current = false; run()
        assertEquals(0, starts); assertEquals(0, notices)
        assertEquals(true, results.single()["closed"]); assertEquals(false, results.single()["current"])
        assertEquals("stale", results.single()["reason"])
    }
    @Test fun replacementDuringResumeWaitCannotGetOldResultNotification() {
        run(); current = false; advance(100)
        assertEquals(0, notices); assertEquals(false, results.single()["current"])
        assertEquals(true, results.single()["closed"]); assertEquals(true, results.single()["launched"])
        advance(5000); assertEquals(1, results.size)
    }
    @Test fun retirementInsideFailedStartAlsoSuppressesNotification() {
        run(flow = flow { current = false; false })
        assertEquals(0, notices); assertEquals(false, results.single()["current"])
    }
    @Test fun disabledResultChannelIsReportedAsNotNotified() {
        accepted = false; notificationAvailable = false; run()
        assertEquals(false, results.single()["notified"]); assertEquals(true, results.single()["current"])
    }
    @Test fun busyExactTaskDoesNotCloseOrNavigate() {
        run(closed = false, busy = true)
        assertEquals(0, starts); assertEquals(0, notices); assertEquals(true, results.single()["busy"])
        assertEquals(false, results.single()["closed"]); assertEquals(true, results.single()["current"])
    }
    @Test fun noReopenRequestDoesNotCreateNotification() {
        run(reopen = false); assertEquals(0, starts); assertEquals(0, notices)
    }
    @Test fun alreadyResumedDoesNotReopenOrNotify() {
        visible = true; run(); assertEquals(0, starts); assertEquals(0, notices)
        assertEquals(true, results.single()["opened"])
    }
    @Test fun duplicatedScheduledCallbackHasNoDuplicateEffects() {
        run(); val first = queue.single().second
        visible = true; first(); first(); advance(5000)
        assertEquals(1, results.size); assertEquals(0, notices)
    }
}
