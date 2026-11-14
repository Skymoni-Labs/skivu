package com.skyjjgw.independent.ski.dshgo.phone.background

import android.os.Bundle
import com.skyjjgw.independent.ski.dshgo.phone.PhoneAppIdentity
import com.skyjjgw.independent.ski.dshgo.phone.PhoneAction
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundDisplayTest {
    @Test fun inputWaitingForChannelCapacityIsFencedByPauseStopAndSealAtAdmission() {
        val display = BackgroundDisplay(
            mayUse = { true },
            admitUse = { action -> action(); true },
            channelProvider = { error("the test owns the actual channel admission") },
        )
        val peer = object : PrivilegedChannel {
            override val backgroundLimit = 1
            override fun execute(request: Bundle, beforeSend: () -> Unit): Bundle = error("not used")
            override fun alive() = true
            override fun close() {}
        }
        @Suppress("UNCHECKED_CAST")
        val io = BackgroundDisplay::class.java.getDeclaredField("resourceIo")
            .apply { isAccessible = true }.get(display) as BackgroundDisplayIo<PrivilegedChannel>
        io.call { io.startResource(peer, { commit -> commit() }) { true } } // The opened resource's pin.
        val calls = PrivilegedCalls(); val sent = AtomicInteger(); val running = AtomicBoolean(true)
        val pool = Executors.newCachedThreadPool()
        // Another channel use (e.g. a shared-channel grant) holds the only slot while this input queues.
        fun queued(meanwhile: () -> Unit): Future<String?> {
            val holding = CountDownLatch(1); val release = CountDownLatch(1); val waiting = CountDownLatch(1)
            pool.submit { calls.execute { holding.countDown(); release.await() } }
            assertTrue(holding.await(3, TimeUnit.SECONDS))
            val input = pool.submit<String?> {
                display.dispatch({ running.get() }) { beforeSend ->
                    waiting.countDown()
                    calls.execute(beforeSend = beforeSend) { sent.incrementAndGet(); "reply" }
                }
            }
            assertTrue(waiting.await(3, TimeUnit.SECONDS)); meanwhile(); release.countDown()
            return input
        }
        try {
            assertEquals("reply", queued {}.get(3, TimeUnit.SECONDS)); assertEquals(1, sent.get())
            // Paused or stopped after the IO body's own check: nothing is sent, reported as not allowed.
            assertNull(queued { running.set(false) }.get(3, TimeUnit.SECONDS)); running.set(true)
            // Sealed after the IO body's own check: the resource refuses before any transport write.
            val sealed = assertThrows(ExecutionException::class.java) { queued { display.seal() }.get(3, TimeUnit.SECONDS) }
            assertTrue(sealed.cause is IllegalStateException)
            assertEquals(1, sent.get()); assertEquals("next", calls.execute { "next" })
        } finally { calls.retire(); pool.shutdownNow() }
    }

    @Test fun aFailedObservationReportsItsReasonAndInvalidatesOldElementNumbers() {
        for (code in listOf("treeUnavailable", "displayTargetChanged", "displayMissing", "systemOperationDenied")) {
            val display = withLastElement()
            assertNotNull(display.target("b7", 1))

            val failure = assertThrows(IllegalStateException::class.java) {
                display.requireObservation(false, code, null)
            }

            assertEquals(Reasons.of(code), failure.message)
            assertNull(display.target("b7", 1))
            assertNull(display.target("b8", 1))
        }
    }

    @Test fun aFailedObservationPreservesTheExistingExceptionTypeDetail() {
        val display = withLastElement()

        val failure = assertThrows(IllegalStateException::class.java) {
            display.requireObservation(false, "deviceUnavailable", "IllegalAccessException")
        }

        assertEquals(Reasons.of("deviceUnavailable", "IllegalAccessException"), failure.message)
        assertNull(display.target("b7", 1))
    }

    @Test fun aSuccessfulObservationMayProceedToDecodeItsSnapshot() {
        val display = withLastElement()

        display.requireObservation(true, null, null)

        // The decoder, not this response guard, replaces successful snapshots.
        assertNotNull(display.target("b7", 1))
    }

    @Test fun unnumberedScrollRejectsAnOldOrInvalidatedSnapshotBeforeOpeningAChannel() {
        val display = withLastElement()
        BackgroundDisplay::class.java.getDeclaredField("currentTarget").apply {
            isAccessible = true
            set(display, PhoneAppIdentity("example.opened", 10123))
        }
        fun assertStale(screenId: String) {
            val result = display.perform(PhoneAction.Scroll(screenId, null, PhoneAction.Direction.DOWN))
            assertFalse(result.ok)
            assertEquals(Reasons.of("staleSnapshot"), result.message)
            org.junit.Assert.assertTrue(result.staleSnapshot)
        }
        assertStale("b6")
        assertThrows(IllegalStateException::class.java) {
            display.requireObservation(false, "treeUnavailable", null)
        }
        assertStale("b7")
    }

    @Test fun collectRejectsAnOldOrInvalidatedScreenBeforeItsFirstObservation() {
        val display = withLastElement()
        BackgroundDisplay::class.java.getDeclaredField("currentTarget").apply {
            isAccessible = true
            set(display, PhoneAppIdentity("example.opened", 10123))
        }
        fun assertStale(id: String) {
            val error = assertThrows(IllegalStateException::class.java) {
                display.collect(id, 1, 2, null)
            }
            assertEquals(Reasons.of("staleSnapshot"), error.message)
        }
        assertStale("b6")
        assertNotNull(display.target("b7", 1))
        assertThrows(IllegalStateException::class.java) {
            display.requireObservation(false, "treeUnavailable", null)
        }
        assertStale("b7")
    }

    @Test fun onePageCollectUsesOnlyTheSelectedScrollableSubtree() {
        val display = withLists()
        val left = display.collect("b7", 2, 1, "right")
        assertEquals(listOf("left", "nested"), left.items)
        assertEquals(1, left.pages)
        assertEquals("pageLimit", left.stopReason)
        assertNull(left.screen)
        assertEquals("untilMatched", display.collect("b7", 2, 1, "nested").stopReason)
        assertEquals(listOf("right"), display.collect("b7", 6, 1, null).items)
        assertNotNull(display.target("b7", 6))
        val empty = display.collect("b7", 9, 1, null)
        assertEquals(emptyList<String>(), empty.items)
        assertEquals(1, empty.pages)
        assertEquals("pageLimit", empty.stopReason)
    }

    @Test fun onePageCollectRejectsMissingAndNonScrollableTargets() {
        val display = withLists()
        for ((id, reason) in listOf(0 to "elementMissing", 99 to "elementMissing", 1 to "inputRejected", 8 to "inputRejected")) {
            val error = assertThrows(IllegalStateException::class.java) { display.collect("b7", id, 1, null) }
            assertEquals(Reasons.of(reason), error.message)
        }
        val stale = assertThrows(IllegalStateException::class.java) { display.collect("b6", 2, 1, null) }
        assertEquals(Reasons.of("staleSnapshot"), stale.message)
        assertNotNull(display.target("b7", 2))
    }

    private fun withLists(): BackgroundDisplay {
        val display = withLastElement()
        BackgroundDisplay::class.java.getDeclaredField("currentTarget").apply {
            isAccessible = true
            set(display, PhoneAppIdentity("example.opened", 10123))
        }
        val elements = listOf(
            Element(1, "文本", "header", Region.MIDDLE),
            Element(2, "列表", "", Region.MIDDLE, isScrollable = true),
            Element(3, "文本", "left", Region.MIDDLE, indent = 1),
            Element(4, "列表", "left", Region.MIDDLE, indent = 1, isScrollable = true),
            Element(5, "文本", "nested", Region.MIDDLE, indent = 2),
            Element(6, "列表", "", Region.MIDDLE, isScrollable = true),
            Element(7, "文本", "right", Region.MIDDLE, indent = 1),
            Element(8, "列表", "not scrollable", Region.MIDDLE),
            Element(9, "文本", "", Region.MIDDLE, isScrollable = true),
        )
        BackgroundDisplay::class.java.getDeclaredField("lastElements").apply {
            isAccessible = true
            set(display, elements)
        }
        return display
    }

    private fun withLastElement(): BackgroundDisplay {
        val display = BackgroundDisplay(
            mayUse = { true },
            admitUse = { action -> action(); true },
            channelProvider = { error("response validation must not start a connection") },
        )
        BackgroundDisplay::class.java.getDeclaredField("targetReady").apply { isAccessible = true; setBoolean(display, true) }
        BackgroundDisplay::class.java.getDeclaredField("lastScreenId").apply {
            isAccessible = true
            set(display, "b7")
        }
        BackgroundDisplay::class.java.getDeclaredField("lastElements").apply {
            isAccessible = true
            set(display, listOf(Element(1, "按钮", "确定", Region.MIDDLE)))
        }
        return display
    }

    @Test fun onlyBackIsSentToTheBackgroundScreen() {
        val display = BackgroundDisplay(
            mayUse = { true },
            admitUse = { action -> action(); true },
            channelProvider = { error("a refused key must not reach the privileged channel") },
        )
        BackgroundDisplay::class.java.getDeclaredField("targetReady").apply { isAccessible = true; setBoolean(display, true) }
        // An app is open on the background screen (set directly: opening one needs the channel).
        BackgroundDisplay::class.java.getDeclaredField("currentTarget").apply {
            isAccessible = true
            set(display, PhoneAppIdentity("example.opened", 10123))
        }

        for (key in PhoneAction.GlobalKey.entries - PhoneAction.GlobalKey.BACK) {
            val result = display.perform(PhoneAction.Key("b1", key))
            assertFalse(key.name, result.ok)
            assertEquals("后台屏不支持该系统键，未执行；请用返回或打开指定应用", result.message)
        }
    }
}
