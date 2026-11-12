package com.skyjjgw.independent.ski

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.roundToInt
import kotlin.math.sin

/** Conservative geometric recognition. Unsupported or ambiguous marks produce no state. */
internal object PhoneVisualState {
    data class Box(val left: Int, val top: Int, val right: Int, val bottom: Int) {
        val width get() = right - left
        val height get() = bottom - top
        fun contains(x: Double, y: Double) = x >= left && x < right && y >= top && y < bottom
        fun list() = listOf(left, top, right, bottom)
    }
    data class Mark(val bounds: Box, val checked: Boolean, val kind: String, val confidence: Double)
    data class Raster(val width: Int, val height: Int, val pixels: IntArray) {
        init { require(width > 0 && height > 0 && pixels.size == width * height) }
    }

    private fun distance(a: Int, b: Int): Int =
        abs((a shr 16 and 255) - (b shr 16 and 255)) +
        abs((a shr 8 and 255) - (b shr 8 and 255)) + abs((a and 255) - (b and 255))

    private fun medianColor(colors: List<Int>): Int {
        fun channel(shift: Int) = colors.map { it shr shift and 255 }.sorted()[colors.size / 2]
        return (255 shl 24) or (channel(16) shl 16) or (channel(8) shl 8) or channel(0)
    }

    /** Glyph exclusions come only from same-frame OCR alphabet markers in an option group. */
    fun detect(image: Raster, glyphs: List<Box> = emptyList()): List<Mark> {
        val width = image.width
        val height = image.height
        val edge = mutableListOf<Int>()
        for (x in 0 until width) { edge.add(image.pixels[x]); edge.add(image.pixels[(height - 1) * width + x]) }
        for (y in 0 until height) { edge.add(image.pixels[y * width]); edge.add(image.pixels[y * width + width - 1]) }
        val background = medianColor(edge)
        // Transparent/privacy-masked or low-contrast regions cannot establish a state.
        if (image.pixels.any { it ushr 24 < 250 }) return emptyList()
        val ink = BooleanArray(image.pixels.size) { distance(image.pixels[it], background) >= 90 }
        val visited = BooleanArray(ink.size)
        val queue = IntArray(ink.size)
        val marks = mutableListOf<Mark>()
        for (start in ink.indices) {
            if (!ink[start] || visited[start]) continue
            var read = 0; var write = 0
            queue[write++] = start; visited[start] = true
            var left = width; var top = height; var right = 0; var bottom = 0
            while (read < write) {
                val index = queue[read++]
                val x = index % width; val y = index / width
                left = minOf(left, x); top = minOf(top, y); right = maxOf(right, x + 1); bottom = maxOf(bottom, y + 1)
                for (dy in -1..1) for (dx in -1..1) {
                    val nx = x + dx; val ny = y + dy
                    if (nx !in 0 until width || ny !in 0 until height) continue
                    val next = ny * width + nx
                    if (ink[next] && !visited[next]) { visited[next] = true; queue[write++] = next }
                }
            }
            val box = Box(left, top, right, bottom)
            if (minOf(box.width, box.height) < 14 || maxOf(box.width, box.height) > 180 ||
                box.width.toDouble() / box.height !in 0.85..1.18 ||
                left < 2 || top < 2 || right > width - 2 || bottom > height - 2) continue
            classify(image, ink, box, background, glyphs)?.let { marks.add(it) }
        }
        // An inner dot/check may itself resemble a shape. Keep only the outer recognized control.
        return marks.filter { candidate -> marks.none { other ->
            other !== candidate && other.bounds.width > candidate.bounds.width &&
                other.bounds.contains(candidate.bounds.left.toDouble(), candidate.bounds.top.toDouble()) &&
                other.bounds.contains(candidate.bounds.right - 1.0, candidate.bounds.bottom - 1.0)
        } }
    }

