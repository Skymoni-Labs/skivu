package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

class FocusObservationTest {
    @Test fun WholeScreenRefusalDoesNotCarryTheHiddenInputIntoItsCopy() {
        var policy = PhonePolicies(denyPackages = listOf("example.app"))
        val gate = SafetyGate({ policy }, PhoneTasks(), { null })
        val focus = FocusObservation(3)
        val source = ScreenSnapshot("s1", "[3] 输入框 Search", "App", "example.app", focus = focus)
        val refused = gate.filterScreen(source)
        assertEquals("s1", refused.id)
        assertNull(refused.focus)
        policy = policy.copy(denyPackages = emptyList())
        assertNull(gate.filterScreen(refused).focus) // Re-enabling reads does not recreate omitted evidence.
        assertNull(gate.filterScreen(source.copy(secure = true)).focus)
    }

    @Test fun RemovingOnlyTheImageKeepsTheInputActuallyPresentInTheText() {
        val gate = SafetyGate({ PhonePolicies(denyPackages = emptyList()) }, PhoneTasks(), { null })
        val focus = FocusObservation(3)
        val source = ScreenSnapshot("s1", "[3] 输入框 Search\n«银行卡已遮盖»", "App", "example.app",
            image = byteArrayOf(1), imageMime = "image/png", focus = focus)
        val shown = gate.filterScreen(source)
        assertNotSame(source, shown)
        assertNull(shown.image)
        assertSame(focus, shown.focus)
        assertTrue(shown.text.startsWith(source.text))
    }

    @Test fun ANewReplyCannotReplaceTheTicketOfAnOldUncommittedObservation() {
        val focus = FocusObservation(3)
        val old = PhoneReplyCommit()
        val replacement = PhoneReplyCommit()
        assertTrue(focus.bind(old))
        assertFalse(focus.bind(replacement))
        val output = ToolOutput("new output").also { it.nativeReplyCommit = replacement }
        val server = McpServer(emptyList(), { _, _, _ -> output })
        val work = PhoneCallWork({ server.runCall(1L, "screen", emptyMap(), null,
            nativeReplyCommit = replacement) }, nativeReplyCommit = replacement)
        assertNotNull(work.run())
        assertTrue(replacement.committed)
        assertFalse(focus.committed)
        assertFalse(focus.bind(replacement))
    }
}
