package com.skyjjgw.independent.ski.dshgo.phone.background

/** A black frame is uncertain, never evidence of FLAG_SECURE. Used by the actual capture loop. */
internal object BackgroundFrameReadiness {
    const val CAPTURE_TIMEOUT_MS = 2_500L
    const val RETRY_WAIT_MS = 200L

    enum class Next { READY, RETRY, NOT_READY }

    /** attempt is 0 for the first acquired frame, 1 for the only additional frame. */
    fun next(black: Boolean, attempt: Int, remainingMs: Long): Next = when {
        !black -> Next.READY
        attempt == 0 && remainingMs > 0 -> Next.RETRY
        else -> Next.NOT_READY
    }

    fun retryWaitMs(remainingMs: Long): Long = minOf(RETRY_WAIT_MS, remainingMs.coerceAtLeast(0))
}
