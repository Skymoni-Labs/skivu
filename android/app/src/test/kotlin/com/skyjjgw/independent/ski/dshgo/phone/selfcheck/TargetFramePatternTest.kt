package com.skyjjgw.independent.ski.dshgo.phone.selfcheck

import org.junit.Assert.*
import org.junit.Test

class TargetFramePatternTest {
    private val run = "12345678-9abc-def0-1234-56789abcdef0"
    private fun rendered(run: String, phase: Int, width: Int = 320, height: Int = 128): IntArray {
        val pixels = IntArray(width * height)
        for (row in 0 until TargetFramePattern.GRID_ROWS) for (column in 0 until TargetFramePattern.GRID_COLUMNS) {
            val color = TargetFramePattern.colorAt(run, phase, column, row)
            for (y in TargetFramePattern.cellTop(row, height) until TargetFramePattern.cellTop(row + 1, height))
                for (x in TargetFramePattern.cellLeft(column, width) until TargetFramePattern.cellLeft(column + 1, width))
                    pixels[y * width + x] = color
        }
        return pixels
    }
    private fun matches(pixels: IntArray, expected: String = run, phase: Int = 1, width: Int = 320, height: Int = 128) =
        TargetFramePattern.matches(expected, phase, width, height) { x, y -> pixels[y * width + x] }

    @Test fun wireIndependentKnownBitsIncludeHeaderUuidAndPhase() {
        fun bit(index: Int) = TargetFramePattern.colorAt(run, 4, index % 20, index / 20)
        assertEquals(TargetFramePattern.LIGHT, bit(0)) // 0xd3 begins 11010011.
        assertEquals(TargetFramePattern.LIGHT, bit(1))
        assertEquals(TargetFramePattern.DARK, bit(2))
        assertEquals(TargetFramePattern.DARK, bit(24)) // UUID starts hex 1 = 0001.
        assertEquals(TargetFramePattern.LIGHT, bit(27))
        assertEquals(TargetFramePattern.LIGHT, bit(56)) // UUID nibble 8 = 9, after first hyphen.
        assertEquals(TargetFramePattern.LIGHT, bit(72)) // UUID nibble 12 = d.
        assertEquals(TargetFramePattern.DARK, bit(88)) // UUID nibble 16 = 1.
        assertEquals(TargetFramePattern.DARK, bit(104)) // UUID nibble 20 = 5.
        assertEquals(TargetFramePattern.DARK, bit(151)) // Last UUID nibble 0.
        assertEquals(TargetFramePattern.LIGHT, bit(157)) // Phase 4 = 00000100.
        assertEquals(TargetFramePattern.DARK, bit(159))
    }

    @Test fun allRunBitsAreCheckedNotJustAHashOrPrefix() {
        val zero = "00000000-0000-0000-0000-000000000000"
        val pixels = rendered(zero, 1)
        for (bit in 0 until 128) {
            val chars = CharArray(32) { '0' }
            chars[bit / 4] = "1248"[bit % 4]
            val hex = String(chars)
            val changed = hex.substring(0, 8) + "-" + hex.substring(8, 12) + "-" + hex.substring(12, 16) +
                "-" + hex.substring(16, 20) + "-" + hex.substring(20)
            assertFalse("run bit $bit", matches(pixels, changed))
        }
    }

    @Test fun eachStageRequiresItsActualPixelsAndInitialPhaseNeverPasses() {
        for (phase in 1..4) {
            val pixels = rendered(run, phase)
            assertTrue(matches(pixels, phase = phase))
            for (other in 1..4) if (other != phase) assertFalse(matches(pixels, phase = other))
        }
        assertFalse(matches(rendered(run, 0)))
        assertFalse(matches(rendered(run, 0), phase = 0))
    }

    @Test fun oddGeometryUsesTheSameActualCellCentersAndRejectsTooSmall() {
        assertTrue(matches(rendered(run, 1, 323, 131), width = 323, height = 131))
        var sampled = false
        assertFalse(TargetFramePattern.matches(run, 1, 159, 64) { _, _ -> sampled = true; 0 })
        assertFalse(TargetFramePattern.matches(run, 1, 160, 63) { _, _ -> sampled = true; 0 })
        assertFalse(sampled)
    }

    @Test fun formatAndOrientationAreVerified() {
        val pixels = rendered(run, 1)
        assertFalse(TargetFramePattern.matches(run, 1, 320, 128) { x, y -> pixels[y * 320 + 319 - x] })
        assertFalse(TargetFramePattern.matches(run, 1, 320, 128) { x, y -> pixels[(127 - y) * 320 + x] })
        pixels[8 * 320 + 8] = TargetFramePattern.DARK // Corrupt fixed top-left format bit.
        assertFalse(matches(pixels))
    }

    @Test fun colorBoundsAreFixedAndBlackOrTransparentCannotPass() {
        val pixels = rendered(run, 1)
        val within = pixels.map { it + 0x000c0c0c }.toIntArray()
        assertTrue(matches(within))
        val over = pixels.copyOf().also { it[8 * 320 + 8] += 0x000d0000 }
        assertFalse(matches(over))
        assertFalse(matches(IntArray(320 * 128) { 0xff000000.toInt() }))
        assertFalse(matches(pixels.map { it and 0x00ffffff }.toIntArray()))
        assertFalse(TargetFramePattern.matches("bad-run", 1, 320, 128) { _, _ -> error("must not sample") })
    }
}
