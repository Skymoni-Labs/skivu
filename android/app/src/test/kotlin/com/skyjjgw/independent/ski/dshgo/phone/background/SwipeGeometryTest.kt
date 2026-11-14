package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class SwipeGeometryTest {
    @Test fun fixedStepAndCoordinateExamplesPreserveExistingGestureShape() {
        for ((duration, expected) in listOf(1 to 1, 15 to 1, 16 to 1, 17 to 1, 32 to 2, 400 to 25)) {
            assertEquals(expected, SwipeGeometry.steps(duration))
        }
        // Fixed observations of the original 400ms path, not a second interpolation implementation.
        assertEquals(101, SwipeGeometry.coordinate(101, 118, 1, 25))
        assertEquals(109, SwipeGeometry.coordinate(101, 118, 12, 25))
        assertEquals(117, SwipeGeometry.coordinate(101, 118, 24, 25))
        assertEquals(117, SwipeGeometry.coordinate(118, 101, 1, 25))
        assertEquals(109, SwipeGeometry.coordinate(118, 101, 12, 25))
        assertEquals(101, SwipeGeometry.coordinate(118, 101, 24, 25))
        assertEquals(361, SwipeGeometry.coordinate(720, 361, 25, 25))
    }

    @Test fun lastMoveCanBeInsideSlopEvenWhenUpEndpointIsOutside() {
        val steps = SwipeGeometry.steps(400)
        assertEquals(25, steps)
        assertEquals(117, SwipeGeometry.coordinate(100, 118, steps - 1, steps))
        assertEquals(118, SwipeGeometry.coordinate(100, 118, steps, steps))
        // Negative delta truncates the final absolute coordinate, not the delta.
        assertEquals(100, SwipeGeometry.coordinate(118, 100, steps - 1, steps))
        assertEquals(1, SwipeGeometry.coordinate(0, 2, steps - 1, steps))
        assertEquals(0, SwipeGeometry.coordinate(2, 0, steps - 1, steps))
    }
}
