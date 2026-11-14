package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.PhoneAppIdentity
import org.junit.Assert.*
import org.junit.Test

class BackgroundAfterVisualTest {
    @Test fun capabilityAndRequestVersionAreStrictAndCoverAllFiveActionsOnly() {
        assertTrue(BackgroundAfterVisual.supported(1))
        for (bad in listOf<Any?>(null, true, 1L, "1", 0, 2)) {
            assertFalse(BackgroundAfterVisual.supported(bad))
            assertFalse(BackgroundAfterVisual.validRequest(Proto.OP_TAP, true, bad))
        }
        for (op in listOf(Proto.OP_TAP, Proto.OP_SCROLL, Proto.OP_KEY, Proto.OP_TEXT, Proto.OP_COORDINATE)) {
            assertTrue(BackgroundAfterVisual.validRequest(op, true, 1))
            assertTrue(BackgroundAfterVisual.validRequest(op, false, null))
        }
        for (op in listOf(null, Proto.OP_OBSERVE, Proto.OP_LAUNCH, Proto.OP_PROBE, Proto.OP_RELEASE, Proto.OP_PREVIEW)) {
            assertFalse(BackgroundAfterVisual.validRequest(op, true, 1))
            assertTrue(BackgroundAfterVisual.validRequest(op, false, null))
        }
    }

    @Test fun newPostReadNonceAndFailedObservationCannotOverwriteAnAlreadyCompletedCoordinateAck() {
        val target = PhoneAppIdentity("example.app", 1010123)
        val receipt = BackgroundCoordinateImage.Receipt("consumed", 48, 48)
        val ack = mutableMapOf<String, Any?>(Proto.BACKGROUND_COORDINATES to 1,
            Proto.COORDINATE_OBSERVATION to receipt.nonce, Proto.COORDINATE_WIDTH to 48,
            Proto.COORDINATE_HEIGHT to 48, Proto.ACTION_ATTEMPTED to true, Proto.OK to true,
            Proto.TARGET_IDENTITY_VERSION to 1, Proto.TARGET_UID to target.uid,
            Proto.PKG to target.packageName, Proto.VISUAL_CHANGE to "unavailable")
        val after = mapOf<String, Any?>(Proto.OK to false, Proto.ERROR to "frameNotReady",
            Proto.BACKGROUND_COORDINATES to 1, Proto.COORDINATE_OBSERVATION to "new-post-frame",
            Proto.COORDINATE_WIDTH to 1600, Proto.COORDINATE_HEIGHT to 900,
            Proto.ACTION_ATTEMPTED to false, Proto.TARGET_IDENTITY_VERSION to 1,
            Proto.TARGET_UID to 9, Proto.PKG to "other.app", "imageBytes" to byteArrayOf(1, 2),
            "imageMime" to "image/jpeg", Proto.COORDINATE_TARGET_INDICES to intArrayOf(1),
            Proto.COUNT to 0, Proto.POOR to true)
        // The producer uses precisely this whitelist before Bundle.putAll.
        ack.putAll(after.filterKeys { it in BackgroundAfterVisual.legacyKeys })
        val result = BackgroundCoordinateImage.Result.parse(receipt, target, ack::get)
        assertNotNull(result)
        assertTrue(result!!.ok)
        assertTrue(result.attempted)
        assertEquals("consumed", ack[Proto.COORDINATE_OBSERVATION])
        assertEquals(target.packageName, ack[Proto.PKG])
        assertFalse(ack.containsKey("imageBytes"))
        assertFalse(ack.containsKey("imageMime"))
        assertFalse(ack.containsKey(Proto.ERROR))
        assertFalse(ack.containsKey(Proto.COORDINATE_TARGET_INDICES))
        assertEquals(0, ack[Proto.COUNT])
        assertEquals(true, ack[Proto.POOR])
    }
}
