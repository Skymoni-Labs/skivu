package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

/** The actual Core request validator. These are not Android Bundle or platform-operation tests. */
class SelfCheckProbeRequestTest {
    private val owner = "123e4567-e89b-42d3-a456-426614174000"
    private fun request(): MutableMap<String, Any?> = linkedMapOf(
        Proto.OP to Proto.OP_SELF_CHECK_PROBE,
        Proto.OWNER to owner,
        Proto.RELEASE_RECEIPT to 1,
        Proto.SELF_CHECK_PROBE_VERSION to 1,
    )
    private fun parse(values: Map<String, Any?>) = SelfCheckProbeRequest.owner(values.keys) { values[it] }

    @Test fun onlyCompleteFixedRequestReturnsOriginalIdentity() {
        assertEquals(owner, parse(request()))
        assertEquals(owner.uppercase(), parse(request().apply { put(Proto.OWNER, owner.uppercase()) }))
    }

    @Test fun missingOrExtraFieldsCannotAllocateEvenWhenTheirValuesAreNull() {
        for (key in request().keys) assertNull(parse(request().apply { remove(key) }))
        for (key in listOf(Proto.PKG, Proto.TEXT, Proto.DISPLAY_ID, Proto.SHORT_SIDE,
            Proto.ASPECT_W, Proto.VIEWPORT_PRESET, Proto.WANT_IMAGE, "purpose", "component", "command")) {
            assertNull(parse(request().apply { put(key, null) }))
        }
        var reads = 0
        assertNull(SelfCheckProbeRequest.owner(request().keys + "unknown") { reads++; error("must reject keys before reading payload") })
        assertEquals(0, reads)
    }

    @Test fun versionAndReleaseRequireExactIntegerOne() {
        for (field in listOf(Proto.RELEASE_RECEIPT, Proto.SELF_CHECK_PROBE_VERSION)) {
            for (value in listOf<Any?>(null, true, "1", 1L, 1.0, 0, 2, -1)) {
                assertNull("$field accepts only Int(1)", parse(request().apply { put(field, value) }))
            }
        }
    }

    @Test fun operationCannotBecomeAnotherPrivilegedCommand() {
        for (value in listOf<Any?>(null, 1, Proto.OP_CREATE, Proto.OP_GATE, Proto.OP_RELEASE, "SelfCheckProbe"))
            assertNull(parse(request().apply { put(Proto.OP, value) }))
    }

    @Test fun ownerIsAnExactUuidNotAnArbitraryLabelOrCoercedValue() {
        for (value in listOf<Any?>(null, 1, "", "__gate__", "1-1-1-1-1", " $owner", "$owner\n",
            owner.replace("-", ""), "g" + owner.drop(1), StringBuilder(owner))) {
            assertNull(parse(request().apply { put(Proto.OWNER, value) }))
        }
    }
}