    private fun classify(image: Raster, ink: BooleanArray, box: Box, background: Int, glyphs: List<Box>): Mark? {
        val width = image.width
        fun near(x: Double, y: Double, radius: Double): Boolean {
            val px = box.left + x * (box.width - 1); val py = box.top + y * (box.height - 1)
            val r = maxOf(1, (radius * minOf(box.width, box.height)).roundToInt())
            for (iy in py.roundToInt() - r..py.roundToInt() + r) for (ix in px.roundToInt() - r..px.roundToInt() + r) {
                if (ix in box.left until box.right && iy in box.top until box.bottom && ink[iy * width + ix]) return true
            }
            return false
        }
        val circle = (0 until 48).count { i ->
            val angle = i * Math.PI / 24
            near(0.5 + 0.49 * cos(angle), 0.5 + 0.49 * sin(angle), 0.035)
        } / 48.0
        val square = (2..8).sumOf { i ->
            val p = i / 10.0
            listOf(near(p, 0.0, 0.035), near(p, 1.0, 0.035), near(0.0, p, 0.035), near(1.0, p, 0.035)).count { it }
        } / 28.0
        val kind = when {
            circle >= 0.95 && square < 0.80 -> "radio"
            square >= 0.95 && listOf(near(0.0,0.0,0.04),near(1.0,0.0,0.04),near(0.0,1.0,0.04),near(1.0,1.0,0.04)).count{it}>=3 -> "checkbox"
            else -> return null
        }
        val interior = mutableListOf<Int>()
        val central = mutableListOf<Int>()
        val rimColors = mutableListOf<Int>()
        for (y in box.top until box.bottom) for (x in box.left until box.right) {
            val nx = (x - box.left + 0.5) / box.width; val ny = (y - box.top + 0.5) / box.height
            val radius = hypot(nx - 0.5, ny - 0.5)
            val index = y * width + x
            val inside = if (kind == "radio") radius <= 0.36 else nx in 0.16..0.84 && ny in 0.16..0.84
            if (inside) interior.add(index)
            if (radius <= 0.17) central.add(index)
            if (ink[index] && (if (kind == "radio") radius >= 0.40 else nx < 0.12 || nx > 0.88 || ny < 0.12 || ny > 0.88))
                rimColors.add(image.pixels[index])
        }
        if (rimColors.isEmpty() || interior.isEmpty()) return null
        val controlColor = medianColor(rimColors)
        val filled = interior.count { ink[it] }.toDouble() / interior.size
        if (kind == "radio" && filled >= 0.72) return Mark(box, true, kind, 0.96)
        // A solid central dot with a surrounding gap is the standard selected radio pattern.
        if (kind == "radio" && central.count { ink[it] } >= central.size * 0.95 && filled >= 0.20)
            return Mark(box, true, kind, 0.95)

        val checkMask = BooleanArray(ink.size)
        for (index in interior) {
            checkMask[index] = if (filled >= 0.65) distance(image.pixels[index], controlColor) >= 120
                else ink[index]
        }
        if (hasCheck(checkMask, image.width, box)) return Mark(box, true, kind, 0.95)

        // Letters can occupy an unselected option circle. Their exact same-frame OCR box is excluded,
        // while colored fill outside that box must remain absent. Arbitrary interior glyphs stay unknown.
        val glyph = if (kind == "radio") glyphs.singleOrNull {
            box.contains((it.left + it.right) / 2.0, (it.top + it.bottom) / 2.0) &&
                it.width < box.width * 0.5 && it.height < box.height * 0.65
        } ?: optionLetter(ink,width,box,interior) else null
        val glyphInk=if(glyph==null)emptyList()else interior.filter{ink[it]&&glyph.contains((it%width).toDouble(),(it/width).toDouble())}
        val exclusion=if(glyphInk.isEmpty())null else Box(glyphInk.minOf{it%width}-2,glyphInk.minOf{it/width}-2,
            glyphInk.maxOf{it%width}+3,glyphInk.maxOf{it/width}+3)
        if(exclusion==null && interior.count{ink[it]}>2)return null
        val examined = interior.filter { index ->
            exclusion == null || !exclusion
                .contains((index % width).toDouble(), (index / width).toDouble())
        }
        if (examined.size < interior.size * 0.55) return null
        if (examined.count { ink[it] }.toDouble() / examined.size <= 0.015)
            return Mark(box, false, kind, 0.95)
        return null
    }

