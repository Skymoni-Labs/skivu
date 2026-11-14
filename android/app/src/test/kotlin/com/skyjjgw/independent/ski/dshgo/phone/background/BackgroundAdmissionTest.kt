package com.skyjjgw.independent.ski.dshgo.phone.background

import android.os.Bundle
import com.skyjjgw.independent.ski.dshgo.phone.PhoneTasks
import org.junit.Assert.*
import org.junit.Test

/** The whole 不打扰模式 admission model: mode, Android version, a connected channel, real occupancy. */
class BackgroundAdmissionTest {
    private fun capacity(mode: String = "shizuku", androidOk: Boolean = true, busy: Boolean = false,
                         peerLimit: Int = 3, configured: Int = 3) =
        BackgroundPolicy.capacity(mode, androidOk, busy, peerLimit, configured)

    @Test fun aConnectedChannelIsReadyAndHasSlotsWhateverItsHandshakeOmitted() {
        // A PROBE with only ok=true: no owner-scope, release-receipt, recovery or self-check fields.
        assertEquals(1, backgroundRequestLimit(true, multiplexed = false))
        assertEquals(3, backgroundRequestLimit(true, multiplexed = true))
        for (mode in listOf("shizuku", "sui", "root", "adb")) {
            assertNull(mode, BackgroundPolicy.unready(mode, androidOk = true, switching = false, channelReason = null))
            assertEquals(BackgroundPolicy.Capacity(3, null), capacity(mode))
        }
        assertEquals(BackgroundPolicy.Capacity(1, "transportSerial"), capacity(peerLimit = 1))
        assertEquals(BackgroundPolicy.Capacity(2, null), capacity(peerLimit = 3, configured = 2))
    }

    @Test fun selfCheckFailuresAndUnconfirmedReleasesAreNotAdmissionInputs() {
        // The gate's facts after a failed self-check, and its last no-response failure, exist only as
        // diagnostics: neither readiness nor capacity takes them, so a connected channel keeps its slots.
        val gate = BackgroundGateState()
        val probe = checkNotNull(gate.begin { true })
        gate.update(probe, ok = false, error = null, injectOk = false, injectError = "systemOperationDenied", detail = null)
        assertEquals(false, gate.snapshot.injectOk)
        assertNull(BackgroundPolicy.unready("shizuku", androidOk = true, switching = false, channelReason = null))
        assertEquals(3, capacity(peerLimit = backgroundRequestLimit(true, multiplexed = true)).effective)
    }

    @Test fun anUnconfirmedReleaseLeavesNoSlotBehind() {
        val peer = object : PrivilegedChannel {
            override val backgroundLimit = 1
            // A RELEASE reply without the owner envelope: the screen's release is not confirmed.
            override fun execute(request: Bundle, beforeSend: () -> Unit): Bundle =
                Bundle().apply { beforeSend(); putBoolean(Proto.OK, false); putString(Proto.ERROR, "releasePending") }
            override fun alive() = true
            override fun close() {}
        }
        val display = BackgroundDisplay(channelProvider = { peer }, mayUse = { true }, admitUse = { action -> action(); true })
        @Suppress("UNCHECKED_CAST")
        val io = BackgroundDisplay::class.java.getDeclaredField("resourceIo")
            .apply { isAccessible = true }.get(display) as BackgroundDisplayIo<PrivilegedChannel>
        io.call { io.startResource(peer, { commit -> commit() }) { true } } // The opened screen's pin.
        assertFalse(display.release()) // BackgroundControl.endTask then discards this peer ...
        val tasks = PhoneTasks(clock = { 100L }, idSource = { 1L })
        val owner = (tasks.begin() as PhoneTasks.Begin.Go).owner
        val slot = BackgroundTaskSlot<BackgroundDisplay, PrivilegedChannel>(Any())
        val record = checkNotNull(slot.acquire(owner, peer, 1, { true }) { display })
        slot.seal(owner.taskId)
        assertTrue(slot.complete(record)) // ... and completes the record anyway.
        assertFalse(slot.occupied)
        assertNull(slot.boundPeer)
    }

    @Test fun offOldAndroidUnconnectedOrSwitchingIsNotReady() {
        assertEquals(BackgroundPolicy.Unready.OFF, BackgroundPolicy.unready("off", true, false, null))
        assertEquals(BackgroundPolicy.Unready.ANDROID, BackgroundPolicy.unready("adb", false, false, null))
        assertEquals(BackgroundPolicy.Unready.SWITCHING, BackgroundPolicy.unready("root", true, true, null))
        assertEquals(BackgroundPolicy.Unready.CHANNEL, BackgroundPolicy.unready("shizuku", true, false, "not authorized"))
        assertEquals(BackgroundPolicy.Unready.UNKNOWN_MODE, BackgroundPolicy.unready("gate", true, false, null))

        assertEquals(BackgroundPolicy.Capacity(0, "off"), capacity(mode = "off"))
        assertEquals(BackgroundPolicy.Capacity(0, "unsupported"), capacity(androidOk = false))
        assertEquals(BackgroundPolicy.Capacity(0, "busy"), capacity(busy = true))
        assertEquals(BackgroundPolicy.Capacity(0, "connectionRequired"), capacity(peerLimit = 0))
        // A rejected or closed PROBE carries nothing.
        assertEquals(0, backgroundRequestLimit(false, multiplexed = true))
        assertEquals(0, backgroundRequestLimit(null, multiplexed = false))
    }
}
