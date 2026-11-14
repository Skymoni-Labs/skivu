package com.skyjjgw.independent.ski.dshgo.pet

/** The two original geometry helpers used by phone EdgeSnap, from upstream
 * PetFrames.kt. The unrelated mascot renderer, packs and artwork are not linked.
 */
object PetFrames {
    fun windowAt(rest: WindowPos, frame: FramePx) = WindowPos(rest.x + frame.left, rest.y + frame.top)
    fun restOf(window: WindowPos, frame: FramePx) = WindowPos(window.x - frame.left, window.y - frame.top)
}
