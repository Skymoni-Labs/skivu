package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.Executor

class PhoneSwitchDispatchTest {
    @Test fun disableRunsBeforeBlockedBackgroundWorkAndCleanupPrecedesLaterEnable() {
        val controls = ArrayDeque<Runnable>()
        val background = ArrayDeque<Runnable>()
        val calls = mutableListOf<String>()
        var completed: Result<Boolean>? = null
        background.addLast(Runnable { calls.add("older-background") })
        dispatchPhoneDisable(Executor { controls.addLast(it) }, Executor { background.addLast(it) }, {
            calls.add("disable"); true
        }, {
            calls.add("cleanup"); true
        }) { completed = it }
        background.addLast(Runnable { calls.add("later-enable") })

        controls.removeFirst().run()
        assertEquals(listOf("disable"), calls)
        assertNull(completed)
        background.removeFirst().run()
        assertNull(completed)
        background.removeFirst().run()
        assertEquals(true, completed!!.getOrThrow())
        background.removeFirst().run()
        assertEquals(listOf("disable", "older-background", "cleanup", "later-enable"), calls)
    }

    @Test fun failureCompletesTheRequestWithoutBlockingLaterBackgroundWork() {
        for (failDisable in listOf(true, false)) {
            val controls = ArrayDeque<Runnable>()
            val background = ArrayDeque<Runnable>()
            val failure = IllegalStateException("fixture failure")
            var completed: Result<Boolean>? = null
            var cleaned = false
            var later = false
            dispatchPhoneDisable(Executor { controls.addLast(it) }, Executor { background.addLast(it) }, {
                if (failDisable) throw failure
                true
            }, {
                cleaned = true
                throw failure
            }) { completed = it }
            background.addLast(Runnable { later = true })
            controls.removeFirst().run()
            assertNull(completed)
            background.removeFirst().run()
            assertSame(failure, completed!!.exceptionOrNull())
            assertEquals(!failDisable, cleaned)
            background.removeFirst().run()
            assertTrue(later)
            assertTrue(controls.isEmpty())
            assertTrue(background.isEmpty())
        }
    }
}
