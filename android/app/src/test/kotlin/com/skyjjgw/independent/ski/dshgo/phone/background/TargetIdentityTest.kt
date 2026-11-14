package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.PhoneAppIdentity
import org.junit.Assert.*
import org.junit.Test

/** The actual Core owner binding and actual native receipt checks; no Android framework stubs. */
class TargetIdentityTest {
    private val a = PhoneAppIdentity("example.app", 10123)
    private val otherUser = PhoneAppIdentity("example.app", 1010123)
    private val sharedUid = PhoneAppIdentity("example.shared", 10123)
    private fun request(state: TargetIdentity, target: PhoneAppIdentity, opening: Boolean = false) =
        state.request(target.packageName, true, 1, true, target.uid, opening)
    private fun opened(target: PhoneAppIdentity = a) = TargetIdentity().also { request(it, target, true); it.opened(target) }
    private fun fails(code: String, body: () -> Unit) {
        assertEquals(code, assertThrows(TargetIdentity.Failure::class.java) { body() }.code)
    }

    @Test fun capabilityRequiresTheExactIntegerVersion() {
        assertTrue(TargetIdentity.supported(1))
        for (value in listOf(null, 0, 2, 1L, 1.0, "1", true)) assertFalse(TargetIdentity.supported(value))
    }

    @Test fun aPresentMalformedIdentityNeverFallsBackToLegacy() {
        for ((version, uid) in listOf(null to 10123, 1 to null, "1" to 10123, 1L to 10123,
                1 to -1, 1 to 10123L, 1 to "10123")) {
            fails("targetIdentityUnavailable") { TargetIdentity().request(a.packageName, true, version, true, uid, true) }
        }
        fails("targetIdentityUnavailable") { TargetIdentity().request(a.packageName, false, null, true, 10123, true) }
        fails("targetIdentityUnavailable") { TargetIdentity().request(a.packageName, true, 1, false, null, true) }
    }

    @Test fun oldCallersStayLegacyButNeitherModeCanChangeWithinAnOwner() {
        val old = TargetIdentity()
        assertNull(old.request(a.packageName, false, null, false, null, true))
        assertNull(old.request(sharedUid.packageName, false, null, false, null, false))
        fails("targetIdentityChanged") { request(old, a, true) }
        val modern = opened()
        fails("targetIdentityChanged") { modern.request(a.packageName, false, null, false, null, false) }
        fails("targetIdentityChanged") { modern.request(a.packageName, false, null, false, null, true) }
    }

    @Test fun unconfirmedReplacementCannotBorrowOldObservationOrChangeTargetThroughAnAction() {
        val state = opened()
        assertEquals(a, request(state, a))
        fails("targetIdentityChanged") { request(state, otherUser) }
        assertEquals(sharedUid, request(state, sharedUid, true))
        assertNull(state.current)
        fails("targetIdentityUnavailable") { request(state, a) }
        fails("targetIdentityUnavailable") { request(state, sharedUid) }
        state.opened(sharedUid)
        assertEquals(sharedUid, request(state, sharedUid))
        fails("targetIdentityChanged") { request(state, a) }
    }

    @Test fun identityLossKeepsTheModeUntilActualResourceRelease() {
        val state = opened()
        state.invalidate()
        fails("targetIdentityUnavailable") { request(state, a) }
        fails("targetIdentityChanged") { state.request(a.packageName, false, null, false, null, true) }
        state.clear() // Called by Core only after its release path has completed.
        assertNull(state.request(a.packageName, false, null, false, null, true))
    }

    @Test fun actualTaskNeedsPackageUidAndUserTogetherIncludingSharedUid() {
        assertTrue(TargetIdentity.matchesTask(a, a.packageName, a.uid, 0, 0))
        assertTrue(TargetIdentity.matchesTask(otherUser, otherUser.packageName, otherUser.uid, 10, 10))
        assertFalse(TargetIdentity.matchesTask(a, sharedUid.packageName, sharedUid.uid, 0, 0))
        assertFalse(TargetIdentity.matchesTask(a, a.packageName, otherUser.uid, 10, 0))
        assertFalse(TargetIdentity.matchesTask(a, a.packageName, a.uid, 10, 0))
        assertFalse(TargetIdentity.matchesTask(a, a.packageName, null, 0, 0))
        assertFalse(TargetIdentity.matchesTask(a, a.packageName, a.uid, null, 0))
    }

    @Test fun nativeSnapshotReceiptRequiresActualTypedMatchingIdentity() {
        assertTrue(TargetIdentity.receipt(a, 1, a.packageName, a.uid))
        assertFalse(TargetIdentity.receipt(a, 1L, a.packageName, a.uid))
        assertFalse(TargetIdentity.receipt(a, 1, a.packageName, a.uid.toLong()))
        assertFalse(TargetIdentity.receipt(a, 1, sharedUid.packageName, sharedUid.uid))
        assertFalse(TargetIdentity.receipt(a, 1, otherUser.packageName, otherUser.uid))
        assertFalse(TargetIdentity.receipt(a, null, null, null))
    }
    @Test fun backgroundOpenConfirmationRequiresEveryTypedFactFromThisReply() {
        fun accepts(ok: Any? = true, evidence: Any? = 1, display: Any? = 7,
                    version: Any? = 1, pkg: Any? = a.packageName, uid: Any? = a.uid) =
            TargetIdentity.backgroundOpenConfirmed(a, ok, evidence, display, version, pkg, uid)
        assertTrue(accepts())
        for (bad in listOf(null, false, 1, "true")) assertFalse(accepts(ok = bad))
        for (bad in listOf(null, 0, 2, 1L, "1", true)) assertFalse(accepts(evidence = bad))
        for (bad in listOf(null, 0, -1, 7L, "7", true)) assertFalse(accepts(display = bad))
        for (bad in listOf(null, 0, 2, 1L, "1")) assertFalse(accepts(version = bad))
        for (bad in listOf(null, "other.app", 1)) assertFalse(accepts(pkg = bad))
        for (bad in listOf(null, otherUser.uid, a.uid.toLong(), "10123")) assertFalse(accepts(uid = bad))
    }
}
