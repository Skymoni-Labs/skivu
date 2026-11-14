package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.pet.Dock
import com.skyjjgw.independent.ski.dshgo.pet.EdgeSnap
import com.skyjjgw.independent.ski.dshgo.pet.SafeArea
import com.skyjjgw.independent.ski.dshgo.pet.Side
import com.skyjjgw.independent.ski.dshgo.pet.WindowPos
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The capsule's place, the ball against it and the screen sides, at 2.625 px/dp (a 1080 px phone, 411 dp wide). */
class BallGeometryTest {
    private val density = 2.625f
    private fun dp(v: Int) = Math.round(v * density)

    private val area = SafeArea(1080, 2400, left = 0, top = 96, right = 0, bottom = 63)
    private val ball = dp(OverlayBall.BALL_DP)
    private val pad = dp(OverlayBall.PAD_DP)
    private val size = ball + 2 * pad
    private val edge = dp(OverlayBall.EDGE_DP)
    private val margin = BallGeometry.margin(edge, pad)
    private val headerH = dp(CapsuleMetrics.HEIGHT_DP)
    private val gap = dp(CapsulePlacement.GAP_DP)

    // The capsule as ControlOverlay places it: centred, hung from the bottom, its root padding the surface.
    private val padX = dp(OverlayCapsule.PAD_X_DP)
    private val padTop = dp(OverlayCapsule.PAD_TOP_DP)
    private val padBottom = dp(OverlayCapsule.PAD_BOTTOM_DP)
    private val capsuleW = dp(240)
    private val windowW = capsuleW + 2 * padX
    private val windowH = headerH + padTop + padBottom
    private val centre = CapsulePlacement.centreY(area, headerH, gap)
    private val windowX = BallGeometry.centredX(area.screenW, windowW)
    private val windowY = CapsulePlacement.windowTop(area.screenH, CapsulePlacement.windowY(area.screenH, centre, headerH, padBottom), windowH)

    private fun end(side: Side) = BallGeometry.ballOver(
        windowX, windowY, padX, padTop, BallGeometry.circleLeft(0, capsuleW, ball, side), 0, pad,
    )

    @Test fun theBallIsTheCapsulesHeight() {
        // One object: the ball is the capsule's end circle, and every form has the same corner.
        assertEquals(CapsuleMetrics.HEIGHT_DP, OverlayBall.BALL_DP)
        assertEquals(CapsuleMetrics.HEIGHT_DP / 2, CapsuleMetrics.RADIUS_DP)
        assertTrue(OverlayBall.BALL_DP >= 48)
    }

    // ---- 胶囊在屏幕中下方 ---------------------------------------------------------------------------

    @Test fun theCapsuleSitsInTheLowerMiddleOfTheSafeArea() {
        val safeH = area.screenH - area.top - area.bottom
        val share = (centre - area.top).toFloat() / safeH
        assertTrue("at $share of the safe height", share in 0.70f..0.75f)
        // Centred across.
        assertEquals(area.screenW - (windowX + windowW), windowX)
        // Clear of the navigation bar.
        assertTrue(centre + headerH / 2 <= area.screenH - area.bottom - gap)
    }

    @Test fun theWindowHangsFromTheBottomAroundTheCapsule() {
        val y = CapsulePlacement.windowY(area.screenH, centre, headerH, padBottom)
        // A taller window (the card) keeps its bottom edge, so the header stays where the capsule was.
        val cardH = dp(320) + padTop + padBottom
        val capsuleBottom = CapsulePlacement.windowTop(area.screenH, y, windowH) + windowH
        val cardBottom = CapsulePlacement.windowTop(area.screenH, y, cardH) + cardH
        assertEquals(capsuleBottom, cardBottom)
        assertEquals(centre + headerH / 2, cardBottom - padBottom)
        // The surface's top in the capsule window is the capsule's.
        assertEquals(centre - headerH / 2, windowY + padTop)
    }

    @Test fun aConfirmCardOrAKeyboardPushesTheCapsuleUpOverIt() {
        val cardTop = 1300
        val lifted = CapsulePlacement.centreY(area, headerH, gap, obstacleTop = cardTop)
        assertEquals(cardTop - gap - headerH / 2, lifted)
        assertTrue(lifted < centre)
        // Something low (a short keyboard under the capsule's place) changes nothing.
        assertEquals(centre, CapsulePlacement.centreY(area, headerH, gap, obstacleTop = area.screenH - area.bottom))
        // Something reaching the top never pushes it under the status bar.
        assertEquals(area.top + gap + headerH / 2, CapsulePlacement.centreY(area, headerH, gap, obstacleTop = area.top + 10))
    }

    @Test fun landscapeKeepsTheSameShareOfTheSafeHeight() {
        val land = SafeArea(2400, 1080, left = 96, top = 0, right = 63, bottom = 0)
        assertEquals(778, CapsulePlacement.centreY(land, headerH, gap)) // 0.72 × 1080
    }

