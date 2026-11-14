package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

/** The actual production classifier receives structured PM adapter facts; this is not a PM emulator. */
class SystemHandlersTest {
    private val browser = SystemHandler("browser.app", "browser.app.Link", 10123)

    @Test fun defaultComponentStateUsesManifestFlag() {
        assertTrue(SystemHandlers.componentEnabled(true) { 0 })
        assertFalse(SystemHandlers.componentEnabled(false) { 0 })
    }

    @Test fun runtimeEnabledOverridesDisabledAliasManifest() {
        assertTrue(SystemHandlers.componentEnabled(false) { 1 })
        assertTrue(SystemHandlers.componentEnabled(true) { 1 })
    }

    @Test fun everyExplicitDisabledStateOverridesManifest() {
        // PackageManager: DISABLED, DISABLED_USER, DISABLED_UNTIL_USED.
        for (state in listOf(2, 3, 4)) {
            for (manifestEnabled in listOf(false, true)) {
                assertFalse("state=$state manifest=$manifestEnabled",
                    SystemHandlers.componentEnabled(manifestEnabled) { state })
            }
        }
    }

    @Test fun unknownComponentStateFailsClosed() {
        for (state in listOf(-1, 5, Int.MIN_VALUE, Int.MAX_VALUE)) {
            for (manifestEnabled in listOf(false, true)) {
                assertFalse("state=$state manifest=$manifestEnabled",
                    SystemHandlers.componentEnabled(manifestEnabled) { state })
            }
        }
    }

    @Test fun componentStateReadFailureDoesNotFallBackToManifest() {
        for (failure in listOf(SecurityException(), IllegalArgumentException(), IllegalStateException())) {
            for (manifestEnabled in listOf(false, true)) {
                assertFalse(SystemHandlers.componentEnabled(manifestEnabled) { throw failure })
            }
        }
    }

    @Test fun componentStateIsReadAgainForFinalRecheck() {
        var state = 1
        var reads = 0
        val readSetting = { reads++; state }
        assertTrue(SystemHandlers.componentEnabled(false, readSetting))
        state = 2
        assertFalse(SystemHandlers.componentEnabled(true, readSetting))
        assertEquals(2, reads)
    }

    @Test fun exactCandidateIsKnownIncludingNonAndroidOemPackages() {
        val oem = SystemHandler("vendor.settings", "vendor.settings.Wifi", 1000)
        assertEquals(SystemResolution.Known(oem), SystemHandlers.resolve(listOf(oem), oem, null, true))
        assertEquals(SystemResolution.Known(browser), SystemHandlers.resolve(listOf(browser), browser, null, true))
    }

    @Test fun outsideResolverRequiresActualChooserAndCannotServeExplicitAppOpen() {
        val outside = SystemHandler("vendor.selection", "vendor.selection.Pick", 1000)
        assertEquals(SystemResolution.Choice, SystemHandlers.resolve(listOf(browser), outside, null, true))
        assertNull(SystemHandlers.resolve(listOf(browser), outside, null, false))
    }

    @Test fun noResolverOrNoCandidatesIsNotUserChoice() {
        assertNull(SystemHandlers.resolve(listOf(browser), null, null, true))
        assertNull(SystemHandlers.resolve(emptyList(), browser, null, true))
        assertFalse(SystemHandlers.valid(emptyList(), null)) // Explicit chooser still needs candidates.
    }

    @Test fun invalidIdentityAndConflictingUidNeverTurnIntoChooser() {
        for (invalid in listOf(browser.copy(uid = -1), browser.copy(packageName = ""), browser.copy(component = ""))) {
            assertNull(SystemHandlers.resolve(listOf(invalid), invalid, null, true))
            assertNull(SystemHandlers.resolve(listOf(browser), invalid, null, true))
        }
        assertNull(SystemHandlers.resolve(listOf(browser), browser.copy(uid = 20123), null, true))
        assertNull(SystemHandlers.resolve(listOf(browser, browser.copy(uid = 20123)), browser, null, true))
    }

    @Test fun sharedUidDoesNotMergeDifferentPackagesAndPackageConstraintIsPreserved() {
        val other = browser.copy(packageName = "other.app", component = "other.app.Link")
        assertEquals(SystemResolution.Choice, SystemHandlers.resolve(listOf(browser), other, null, true))
        assertNull(SystemHandlers.resolve(listOf(browser), browser, "other.app", true))
        assertFalse(SystemHandlers.valid(listOf(browser, other), "browser.app"))
    }

}
