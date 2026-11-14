package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

class PhoneVisualScopesTest {
    private fun scope(owner: String = "resource", uid: Int = 10123, pkg: String = "example.app") =
        VisualScope.Background(owner, PhoneAppIdentity(pkg, uid), Any())
    @Test fun currentScopeIsRequiredAndAtoBtoADoesNotRestoreGrant() {
        val tasks = PhoneTasks(); val owner = (tasks.begin() as PhoneTasks.Begin.Go).owner
        val a = scope(); val b = scope(uid = 1010123)
        assertFalse(tasks.confirmVisualIfCurrent(owner, a))
        tasks.syncVisualScope(owner, PhoneScreen.BACKGROUND, a)
        assertTrue(tasks.confirmVisualIfCurrent(owner, a)); assertTrue(tasks.hasVisualGrant(owner, a))
        tasks.syncVisualScope(owner, PhoneScreen.BACKGROUND, b)
        assertFalse(tasks.confirmVisualIfCurrent(owner, a)) // Late A card cannot rebuild its revoked slot.
        tasks.syncVisualScope(owner, PhoneScreen.BACKGROUND, a)
        assertFalse(tasks.hasVisualGrant(owner, a))
        assertTrue(tasks.confirmVisualIfCurrent(owner, a))
        tasks.syncVisualScope(owner, PhoneScreen.BACKGROUND, null)
        assertFalse(tasks.confirmVisualIfCurrent(owner, a))
    }
    @Test fun LifecycleReplacementAndDifferentTaskNeverInherit() {
        val tasks = PhoneTasks(); val owner = (tasks.begin() as PhoneTasks.Begin.Go).owner; val a = scope()
        tasks.syncVisualScope(owner, PhoneScreen.BACKGROUND, a); tasks.confirmVisualIfCurrent(owner, a)
        tasks.cancelPending()
        assertFalse(tasks.hasVisualGrant(owner, a)); assertFalse(tasks.confirmVisualIfCurrent(owner, a))
        val replacement = checkNotNull(tasks.activeOwner())
        tasks.syncVisualScope(replacement, PhoneScreen.BACKGROUND, a)
        assertFalse(tasks.hasVisualGrant(replacement, a))
        val other = PhoneTasks(); val otherOwner = (other.begin() as PhoneTasks.Begin.Go).owner
        other.syncVisualScope(otherOwner, PhoneScreen.BACKGROUND, a)
        assertFalse(other.hasVisualGrant(otherOwner, a))
    }
    @Test fun ordinaryApprovalAndBothScreenSlotsRemainSeparate() {
        val tasks = PhoneTasks(); val owner = (tasks.begin() as PhoneTasks.Begin.Go).owner
        val bg = scope(); val main = VisualScope.Main(Any(), Any(), 7, "example.app")
        tasks.approve("example.app"); tasks.waive()
        tasks.syncVisualScope(owner, PhoneScreen.BACKGROUND, bg); tasks.syncVisualScope(owner, PhoneScreen.MAIN, main)
        assertFalse(tasks.hasVisualGrant(owner, bg)); assertFalse(tasks.hasVisualGrant(owner, main))
        tasks.confirmVisualIfCurrent(owner, bg)
        assertFalse(tasks.hasVisualGrant(owner, main))
        tasks.syncVisualScope(owner, PhoneScreen.MAIN, null)
        assertTrue(tasks.hasVisualGrant(owner, bg))
        for (different in listOf(scope(owner = "new"), scope(uid = 1010123), scope(pkg = "other.app")))
            assertFalse(tasks.hasVisualGrant(owner, different))
    }
}
