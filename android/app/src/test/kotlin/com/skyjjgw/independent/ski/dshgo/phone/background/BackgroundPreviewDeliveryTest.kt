package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundPreviewDeliveryTest {
    private fun seq(value: Map<String, Any?>) = value.getValue("sequence") as Long

    @Test fun failedTransportClearsAFrameAndTheSameCoreSequenceCanRecover() {
        val state = BackgroundPreviewDelivery(); state.reset(7)
        val first = state.accept("frame", 81, 2, 1, byteArrayOf(1))!!
        val error = state.failure()!!
        assertTrue(seq(error) > seq(first))
        assertNull(error["imageBytes"])
        assertEquals(-1L, state.afterSequence)
        val recovered = state.accept("frame", 81, 2, 1, byteArrayOf(1))!!
        assertTrue(seq(recovered) > seq(error))
        assertNotNull(recovered["imageBytes"])
        assertEquals(81L, state.afterSequence)
    }

    @Test fun busyCannotAcknowledgeAnUndeliveredFrame() {
        val state = BackgroundPreviewDelivery(); state.reset(7)
        assertNull(state.accept("busy", 99, 0, 0, null))
        assertEquals(-1L, state.afterSequence)
        assertNotNull(state.accept("frame", 99, 1, 1, byteArrayOf(1)))
        assertNull(state.accept("frame", 99, 0, 0, null))
        assertNull(state.accept("frame", 99, 1, 1, byteArrayOf(1)))
    }

    @Test fun blackOrSecureStateIsANewerClearEventNotAnOldNegativeSequence() {
        val state = BackgroundPreviewDelivery(); state.reset(7)
        val frame = state.accept("frame", 40, 1, 1, byteArrayOf(1))!!
        val black = state.accept("unavailable", 41, 0, 0, null)!!
        val secure = state.accept("protected", 42, 0, 0, null)!!
        assertTrue(seq(black) > seq(frame))
        assertTrue(seq(secure) > seq(black))
        assertNull(black["imageBytes"]); assertNull(secure["imageBytes"])
        assertNull(state.accept("protected", 42, 0, 0, null))
    }

    @Test fun taskSwitchClearsPixelsAndGivesOldConsumerAnOffEvent() {
        val state = BackgroundPreviewDelivery(); state.reset(7)
        val old = state.accept("frame", 999, 1, 1, byteArrayOf(1))!!
        val generation = state.generation
        state.reset(8)
        assertTrue(state.generation > generation)
        val stopped = state.initial(7)
        assertEquals("off", stopped["state"])
        assertNull(stopped["imageBytes"])
        assertTrue(seq(stopped) > seq(old))
        assertEquals("waiting", state.initial(8)["state"])
        assertEquals(-1L, state.afterSequence)
        assertNotNull(state.accept("frame", 0, 1, 1, byteArrayOf(2)))
    }

    @Test fun repeatedErrorsDoNotPublishAndNewConsumerReceivesCachedPixels() {
        val state = BackgroundPreviewDelivery(); state.reset(7)
        assertNotNull(state.failure()); assertNull(state.failure())
        val bytes = byteArrayOf(1)
        val frame = state.accept("frame", 1, 1, 1, bytes)!!
        assertSame(frame, state.initial(7))
        state.reset(null)
        assertNull(state.initial(7)["imageBytes"])
        assertEquals("off", state.initial(7)["state"])
    }

    @Test fun losingConsumerClearsWithoutReplacingTheWinnersCacheOrAcknowledgement() {
        val state = BackgroundPreviewDelivery(); state.reset(7)
        val frame = state.accept("frame", 40, 2, 1, byteArrayOf(1))!!
        val occupied = state.placeholder(8, true)
        assertEquals(8L, occupied["taskId"])
        assertEquals("inUse", occupied["state"])
        assertNull(occupied["imageBytes"])
        assertEquals(0, occupied["width"]); assertEquals(0, occupied["height"])
        assertTrue(seq(occupied) > seq(frame))
        assertEquals(40L, state.afterSequence)
        assertSame(frame, state.initial(7))
        val ended = state.placeholder(8, false)
        assertEquals("off", ended["state"])
        assertTrue(seq(ended) > seq(occupied))
        assertSame(frame, state.initial(7))
    }

    @Test fun selectedTasksWithoutReadyTargetsStillHaveDifferentGenerations() {
        val state = BackgroundPreviewDelivery(); state.reset(7)
        val first = state.initial(7)
        state.reset(8)
        val second = state.initial(8)
        assertEquals("waiting", first["state"]); assertEquals("waiting", second["state"])
        assertTrue((second["generation"] as Long) > (first["generation"] as Long))
        assertNull(second["imageBytes"])
        assertEquals(-1L, state.afterSequence)
    }

}
