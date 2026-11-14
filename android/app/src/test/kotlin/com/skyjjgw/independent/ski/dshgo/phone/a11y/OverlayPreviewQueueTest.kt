package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.*
import org.junit.Test

class OverlayPreviewQueueTest {
    @Test fun slowDecodeKeepsOnlyTheLatestWaitingImage() {
        val queue = OverlayPreviewQueue()
        val first = byteArrayOf(1); val middle = byteArrayOf(2); val latest = byteArrayOf(3)
        queue.offer(first); val running = queue.start()!!
        queue.offer(middle); queue.offer(latest)
        assertNull(queue.start())
        assertSame(first, running.bytes)
        assertTrue(queue.finish(running))
        assertSame(latest, queue.start()!!.bytes)
    }

    @Test fun hidingClearsWaitingBytesAndRejectsTheLateDecode() {
        val queue = OverlayPreviewQueue()
        queue.offer(byteArrayOf(1)); val running = queue.start()!!
        queue.offer(byteArrayOf(2)); queue.clear()
        assertFalse(queue.finish(running))
        assertNull(queue.start())
    }

    @Test fun reopeningWaitsForTheOldPhysicalDecodeButCannotDisplayIt() {
        val queue = OverlayPreviewQueue()
        queue.offer(byteArrayOf(1)); val old = queue.start()!!
        queue.clear(); val next = byteArrayOf(3); queue.offer(next)
        assertNull(queue.start())
        assertFalse(queue.finish(old))
        val current = queue.start()!!
        assertSame(next, current.bytes)
        assertFalse(queue.finish(old)) // Cannot release the new worker's slot.
        assertNull(queue.start())
        assertTrue(queue.finish(current))
    }

    @Test fun protectedOrErrorClearRejectsPreviouslyQueuedPixels() {
        val queue = OverlayPreviewQueue()
        queue.offer(byteArrayOf(1)); queue.clear()
        assertNull(queue.start())
        queue.offer(byteArrayOf(2)); val current = queue.start()!!
        assertTrue(queue.finish(current))
        assertNull(queue.start())
    }
}
