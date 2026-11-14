package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class PrivilegedKeepStateTest {
    @Test fun taskSelectionTicketDoesNotRequireKeepConsent() {
        val s = PrivilegedKeepState("off", true, true)
        s.select("sui")
        val selected = s.selectionTicket()
        assertEquals("sui", selected.mode)
        assertFalse(s.enabled)
        assertTrue(s.selectionCurrent(selected))
        assertFalse(s.current(selected))
    }

    @Test fun returningToTheSameModeDoesNotReviveAnOldTaskSelection() {
        val s = enabled("sui")
        val old = s.selectionTicket()
        s.select("adb")
        assertFalse(s.selectionCurrent(old))
        s.select("sui")
        assertFalse(s.selectionCurrent(old))
        assertTrue(s.selectionCurrent(s.selectionTicket()))
    }

    @Test fun keepChangeRevokesOldTasksButNewTasksStillHaveTheSelectedMode() {
        val s = enabled("root")
        val old = s.selectionTicket()
        val off = s.configure("off")
        assertFalse(s.selectionCurrent(old))
        val fresh = s.selectionTicket()
        assertEquals("root", fresh.mode)
        assertTrue(s.selectionCurrent(fresh))
        assertTrue(s.saved(off, true))
        assertTrue(s.selectionCurrent(fresh))
        assertFalse(s.enabled)
    }

    @Test fun sameEnabledModePreservesSelectionButOffIntentAlwaysRevokesIt() {
        val s = enabled("sui")
        val old = s.selectionTicket()
        s.select("sui")
        assertTrue(s.selectionCurrent(old))
        s.select("off")
        val off = s.selectionTicket()
        s.select("off")
        assertFalse(s.selectionCurrent(off))
    }

    private fun enabled(mode: String = "root") = PrivilegedKeepState(mode, true, true)
    @Test fun onlyAnExplicitValidSavedModeRestoresSelection() {
        assertEquals("off", PrivilegedKeepState("off", true, true).mode)
        assertEquals("off", PrivilegedKeepState("unknown", true, true).mode)
        assertEquals("off", PrivilegedKeepState("root", false, true).mode)
        assertEquals("off", PrivilegedKeepState("root", true, false).mode)
        assertEquals("root", enabled().mode)
        assertTrue(enabled().enabled)
        assertEquals("idle", enabled().map(false)["phase"])
    }
    @Test fun noRestoringUntilExplicitConsentWasSaved() {
        val s = PrivilegedKeepState("off", true, true)
        s.select("root")
        assertNull(s.begin(0))
        val change = s.configure("root")
        assertNull(s.begin(0))
        assertTrue(s.saved(change, true))
        assertNotNull(s.begin(0))
    }
    @Test fun switchingProvidersNeverCarriesRootConsent() {
        val s = enabled("sui")
        val old = s.begin(0)!!
        s.select("root")
        assertEquals("off", s.keptMode)
        assertFalse(s.current(old))
        assertNull(s.begin(10_000))
    }
    @Test fun disableRevokesBeforeDiskSaveAndOldSuccessCannotPublish() {
        val s = enabled(); val old = s.begin(0)!!
        val off = s.configure("off")
        assertFalse(s.current(old))
        s.complete(old, true, null, false, 0)
        assertEquals("disabled", s.map(true)["phase"])
        assertTrue(s.saved(off, true)); assertFalse(s.enabled)
    }
    @Test fun obsoleteSaveDoesNotReauthorizeAfterNewOffIntent() {
        val s = enabled()
        val first = s.configure("root")
        val off = s.configure("off")
        assertFalse(s.saving(first)); assertFalse(s.saved(first, true))
        assertTrue(s.saved(off, true)); assertFalse(s.enabled)
    }
    @Test fun persistenceFailureNeverAuthorizesRestore() {
        val s = enabled()
        val change = s.configure("root")
        assertFalse(s.saved(change, false)); assertFalse(s.enabled)
        assertNull(s.begin(0))
        assertEquals("persistenceFailed", s.map(false)["reasonCode"])
    }
    @Test fun unresolvedOldAttemptOccupiesOnlySlotAcrossSelectionChanges() {
        val s = enabled()
        val old = s.begin(0)!!
        s.saved(s.configure("root"), true)
        assertNull(s.begin(0))
        s.complete(old, false, "rootCancelled", false, 0)
        val fresh = s.begin(0)!!
        s.complete(old, true, null, false, 0)
        assertEquals("restoring", s.map(false)["phase"])
        assertTrue(s.current(fresh))
    }
    @Test fun failuresWaitForRealEventAndMinimumInterval() {
        val s = enabled()
        s.complete(s.begin(0)!!, false, "rootTimeout", false, 1)
        assertNull(s.begin(5000)); assertNotNull(s.begin(5001))
    }
    @Test fun wirelessSettingAttemptIsNotRenewedByTaskOrNetworkEvents() {
        val s = enabled("adb")
        val t = s.begin(0)!!
        assertTrue(s.takeWirelessAttempt(t)); assertFalse(s.takeWirelessAttempt(t))
        s.complete(t, false, "connectFailed", false, 0)
        assertFalse(s.takeWirelessAttempt(s.begin(5000)!!))
    }
    @Test fun missingFactsDoNotThrottleTheNextRealAvailabilityEvent() {
        val s = enabled("shizuku")
        s.complete(s.begin(0)!!, false, "serviceUnavailable", true, 1)
        assertNotNull(s.begin(2))
    }
    @Test fun liveTransportDoesNotTurnDisabledKeepIntoPermission() {
        val s = PrivilegedKeepState("off", true, true)
        assertEquals(false, s.map(true)["enabled"])
        assertEquals("disabled", s.map(true)["phase"])
    }
    @Test fun lostReadyBecomesWaitingWithoutNewAttemptOrPermission() {
        val s = enabled()
        s.complete(s.begin(0)!!, true, null, false, 0)
        assertEquals("connected", s.map(true)["phase"])
        assertEquals("waiting", s.map(false)["phase"])
        assertEquals("connectFailed", s.map(false)["reasonCode"])
    }
}
