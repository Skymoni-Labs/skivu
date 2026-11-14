package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class TreeTransactionsTest {
    @Test fun secondConnectionCannotStartBeforeLastLiveNodeAndClose() {
        val first = Any(); val second = Any(); val live = CountDownLatch(1); val finish = CountDownLatch(1)
        val attempted = CountDownLatch(1); val madeSecond = CountDownLatch(1)
        val order = java.util.Collections.synchronizedList(mutableListOf<String>())
        val gate = TreeTransactions<Any> { order += if (it === first) "close A" else "close B"; true }
        val pool = Executors.newFixedThreadPool(2)
        try {
            val a = pool.submit { gate.read(first, { first }) {
                live.countDown(); assertTrue(finish.await(5, TimeUnit.SECONDS)); order += "recycle A"
            } }
            assertTrue(live.await(5, TimeUnit.SECONDS))
            val b = pool.submit { attempted.countDown(); gate.read(second, {
                order += "open B"; madeSecond.countDown(); second
            }) { order += "node B" } }
            assertTrue(attempted.await(5, TimeUnit.SECONDS)); assertEquals(1L, madeSecond.count)
            finish.countDown(); a.get(5, TimeUnit.SECONDS); b.get(5, TimeUnit.SECONDS)
            assertEquals(listOf("recycle A", "close A", "open B", "node B", "close B"), order)
        } finally { finish.countDown(); pool.shutdownNow() }
    }

    @Test fun unregisterUnknownKeepsOriginalClientAndOnlyItsOwnerCanCloseIt() {
        val owner = Any(); val other = Any(); val client = Any()
        var canClose = false; val attempted = mutableListOf<Any>()
        val registration = TreeRegistration<Any> { attempted += it; check(canClose) }
        val gate = TreeTransactions<TreeRegistration<Any>> { it.close { it.unregister() } }
        try { gate.read(owner, { registration }) { it.register(client) {}; "accepted input" }; fail() }
        catch (_: TreeTransactions.CleanupPending) { }
        assertFalse(gate.ready()); assertEquals(listOf(client), attempted)
        assertTrue(gate.closeOwned(other)); assertEquals(1, attempted.size)
        var newClient = false
        try { gate.read(other, { newClient = true; registration }) {}; fail() }
        catch (_: TreeTransactions.CleanupPending) { }
        assertFalse(newClient)
        canClose = true; assertTrue(gate.closeOwned(owner)); assertTrue(gate.ready())
        assertEquals(listOf(client, client), attempted)
    }

}
