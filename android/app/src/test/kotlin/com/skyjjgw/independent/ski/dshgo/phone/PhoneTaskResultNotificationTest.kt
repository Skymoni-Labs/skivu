package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

/** Models NotificationManager's (tag, id) replacement rule using the production tag function.
 * Real PhoneTaskReturn supplies the blocked-start path and the notified receipt. No Android mocks. */
class PhoneTaskResultNotificationTest {
    private val posted = linkedMapOf<Pair<String, Int>, String>()
    private val replies = mutableListOf<Map<String, Any?>>()
    private var starts = 0

    private fun rejectedStart(taskId: Long, session: String, host: String? = null) {
        PhoneTaskReturn(
            current = { true },
            visible = { false },
            launch = { starts++; false },
            notify = {
                posted[NotificationGate.resultTag(taskId, session, host) to 4300] = session
                true
            },
            schedule = { _, _ -> error("A rejected start must fall back immediately") },
            clock = { 0L },
        ).start(closed = true, busy = false, reopen = true) { replies += it }
    }

    @Test fun twoBlockedModernTasksRetainBothNotificationsAndTheirDestinations() {
        rejectedStart(7, "session-a")
        rejectedStart(8, "session-b")
        assertEquals(2, starts)
        assertEquals(2, replies.size)
        assertTrue(replies.all { it["notified"] == true && it["opened"] == false && it["closed"] == true })
        assertEquals(2, posted.size)
        assertEquals("session-a", posted[NotificationGate.resultTag(7, "session-a", null) to 4300])
        assertEquals("session-b", posted[NotificationGate.resultTag(8, "session-b", null) to 4300])
    }

    @Test fun highLongBitsCannotCollideAndRepeatingOneTaskUpdatesOnlyThatTask() {
        val first = 7L
        val second = first + (1L shl 32)
        assertEquals(first.toInt(), second.toInt())
        rejectedStart(first, "session-a")
        rejectedStart(second, "session-b")
        rejectedStart(first, "session-a")
        assertEquals(2, posted.size)
        assertEquals("session-a", posted[NotificationGate.resultTag(first, "session-a", null) to 4300])
        assertEquals("session-b", posted[NotificationGate.resultTag(second, "session-b", null) to 4300])
        assertEquals(3, replies.size)
    }

    @Test fun reusedTaskNumberWithAnotherDestinationCannotReplaceOlderNotification() {
        rejectedStart(1, "old-session", "host-a")
        rejectedStart(1, "new-session", "host-a")
        rejectedStart(1, "new-session", "host-b")
        assertEquals(3, posted.size)
        assertEquals("old-session", posted[NotificationGate.resultTag(1, "old-session", "host-a") to 4300])
        assertEquals("new-session", posted[NotificationGate.resultTag(1, "new-session", "host-a") to 4300])
        assertEquals("new-session", posted[NotificationGate.resultTag(1, "new-session", "host-b") to 4300])
    }

    @Test fun nullableAndDelimiterContainingDestinationsHaveUnambiguousKeys() {
        val keys = listOf(
            NotificationGate.resultTag(1, null, ""),
            NotificationGate.resultTag(1, "", null),
            NotificationGate.resultTag(1, "a:b", "c"),
            NotificationGate.resultTag(1, "a", "b:c"),
            NotificationGate.resultTag(1, "😀", "host"),
        )
        assertEquals(keys.size, keys.toSet().size)
    }

    @Test fun singleTaskStillPostsOneSuccessfulNativeFallback() {
        rejectedStart(1, "legacy-session")
        assertEquals(1, posted.size)
        assertEquals("legacy-session", posted.values.single())
        assertEquals(true, replies.single()["notified"])
        assertEquals(false, replies.single()["launched"])
    }
}
