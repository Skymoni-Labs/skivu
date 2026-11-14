package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

class PhoneNativeReplyCommitTest {
    @Test fun encodingAloneNeverCommitsButNormalWinnerDoes() {
        val ticket = PhoneReplyCommit()
        val out = ToolOutput("screen").also { it.nativeReplyCommit = ticket }
        val server = McpServer(emptyList(), { _, _, _ -> out })
        val work = PhoneCallWork({
            server.runCall(1, "screen", emptyMap(), null, nativeReplyCommit = ticket).also {
                assertFalse(ticket.committed)
            }
        }, { 1L }, { "timeout" }, ticket)
        assertTrue(work.run()!!.contains("screen"))
        assertTrue(ticket.committed)
        assertNull(work.expire())
    }

    @Test fun timerWinnerDiscardsLaterEncodedResultWithoutGrantingItsTicket() {
        val ticket = PhoneReplyCommit()
        val out = ToolOutput("screen").also { it.nativeReplyCommit = ticket }
        val server = McpServer(emptyList(), { _, _, _ -> out })
        val work = PhoneCallWork({ server.runCall(1, "screen", emptyMap(), null,
            nativeReplyCommit = ticket) }, { 0L }, { "timeout" }, ticket)
        assertEquals("timeout", work.expire())
        assertNull(work.run())
        assertFalse(ticket.committed)
    }

    @Test fun encodingCanFinishAfterDeadlineWithoutTimerRunning() {
        var remaining = 1L
        val ticket = PhoneReplyCommit()
        val out = ToolOutput("screen").also { it.nativeReplyCommit = ticket }
        val server = McpServer(emptyList(), { _, _, _ -> out })
        val work = PhoneCallWork({ server.runCall(1, "screen", emptyMap(), null,
            nativeReplyCommit = ticket).also { remaining = 0L } }, { remaining }, { "timeout" }, ticket)
        assertEquals("timeout", work.run())
        assertFalse(ticket.committed)
    }

    @Test fun actualJsonEncodingExceptionCannotCommit() {
        val ticket = PhoneReplyCommit()
        val out = ToolOutput("screen").also { it.nativeReplyCommit = ticket }
        val server = McpServer(emptyList(), { _, _, _ -> out })
        val badId = object { override fun toString(): String = throw IllegalStateException("encode") }
        val work = PhoneCallWork({ server.runCall(badId, "screen", emptyMap(), null,
            nativeReplyCommit = ticket) }, { 1L }, { "timeout" }, ticket)
        try { work.run(); fail("encoding must throw") }
        catch (expected: IllegalStateException) { assertEquals("encode", expected.message) }
        assertFalse(ticket.committed)
    }

    @Test fun handlerFinallyExceptionEncodesOnlyTheErrorWithoutOriginalTicket() {
        val ticket = PhoneReplyCommit()
        val out = ToolOutput("screen").also { it.nativeReplyCommit = ticket }
        val server = McpServer(emptyList(), { _, _, _ ->
            try { out } finally { throw IllegalStateException("tail") }
        })
        val work = PhoneCallWork({ server.runCall(1, "screen", emptyMap(), null,
            nativeReplyCommit = ticket) }, { 1L }, { "timeout" }, ticket)
        assertTrue(work.run()!!.contains("tail"))
        assertFalse(ticket.committed)
    }

    @Test fun reusedOutputCannotCommitAnEarlierTimedOutCallsTicket() {
        val first = PhoneReplyCommit()
        val reused = ToolOutput("screen").also { it.nativeReplyCommit = first }
        val server = McpServer(emptyList(), { _, _, _ -> reused })
        val old = PhoneCallWork({ server.runCall(1, "screen", emptyMap(), null,
            nativeReplyCommit = first) }, { 0L }, { "timeout" }, first)
        assertEquals("timeout", old.run())
        val second = PhoneReplyCommit()
        val next = PhoneCallWork({ server.runCall(2, "screen", emptyMap(), null,
            nativeReplyCommit = second) }, { 1L }, { "timeout" }, second)
        assertNotNull(next.run())
        assertFalse(first.committed)
        assertFalse(second.committed)
    }
    @Test fun expirationBetweenEncodingAndNormalCommitWins() {
        var remaining = 1L
        val ticket = PhoneReplyCommit()
        val out = ToolOutput("screen").also { it.nativeReplyCommit = ticket }
        val server = McpServer(emptyList(), { _, _, _ -> out })
        lateinit var work: PhoneCallWork
        work = PhoneCallWork({
            val line = server.runCall(1, "screen", emptyMap(), null, nativeReplyCommit = ticket)
            remaining = 0L
            assertEquals("timeout", work.expire())
            line
        }, { remaining }, { "timeout" }, ticket)
        assertNull(work.run())
        assertFalse(ticket.committed)
    }

    @Test fun throwingExistingDeadlineCallbackCannotCommit() {
        val ticket = PhoneReplyCommit()
        val out = ToolOutput("screen").also { it.nativeReplyCommit = ticket }
        val server = McpServer(emptyList(), { _, _, _ -> out })
        val work = PhoneCallWork({ server.runCall(1, "screen", emptyMap(), null,
            nativeReplyCommit = ticket) }, { throw IllegalStateException("deadline") }, { "timeout" }, ticket)
        try { work.run(); fail("deadline callback must throw") }
        catch (expected: IllegalStateException) { assertEquals("deadline", expected.message) }
        assertFalse(ticket.committed)
    }

    @Test fun parsedCallUsesTheSameTicketThroughRealReplyEncoding() {
        val ticket = PhoneReplyCommit()
        val server = McpServer(emptyList(), { _, _, _ -> error("explicit native handler required") })
        val call = server.dispatch("""{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"screen","arguments":{}}}""") as McpServer.Dispatch.Call
        val work = PhoneCallWork({ call.runWithCommit(ticket) { name, args, _ ->
            assertEquals("screen", name)
            assertTrue(args.isEmpty())
            assertFalse(ticket.committed)
            ToolOutput("original observation").also { it.nativeReplyCommit = ticket }
        } }, { 1L }, { "timeout" }, ticket)
        val reply = Json.parse(checkNotNull(work.run())) as Map<*, *>
        assertEquals(17L, reply["id"])
        assertTrue(reply.containsKey("result"))
        assertTrue(ticket.committed)
    }

    @Test fun synchronousConvenienceReplyDoesNotAcquireNativeCommitAuthority() {
        val ticket = PhoneReplyCommit()
        val server = McpServer(emptyList(), { _, _, _ ->
            ToolOutput("observation").also { it.nativeReplyCommit = ticket }
        })
        assertNotNull(server.handle("""{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"screen","arguments":{}}}"""))
        assertFalse(ticket.committed)
    }
}
