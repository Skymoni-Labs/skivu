package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

/** The production journal is reconstructed over actual read/commit storage, not a fake count. */
class PhoneTaskJournalTest {
    private val processA = "00000000-0000-4000-8000-000000000001"
    private val processB = "00000000-0000-4000-8000-000000000002"
    private class Store {
        var value: String? = null
        var fail = false
        var writes = 0
        fun commit(next: String): Boolean { writes++; if (fail) return false; value = next; return true }
    }
    private fun journal(store: Store, process: String = processA) = PhoneTaskJournal({ store.value }, store::commit, process) { 1234 }
    private fun record(journal: PhoneTaskJournal) = journal.record((PhoneTasks().begin() as PhoneTasks.Begin.Go).owner)

    @Test fun reconstructedProcessRequiresExplicitAckWithoutReplayingOrPersistingPayload() {
        val disk = Store(); val a = journal(disk); val r = record(a)
        assertTrue(a.mark(r)); assertEquals(1, disk.writes)
        val raw = Json.parse(disk.value!!) as Map<*, *>
        assertEquals(setOf("version", "records"), raw.keys)
        val row = (raw["records"] as List<*>).single() as Map<*, *>
        assertEquals(setOf("token", "processInstance", "taskId", "lifecycle", "startedAt"), row.keys)
        assertNull(journal(disk).refusal()) // Same App process, not a crash.
        val b = journal(disk, processB)
        assertEquals(PhoneTaskJournal.INTERRUPTION_MESSAGE, b.refusal())
        assertEquals(1, b.status()["count"])
        assertFalse(b.acknowledge("stale"))
        assertTrue(b.acknowledge(b.status()["batchToken"] as String))
        assertNull(b.refusal()); assertEquals(0, journal(disk, processA).also { it.load() }.status()["count"])
    }

    @Test fun failedAckKeepsTheExactBatchAndDoesNotRemoveNewProcessRecord() {
        val disk = Store(); val a = journal(disk); assertTrue(a.mark(record(a)))
        val b = journal(disk, processB); b.load(); val batch = b.status()["batchToken"] as String
        disk.fail = true; assertFalse(b.acknowledge(batch)); assertEquals("writeFailed", b.status()["error"])
        disk.fail = false; assertTrue(b.retryStorage()); assertEquals(batch, b.status()["batchToken"])
        assertTrue(b.acknowledge(batch))
        val current = record(b); assertTrue(b.mark(current))
        assertFalse(b.acknowledge(batch))
        val records = (Json.parse(disk.value!!) as Map<*, *>)["records"] as List<*>
        assertEquals(current.token, (records.single() as Map<*, *>)["token"])
    }

    @Test fun failedClearStaysVisibleAcrossAnotherSuccessfulTransactionAndRetriesOnlyItsToken() {
        val disk = Store(); val j = journal(disk); val a = record(j); val b = record(j)
        assertTrue(j.mark(a)); assertTrue(j.mark(b))
        disk.fail = true; assertFalse(j.clear(a))
        disk.fail = false; assertTrue(j.clear(b))
        assertEquals("writeFailed", j.status()["error"])
        assertTrue(j.retryStorage()); assertEquals("writeFailed", j.status()["error"])
        assertTrue(j.clear(a)); assertNull(j.status()["error"])
        assertEquals(emptyList<Any>(), (Json.parse(disk.value!!) as Map<*, *>)["records"])
    }

    @Test fun corruptionUnknownVersionAndReadFailureRequireRealRetry() {
        for (bad in listOf("{}", "{\"version\":2,\"records\":[]}", "{\"version\":1,\"records\":[{}]}")) {
            val disk = Store().apply { value = bad }; val j = journal(disk)
            assertEquals(PhoneTaskJournal.STORAGE_MESSAGE, j.refusal()); assertEquals("loadFailed", j.status()["error"])
            disk.value = null; assertFalse(j.load()) // Failed load is not silently reinterpreted by a getter.
            assertTrue(j.retryStorage()); assertNull(j.refusal())
        }
        var unavailable = true
        val j = PhoneTaskJournal({ if (unavailable) error("disk unavailable") else null }, { true }, processA)
        assertFalse(j.load()); unavailable = false; assertTrue(j.retryStorage())
    }

    @Test fun unchangedOwnerTokenDoesNotWriteTwiceAndLateClearCannotRemoveSuccessor() {
        val disk = Store(); val j = journal(disk); val first = record(j)
        assertTrue(j.mark(first)); assertTrue(j.mark(first)); assertEquals(1, disk.writes)
        assertTrue(j.clear(first)); val next = record(j); assertTrue(j.mark(next))
        assertTrue(j.clear(first))
        assertEquals(next.token, (((Json.parse(disk.value!!) as Map<*, *>)["records"] as List<*>).single() as Map<*, *>)["token"])
    }

    @Test fun recordBudgetIsJointAndUserAckFreesOldProcessRecords() {
        val disk = Store(); val a = journal(disk)
        repeat(256) { assertTrue(a.mark(record(a))) }
        assertFalse(a.mark(record(a)))
        val b = journal(disk, processB); b.load()
        assertEquals(256, b.status()["count"])
        assertTrue(b.acknowledge(b.status()["batchToken"] as String))
        assertTrue(b.mark(record(b)))
    }
}
