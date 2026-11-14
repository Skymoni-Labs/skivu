package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class ShizukuStatusTest {
    @Test fun appOnlyUsesTheShizukuProvider() {
        val status = ShizukuStatus.fromFacts(true, false, true, true)
        assertEquals(ShizukuStatus.SHIZUKU, status.provider)
        assertTrue(status.appInstalled)
        assertTrue(status.installed && status.running && status.granted)
    }

    @Test fun suiDoesNotRequireTheShizukuApk() {
        val status = ShizukuStatus.fromFacts(false, true, true, true)
        assertEquals(ShizukuStatus.SUI, status.provider)
        assertFalse(status.appInstalled)
        assertTrue(status.installed && status.running && status.granted)
    }

    @Test fun suiOwnsTheSharedBinderWhenBothArePresent() {
        val status = ShizukuStatus.fromFacts(true, true, true, false)
        assertEquals(ShizukuStatus.SUI, status.provider)
        assertTrue(status.installed && status.appInstalled && status.running)
        assertFalse(status.granted)
    }

    @Test fun neitherProviderReportsMissing() {
        val status = ShizukuStatus.fromFacts(false, false, false, false)
        assertNull(status.provider)
        assertFalse(status.installed || status.running || status.granted)
    }

    @Test fun aLiveInterfaceWithoutPermissionIsAvailableButNotGranted() {
        for (sui in listOf(false, true)) {
            val status = ShizukuStatus.fromFacts(!sui, sui, true, false)
            assertTrue(status.installed && status.running)
            assertFalse(status.granted)
        }
    }

    @Test fun packageVisibilityCannotHideALiveInterface() {
        val status = ShizukuStatus.fromFacts(false, false, true, true)
        assertFalse(status.appInstalled)
        assertTrue(status.installed && status.running && status.granted)
        assertEquals(ShizukuStatus.SHIZUKU, status.provider)
    }

    @Test fun rememberedSuiOriginIsNotProofOfALiveAuthorizedBinder() {
        val status = ShizukuStatus.fromFacts(false, true, false, true)
        assertEquals(ShizukuStatus.SUI, status.provider)
        assertTrue(status.installed)
        assertFalse(status.running || status.granted)
    }

    @Test fun anInstalledButStoppedAppDoesNotBecomeReady() {
        val status = ShizukuStatus.fromFacts(true, false, false, true)
        assertTrue(status.installed)
        assertFalse(status.running || status.granted)
        assertEquals(ShizukuStatus.SHIZUKU, status.provider)
    }

    @Test fun legacyStatusFieldsAndConstructorStayCompatible() {
        val map = ShizukuStatus(true, true, false).map()
        assertEquals(true, map["installed"])
        assertEquals(true, map["running"])
        assertEquals(false, map["granted"])
        assertEquals(true, map["appInstalled"])
        assertNull(map["provider"])
    }
}
