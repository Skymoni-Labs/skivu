package com.skyjjgw.independent.ski

/** Service-local counters. Callers can subtract snapshots to report one operation. */
internal class PhoneVisionMetrics {
    private val values = linkedMapOf(
        "captureCount" to 0L,
        "captureAttemptCount" to 0L,
        "captureRetryCount" to 0L,
        "captureMs" to 0L,
        "captureQueueMs" to 0L,
        "ocrCount" to 0L,
        "ocrCacheHitCount" to 0L,
        "ocrMs" to 0L,
        "reusedObservationCount" to 0L,
        "preDispatchRefreshCount" to 0L,
        "waitMs" to 0L,
        "streamRequestCount" to 0L,
        "streamFrameCount" to 0L,
        "streamFallbackCount" to 0L,
    )

    @Synchronized fun snapshot(): Map<String, Long> = values.toMap()

    @Synchronized fun recordCaptureAttempt(retry: Boolean) {
        add("captureAttemptCount", 1)
        if (retry) add("captureRetryCount", 1)
    }

    @Synchronized fun recordCaptureSuccess() = add("captureCount", 1)
    @Synchronized fun recordCapture(elapsedMs: Long) = add("captureMs", elapsedMs)
    @Synchronized fun recordCaptureQueue(elapsedMs: Long) = add("captureQueueMs", elapsedMs)

    @Synchronized fun recordOcr(elapsedMs: Long, cacheHit: Boolean) {
        add(if (cacheHit) "ocrCacheHitCount" else "ocrCount", 1)
        add("ocrMs", elapsedMs)
    }

    @Synchronized fun recordReuse() = add("reusedObservationCount", 1)
    @Synchronized fun recordRefresh() = add("preDispatchRefreshCount", 1)
    @Synchronized fun recordWait(elapsedMs: Long) = add("waitMs", elapsedMs)
    @Synchronized fun recordStreamRequest() = add("streamRequestCount", 1)
    @Synchronized fun recordStreamFrame() { add("streamFrameCount", 1); add("captureCount", 1) }
    @Synchronized fun recordStreamFallback() = add("streamFallbackCount", 1)

    private fun add(name: String, amount: Long) {
        values[name] = values.getValue(name) + amount.coerceAtLeast(0)
    }
}

/** The platform rejects display screenshot requests spaced at most 333 ms apart. */
internal class PhoneCaptureTiming {
    private var lastAttemptMs: Long? = null
    private var intervalMs = 334L

    @Synchronized fun delayMs(now: Long): Long = lastAttemptMs?.let {
        (intervalMs - (now - it)).coerceAtLeast(0)
    } ?: 0

    @Synchronized fun attempted(now: Long) { lastAttemptMs = now }

    @Synchronized fun intervalRejected() {
        // Allow for vendor throttles and requests from another screenshot entry point.
        intervalMs = (intervalMs + 50).coerceAtMost(1_000)
    }
}
