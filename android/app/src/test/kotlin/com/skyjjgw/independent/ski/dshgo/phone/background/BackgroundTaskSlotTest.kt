package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.PhoneTasks
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Actual resource table, real task lifetimes and physical I/O admission. */
class BackgroundTaskSlotTest {
    private fun begin(tasks: PhoneTasks) = (tasks.begin() as PhoneTasks.Begin.Go).owner
    private fun task(id: Long) = PhoneTasks(clock = { 100L }, idSource = { id })

    @Test fun repeatedOwnerValuesAndOrdinaryPauseKeepTheOriginalDriver() {
        val tasks = task(1L)
        val slot = BackgroundTaskSlot<Any, Any>(Any())
        val owner = begin(tasks); val peer = Any(); val driver = Any()
        val original = slot.acquire(owner, peer, 1, { tasks.isCurrent(owner) }) { driver }!!
        tasks.setPaused(true)
        tasks.setPaused(false)
        val again = begin(tasks)
        assertNotSame(owner, again)
        assertEquals(owner.lifecycle, again.lifecycle)
        assertSame(original, slot.acquire(again, peer, 1, { tasks.isCurrent(again) }) { error("must not construct") })
        assertSame(driver, slot.find(again)?.driver)
    }

    @Test fun anotherTaskOrNewLifecycleCannotDisplaceAnOccupiedResource() {
        val tasks = task(50L); val other = task(4L); val peer = Any()
        val slot = BackgroundTaskSlot<Any, Any>(Any())
        val owner = begin(tasks); val otherOwner = begin(other)
        val original = slot.acquire(owner, peer, 1, { tasks.isCurrent(owner) }) { Any() }!!
        assertNull(slot.acquire(otherOwner, peer, 1, { other.isCurrent(otherOwner) }) { error("no eviction") })
        tasks.invalidateOwners()
        val newLife = tasks.activeOwner()!!
        assertEquals(owner.taskId, newLife.taskId)
        assertNotEquals(owner.lifecycle, newLife.lifecycle)
        assertNull(slot.acquire(newLife, peer, 1, { tasks.isCurrent(newLife) }) { error("old resource remains") })
        assertSame(original, slot.seal(owner.taskId).singleOrNull())
        assertTrue(slot.complete(original))
        assertNotNull(slot.acquire(otherOwner, peer, 1, { other.isCurrent(otherOwner) }) { Any() })
    }

    @Test fun stopDuringConnectionPreventsTheDelayedRegistration() {
        val tasks = task(1L); val owner = begin(tasks); val peer = Any()
        val slot = BackgroundTaskSlot<Any, Any>(Any())
        val connecting = CountDownLatch(1); val connected = CountDownLatch(1)
        val pool = Executors.newSingleThreadExecutor()
        try {
            val call = pool.submit<BackgroundTaskSlot.TaskResource<Any, Any>?> {
                connecting.countDown(); check(connected.await(5, TimeUnit.SECONDS))
                slot.acquire(owner, peer, 1, { tasks.isCurrent(owner) }) { error("stopped setup must not publish") }
            }
            assertTrue(connecting.await(5, TimeUnit.SECONDS))
            tasks.stop("stop")
            assertTrue(slot.seal(owner.taskId).isEmpty())
            connected.countDown()
            assertNull(call.get(5, TimeUnit.SECONDS))
            assertFalse(slot.occupied)
        } finally { connected.countDown(); pool.shutdownNow() }
    }

    @Test fun stopDuringConstructionSealsThePublishedOriginalAfterTheSameMonitor() {
        val tasks = task(1L); val owner = begin(tasks); val peer = Any()
        val lock = Any(); val slot = BackgroundTaskSlot<Any, Any>(lock)
        val constructing = CountDownLatch(1); val finish = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        try {
            val acquire = pool.submit<BackgroundTaskSlot.TaskResource<Any, Any>?> {
                slot.acquire(owner, peer, 1, { tasks.isCurrent(owner) }) {
                    constructing.countDown(); check(finish.await(5, TimeUnit.SECONDS)); Any()
                }
            }
            assertTrue(constructing.await(5, TimeUnit.SECONDS))
            tasks.stop("stop")
            val cleanup = pool.submit<BackgroundTaskSlot.TaskResource<Any, Any>?> {
                slot.seal(owner.taskId).singleOrNull()
            }
            finish.countDown()
            val original = acquire.get(5, TimeUnit.SECONDS)!!
            assertSame(original, cleanup.get(5, TimeUnit.SECONDS))
            assertNull(slot.find(owner))
            assertTrue(slot.occupied)
            assertTrue(slot.complete(original))
        } finally { finish.countDown(); pool.shutdownNow() }
    }

    @Test fun cancelledOwnerAndUnknownPhysicalReleaseKeepTheOriginalSlotUntilRetry() {
        val tasks = task(1L); val owner = begin(tasks); val peer = Any()
        val slot = BackgroundTaskSlot<BackgroundDisplayIo<Any>, Any>(Any())
        val original = slot.acquire(owner, peer, 1, { tasks.isCurrent(owner) }) { BackgroundDisplayIo() }!!
        val io = original.driver
        io.call { io.startResource(peer, { beforeSend -> beforeSend(); true }) { it } }
        tasks.stop("stop")
        assertSame(original, slot.seal(owner.taskId).singleOrNull())
        io.seal()
        assertFalse(io.release { assertSame(peer, it); false })
        assertTrue(slot.occupied)
        assertFalse(slot.current(original))
        assertNull(slot.find(owner))
        val other = task(8L); val otherOwner = begin(other)
        assertNull(slot.acquire(otherOwner, peer, 1, { other.isCurrent(otherOwner) }) { error("unknown retains slot") })
        assertTrue(io.release { assertSame(peer, it); true })
        assertTrue(slot.complete(original))
        assertFalse(slot.occupied)
    }

