package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.phone.Json
import org.junit.Assert.*
import org.junit.Test

class PhoneSkillOutcomesTest {
    private fun id(n: Int) = n.toString(16).padStart(32, '0')
    private val key = PhoneSkillOutcomes.Key("phone-task-${id(1)}", id(2), "a".repeat(64))
    private class Disk {
        var bytes: String? = null
        var fail = false
        var writeDespiteFailure = false
        var throwAfterWrite = false
        val writes = mutableListOf<String>()
        fun commit(next: String): Boolean {
            writes += next
            if (!fail || writeDespiteFailure || throwAfterWrite) bytes = next
            if (throwAfterWrite) throw IllegalStateException("storage error")
            return !fail
        }
    }
    private fun store(disk: Disk, process: Int = 100) = PhoneSkillOutcomes({ disk.bytes }, disk::commit, id(process))

    @Test fun failedSettlementRetriesExactBytesAndDoesNotRecountAfterAnAckIsLost() {
        for (writeOnFailure in listOf(false, true)) {
            val disk = Disk(); val outcomes = store(disk)
            assertEquals(PhoneSkillOutcomes.Result.SAVED, outcomes.begin(id(10), key))
            assertEquals(PhoneSkillOutcomes.Result.SAVED, outcomes.markDispatch(id(10)))
            disk.fail = true; disk.writeDespiteFailure = writeOnFailure
            assertEquals(PhoneSkillOutcomes.Result.BLOCKED, outcomes.settle(id(10), PhoneSkillOutcomes.Outcome.SUCCESS))
            val uncertainWrite = disk.writes.last()
            assertNull(outcomes.counts(key))
            // A duplicate caller cannot choose another result or create another count meanwhile.
            assertEquals(PhoneSkillOutcomes.Result.BLOCKED, outcomes.settle(id(10), PhoneSkillOutcomes.Outcome.FAILURE))
            disk.fail = false
            assertTrue(outcomes.retryStorage())
            assertEquals(uncertainWrite, disk.writes.last())
            val writeCount = disk.writes.size
            assertEquals(PhoneSkillOutcomes.Result.UNCHANGED, outcomes.settle(id(10), PhoneSkillOutcomes.Outcome.SUCCESS))
            assertEquals(writeCount, disk.writes.size)
            assertEquals(PhoneSkillOutcomes.Counts(1, 0, 0, PhoneSkillOutcomes.Outcome.SUCCESS), outcomes.counts(key))
            val restarted = store(disk, 101)
            assertTrue(restarted.load())
            assertEquals(1L, restarted.counts(key)!!.successes)
            assertEquals(PhoneSkillOutcomes.Result.UNCHANGED, restarted.settle(id(10), PhoneSkillOutcomes.Outcome.SUCCESS))
        }
    }

    @Test fun pendingOldRevisionCannotOverwriteAnotherInvocationsNewRevisionResult() {
        val disk = Disk(); val outcomes = store(disk)
        val newer = key.copy(revision = id(3), digest = "b".repeat(64))
        assertEquals(PhoneSkillOutcomes.Result.SAVED, outcomes.begin(id(10), key))
        assertEquals(PhoneSkillOutcomes.Result.SAVED, outcomes.begin(id(11), newer))
        disk.fail = true; disk.writeDespiteFailure = true
        assertEquals(PhoneSkillOutcomes.Result.BLOCKED, outcomes.settle(id(10), PhoneSkillOutcomes.Outcome.FAILURE))
        val pendingA = disk.writes.last()
        val frozenB = PhoneSkillOutcomes.Outcome.SUCCESS // Belongs to B's execution record, not A's pending storage.
        assertEquals(PhoneSkillOutcomes.Result.BLOCKED, outcomes.settle(id(11), frozenB))
        assertEquals(pendingA, disk.writes.last())
        disk.fail = false
        assertTrue(outcomes.retryStorage())
        assertEquals(pendingA, disk.writes.last())
        assertEquals(PhoneSkillOutcomes.Result.SAVED, outcomes.settle(id(11), frozenB))
        val withBoth = disk.bytes
        assertTrue(outcomes.retryStorage())
        assertEquals(withBoth, disk.bytes)
        assertEquals(1L, outcomes.counts(key)!!.failures)
        assertEquals(0L, outcomes.counts(key)!!.successes)
        assertEquals(1L, outcomes.counts(newer)!!.successes)
        assertEquals(0L, outcomes.counts(newer)!!.failures)
        val restarted = store(disk, 101)
        assertTrue(restarted.load())
        assertEquals(outcomes.counts(key), restarted.counts(key))
        assertEquals(outcomes.counts(newer), restarted.counts(newer))
    }

    @Test fun crashOnEitherSideOfAnUncertainSettlementNeverInventsSuccess() {
        for (persistSettlement in listOf(false, true)) {
            val disk = Disk(); val outcomes = store(disk)
            outcomes.begin(id(10), key); outcomes.markDispatch(id(10))
            disk.fail = true; disk.writeDespiteFailure = persistSettlement
            assertEquals(PhoneSkillOutcomes.Result.BLOCKED, outcomes.settle(id(10), PhoneSkillOutcomes.Outcome.SUCCESS))
            disk.fail = false
            val recovered = store(disk, 101)
            assertTrue(recovered.load())
            val count = recovered.counts(key)!!
            assertEquals(if (persistSettlement) 1L else 0L, count.successes)
            assertEquals(if (persistSettlement) PhoneSkillOutcomes.Outcome.SUCCESS else PhoneSkillOutcomes.Outcome.UNKNOWN, count.last)
            assertEquals(0L, count.failures)
            // There is no replay/resume callback in this storage object.
            assertEquals(PhoneSkillOutcomes.Result.UNCHANGED, recovered.settle(id(10), PhoneSkillOutcomes.Outcome.SUCCESS))
        }
    }

