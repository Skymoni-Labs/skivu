package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.assertEquals
import org.junit.Test

/** Production capture policy only; no Android frame, transport, or snapshot behavior is simulated. */
class BackgroundFrameReadinessTest {
    @Test fun aNonblackFirstFrameIsReadyWithoutAnExtraFrame() {
        assertEquals(BackgroundFrameReadiness.Next.READY,
            BackgroundFrameReadiness.next(black = false, attempt = 0, remainingMs = 2_400))
    }

    @Test fun anInitialBlackFrameMayWaitOnceWithinTheExistingDeadline() {
        assertEquals(BackgroundFrameReadiness.Next.RETRY,
            BackgroundFrameReadiness.next(black = true, attempt = 0, remainingMs = 2_400))
        assertEquals(200L, BackgroundFrameReadiness.retryWaitMs(2_400))
    }

    @Test fun aRenderedSecondFrameCanBeUsed() {
        assertEquals(BackgroundFrameReadiness.Next.READY,
            BackgroundFrameReadiness.next(black = false, attempt = 1, remainingMs = 2_000))
    }

    @Test fun aSecondBlackFrameIsNotReadyRatherThanProofOfSecurity() {
        assertEquals(BackgroundFrameReadiness.Next.NOT_READY,
            BackgroundFrameReadiness.next(black = true, attempt = 1, remainingMs = 2_000))
    }

    @Test fun noRetryCanStartAfterTheOriginalDeadline() {
        for (remaining in listOf(0L, -1L)) {
            assertEquals(BackgroundFrameReadiness.Next.NOT_READY,
                BackgroundFrameReadiness.next(black = true, attempt = 0, remainingMs = remaining))
            assertEquals(0L, BackgroundFrameReadiness.retryWaitMs(remaining))
        }
    }

    @Test fun aShortRemainingBudgetIsNotExtendedToTwoHundredMilliseconds() {
        assertEquals(1L, BackgroundFrameReadiness.retryWaitMs(1))
        assertEquals(75L, BackgroundFrameReadiness.retryWaitMs(75))
        assertEquals(200L, BackgroundFrameReadiness.retryWaitMs(200))
        assertEquals(2_500L, BackgroundFrameReadiness.CAPTURE_TIMEOUT_MS)
    }
}
