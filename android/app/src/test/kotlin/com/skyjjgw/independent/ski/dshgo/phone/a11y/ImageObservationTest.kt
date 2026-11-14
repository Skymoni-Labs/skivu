package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.*
import org.junit.Test

class ImageObservationTest {
    private val geometry = ImageGeometry(20, 80, 0.5f, 0.5f, 240, 400)
    private fun frame(width: Int = 96, height: Int = 96, pixel: (Int, Int) -> Int = { _, _ -> 0xff808080.toInt() }) =
        VisualFrame.capture(width, height) { y, row -> for (x in row.indices) row[x] = pixel(x, y) }

    @Test fun onlyOcrCoordinatesAreRevokedByOffAndStayRevokedAfterOn() {
        assertTrue(mainOcrEpochCurrent(4L, 4L))
        assertFalse(mainOcrEpochCurrent(4L, null))
        assertFalse(mainOcrEpochCurrent(4L, 6L))
        assertTrue(mainOcrEpochCurrent(6L, 6L))
        // A publicly returned image has independent existing visual qualification.
        assertTrue(mainOcrEpochCurrent(null, null))
        assertTrue(mainOcrEpochCurrent(null, 6L))
    }

    @Test fun textOnlyShotRetainsRawGeometryAndLocalRecognitionWithoutImageBytes() {
        val text = LocalOcrResult.Recognized(listOf(LocalOcrResult.Line("合成", 0, 0, 20, 20)))
        val viewport = com.skyjjgw.independent.ski.dshgo.phone.VisualBounds(20, 80, 500, 880)
        val shot = Shot(null, null, geometry, false, null, 1_000L,
            ImageObservation(geometry, 1_000, frame()), text, 480, 800, viewport)
        assertNull(shot.bytes)
        assertSame(text, shot.localText)
        assertEquals(480, shot.rawWidth)
        assertEquals(800, shot.rawHeight)
        assertEquals(viewport, shot.viewport)
        assertEquals(geometry, shot.observation!!.geometry)
        val output = shot.visualText()!!
        assertTrue(output.text.contains("point=(0,0)"))
        assertTrue(output.hasPoints)
        assertFalse(output.sensitiveText)
        val privateShot = Shot(null, null, geometry, false, null, localText =
            LocalOcrResult.Recognized(listOf(LocalOcrResult.Line("验证码 123456", 0, 0, 20, 20))),
            rawWidth = 480, rawHeight = 800, viewport = viewport)
        assertTrue(privateShot.visualText()!!.sensitiveText)
        assertFalse(privateShot.visualText()!!.hasPoints)
        assertFalse(privateShot.visualText()!!.text.contains("123456"))
    }

    @Test fun pixelsMapBackToWindowOriginAndRejectEveryOutsideEdge() {
        assertEquals(20 to 80, geometry.toScreen(0, 0))
        assertEquals(498 to 878, geometry.toScreen(239, 399))
        assertNull(geometry.toScreen(-1, 0))
        assertNull(geometry.toScreen(0, -1))
        assertNull(geometry.toScreen(240, 0))
        assertNull(geometry.toScreen(0, 400))
        val nonInteger = ImageGeometry(17, 31, 0.65f, 0.65f, 650, 1300)
        assertEquals(1015 to 2029, nonInteger.toScreen(649, 1299))
    }

    @Test fun expiryUsesCaptureTimeAndDoesNotAllowFutureOrOlderFrames() {
        val old = ImageObservation(geometry, 1_000, frame())
        assertFalse(old.isFresh(999))
        assertTrue(old.isFresh(1_000))
        assertTrue(old.isFresh(31_000))
        assertFalse(old.isFresh(31_001))
        assertTrue(old.sameViewportAs(ImageObservation(geometry, 2_000, frame()), 2_000))
        assertFalse(old.sameViewportAs(ImageObservation(geometry, 900, frame()), 2_000))
        assertFalse(old.sameViewportAs(ImageObservation(geometry, 2_001, frame()), 2_000))
        // A fresh verification frame cannot renew an expired original screenshot.
        assertFalse(old.sameViewportAs(ImageObservation(geometry, 31_001, frame()), 31_001))
    }

    @Test fun unrelatedPixelChangesDoNotInvalidateTheViewport() {
        val before = frame()
        val after = frame { x, y -> if (x == 1 && y == 1) 0xffffffff.toInt() else 0xff808080.toInt() }
        assertTrue(ImageObservation(geometry, 1_000, before).sameViewportAs(ImageObservation(geometry, 2_000, after), 2_000))
        val sampledPixel = frame { x, y -> if (x == 2 && y == 2) 0xffffffff.toInt() else 0xff808080.toInt() }
        assertTrue(ImageObservation(geometry, 1_000, before).sameViewportAs(
            ImageObservation(geometry, 2_000, sampledPixel), 2_000))
        // Viewport validation is not pixel-target matching. Even large canvas changes are
        // only reported after the action; the original tree/window checks remain separate.
        assertTrue(ImageObservation(geometry, 1_000, before).sameViewportAs(
            ImageObservation(geometry, 2_000, frame { _, _ -> 0xffffffff.toInt() }), 2_000))
        // One pixel is not evidence that the intended action succeeded.
        assertEquals(VisualFrame.Change.UNCHANGED, after.changeFrom(before))
    }

    @Test fun geometryChangesRejectEvenWhenPixelsMatch() {
        val old = ImageObservation(geometry, 1_000, frame())
        for (next in listOf(
            geometry.copy(originX = 21), geometry.copy(originY = 81),
            geometry.copy(scaleX = 0.6f), geometry.copy(scaleY = 0.6f),
            geometry.copy(width = 241), geometry.copy(height = 401),
        )) {
            val current = ImageObservation(next, 2_000, frame())
            assertFalse(old.sameViewportAs(current, 2_000))
            assertEquals(VisualFrame.Change.UNAVAILABLE, current.changeFrom(old))
        }
        assertEquals(VisualFrame.Change.UNAVAILABLE, frame(48, 96).changeFrom(frame(96, 48)))
    }

    @Test fun visiblePatchChangesAreReportedWithoutSemanticSuccess() {
        val before = frame()
        val after = frame { x, y -> if (x < 24 && y < 24) 0xffffffff.toInt() else 0xff808080.toInt() }
        assertEquals(VisualFrame.Change.CHANGED, after.changeFrom(before))
        assertEquals(VisualFrame.Change.UNCHANGED, before.changeFrom(frame()))
    }

    @Test fun capturesOwnTheirSamplesAndHandleScreensSmallerThanTheSamplingGrid() {
        val rowSource = IntArray(8) { 0xff202020.toInt() }
        val before = VisualFrame.capture(8, 8) { _, row -> rowSource.copyInto(row) }
        rowSource.fill(0xffe0e0e0.toInt())
        val after = VisualFrame.capture(8, 8) { _, row -> rowSource.copyInto(row) }
        assertEquals(VisualFrame.Change.UNCHANGED, before.changeFrom(frame(8, 8) { _, _ -> 0xff202020.toInt() }))
        assertEquals(VisualFrame.Change.CHANGED, after.changeFrom(before))
    }
}
