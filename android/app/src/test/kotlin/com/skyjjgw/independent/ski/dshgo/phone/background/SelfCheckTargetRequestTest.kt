package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

/** Actual request and once-state production classes; no Android Bundle/platform simulation. */
class SelfCheckTargetRequestTest {
    private val owner = "123e4567-e89b-42d3-a456-426614174000"
    private val run = "123e4567-e89b-42d3-a456-426614174001"
    private fun nonce(i: Int) = "123e4567-e89b-42d3-a456-42661417410$i"
    private fun values(step: SelfCheckTargetRequest.Step) = linkedMapOf<String, Any?>(
        Proto.OP to step.op, Proto.OWNER to owner, Proto.TARGET_RUN to run,
        Proto.STEP_NONCE to nonce(step.ordinal), Proto.SELF_CHECK_TARGET_VERSION to 1,
    ).apply { if (step == SelfCheckTargetRequest.Step.CREATE) put(Proto.RELEASE_RECEIPT, 1) }
    private fun parse(value: Map<String, Any?>) = SelfCheckTargetRequest.parse(value.keys) { value[it] }
    private fun request(step: SelfCheckTargetRequest.Step) = checkNotNull(parse(values(step)))

    @Test fun threeFixedOperationsPreserveExactIdentity() {
        for (step in SelfCheckTargetRequest.Step.entries.take(3)) {
            val parsed = checkNotNull(parse(values(step)))
            assertEquals(step, parsed.step); assertEquals(owner, parsed.owner)
            assertEquals(run, parsed.run); assertEquals(nonce(step.ordinal), parsed.nonce)
        }
    }

    @Test fun everyMissingOrAdditionalFieldIsRejected() {
        for (step in SelfCheckTargetRequest.Step.entries.take(3)) {
            for (key in values(step).keys) assertNull(parse(values(step).apply { remove(key) }))
            for (key in listOf(Proto.PKG, Proto.TEXT, Proto.DISPLAY_ID, Proto.ELEMENT,
                Proto.SHORT_SIDE, Proto.ASPECT_W, Proto.WANT_IMAGE, Proto.ALLOW_SECRET,
                "component", "flags", "targetUid", "userId", "command")) {
                assertNull(parse(values(step).apply { put(key, null) }))
            }
        }
        assertNull(parse(values(SelfCheckTargetRequest.Step.READ).apply { put(Proto.RELEASE_RECEIPT, 1) }))
    }

    @Test fun versionsAreExactIntOneAndAllIdentitiesAreUuidStrings() {
        for (key in listOf(Proto.SELF_CHECK_TARGET_VERSION, Proto.RELEASE_RECEIPT))
            for (value in listOf<Any?>(null, true, "1", 1L, 1.0, 0, 2))
                assertNull(parse(values(SelfCheckTargetRequest.Step.CREATE).apply { put(key, value) }))
        for (key in listOf(Proto.OWNER, Proto.TARGET_RUN, Proto.STEP_NONCE))
            for (value in listOf<Any?>(null, 1, "", " $owner", "$owner\n", "1-1-1-1-1", StringBuilder(owner)))
                assertNull(parse(values(SelfCheckTargetRequest.Step.CREATE).apply { put(key, value) }))
        assertNull(parse(values(SelfCheckTargetRequest.Step.CREATE).apply { put(Proto.OP, Proto.OP_CREATE) }))
    }

    @Test fun admissionConsumesFailedCreateAndCannotBeRetriedWithAnotherNonce() {
        val sequence = SelfCheckTargetSequence(owner, run)
        val create = request(SelfCheckTargetRequest.Step.CREATE)
        assertNull(sequence.enter(create)) // Allocation may now fail; do not call complete.
        assertEquals("alreadyAttempted", sequence.enter(create.copy(nonce = nonce(8))))
        assertEquals("outOfOrder", sequence.enter(request(SelfCheckTargetRequest.Step.READ)))
    }

    @Test fun failedReadCannotAdvanceToTapOrBeRepeated() {
        val sequence = SelfCheckTargetSequence(owner, run)
        assertNull(sequence.enter(request(SelfCheckTargetRequest.Step.CREATE)))
        sequence.complete(SelfCheckTargetRequest.Step.CREATE)
        assertNull(sequence.enter(request(SelfCheckTargetRequest.Step.READ)))
        assertEquals("alreadyAttempted", sequence.enter(request(SelfCheckTargetRequest.Step.READ).copy(nonce = nonce(8))))
        assertEquals("outOfOrder", sequence.enter(request(SelfCheckTargetRequest.Step.TAP)))
    }

    @Test fun tapReplyLossNeverPermitsAnotherTapAndStateIsBoundedToThreeStages() {
        val sequence = SelfCheckTargetSequence(owner, run)
        for (step in listOf(SelfCheckTargetRequest.Step.CREATE, SelfCheckTargetRequest.Step.READ)) {
            assertNull(sequence.enter(request(step))); sequence.complete(step)
        }
        assertNull(sequence.enter(request(SelfCheckTargetRequest.Step.TAP)))
        repeat(100) {
            assertEquals("alreadyAttempted", sequence.enter(request(SelfCheckTargetRequest.Step.TAP).copy(nonce = nonce(8))))
        }
        sequence.complete(SelfCheckTargetRequest.Step.TAP)
        for (step in SelfCheckTargetRequest.Step.entries.take(3)) assertEquals("alreadyAttempted", sequence.enter(request(step)))
    }

    @Test fun wrongScopeAndCrossStageNonceReuseDoNotConsumeValidNextAdmission() {
        val sequence = SelfCheckTargetSequence(owner, run)
        val create = request(SelfCheckTargetRequest.Step.CREATE)
        assertEquals("identityChanged", sequence.enter(create.copy(owner = run)))
        assertEquals("identityChanged", sequence.enter(create.copy(run = owner)))
        assertEquals("outOfOrder", sequence.enter(request(SelfCheckTargetRequest.Step.TAP)))
        assertNull(sequence.enter(create)); sequence.complete(SelfCheckTargetRequest.Step.CREATE)
        val read = request(SelfCheckTargetRequest.Step.READ)
        assertEquals("alreadyAttempted", sequence.enter(read.copy(nonce = create.nonce)))
        assertNull(sequence.enter(read)); sequence.complete(SelfCheckTargetRequest.Step.READ)
        assertNull(sequence.enter(request(SelfCheckTargetRequest.Step.TAP)))
    }
}
