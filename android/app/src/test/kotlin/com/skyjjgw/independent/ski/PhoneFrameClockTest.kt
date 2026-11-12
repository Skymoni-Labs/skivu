package com.skyjjgw.independent.ski

import org.junit.Assert.*
import org.junit.Test

class PhoneFrameClockTest {
    @Test fun rejectsOldQueuedFramesFutureFramesAndIncompatibleProducerClock() {
        assertNull(PhoneFrameClock.capturedAt(100,101,120,500))
        assertNull(PhoneFrameClock.capturedAt(121,100,120,500))
        assertNull(PhoneFrameClock.capturedAt(100,0,600_000_101,500))
    }
    @Test fun copyingAndRecognitionCannotMoveTheCaptureTimeForward() {
        val captured=PhoneFrameClock.capturedAt(1_000_000_000,900_000_000,1_025_000_000,2025)
        assertEquals(2000L,captured)
        // A later check of that same producer timestamp still maps to the same instant.
        assertEquals(captured,PhoneFrameClock.capturedAt(1_000_000_000,900_000_000,1_125_000_000,2125))
    }
}
