package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** The 悬浮条 settings: defaults and the 30–100 % range (the overlay applies whatever this gives). */
class OverlayPrefsTest {
    @Test fun defaultsKeepThePillOpenAt70Percent() {
        val p = OverlayPrefs()
        assertEquals(0.7f, p.idleOpacity)
        assertFalse(p.autoFold)
        assertEquals(mapOf("idleOpacity" to 0.7f.toDouble(), "autoCollapse" to false), p.toMap())
    }

    @Test fun opacityStaysWithin30And100Percent() {
        assertEquals(0.3f, OverlayPrefs.clampOpacity(0.05f))
        assertEquals(1f, OverlayPrefs.clampOpacity(1.4f))
        assertEquals(0.55f, OverlayPrefs.clampOpacity(0.55f))
        // Whole percents.
        assertEquals(0.67f, OverlayPrefs.clampOpacity(0.6666f))
        assertEquals(OverlayPrefs.DEFAULT_OPACITY, OverlayPrefs.clampOpacity(Float.NaN))
    }
}
