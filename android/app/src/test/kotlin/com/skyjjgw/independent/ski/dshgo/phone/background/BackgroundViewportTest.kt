package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundViewportTest {
    @Test fun presetsSwapAxesWithoutChangingPixelBudget() {
        val portrait = BackgroundPolicy.Viewport.PORTRAIT
        val landscape = BackgroundPolicy.Viewport.LANDSCAPE
        assertEquals(720, portrait.width); assertEquals(1600, portrait.height)
        assertEquals(portrait.height, landscape.width); assertEquals(portrait.width, landscape.height)
        assertEquals(1_152_000, portrait.width * portrait.height)
        assertEquals(1_152_000, landscape.width * landscape.height)
    }

    @Test fun arbitrarySizesCaseVariantsAndWrongTypesAreNotPresets() {
        for (value in listOf(null, "", "LANDSCAPE", "720x1600", "square", true, 1)) {
            assertNull(BackgroundPolicy.Viewport.parse(value))
        }
        assertEquals(BackgroundPolicy.Viewport.PORTRAIT, BackgroundPolicy.Viewport.parse("portrait"))
        assertEquals(BackgroundPolicy.Viewport.LANDSCAPE, BackgroundPolicy.Viewport.parse("landscape"))
    }

    @Test fun oldAspectRequestsKeepTheirPortraitSemantics() {
        assertArrayEquals(intArrayOf(720, 1600), BackgroundPolicy.displaySize(720, 9, 20))
        assertArrayEquals(intArrayOf(720, 1600), BackgroundPolicy.displaySize(720, 20, 9))
        assertArrayEquals(intArrayOf(360, 800), BackgroundPolicy.displaySize(360, 9, 20))
    }
}
