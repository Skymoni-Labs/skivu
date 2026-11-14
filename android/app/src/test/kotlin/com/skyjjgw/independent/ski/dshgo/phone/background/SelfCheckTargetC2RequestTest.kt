package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class SelfCheckTargetC2RequestTest {
    private val owner = "123e4567-e89b-42d3-a456-426614174000"
    private val run = "123e4567-e89b-42d3-a456-426614174001"
    private fun nonce(i: Int) = "123e4567-e89b-42d3-a456-4266141741" + i.toString().padStart(2, '0')
    private val steps = listOf(SelfCheckTargetRequest.Step.CREATE, SelfCheckTargetRequest.Step.READ,
        SelfCheckTargetRequest.Step.TAP, SelfCheckTargetRequest.Step.TEXT_ASCII, SelfCheckTargetRequest.Step.TEXT_ZH,
        SelfCheckTargetRequest.Step.CAPTURE, SelfCheckTargetRequest.Step.CONTINUITY,
        SelfCheckTargetRequest.Step.CONTINUITY, SelfCheckTargetRequest.Step.CONTINUITY)
    private fun request(i: Int) = SelfCheckTargetRequest(steps[i], owner, run, nonce(i), true)
    private fun values(i: Int) = linkedMapOf<String, Any?>(Proto.OP to steps[i].op, Proto.OWNER to owner,
        Proto.TARGET_RUN to run, Proto.STEP_NONCE to nonce(i), Proto.SELF_CHECK_TARGET_C2_VERSION to 1).apply {
        if (i == 0) put(Proto.RELEASE_RECEIPT, 1)
    }
    private fun parse(v: Map<String, Any?>) = SelfCheckTargetRequest.parse(v.keys) { v[it] }

    @Test fun exactSevenOperationsDoNotAcceptFreePhaseOrTextOrBothVersions() {
        for (i in steps.indices) {
            assertEquals(request(i), parse(values(i)))
            for (key in values(i).keys) assertNull(parse(values(i).apply { remove(key) }))
            for (key in listOf("phase", "index", "count", Proto.TEXT, Proto.PKG, Proto.DISPLAY_ID, Proto.SELF_CHECK_TARGET_VERSION))
                assertNull(parse(values(i).apply { put(key, 1) }))
        }
        for (bad in listOf<Any?>(true, 1L, "1", null, 2))
            assertNull(parse(values(0).apply { put(Proto.SELF_CHECK_TARGET_C2_VERSION, bad) }))
        for (i in 3..8) assertNull(parse(values(i).apply {
            remove(Proto.SELF_CHECK_TARGET_C2_VERSION); put(Proto.SELF_CHECK_TARGET_VERSION, 1)
        }))
    }

    @Test fun nineSlotsDeriveFramePhasesAndCannotGrowAfterLastSuccess() {
        val sequence = SelfCheckTargetSequence(owner, run, true)
        for (i in steps.indices) {
            assertNull(sequence.enter(request(i)))
            if (i >= 5) assertEquals(i - 4, sequence.framePhase)
            sequence.complete(steps[i])
        }
        repeat(20) { assertEquals("alreadyAttempted", sequence.enter(request(8).copy(nonce = nonce(20 + it)))) }
    }

    @Test fun failedContinuityCannotReplayWithFreshNonceOrSkipItsConsumedSlot() {
        val sequence = SelfCheckTargetSequence(owner, run, true)
        for (i in 0..5) { assertNull(sequence.enter(request(i))); sequence.complete(steps[i]) }
        assertNull(sequence.enter(request(6))) // Actual image/check may now fail or the reply may be lost.
        assertEquals("alreadyAttempted", sequence.enter(request(7)))
        assertEquals("alreadyAttempted", sequence.enter(request(6)))
        assertEquals(2, sequence.framePhase)
    }

    @Test fun profileAndIdentityCannotCrossScopesOrConsumeValidSlot() {
        val sequence = SelfCheckTargetSequence(owner, run, true)
        assertEquals("identityChanged", sequence.enter(request(0).copy(c2 = false)))
        assertEquals("identityChanged", sequence.enter(request(0).copy(run = owner)))
        assertEquals("outOfOrder", sequence.enter(request(6)))
        assertNull(sequence.enter(request(0)))
    }

    @Test fun releaseBindingIsExactAndSealsAllRemainingTestSlots() {
        val sequence = SelfCheckTargetSequence(owner, run, true)
        assertNull(sequence.enter(request(0))); sequence.complete(steps[0])
        val release = SelfCheckTargetRelease(owner, run, nonce(50))
        assertFalse(sequence.bindRelease(release.copy(run = owner)))
        assertTrue(sequence.bindRelease(release))
        assertTrue(sequence.bindRelease(release))
        assertFalse(sequence.bindRelease(release.copy(nonce = nonce(51))))
        assertEquals("releasePending", sequence.enter(request(1)))
        assertFalse(SelfCheckTargetSequence(owner, run).bindRelease(release))
    }

    @Test fun releaseRequiresWholeFixedGroupAndNoStageNonce() {
        val v = linkedMapOf<String, Any?>(Proto.OP to Proto.OP_RELEASE, Proto.OWNER to owner,
            Proto.RELEASE_RECEIPT to 1, Proto.SELF_CHECK_TARGET_C2_VERSION to 1,
            Proto.SELF_CHECK_FINAL_MAIN to 1, Proto.TARGET_RUN to run, Proto.RELEASE_NONCE to nonce(50))
        fun parse(m: Map<String, Any?>) = SelfCheckTargetRelease.parse(m.keys) { m[it] }
        assertEquals(SelfCheckTargetRelease(owner, run, nonce(50)), parse(v))
        for (key in v.keys) assertNull(parse(v.toMutableMap().apply { remove(key) }))
        assertNull(parse(v.toMutableMap().apply { put(Proto.STEP_NONCE, nonce(0)) }))
        assertNull(parse(v.toMutableMap().apply { put(Proto.SELF_CHECK_FINAL_MAIN, true) }))
    }
}
