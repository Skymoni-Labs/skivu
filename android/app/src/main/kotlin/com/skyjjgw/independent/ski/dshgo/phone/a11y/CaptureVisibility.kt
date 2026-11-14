package com.skyjjgw.independent.ski.dshgo.phone.a11y

/** Main-thread paired holds: overlapping pet/agent captures restore only after both finish. */
internal class CaptureVisibility {
    private var holds = 0
    val hidden: Boolean get() = holds > 0

    /** Returns whether windows need a visibility update, not whether the hold was accepted. */
    fun update(hide: Boolean): Boolean {
        val before = hidden
        if (hide) holds++ else if (holds > 0) holds--
        return before != hidden
    }
}
