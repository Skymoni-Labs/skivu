package com.skyjjgw.independent.ski.dshgo.pet

import kotlin.math.roundToInt

/** A rectangle in physical pixels, relative to the rest frame's top-left (the pet's fixed origin). */
data class FramePx(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width: Int get() = right - left
    val height: Int get() = bottom - top

    fun union(o: FramePx) = FramePx(minOf(left, o.left), minOf(top, o.top), maxOf(right, o.right), maxOf(bottom, o.bottom))

    fun contains(o: FramePx) = o.left >= left && o.top >= top && o.right <= right && o.bottom <= bottom

    fun contains(x: Float, y: Float) = x >= left && x < right && y >= top && y < bottom

    /** On screen, with the rest frame's top-left at [rest]. */
    fun at(rest: WindowPos) = ScreenRect(rest.x + left, rest.y + top, rest.x + right, rest.y + bottom)
}
