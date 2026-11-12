package com.skyjjgw.independent.ski

import org.junit.Assert.assertEquals
import org.junit.Test

class PhoneVisionMetricsTest {
    @Test fun retriesAndCacheHitsDoNotCountAsSuccessfulCaptureOrInference() {
        val metrics = PhoneVisionMetrics()
        metrics.recordCaptureAttempt(false)
        metrics.recordCaptureAttempt(true)
        metrics.recordCaptureSuccess()
        metrics.recordCaptureQueue(120)
        metrics.recordCapture(200)
        metrics.recordOcr(42, false)
        metrics.recordOcr(0, true)
        metrics.recordReuse()
        metrics.recordWait(60)
        val result = metrics.snapshot()
        assertEquals(2L, result["captureAttemptCount"])
        assertEquals(1L, result["captureRetryCount"])
        assertEquals(1L, result["captureCount"])
        assertEquals(120L, result["captureQueueMs"])
        assertEquals(200L, result["captureMs"])
        assertEquals(1L, result["ocrCount"])
        assertEquals(1L, result["ocrCacheHitCount"])
        assertEquals(42L, result["ocrMs"])
        assertEquals(1L, result["reusedObservationCount"])
        assertEquals(60L, result["waitMs"])
    }

    @Test fun snapshotsAreIndependentAndConcurrentUpdatesAreRetained() {
        val metrics = PhoneVisionMetrics()
        val before = metrics.snapshot()
        val workers = List(4) {
            Thread { repeat(500) { metrics.recordOcr(1, false) } }
        }
        workers.forEach { it.start() }
        workers.forEach { it.join() }
        assertEquals(0L, before["ocrCount"])
        assertEquals(2_000L, metrics.snapshot()["ocrCount"])
        assertEquals(2_000L, metrics.snapshot()["ocrMs"])
    }

    @Test fun successiveRequestsWaitBeyondPlatformMinimum() {
        val timing = PhoneCaptureTiming()
        assertEquals(0L, timing.delayMs(1_000))
        timing.attempted(1_000)
        assertEquals(334L, timing.delayMs(1_000))
        assertEquals(234L, timing.delayMs(1_100))
        assertEquals(0L, timing.delayMs(1_334))
        timing.attempted(1_334)
        assertEquals(334L, timing.delayMs(1_334))
    }

    @Test fun intervalFailureReschedulesFromActualAttemptAndCancelledWaitDoesNotReserveTime() {
        val timing = PhoneCaptureTiming()
        timing.attempted(1_000)
        timing.intervalRejected()
        assertEquals(284L, timing.delayMs(1_100))
        // Merely asking when to run does not reserve a new attempt. If that
        // waiting job is cancelled, the next job retains the same deadline.
        assertEquals(0L, timing.delayMs(1_384))
        assertEquals(0L, timing.delayMs(2_000))
        timing.attempted(2_000)
        assertEquals(384L, timing.delayMs(2_000))
    }
}