    @Test fun aShortScreenWithTheKeyboardUpCapsTheCardUnderTheStatusBar() {
        // Landscape, a 200 dp keyboard: the header sits above it, the card's body scrolls in what is left.
        val land = SafeArea(2400, 1080, left = 96, top = 0, right = 63, bottom = 0)
        val keyboardTop = 1080 - dp(200)
        val c = CapsulePlacement.centreY(land, headerH, gap, obstacleTop = keyboardTop)
        assertEquals(keyboardTop - gap - headerH / 2, c)
        val room = CapsulePlacement.cardRoom(land, c, headerH, gap)
        val headerPart = headerH - dp(6) // the body tucks 6 dp into the header
        val body = CapsulePlacement.bodyHeight(natural = dp(320), maxCard = room, headerPart = headerPart)
        val cardTop = c + headerH / 2 - (headerPart + body)
        assertEquals(land.top + gap, cardTop)
        assertTrue(body < dp(320))
    }

    @Test fun aCardThatFitsKeepsItsHeight() {
        val room = CapsulePlacement.cardRoom(area, centre, headerH, gap)
        assertEquals(dp(300), CapsulePlacement.bodyHeight(natural = dp(300), maxCard = room, headerPart = headerH))
        // No room at all: no body, never a negative one.
        assertEquals(0, CapsulePlacement.bodyHeight(natural = dp(300), maxCard = headerH / 2, headerPart = headerH))
        assertEquals(dp(300), CapsulePlacement.bodyHeight(natural = dp(300), maxCard = Int.MAX_VALUE, headerPart = headerH))
    }

    // ---- 小球 ------------------------------------------------------------------------------------

    @Test fun aBallNeverMovedRestsOnTheRightLevelWithTheCapsule() {
        val dock = BallGeometry.defaultDock(area, size, margin, centre)
        assertEquals(Side.RIGHT, dock.side)
        val pos = EdgeSnap.position(dock, size, size, area, margin)
        assertEquals(centre.toFloat(), pos.y + size / 2f, 1f)
    }

    @Test fun aRestingBallLiftsAboveAConfirmCard() {
        val minY = EdgeSnap.minY(area, margin)
        val pos = WindowPos(900, 1600)
        assertEquals(pos, BallGeometry.above(pos, size, limit = null, minY = minY))
        assertEquals(pos, BallGeometry.above(pos, size, limit = 1600 + size, minY = minY))
        assertEquals(WindowPos(900, 1200 - size), BallGeometry.above(pos, size, limit = 1200, minY = minY))
        // Never above the safe area.
        assertEquals(WindowPos(900, minY), BallGeometry.above(pos, size, limit = minY + 10, minY = minY))
    }

    @Test fun dockedBallsSitTheSameGapFromEitherSide() {
        val left = EdgeSnap.position(Dock(Side.LEFT, 0.3f), size, size, area, margin)
        val right = EdgeSnap.position(Dock(Side.RIGHT, 0.3f), size, size, area, margin)
        val leftGap = left.x + pad
        val rightGap = area.screenW - (right.x + pad + ball)
        assertEquals(edge, leftGap)
        assertEquals(edge, rightGap)
        // Mirror images: same height.
        assertEquals(left.y, right.y)
    }

    @Test fun theFoldStartsOnTheCapsulesEndCircle() {
        val surfaceLeft = windowX + padX
        val surfaceTop = windowY + padTop
        val r = end(Side.RIGHT)
        assertEquals(surfaceLeft + capsuleW - ball, r.x + pad)
        assertEquals(surfaceTop, r.y + pad)
        val l = end(Side.LEFT)
        assertEquals(surfaceLeft, l.x + pad)
        assertEquals(r.y, l.y)
        // The circle is the capsule's own: centred on the capsule's centre line.
        assertEquals(centre, r.y + pad + ball / 2)
    }

    @Test fun theTwoEndsAreMirrorImagesAboutTheScreensCentre() {
        val r = end(Side.RIGHT)
        val l = end(Side.LEFT)
        val leftOfLeft = l.x + pad
        val rightOfRight = r.x + pad + ball
        assertTrue(kotlin.math.abs((leftOfLeft + rightOfRight) - area.screenW) <= 1)
    }

    @Test fun aCircleAtEitherEndOfAWideCard() {
        // From the card, the fold goes to the header's end: the card's corner circle.
        val cardW = CapsuleMetrics.maxPx(area.screenW, density)
        assertEquals(cardW - ball, BallGeometry.circleLeft(0, cardW, ball, Side.RIGHT))
        assertEquals(0, BallGeometry.circleLeft(0, cardW, ball, Side.LEFT))
        assertEquals(30, BallGeometry.circleLeft(30, 30 + cardW, ball, Side.LEFT))
    }
}
