package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class OwnerScopeIoTest {
    @Test fun exactRefusalDischargesOnlyAfterTheActualFirstCallReturns() {
        val io = BackgroundDisplayIo<Any>(); val peer = Any()
        val reply = CountDownLatch(1); val leave = CountDownLatch(1); val pool = Executors.newSingleThreadExecutor()
        var releases = 0
        try {
            val call = pool.submit { io.call {
                io.startResource(peer, { beforeSend -> beforeSend(); false }) { it }
                reply.countDown(); check(leave.await(5, TimeUnit.SECONDS))
            } }
            assertTrue(reply.await(5, TimeUnit.SECONDS)); assertSame(peer, io.peer())
            assertFalse(io.release { releases++; true }); assertEquals(0, releases)
            leave.countDown(); call.get(5, TimeUnit.SECONDS)
            assertTrue(io.wasNotAdmitted()); assertNull(io.peer())
            assertTrue(io.release { releases++; true }); assertEquals(0, releases)
        } finally { leave.countDown(); pool.shutdownNow(); io.seal() }
    }

    @Test fun lostReplyKeepsOriginalPeerAndCannotLaterImportAFalseFirstReceipt() {
        val io = BackgroundDisplayIo<Any>(); val peer = Any()
        try { io.call { io.startResource<Unit>(peer, { beforeSend -> beforeSend(); throw IllegalStateException("lost reply") }) { false } }; fail() }
        catch (_: IllegalStateException) { }
        assertSame(peer, io.peer()); assertFalse(io.wasNotAdmitted())
        var sentAgain = false
        try { io.call { io.startResource(peer, { beforeSend -> beforeSend(); sentAgain = true; false }) { it } }; fail() }
        catch (_: IllegalStateException) { }
        assertFalse(sentAgain)
        assertTrue(io.release { assertSame(peer, it); true })
    }

    @Test fun contradictoryWrongOwnerAndMissingEnvelopesNeverProveUnused() {
        val owner = "original"
        assertEquals(false, OwnerScopeReply.first(owner, 1, owner, false, false))
        assertEquals(true, OwnerScopeReply.first(owner, 1, owner, true, false))
        for (version in listOf(null, 1L, "1", 2)) assertNull(OwnerScopeReply.first(owner, version, owner, false, false))
        assertNull(OwnerScopeReply.first(owner, 1, "other", false, false))
        assertNull(OwnerScopeReply.first(owner, 1, owner, false, true))
        assertNull(OwnerScopeReply.first(owner, 1, owner, null, false))
        assertNull(OwnerScopeReply.first(owner, 1, owner, false, null))
        val io = BackgroundDisplayIo<Any>(); val peer = Any()
        io.call { io.startResource(peer, { beforeSend -> beforeSend(); "bad response" }) { null } }
        assertFalse(io.wasNotAdmitted()); assertSame(peer, io.peer())
        assertTrue(io.release { assertSame(peer, it); true })
    }
}
