package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.PhoneAppIdentity
import com.skyjjgw.independent.ski.dshgo.phone.a11y.ImageGeometry
import com.skyjjgw.independent.ski.dshgo.phone.a11y.ImageObservation
import com.skyjjgw.independent.ski.dshgo.phone.a11y.VisualFrame
import org.junit.Assert.*
import org.junit.Test

class BackgroundCoordinatesTest {
    private val scope = BackgroundCoordinateObservation.Scope(Any(), "owner", PhoneAppIdentity("example.app", 1010123))
    private val window = BackgroundVisualObservation.Window(7, 0, 0, 48, 48)
    private fun image(at: Long = 100, color: Int = 0xff303030.toInt()) = ImageObservation(
        ImageGeometry(0, 0, 1f, 1f, 48, 48), at, VisualFrame.capture(48, 48) { _, row -> row.fill(color) })
    private fun observed() = BackgroundCoordinateObservation.create("nonce", scope, window, "canvas-root-context", image(), true, false, false, 100)!!
    private fun request(gesture: String = "tap") = mutableMapOf<String, Any?>(
        Proto.OP to Proto.OP_COORDINATE, Proto.OWNER to "owner", Proto.PKG to "example.app",
        Proto.TARGET_IDENTITY_VERSION to 1, Proto.TARGET_UID to 1010123,
        Proto.BACKGROUND_COORDINATES to 1, Proto.COORDINATE_OBSERVATION to "nonce",
        Proto.GESTURE to gesture, Proto.X to 0, Proto.Y to 47)
    private fun parse(fields: Map<String, Any?>) = BackgroundCoordinateRequest.parse(fields.keys, fields::get)

    @Test fun fixedGrammarRejectsExtraFieldsWrongTypesAndGestureOnlyArguments() {
        assertNotNull(parse(request()))
        assertNotNull(parse(request("long")))
        for ((key, value) in listOf(Proto.BACKGROUND_COORDINATES to 1L, Proto.X to 1.0,
            Proto.Y to -1, Proto.GESTURE to "press", "displayId" to 8, Proto.DURATION_MS to 400,
            Proto.X2 to 1, Proto.Y2 to 1)) {
            assertNull(parse(request().apply { put(key, value) }))
        }
        assertNull(parse(request().apply { remove(Proto.COORDINATE_OBSERVATION) }))
        assertNull(parse(request().apply { put(Proto.COORDINATE_OBSERVATION, "") }))
    }

    @Test fun afterVisualIsTheOnlyNewOptionalCoordinateFieldAndMustBeExactVersionOne() {
        assertNotNull(parse(request() + (Proto.AFTER_LOCAL_VISUAL to 1)))
        for (bad in listOf<Any?>(null, true, 1L, "1", 0, 2))
            assertNull(parse(request() + (Proto.AFTER_LOCAL_VISUAL to bad)))
        assertNull(parse(request() + (Proto.AFTER_VISUAL to "reply-only")))
        assertNull(parse(request() + (Proto.AFTER_LOCAL_VISUAL to 1) + (Proto.WANT_IMAGE to true)))
    }

    @Test fun swipeHasBoundedDurationAndEveryEndpointMustFitTheOriginalImage() {
        val fields = request("swipe").apply { put(Proto.X2, 47); put(Proto.Y2, 0) }
        assertEquals(400, parse(fields)!!.durationMs)
        for (duration in listOf(100, 2000)) assertTrue(parse(fields + (Proto.DURATION_MS to duration))!!.fits(48, 48))
        for (duration in listOf(99, 2001, 400L)) assertNull(parse(fields + (Proto.DURATION_MS to duration)))
        assertNull(parse(fields - Proto.X2))
        assertFalse(parse(fields + (Proto.X2 to 48))!!.fits(48, 48))
        assertFalse(parse(fields + (Proto.Y to 48))!!.fits(48, 48))
    }