    @Test fun crashBeforeDispatchAndFailedMarkerAreDistinguishedConservatively() {
        for (writeMarker in listOf(false, true)) {
            val disk = Disk(); val outcomes = store(disk)
            outcomes.begin(id(10), key)
            disk.fail = true; disk.writeDespiteFailure = writeMarker
            assertEquals(PhoneSkillOutcomes.Result.BLOCKED, outcomes.markDispatch(id(10)))
            // Caller sees BLOCKED: no device action may follow even if the marker did persist.
            disk.fail = false
            val recovered = store(disk, 101)
            assertTrue(recovered.load())
            assertEquals(if (writeMarker) PhoneSkillOutcomes.Outcome.UNKNOWN else PhoneSkillOutcomes.Outcome.NOT_STARTED,
                recovered.counts(key)!!.last)
            assertEquals(0L, recovered.counts(key)!!.successes)
            assertEquals(0L, recovered.counts(key)!!.failures)
        }
    }

    @Test fun onlyVerifiedSuccessClearsTheFailureStreakAndNoResultAutomaticallyDisables() {
        val disk = Disk(); val outcomes = store(disk)
        val sequence = listOf(PhoneSkillOutcomes.Outcome.FAILURE, PhoneSkillOutcomes.Outcome.UNKNOWN,
            PhoneSkillOutcomes.Outcome.CANCEL, PhoneSkillOutcomes.Outcome.NOT_STARTED,
            PhoneSkillOutcomes.Outcome.FAILURE, PhoneSkillOutcomes.Outcome.FAILURE)
        for ((index, result) in sequence.withIndex()) {
            outcomes.begin(id(10 + index), key)
            outcomes.settle(id(10 + index), result)
        }
        assertEquals(3L, outcomes.counts(key)!!.streak)
        assertTrue(outcomes.counts(key)!!.suggestDisable)
        assertEquals(PhoneSkillOutcomes.Result.SAVED, outcomes.begin(id(20), key))
        outcomes.settle(id(20), PhoneSkillOutcomes.Outcome.SUCCESS)
        assertEquals(PhoneSkillOutcomes.Counts(1, 3, 0, PhoneSkillOutcomes.Outcome.SUCCESS), outcomes.counts(key))
    }

    @Test fun corruptStorageIsNotSilentlyOverwrittenAndFailedRecoveryBlocksAdmission() {
        val disk = Disk(); disk.bytes = "{bad"
        val outcomes = store(disk)
        assertFalse(outcomes.load())
        assertEquals(PhoneSkillOutcomes.Result.BLOCKED, outcomes.begin(id(10), key))
        assertTrue(disk.writes.isEmpty())
        disk.bytes = null
        assertTrue(outcomes.retryStorage())
        outcomes.begin(id(10), key); outcomes.markDispatch(id(10))
        disk.fail = true
        val recovered = store(disk, 101)
        assertFalse(recovered.load())
        val expected = disk.writes.last()
        assertEquals(PhoneSkillOutcomes.Result.BLOCKED, recovered.begin(id(11), key))
        disk.fail = false
        assertTrue(recovered.retryStorage())
        assertEquals(expected, disk.writes.last())
        assertEquals(PhoneSkillOutcomes.Outcome.UNKNOWN, recovered.counts(key)!!.last)
    }

    @Test fun thrownCommitAfterWritingUsesTheSamePendingSnapshot() {
        val disk = Disk(); val outcomes = store(disk)
        outcomes.begin(id(10), key)
        disk.throwAfterWrite = true
        assertEquals(PhoneSkillOutcomes.Result.BLOCKED, outcomes.settle(id(10), PhoneSkillOutcomes.Outcome.FAILURE))
        val next = disk.bytes
        disk.throwAfterWrite = false
        assertTrue(outcomes.retryStorage())
        assertEquals(next, disk.bytes)
        assertEquals(1L, outcomes.counts(key)!!.failures)
    }

    @Test fun storageContainsOnlyBoundedIdentityCountersAndDispatchMarker() {
        val disk = Disk(); val outcomes = store(disk)
        outcomes.begin(id(10), key)
        val parsed = Json.parse(disk.bytes!!) as Map<*, *>
        assertEquals(setOf("version", "skills", "active"), parsed.keys)
        val active = (parsed["active"] as List<*>).single() as Map<*, *>
        assertEquals(setOf("name", "revision", "digest", "invocation", "process", "dispatched"), active.keys)
        assertEquals(false, active["dispatched"])
        assertEquals(PhoneSkillOutcomes.Result.INVALID, outcomes.begin(id(11), key.copy(name = "../SKILL.md")))
        assertEquals(PhoneSkillOutcomes.Result.INVALID, outcomes.begin("model-supplied-id", key))
    }
}
