package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundLocalOcrTest {
    @Test fun decodedFrameBudgetIncludesBothPresetsAndTheLegacyMaximum() {
        for (preset in BackgroundPolicy.Viewport.entries)
            assertTrue(BackgroundLocalOcr.acceptsDimensions(preset.width, preset.height))
        val legacy = BackgroundPolicy.displaySize(1080, 1, 3)
        assertTrue(BackgroundLocalOcr.acceptsDimensions(legacy[0], legacy[1]))
        assertTrue(BackgroundLocalOcr.acceptsDimensions(3240, 1080))
        assertFalse(BackgroundLocalOcr.acceptsDimensions(1080, 3241))
        assertFalse(BackgroundLocalOcr.acceptsDimensions(1081, 1081))
        assertFalse(BackgroundLocalOcr.acceptsDimensions(Int.MAX_VALUE, Int.MAX_VALUE))
        assertFalse(BackgroundLocalOcr.acceptsDimensions(0, 1600))
        assertFalse(BackgroundLocalOcr.acceptsDimensions(720, -1))
    }
}
