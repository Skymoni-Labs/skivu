package com.skyjjgw.independent.ski.dshgo.phone.background

/** Shared by the pre-input distance check and the actual injected MOVE coordinates. */
internal object SwipeGeometry {
    fun steps(duration: Int): Int = (duration / 16).coerceAtLeast(1)

    fun coordinate(start: Int, end: Int, step: Int, steps: Int): Int =
        (start + (end - start) * (step.toFloat() / steps)).toInt()
}