    @Test fun aLateCleanupCommitOrPreviewCannotTargetTheSuccessorRecord() {
        val slot = BackgroundTaskSlot<Any, Any>(Any()); val peer = Any()
        val first = task(1L); val a = begin(first)
        val old = slot.acquire(a, peer, 1, { first.isCurrent(a) }) { Any() }!!
        assertSame(old, slot.seal(a.taskId).singleOrNull())
        assertTrue(slot.complete(old))
        val second = task(2L); val b = begin(second)
        val next = slot.acquire(b, peer, 1, { second.isCurrent(b) }) { Any() }!!
        assertFalse(slot.complete(old))
        assertFalse(slot.current(old))
        assertTrue(slot.seal(a.taskId).isEmpty())
        assertSame(next, slot.find(b))
        assertTrue(slot.current(next))
    }

    @Test fun threeOriginalsShareOnePeerAndARepeatedOwnerDoesNotConsumeAnotherSlot() {
        val slot = BackgroundTaskSlot<Any, Any>(Any()); val peer = Any()
        val tasks = (1L..4L).map(::task)
        val owners = tasks.map(::begin)
        val records = (0..2).map { i ->
            slot.acquire(owners[i], peer, 3, { tasks[i].isCurrent(owners[i]) }) { Any() }!!
        }
        assertSame(peer, slot.boundPeer)
        assertEquals(3, records.map { it.driver }.toSet().size)
        assertSame(records[1], slot.acquire(owners[1], peer, 3, { true }) { error("same owner") })
        assertNull(slot.acquire(owners[3], peer, 3, { true }) { error("hard capacity") })
        assertSame(records[1], slot.seal(owners[1].taskId).singleOrNull())
        assertTrue(slot.complete(records[1]))
        assertTrue(slot.current(records[0])); assertTrue(slot.current(records[2]))
        assertNotNull(slot.acquire(owners[3], peer, 3, { true }) { Any() })
    }

    @Test fun aDifferentPeerCannotEnterUntilEveryOriginalRecordHasCleared() {
        val slot = BackgroundTaskSlot<Any, Any>(Any()); val peer = Any(); val nextPeer = Any()
        val aTasks = task(1L); val bTasks = task(2L); val cTasks = task(3L)
        val a = begin(aTasks); val b = begin(bTasks); val c = begin(cTasks)
        val first = slot.acquire(a, peer, 3, { true }) { Any() }!!
        val second = slot.acquire(b, peer, 3, { true }) { Any() }!!
        assertNull(slot.acquire(a, nextPeer, 3, { true }) { error("must not retarget an owner") })
        assertNull(slot.acquire(c, nextPeer, 3, { true }) { error("different peer with free capacity") })
        assertSame(first, slot.seal(a.taskId).singleOrNull())
        assertTrue(slot.complete(first))
        assertSame(peer, slot.boundPeer)
        assertNull(slot.acquire(c, nextPeer, 3, { true }) { error("one original still retained") })
        assertSame(second, slot.seal(b.taskId).singleOrNull())
        assertTrue(slot.complete(second))
        assertNull(slot.boundPeer)
        assertNotNull(slot.acquire(c, nextPeer, 3, { true }) { Any() })
        assertSame(nextPeer, slot.boundPeer)
    }

    @Test fun aNewLifecycleCannotUseSpareCapacityToBypassItsUnclearedOriginal() {
        val slot = BackgroundTaskSlot<Any, Any>(Any()); val peer = Any()
        val tasks = task(1L); val owner = begin(tasks)
        val original = slot.acquire(owner, peer, 3, { tasks.isCurrent(owner) }) { Any() }!!
        tasks.invalidateOwners()
        val current = tasks.activeOwner()!!
        assertTrue(tasks.isCurrent(current))
        assertNotEquals(owner.lifecycle, current.lifecycle)
        assertNull(slot.acquire(current, peer, 3, { tasks.isCurrent(current) }) { error("same task still retained") })
        assertSame(original, slot.seal(current.taskId).singleOrNull())
        assertFalse(slot.current(original))
        assertTrue(slot.complete(original))
        assertNotNull(slot.acquire(current, peer, 3, { tasks.isCurrent(current) }) { Any() })
    }

    @Test fun batchSealRetainsEachFailedOriginalWithoutRetainingACompletedSibling() {
        val slot = BackgroundTaskSlot<BackgroundDisplayIo<Any>, Any>(Any()); val peer = Any()
        val aTasks = task(1L); val bTasks = task(2L)
        val a = begin(aTasks); val b = begin(bTasks)
        val first = slot.acquire(a, peer, 3, { true }) { BackgroundDisplayIo() }!!
        val second = slot.acquire(b, peer, 3, { true }) { BackgroundDisplayIo() }!!
        first.driver.call { first.driver.startResource(peer, { commit -> commit(); true }) { it } }
        second.driver.call { second.driver.startResource(peer, { commit -> commit(); true }) { it } }
        val originals = slot.seal()
        assertEquals(listOf(first, second), originals)
        first.driver.seal(); second.driver.seal()
        assertFalse(first.driver.release { assertSame(peer, it); false })
        assertTrue(second.driver.release { assertSame(peer, it); true })
        assertTrue(slot.complete(second))
        assertEquals(listOf(first), slot.cleanupCandidates())
        assertTrue(slot.occupied)
        assertFalse(slot.current(first)); assertFalse(slot.current(second))
        assertSame(peer, slot.boundPeer)
        assertTrue(first.driver.release { assertSame(peer, it); true })
        assertTrue(slot.complete(first))
        assertFalse(slot.occupied)
        assertNull(slot.boundPeer)
    }
}
