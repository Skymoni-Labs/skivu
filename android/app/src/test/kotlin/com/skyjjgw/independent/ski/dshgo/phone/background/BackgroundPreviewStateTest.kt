package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

/** Production preview ownership and rate policy; does not simulate Android Images or Binder. */
class BackgroundPreviewStateTest {
    private fun raw(value: Byte) = BackgroundPreviewState.RawFrame(1, 1, byteArrayOf(value, 0, 0, -1))

    private fun frame(vararg pixels: Int) = BackgroundPreviewState.Frame(
        pixels.size, 1, pixels, byteArrayOf(1, 2, 3))

    @Test fun rawAgentCandidateIsTransferredWithoutAJpegRoundTripOrExtraCopy() {
        val state = BackgroundPreviewState(); state.configure(true)
        val pixels = byteArrayOf(20, 43, 68, -1, 21, 44, 69, -1)
        val raw = BackgroundPreviewState.RawFrame(2, 1, pixels)
        state.captured(raw)
        val ticket = state.begin(0)!!
        assertSame(raw, ticket.candidate)
        assertSame(pixels, ticket.candidate!!.pixels)
        assertEquals(2, ticket.candidate!!.width)
        state.consumed(ticket); state.finish(ticket)
        assertNull(state.begin(200)!!.candidate)
        state.configure(false)
        assertFalse(state.acceptsCandidate())
    }

    @Test fun defaultOffDoesNotStartWorkOrRetainAgentCandidates() {
        val state = BackgroundPreviewState()
        state.captured(raw(7))
        assertNull(state.begin(0))
        assertEquals("off", state.snapshot().state)
        state.configure(true)
        assertNull(state.begin(0)!!.candidate)
    }

    @Test fun closingInvalidatesLateEncodeAndClearsTheImage() {
        val state = BackgroundPreviewState(); state.configure(true)
        val first = state.begin(0)!!
        state.publish(first, frame(1), 0); state.finish(first)
        val next = state.begin(200)!!
        state.configure(false)
        state.publish(next, frame(2), 200)
        assertEquals("off", state.snapshot().state)
        assertNull(state.snapshot().frame)
        assertFalse(state.current(next))
        state.finish(next)
        assertNull(state.begin(400))
    }

    @Test fun replacementReaderInvalidatesOldTicketButKeepsItsPhysicalSlot() {
        val state = BackgroundPreviewState(); state.configure(true)
        val old = state.begin(0)!!
        state.invalidate()
        assertNull(state.begin(200))
        state.publish(old, frame(3), 200)
        assertEquals("waiting", state.snapshot().state)
        state.finish(old)
        val current = state.begin(200)!!
        assertTrue(current.readerEpoch > old.readerEpoch)
        state.publish(current, frame(4), 200)
        assertEquals(4, state.snapshot().frame!!.pixels.single())
    }

    @Test fun repeatedAgentCapturesOnTheSameDisplayKeepTheFrameAndExactDeduplicationBaseline() {
        val state = BackgroundPreviewState(); state.configure(true)
        val initial = state.begin(0)!!
        state.publish(initial, frame(1, 2, 3), 0); state.finish(initial)
        val displayed = state.snapshot()
        for (time in listOf(200L, 400L, 600L)) {
            state.readerChanged()
            assertSame(displayed, state.snapshot()) // No intermediate waiting flash.
            state.captured(raw(9))
            val next = state.begin(time)!!
            assertFalse(state.changed(next, intArrayOf(1, 2, 3), 3, 1))
            state.consumed(next); state.finish(next)
            assertSame(displayed, state.snapshot())
        }
        state.readerChanged()
        val changed = state.begin(800)!!
        assertTrue(state.changed(changed, intArrayOf(1, 2, 4), 3, 1))
        state.publish(changed, frame(1, 2, 4), 800)
        assertTrue(state.snapshot().sequence > displayed.sequence)
    }

    @Test fun readerReplacementRetiresOldWorkerWithoutClearingTheDisplay() {
        val state = BackgroundPreviewState(); state.configure(true)
        val initial = state.begin(0)!!
        state.publish(initial, frame(1), 0); state.finish(initial)
        val displayed = state.snapshot()
        val old = state.begin(200)!!
        state.readerChanged()
        state.publish(old, frame(2), 200)
        assertSame(displayed, state.snapshot())
        assertNull(state.begin(400))
        state.finish(old)
        assertTrue(state.begin(400)!!.readerEpoch > old.readerEpoch)
    }

    @Test fun unusableAgentObservationClearsOldImageAndTheSameImageCanRestoreIt() {
        val state = BackgroundPreviewState(); state.configure(true)
        val initial = state.begin(0)!!
        state.publish(initial, frame(1), 0); state.finish(initial)
        state.readerChanged()
        state.observationUnavailable(null)
        assertEquals("waiting", state.snapshot().state)
        assertNull(state.snapshot().frame)
        val recovery = state.begin(200)!!
        assertTrue(state.changed(recovery, intArrayOf(1), 1, 1))
        state.publish(recovery, frame(1), 200)
        assertEquals("frame", state.snapshot().state)
    }