    @Test fun readableCanvasDoesNotNeedEmittedElementsButIncompleteOrPrivateEvidenceCannotAuthorize() {
        assertNotNull(observed()) // Eligibility has no element-count condition: a complete canvas root is valid.
        assertNull(BackgroundCoordinateObservation.create("n", scope, null, "ctx", image(), true, false, false, 100))
        assertNull(BackgroundCoordinateObservation.create("n", scope, window, null, image(), true, false, false, 100))
        assertNull(BackgroundCoordinateObservation.create("n", scope, window, "ctx", null, true, false, false, 100))
        for ((complete, secret, sensitive) in listOf(Triple(false, false, false), Triple(true, true, false), Triple(true, false, true))) {
            assertNull(BackgroundCoordinateObservation.create("n", scope, window, "ctx", image(), complete, secret, sensitive, 100))
        }
        assertNull(BackgroundCoordinateObservation.create("n", scope, window.copy(right = 49), "ctx", image(), true, false, false, 100))
    }

    @Test fun ownerFullUidDisplayWindowContextGeometryAndMonotonicExpiryAllBindTheObservation() {
        val observed = observed()
        fun match(current: BackgroundCoordinateObservation.Scope = scope, win: BackgroundVisualObservation.Window = window,
                  context: String = "canvas-root-context", geometry: ImageGeometry = image().geometry, now: Long = 100) =
            observed.matches(current, win, context, geometry, now)
        assertTrue(match(now = 30_100))
        assertFalse(match(now = 30_101)); assertFalse(match(now = 99))
        assertFalse(match(current = scope.copy(display = Any())))
        assertFalse(match(current = scope.copy(owner = "new-owner")))
        assertFalse(match(current = scope.copy(target = scope.target.copy(uid = 123))))
        assertFalse(match(current = scope.copy(target = scope.target.copy(packageName = "other.app"))))
        assertFalse(match(win = window.copy(id = 8)))
        assertFalse(match(win = window.copy(left = 1)))
        assertFalse(match(context = "changed-tree"))
        assertFalse(match(geometry = image().geometry.copy(width = 49)))
    }

    @Test fun postFrameDifferenceNeverAuthorizesAndMissingPrivacyOrIdentityMeansUnavailable() {
        val observed = observed()
        assertEquals("unchanged", observed.change(scope, window, image(200), true, 200))
        assertEquals("changed", observed.change(scope, window, image(200, 0xffeeeeee.toInt()), true, 200))
        assertEquals("unavailable", observed.change(scope, window, image(200), false, 200))
        assertEquals("unavailable", observed.change(scope.copy(owner = "next"), window, image(200), true, 200))
        assertEquals("unavailable", observed.change(scope, window, null, true, 200))
        assertEquals("unavailable", observed.change(scope, window, image(99), true, 100))
    }

    @Test fun finalImageCommitIsRequiredAndOneTakeCannotBeReplayedOrRevived() {
        val state = BackgroundCoordinateImage()
        val receipt = BackgroundCoordinateImage.Receipt("original", 48, 48)
        state.candidate("b1", receipt)
        assertNull(state.take("b1")) // Candidate alone is not permission after a removed image.
        state.candidate("b2", receipt)
        state.accept("b1")
        assertNull(state.take("b2"))
        state.candidate("b3", receipt); state.accept("b3")
        assertSame(receipt, state.take("b3"))
        state.accept("b3")
        assertNull(state.take("b3"))
        state.candidate("b4", receipt); state.accept("b4"); state.clear()
        assertNull(state.take("b4"))
    }