    /** Small standard letter stencils cover option labels omitted by full-screen OCR. */
    private fun optionLetter(ink:BooleanArray,width:Int,control:Box,interior:List<Int>):Box? {
        val points=interior.filter{ink[it]}
        if(points.isEmpty())return null
        val glyph=Box(points.minOf{it%width},points.minOf{it/width},points.maxOf{it%width}+1,points.maxOf{it/width}+1)
        if(glyph.width.toDouble()/control.width !in 0.10..0.49 ||
            glyph.height.toDouble()/control.height !in 0.18..0.60 ||
            glyph.width.toDouble()/glyph.height !in 0.35..1.10 ||
            points.size.toDouble()/(glyph.width*glyph.height) !in 0.12..0.70)return null
        val stencil=buildString {
            for(row in 0 until 7)for(column in 0 until 5) {
                val left=glyph.left+column*glyph.width/5;val right=glyph.left+(column+1)*glyph.width/5
                val top=glyph.top+row*glyph.height/7;val bottom=glyph.top+(row+1)*glyph.height/7
                var count=0
                for(y in top until bottom)for(x in left until right)if(ink[y*width+x])count++
                append(if(count>=(right-left)*(bottom-top)*0.18)'1'else'0')
            }
        }
        // A-H are complete glyph shapes. A blank moat or arbitrary center ink alone is insufficient.
        val templates=listOf(
            "00100/01110/01010/01010/11111/11001/10001",
            "01110/10001/10001/11111/10001/10001/10001",
            "11111/10011/10011/11111/10001/10011/11111",
            "11110/10001/10001/11110/10001/10001/11110",
            "01111/10000/10000/10000/10000/10000/01111",
            "11110/10001/10001/10001/10001/10001/11110",
            "11111/10000/10000/11110/10000/10000/11111",
            "11111/10000/10000/11110/10000/10000/10000",
            "01111/10000/10000/10111/10001/10001/01111",
            "10001/10001/10001/11111/10001/10001/10001",
        )
        return glyph.takeIf{templates.any { pattern -> pattern.replace("/","").zip(stencil).count{it.first!=it.second}<=4 }}
    }

    private fun hasCheck(mask: BooleanArray, width: Int, box: Box): Boolean {
        val inkPoints = mutableListOf<Pair<Double, Double>>()
        for (y in box.top until box.bottom) for (x in box.left until box.right) {
            if (mask[y * width + x]) inkPoints.add((x - box.left).toDouble() / box.width to (y - box.top).toDouble() / box.height)
        }
        if (inkPoints.size !in (box.width * box.height * 0.025).toInt()..(box.width * box.height * 0.24).toInt()) return false
        val a = 0.20 to 0.50; val b = 0.40 to 0.70; val c = 0.80 to 0.28
        fun segmentDistance(p: Pair<Double, Double>, from: Pair<Double, Double>, to: Pair<Double, Double>): Double {
            val dx = to.first - from.first; val dy = to.second - from.second
            val t = (((p.first - from.first) * dx + (p.second - from.second) * dy) / (dx * dx + dy * dy)).coerceIn(0.0, 1.0)
            return hypot(p.first - from.first - t * dx, p.second - from.second - t * dy)
        }
        if (inkPoints.count { minOf(segmentDistance(it, a, b), segmentDistance(it, b, c)) <= 0.10 } < inkPoints.size * 0.90) return false
        for ((from, to) in listOf(a to b, b to c)) {
            val covered = (0..12).count { i ->
                val t = i / 12.0
                val point = from.first + t * (to.first - from.first) to from.second + t * (to.second - from.second)
                inkPoints.any { hypot(it.first - point.first, it.second - point.second) <= 0.075 }
            }
            if (covered < 12) return false
        }
        return true
    }
}