    @Test fun unavailableObservationBeforeReaderChangeRetiresLateEncodeButKeepsItsPhysicalSlot() {
        for (reason in listOf(null, "captureFailed")) {
            val state = BackgroundPreviewState(); state.configure(true)
            val first = state.begin(0)!!
            state.publish(first, frame(1), 0); state.finish(first)
            state.captured(raw(9))
            val encoding = state.begin(200)!!
            // Real capture can throw at ImageReader allocation before readerChanged is reached.
            state.observationUnavailable(reason)
            val cleared = state.snapshot()
            assertEquals(if (reason == null) "waiting" else "unavailable", cleared.state)
            assertNull(cleared.frame)
            assertFalse(state.current(encoding))
            state.publish(encoding, frame(2), 200)
            assertSame(cleared, state.snapshot())
            assertNull(state.begin(400)) // Invalidating a ticket does not finish its physical work.
            state.finish(encoding)
            val recovery = state.begin(400)!!
            assertNull(recovery.candidate)
            state.finish(encoding) // An old completion must not release the new worker's slot.
            assertTrue(state.current(recovery))
            assertNull(state.begin(600))
            state.publish(recovery, frame(3), 400); state.finish(recovery)
            assertEquals(3, state.snapshot().frame!!.pixels.single())
        }
    }

    @Test fun noNewFrameKeepsTheSameSequenceAndImage() {
        val state = BackgroundPreviewState(); state.configure(true)
        val first = state.begin(0)!!; val image = frame(2, 4)
        state.publish(first, image, 0); state.finish(first)
        val snapshot = state.snapshot()
        val next = state.begin(200)!!
        state.finish(next)
        assertSame(snapshot, state.snapshot())
        assertSame(image, state.snapshot().frame)
    }

    @Test fun pixelComparisonIsExactAndIncludesGeometry() {
        val state = BackgroundPreviewState(); state.configure(true)
        val first = state.begin(0)!!
        state.publish(first, frame(1, 2, 3), 0); state.finish(first)
        val next = state.begin(200)!!
        assertFalse(state.changed(next, intArrayOf(1, 2, 3), 3, 1))
        assertTrue(state.changed(next, intArrayOf(1, 2, 4), 3, 1))
        assertTrue(state.changed(next, intArrayOf(1, 2, 3), 1, 3))
    }

    @Test fun blackFrameClearsOldImageButDoesNotDeclareSecureOrBlockRecovery() {
        val state = BackgroundPreviewState(); state.configure(true)
        val first = state.begin(0)!!
        state.publish(first, frame(1), 0); state.finish(first)
        val next = state.begin(200)!!
        state.unavailable(next, "blackFrame"); state.finish(next)
        assertEquals("unavailable", state.snapshot().state)
        assertEquals("blackFrame", state.snapshot().reason)
        assertNull(state.snapshot().frame)
        val recovery = state.begin(400)!!
        assertTrue(state.changed(recovery, intArrayOf(1), 1, 1))
    }

    @Test fun explicitSecureVerdictRetiresAllCandidatesUntilTheNextReader() {
        val state = BackgroundPreviewState(); state.configure(true)
        state.captured(raw(9))
        val ticket = state.begin(0)!!
        state.protect()
        state.publish(ticket, frame(1), 0); state.finish(ticket)
        assertEquals("protected", state.snapshot().state)
        assertNull(state.snapshot().frame)
        assertNull(state.begin(200))
        state.invalidate()
        assertNull(state.begin(200)!!.candidate)
    }

    @Test fun captureCandidateSurvivesAWorkerThatCouldNotAcquireTheDisplay() {
        val state = BackgroundPreviewState(); state.configure(true)
        val bytes = raw(9); state.captured(bytes)
        val busy = state.begin(0)!!; state.finish(busy)
        val retry = state.begin(200)!!
        assertSame(bytes, retry.candidate)
        state.consumed(retry); state.finish(retry)
        assertNull(state.begin(400)!!.candidate)
    }

    @Test fun slowEncodeCannotCauseCloselySpacedPublishedFrames() {
        val state = BackgroundPreviewState(); state.configure(true)
        val first = state.begin(0)!!
        assertNull(state.begin(200)) // One physical encoder, regardless of elapsed time.
        state.publish(first, frame(1), 195); state.finish(first)
        assertNull(state.begin(200))
        assertNull(state.begin(394))
        assertNotNull(state.begin(395))
    }

    @Test fun readerResetAndReenableCannotBypassTheRateLimit() {
        val state = BackgroundPreviewState(); state.configure(true)
        val first = state.begin(0)!!; state.publish(first, frame(1), 10); state.finish(first)
        state.invalidate()
        assertNull(state.begin(200))
        state.configure(false); state.configure(true)
        assertNull(state.begin(209))
        assertNotNull(state.begin(210))
    }

    @Test fun oldFinishCannotReleaseTheNextWorkersSlotAndSequencesNeverReset() {
        val state = BackgroundPreviewState(); state.configure(true)
        val old = state.begin(0)!!; state.finish(old)
        val sequence = state.snapshot().sequence
        state.configure(false); state.configure(true)
        val next = state.begin(200)!!
        state.finish(old)
        assertNull(state.begin(400))
        assertTrue(state.current(next))
        assertTrue(state.snapshot().sequence > sequence)
    }
}
