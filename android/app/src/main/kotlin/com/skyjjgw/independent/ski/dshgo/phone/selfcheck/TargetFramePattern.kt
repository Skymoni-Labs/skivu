package com.skyjjgw.independent.ski.dshgo.phone.selfcheck

/** Fixed C2 pixels, shared by the real Target drawing and the borrowed Bitmap verifier. */
internal object TargetFramePattern {
    const val GRID_COLUMNS = 20
    const val GRID_ROWS = 8
    const val MIN_CELL_PX = 8
    const val WIDTH_PX = 320
    const val HEIGHT_PX = 128
    const val DARK = 0xff202020.toInt()
    const val LIGHT = 0xffe0e0e0.toInt()
    const val COLOR_TOLERANCE = 12
    private const val FORMAT = 0xd39a65

    fun cellLeft(column: Int, width: Int): Int = (column.toLong() * width / GRID_COLUMNS).toInt()
    fun cellTop(row: Int, height: Int): Int = (row.toLong() * height / GRID_ROWS).toInt()

    /** 24 asymmetric format bits, all 128 UUID bits, then eight phase bits. No OCR or hash. */
    fun colorAt(run: String, phase: Int, column: Int, row: Int): Int {
        require(phase in 0..4 && column in 0 until GRID_COLUMNS && row in 0 until GRID_ROWS)
        val index = row * GRID_COLUMNS + column
        val bit = when {
            index < 24 -> FORMAT ushr (23 - index) and 1
            index < 152 -> {
                val offset = index - 24
                val nibble = offset / 4
                val charIndex = nibble + (if (nibble >= 8) 1 else 0) +
                    (if (nibble >= 12) 1 else 0) + (if (nibble >= 16) 1 else 0) +
                    (if (nibble >= 20) 1 else 0)
                run[charIndex].digitToInt(16) ushr (3 - offset % 4) and 1
            }
            else -> phase ushr (159 - index) and 1
        }
        return if (bit == 0) DARK else LIGHT
    }

    /** pixelAt coordinates are relative to the exact tree ROI, never free request coordinates. */
    fun matches(run: String, expectedPhase: Int, width: Int, height: Int, pixelAt: (Int, Int) -> Int): Boolean {
        if (!TargetContract.validRun(run) || expectedPhase !in 1..4 ||
            width < GRID_COLUMNS * MIN_CELL_PX || height < GRID_ROWS * MIN_CELL_PX) return false
        for (row in 0 until GRID_ROWS) for (column in 0 until GRID_COLUMNS) {
            val x = cellLeft(column, width) + (cellLeft(column + 1, width) - cellLeft(column, width)) / 2
            val y = cellTop(row, height) + (cellTop(row + 1, height) - cellTop(row, height)) / 2
            val actual = pixelAt(x, y)
            val expected = colorAt(run, expectedPhase, column, row)
            if (actual ushr 24 < 240) return false
            for (shift in 16 downTo 0 step 8)
                if (kotlin.math.abs((actual ushr shift and 255) - (expected ushr shift and 255)) > COLOR_TOLERANCE)
                    return false
        }
        return true
    }
}
