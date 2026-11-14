package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.*
import org.junit.Test

class KeeperPlanTest {
    private val pkg = "example.app"
    private val cls = "$pkg.Service"
    private val me = "$pkg/$cls"
    private fun plan() = KeeperPlan(pkg, cls)

    @Test fun editingPreservesOtherComponentsAndTheirFormatting() {
        val p = plan()
        val others = "other/.First:: another/another.Second "
        assertEquals("$others:$me", p.withMe(others))
        assertEquals(others, p.withoutMe("$others:$me"))
        assertEquals("other/.First::another/.Last", p.withoutMe("other/.First:$pkg/.Service::another/.Last"))
        assertEquals("$pkg/.Service", p.withMe("$pkg/.Service"))
        assertFalse(p.listed("example.application/.Service"))
    }

    @Test fun disabledOrUnauthorizedNeverWrites() {
        val p = plan()
        assertEquals(KeeperPlan.Step.NONE, p.next(false, true, null, false, 0))
        assertEquals(KeeperPlan.Step.NONE, p.next(true, false, null, false, 0))
        assertEquals(KeeperPlan.Step.NONE, p.next(true, true, me, true, 0))
    }

    @Test fun missingAddsImmediatelyButRepeatedLossBacksOff() {
        val p = plan()
        assertEquals(KeeperPlan.Step.ADD, p.next(true, true, null, false, 0))
        assertEquals(KeeperPlan.Step.NONE, p.next(true, true, null, false, 4_999))
        assertEquals(KeeperPlan.Step.ADD, p.next(true, true, null, false, 5_000))
        assertEquals(KeeperPlan.Step.NONE, p.next(true, true, null, false, 14_999))
        assertEquals(KeeperPlan.Step.ADD, p.next(true, true, null, false, 15_000))
        assertEquals(600_000L, KeeperPlan.backoff(Int.MAX_VALUE))
    }

    @Test fun listedServiceGetsTimeToBindBeforeCycling() {
        val p = plan()
        assertEquals(KeeperPlan.Step.NONE, p.next(true, true, me, false, 0))
        assertEquals(KeeperPlan.Step.NONE, p.next(true, true, me, false, KeeperPlan.UNBOUND_MS - 1))
        assertEquals(KeeperPlan.Step.REBIND, p.next(true, true, me, false, KeeperPlan.UNBOUND_MS))
        assertEquals(KeeperPlan.Step.NONE, p.next(true, true, me, false, KeeperPlan.UNBOUND_MS + 1))
    }

    @Test fun switchingOffCancelsPendingRebindAndResetsBackoff() {
        val p = plan()
        p.next(true, true, null, false, 0)
        assertEquals(KeeperPlan.Step.NONE, p.next(false, true, me, false, 10))
        assertEquals(KeeperPlan.Step.NONE, p.next(true, true, me, false, 20))
        assertEquals(KeeperPlan.Step.ADD, p.next(true, true, null, false, 21))
    }

    @Test fun stableConnectionResetsEvenTheLongestBackoff() {
        val p = plan()
        var now = 0L
        repeat(8) {
            assertEquals(KeeperPlan.Step.ADD, p.next(true, true, null, false, now))
            now += KeeperPlan.backoff(it + 1)
        }
        p.next(true, true, me, true, now - 590_000)
        p.next(true, true, me, true, now - 520_000)
        assertEquals(KeeperPlan.Step.ADD, p.next(true, true, null, false, now - 519_999))
    }
}
