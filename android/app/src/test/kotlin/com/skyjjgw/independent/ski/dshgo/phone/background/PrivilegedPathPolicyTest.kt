package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class PrivilegedPathPolicyTest {
    private fun recommend(mode: String = "off", ready: Boolean = false, androidOk: Boolean = true,
                          provider: String? = null, running: Boolean = false, granted: Boolean = false,
                          rootSelected: Boolean = false, rootConnected: Boolean = false,
                          paired: Boolean = false, wireless: Boolean? = null): String =
        PrivilegedPathPolicy.recommended(mode, ready, androidOk, provider, running, granted,
            rootSelected, rootConnected, paired, wireless)

    @Test fun fiveModesAndLegacyProjectionAreExplicit() {
        assertEquals(listOf("off", "shizuku", "sui", "root", "adb"), PrivilegedPathPolicy.modes)
        assertEquals("shizuku", PrivilegedPathPolicy.legacyMode("sui"))
        assertEquals("off", PrivilegedPathPolicy.legacyMode("root"))
        assertFalse(PrivilegedPathPolicy.legacyReady("root", true))
        assertFalse(PrivilegedPathPolicy.legacyReady("off", true))
        assertTrue(PrivilegedPathPolicy.legacyReady("sui", true))
        assertEquals("off", PrivilegedPathPolicy.legacyMode("future"))
        assertFalse(PrivilegedPathPolicy.legacyReady("future", true))
    }

    @Test fun legacyShizukuChoiceReportsTheActualSuiProvider() {
        assertEquals("sui", PrivilegedPathPolicy.canonicalMode("shizuku", "sui"))
        assertEquals("shizuku", PrivilegedPathPolicy.canonicalMode("shizuku", "shizuku"))
        assertNull(PrivilegedPathPolicy.canonicalMode("su -c anything", null))
        assertEquals("root", PrivilegedPathPolicy.canonicalMode("root", "sui"))
    }

    @Test fun failedRootToolCallsKeepTheirRealReasonInTheLegacyProjection() {
        val compatibility = "use the root-capable page"
        assertEquals(compatibility, PrivilegedPathPolicy.legacyReason("root", null, compatibility))
        for (failure in listOf("root disconnected", "root timed out", "virtual display unsupported")) {
            assertEquals(failure, PrivilegedPathPolicy.legacyReason("root", failure, compatibility))
        }
        assertNull(PrivilegedPathPolicy.legacyReason("sui", null, compatibility))
        assertEquals("adb off", PrivilegedPathPolicy.legacyReason("adb", "adb off", compatibility))
    }

    @Test fun screenOffKeepsRootBecauseOnlyAnExplicitChoiceReopensIt() {
        // The Shizuku/Sui UserService rebinds and self-ADB reconnects on the next task.
        assertTrue(PrivilegedPathPolicy.closesOnInterrupt("shizuku"))
        assertTrue(PrivilegedPathPolicy.closesOnInterrupt("adb"))
        // A closed root connection stays closed (tasks never run su) until root is chosen again,
        // so closing it on every screen-off would break root 不打扰模式 after the first lock.
        val state = RootState()
        state.finish(state.begin(), null)
        state.disconnect()
        assertFalse(state.status().connected)
        assertEquals("rootDisconnected", state.status().reasonCode)
        assertFalse(PrivilegedPathPolicy.closesOnInterrupt("root"))
    }

    @Test fun legacyGrantKeepsTheActiveSuiUserService() {
        assertTrue(PrivilegedPathPolicy.sharesGrantChannel("sui", "shizuku"))
        assertTrue(PrivilegedPathPolicy.sharesGrantChannel("sui", "sui"))
        assertTrue(PrivilegedPathPolicy.sharesGrantChannel("shizuku", "sui"))
        assertTrue(PrivilegedPathPolicy.sharesGrantChannel("adb", "adb"))
        assertFalse(PrivilegedPathPolicy.sharesGrantChannel("off", "shizuku"))
        assertFalse(PrivilegedPathPolicy.sharesGrantChannel("root", "shizuku"))
        assertFalse(PrivilegedPathPolicy.sharesGrantChannel("sui", "adb"))
        assertFalse(PrivilegedPathPolicy.sharesGrantChannel("future", "future"))
    }

    @Test fun unknownOrDisconnectedRootIsNeverAnAutomaticRecommendation() {
        assertEquals("off", recommend())
        assertEquals("off", recommend(rootSelected = true))
        assertEquals("off", recommend(rootConnected = true))
        assertEquals("root", recommend(rootSelected = true, rootConnected = true))
    }

    @Test fun keepReadySelectionThenPreferAnAuthorizedSharedInterface() {
        assertEquals("adb", recommend("adb", true, provider = "sui", running = true, granted = true))
        assertEquals("sui", recommend(provider = "sui", running = true, granted = true,
            rootSelected = true, rootConnected = true, paired = true))
        assertEquals("shizuku", recommend(provider = "shizuku", running = true, granted = true))
    }

    @Test fun pairedAdbPrecedesANewPermissionPromptUnlessWirelessDebuggingIsOff() {
        assertEquals("adb", recommend(provider = "sui", running = true, paired = true))
        assertEquals("sui", recommend(provider = "sui", running = true, paired = true, wireless = false))
        assertEquals("off", recommend(paired = true, wireless = false))
    }

    @Test fun unsupportedAndroidDoesNotRecommendAVirtualDisplay() {
        assertEquals("off", recommend("root", true, androidOk = false,
            rootSelected = true, rootConnected = true))
    }

    @Test fun newGrantPathsPreserveLegacyPathsAndTheExplicitRootChoice() {
        val sui = ShizukuStatus.fromFacts(false, true, true, true)
        val adb = AdbStatus(true, true, true)
        assertEquals("shizuku", SecureSettingsGrant.path(false, sui, adb))
        assertEquals("sui", SecureSettingsGrant.privilegedPath(false, sui, adb, false, false))
        assertEquals("root", SecureSettingsGrant.privilegedPath(false, sui, adb, true, true))
        assertEquals("setup", SecureSettingsGrant.privilegedPath(false, sui, adb, true, false))
        assertEquals("granted", SecureSettingsGrant.privilegedPath(true, sui, adb, true, false))
        assertEquals("suiPermission", SecureSettingsGrant.privilegedPath(false, sui.copy(granted = false),
            adb.copy(paired = false), false, false))
    }
}