    @Test fun malformedImageReceiptCannotCreateAnAppCandidate() {
        assertNotNull(BackgroundCoordinateImage.Receipt.parse(1, "n", 720, 1600))
        assertNull(BackgroundCoordinateImage.Receipt.parse(1L, "n", 720, 1600))
        assertNull(BackgroundCoordinateImage.Receipt.parse(1, "n", 720L, 1600))
        assertNull(BackgroundCoordinateImage.Receipt.parse(1, "", 720, 1600))
        assertNull(BackgroundCoordinateImage.Receipt.parse(1, "n", 0, 1600))
        assertNull(BackgroundCoordinateImage.Receipt.parse(null, "n", 720, 1600))
    }
    @Test fun realReplyDecoderKeepsAttemptedFactsAndNeverAcceptsMissingOrContradictoryAcknowledgement() {
        val receipt = BackgroundCoordinateImage.Receipt("nonce", 48, 48)
        val wire = mapOf<String, Any?>(Proto.BACKGROUND_COORDINATES to 1, Proto.COORDINATE_OBSERVATION to "nonce",
            Proto.COORDINATE_WIDTH to 48, Proto.COORDINATE_HEIGHT to 48, Proto.TARGET_IDENTITY_VERSION to 1,
            Proto.PKG to scope.target.packageName, Proto.TARGET_UID to scope.target.uid,
            Proto.OK to true, Proto.ACTION_ATTEMPTED to true, Proto.VISUAL_CHANGE to "changed")
        fun result(fields: Map<String, Any?>) = BackgroundCoordinateImage.Result.parse(receipt, scope.target, fields::get)
        assertTrue(result(wire)!!.ok)
        assertEquals("changed", result(wire)!!.change)
        for (bad in listOf(wire - Proto.ACTION_ATTEMPTED, wire + (Proto.ACTION_ATTEMPTED to "true"),
            wire + (Proto.OK to 1), wire + (Proto.COORDINATE_OBSERVATION to "old"),
            wire + (Proto.COORDINATE_WIDTH to 48L), wire + (Proto.ACTION_ATTEMPTED to false))) assertNull(result(bad))
        val postFailure = result(wire + (Proto.OK to false) + (Proto.TARGET_UID to -1))!!
        assertTrue(postFailure.attempted); assertFalse(postFailure.ok)
        assertEquals("unavailable", postFailure.change)
        val before = result(wire + (Proto.OK to false) + (Proto.ACTION_ATTEMPTED to false))!!
        assertFalse(before.attempted); assertFalse(before.ok)
        assertEquals("unavailable", result(wire + (Proto.VISUAL_CHANGE to "PRIVATE_TEXT"))!!.change)
    }

    @Test fun optionalNativeTargetsAreBoundedAndNeedTheAcceptedImage() {
        val state = BackgroundCoordinateImage()
        val target = PhoneAppIdentity("example.app", 10123)
        val bounds = intArrayOf(1, 2, 20, 30)
        val eligible = BackgroundCoordinateImage.targets(1, intArrayOf(1), bounds, 1, 40, 40)
        assertEquals(1, eligible.size)
        state.publishScope("b1", true, "resource", target)
        val scope = state.scope("b1")
        state.candidate("b1", BackgroundCoordinateImage.Receipt("nonce", 40, 40), eligible)
        assertNull(state.targetAt("b1", 10, 10))
        state.accept("b1"); assertEquals(1, state.targetAt("b1", 10, 10))
        assertNull(state.targetAt("other", 10, 10))
        state.take("b1"); assertNull(state.targetAt("b1", 10, 10))
        state.publishScope("b2", true, "resource", target)
        assertEquals(scope, state.scope("b2")) // new candidate is not a scope transition
        state.publishScope("b3", false, "resource", target)
        state.publishScope("b4", true, "resource", target)
        assertNotEquals(scope, state.scope("b4")) // internal unknown cannot revive a previous grant
    }
    @Test fun malformedOptionalMetadataNeverInventsAUsableTarget() {
        fun parsed(v: Any?, ids: Any?, boxes: Any?, count: Int = 2) = BackgroundCoordinateImage.targets(v, ids, boxes, count, 40, 40)
        val b = intArrayOf(1, 2, 20, 30)
        assertTrue(parsed(2, intArrayOf(1), b).isEmpty())
        assertTrue(parsed(1L, intArrayOf(1), b).isEmpty())
        assertTrue(parsed(1, listOf(1), b).isEmpty())
        assertTrue(parsed(1, intArrayOf(1), b, 0).isEmpty()) // actual serialized prefix, not merely <=120
        assertTrue(parsed(1, intArrayOf(1, 1), b + b).isEmpty())
        assertTrue(parsed(1, intArrayOf(1, 2), b + b).isEmpty())
        assertTrue(parsed(1, intArrayOf(1), intArrayOf(-1, 0, 20, 30)).isEmpty())
    }

}
