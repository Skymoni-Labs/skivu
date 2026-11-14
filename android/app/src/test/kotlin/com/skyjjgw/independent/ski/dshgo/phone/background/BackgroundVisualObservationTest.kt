package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.a11y.ImageGeometry
import com.skyjjgw.independent.ski.dshgo.phone.a11y.ImageObservation
import com.skyjjgw.independent.ski.dshgo.phone.a11y.VisualFrame
import org.junit.Assert.*
import org.junit.Test

class BackgroundVisualObservationTest {
    private val display = Any()
    private val scope = BackgroundVisualObservation.Scope(display, "task", "example.app",
        BackgroundVisualObservation.Window(7, 0, 0, 720, 1600))

    private fun image(at: Long = 100, color: Int = 0xff303030.toInt(), width: Int = 48) =
        ImageObservation(ImageGeometry(0, 0, 1f, 1f, width, 48), at,
            VisualFrame.capture(width, 48) { _, row -> row.fill(color) })
    private fun observation(scope: BackgroundVisualObservation.Scope = this.scope,
        frame: ImageObservation = image(), now: Long = frame.capturedUptimeMs) =
        BackgroundVisualObservation.create(scope, frame, true, false, false, now)!!

    @Test fun equalAndChangedFramesProduceOnlyTheFixedSummary() {
        val before = observation()
        assertEquals("unchanged", observation(frame = image(at = 200)).changeFrom(before, 200))
        assertEquals("changed", observation(frame = image(at = 200, color = 0xffdddddd.toInt())).changeFrom(before, 200))
        assertEquals("unavailable", observation().changeFrom(null, 100))
    }

    @Test fun numericDisplayReuseAndEveryIdentityDimensionInvalidateComparison() {
        val before = observation()
        val alternatives = listOf(
            scope.copy(display = Any()), scope.copy(owner = "another-owner"), scope.copy(pkg = "other.app"),
            scope.copy(window = scope.window.copy(id = 8)),
            scope.copy(window = scope.window.copy(left = 1)), scope.copy(window = scope.window.copy(bottom = 1599)),
        )
        for (other in alternatives) assertEquals("unavailable", observation(other, image(200)).changeFrom(before, 200))
    }

    @Test fun expiryAndBackwardTimeCannotReuseThePreviousObservation() {
        val before = observation()
        assertEquals("unchanged", observation(frame = image(30_100)).changeFrom(before, 30_100))
        assertEquals("unavailable", observation(frame = image(30_101)).changeFrom(before, 30_101))
        assertEquals("unavailable", observation(frame = image(99)).changeFrom(before, 100))
        assertEquals("unavailable", observation(frame = image(101)).changeFrom(before, 100))
    }

    @Test fun viewportChangeAndPostFrameExpiryDoNotBecomeChanged() {
        val before = observation()
        assertEquals("unavailable", observation(frame = image(at = 200, width = 96)).changeFrom(before, 200))
        assertEquals("unavailable", observation(frame = image(200)).changeFrom(before, 30_201))
    }

    @Test fun missingOrPrivateFramesCannotCreateRetainedObservation() {
        assertNull(BackgroundVisualObservation.create(scope, null, true, false, false, 100))
        assertNull(BackgroundVisualObservation.create(null, image(), true, false, false, 100))
        assertNull(BackgroundVisualObservation.create(scope, image(), false, false, false, 100))
        assertNull(BackgroundVisualObservation.create(scope, image(), true, true, false, 100))
        assertNull(BackgroundVisualObservation.create(scope, image(), true, false, true, 100))
        assertNull(BackgroundVisualObservation.create(scope, image(), true, false, false, 30_101))
        assertNull(BackgroundVisualObservation.create(scope, image(), true, false, false, 99))
    }

    @Test fun unknownOrEmptyWindowGeometryIsUnavailable() {
        for (window in listOf(scope.window.copy(id = -1), scope.window.copy(right = 0), scope.window.copy(bottom = 0))) {
            assertNull(BackgroundVisualObservation.create(scope.copy(window = window), image(), true, false, false, 100))
        }
    }

    @Test fun missingUnknownAndWrongTypePeerValuesKeepTheLegacyMessage() {
        for (value in listOf(null, 1, true, "CHANGED", "PRIVATE_PEER_TEXT", byteArrayOf(1))) {
            assertEquals("", backgroundVisualNote(value))
        }
        assertTrue(backgroundVisualNote("changed").contains("与最近观察相比"))
        assertTrue(backgroundVisualNote("changed").contains("不表示操作成功"))
        for (value in listOf("unchanged", "unavailable")) {
            assertTrue(backgroundVisualNote(value).contains("请勿据此重试"))
        }
    }
    @Test fun additionalPrivacyScanRejectsSensitiveAndOversizedFieldsWithoutTruncating() {
        assertFalse(backgroundVisualSensitive("Next", "", "", "example:id/next"))
        assertTrue(backgroundVisualSensitive("支付", "", "", null))
        assertTrue(backgroundVisualSensitive(" ".repeat(4097), "Next", "", null))
        assertTrue(backgroundVisualSensitive("Next", "Payment", "", null))
        assertTrue(backgroundVisualSensitive("Next", "", "", "example:id/payButton"))
        assertTrue(backgroundVisualSensitive("Next", "x".repeat(4097), "", null))
        assertTrue(backgroundVisualSensitive("x".repeat(4097), "", "", null))
        assertTrue(backgroundVisualSensitive("Next", "", "x".repeat(4097), null))
        assertTrue(backgroundVisualSensitive("Next", "", "", "x".repeat(4097)))
    }

}
