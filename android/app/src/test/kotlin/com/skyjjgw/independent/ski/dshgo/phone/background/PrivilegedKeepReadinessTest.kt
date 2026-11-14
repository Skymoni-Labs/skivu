package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class PrivilegedKeepReadinessTest {
    private fun enabled() = PrivilegedKeepState("shizuku", true, true)

    @Test fun anUnattemptedOrRetryingChannelRetainsUnknownSemantics() {
        val state = enabled()
        assertFalse(state.connectionUnavailable(false))
        val first = state.begin(0)!!
        assertFalse(state.connectionUnavailable(false))
        state.complete(first, false, "connectFailed", false, 1)
        assertTrue(state.connectionUnavailable(false))
        assertNotNull(state.begin(5_001))
        assertFalse(state.connectionUnavailable(false))
    }

    @Test fun aCompletedFailureNeedsAReplacementEvenWithoutAReasonCode() {
        for (reason in listOf("connectFailed", null)) {
            val state = enabled()
            state.complete(state.begin(0)!!, false, reason, false, 1)
            assertTrue(state.connectionUnavailable(false))
            assertFalse(state.connectionUnavailable(true))
            assertEquals("failed", state.map(true)["phase"])
        }
    }

    @Test fun losingAPublishedConnectionIsKnownUnavailability() {
        val state = enabled()
        state.complete(state.begin(0)!!, true, null, false, 1)
        assertFalse(state.connectionUnavailable(true))
        assertTrue(state.connectionUnavailable(false))
        assertEquals("waiting", state.map(false)["phase"])
        assertEquals("connectFailed", state.map(false)["reasonCode"])
        assertFalse(state.connectionUnavailable(true))
    }

    @Test fun aDisabledOrUnsavedSelectionDoesNotAddAConnectionFailure() {
        val state = enabled()
        state.complete(state.begin(0)!!, false, "connectFailed", false, 1)
        state.configure("off")
        assertFalse(state.connectionUnavailable(false))
        val attempt = state.configure("shizuku")
        assertFalse(state.saved(attempt, false))
        assertEquals("failed", state.map(false)["phase"])
        assertFalse(state.connectionUnavailable(false))
    }

    @Test fun anOldCompletionCannotPoisonTheNewSelection() {
        val state = enabled()
        val old = state.begin(0)!!
        assertTrue(state.saved(state.configure("shizuku"), true))
        state.complete(old, false, "connectFailed", false, 1)
        assertEquals("idle", state.map(false)["phase"])
        assertFalse(state.connectionUnavailable(false))
        val current = state.begin(2)!!
        state.complete(old, false, "connectFailed", false, 3)
        assertTrue(state.current(current))
        assertFalse(state.connectionUnavailable(false))
    }
}
