package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

class PhoneCapacityStatusDeliveryTest {
    @Test fun delayedOldLimitDropsWholeBlockWithoutMutatingCachedSnapshot() {
        val parallelism = mapOf("v" to 1, "configuredLimit" to 3,
            "effectiveLimit" to 3, "heldSlots" to 3, "reason" to null)
        val background = mapOf("mode" to "root", "parallelism" to parallelism)
        val tasks = listOf(mapOf("id" to 7L))
        val old = mapOf("background" to background, "tasks" to tasks, "statusRevision" to 42L)
        val delivered = capacityStatusForDelivery(old, 1)
        assertNotSame(old, delivered)
        assertSame(tasks, delivered["tasks"])
        assertEquals(42L, delivered["statusRevision"])
        assertEquals(mapOf("mode" to "root"), delivered["background"])
        assertSame(parallelism, background["parallelism"])
        assertSame(background, old["background"])
        val fresh = mapOf("background" to mapOf("parallelism" to mapOf(
            "v" to 1, "configuredLimit" to 1, "effectiveLimit" to 1,
            "heldSlots" to 3, "reason" to null)))
        assertSame(fresh, capacityStatusForDelivery(fresh, 1))
    }

    @Test fun missingCapacityStaysUnknownAndMatchingLimitIsNotAnEpochClaim() {
        val unknown = mapOf<String, Any?>("background" to mapOf("mode" to "off"))
        assertSame(unknown, capacityStatusForDelivery(unknown, 1))
        val oldThree = mapOf<String, Any?>("background" to mapOf("parallelism" to mapOf(
            "configuredLimit" to 3, "effectiveLimit" to 3, "heldSlots" to 2)))
        // This helper cannot infer 3 -> 1 -> 3; the existing capture actor owns statusRevision.
        assertSame(oldThree, capacityStatusForDelivery(oldThree, 3))
    }
}
