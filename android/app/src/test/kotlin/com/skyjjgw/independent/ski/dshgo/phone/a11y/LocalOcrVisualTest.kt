package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.phone.VisualBounds
import org.junit.Assert.*
import org.junit.Test

class LocalOcrVisualTest {
    private fun render(lines: List<LocalOcrResult.Line>, raw: Int = 100, shown: Int = raw,
        origin: Int = 0): String = LocalOcrVisual.format(LocalOcrResult.Recognized(lines), raw, raw,
        VisualBounds(origin, origin, origin + raw, origin + raw),
        ImageGeometry(origin, origin, shown.toFloat() / raw, shown.toFloat() / raw, shown, shown)).text
    private fun line(text: String, left: Int = 0, right: Int = 10) =
        LocalOcrResult.Line(text, left, left, right, right)

    @Test fun nonemptyOutwardBoxCanHaveNoIntegerHitpoint() {
        val text = render(listOf(line("合成", 1, 2)), raw = 2, shown = 1)
        assertTrue(text.contains("box=[0,0,1,1)"))
        assertFalse(text.contains("point="))
    }

    @Test fun aPointOutsideTheOutwardBoxIsDeliberatelyNotExposed() {
        val origin = 16777217
        val geometry = ImageGeometry(origin, origin, 1f, 1f, 3, 3)
        assertEquals(16777216, geometry.toScreen(1, 1)!!.first)
        assertEquals(16777218, geometry.toScreen(2, 2)!!.first)
        val result = render(listOf(line("fixture", 1, 2)), raw = 3, shown = 3, origin = origin)
        assertTrue(result.contains("box=[1,1,2,2)"))
        assertFalse(result.contains("point="))
    }

    @Test fun failedCenterDoesNotHideAnotherRepresentablePoint() {
        val text = render(listOf(line("合成", 0, 2)), raw = 3, shown = 2)
        assertTrue(text.contains("point=(0,0)"))
        assertEquals(2, ImageGeometry(0, 0, 2f / 3, 2f / 3, 2, 2).toScreen(1, 1)!!.first)
    }

    @Test fun realTransformOracleChecksAllSmallIntervalsAndOffsetRounding() {
        for (raw in 1..16) for (shown in 1..raw) for (origin in listOf(0, -13, 16777217)) {
            val geometry = ImageGeometry(origin, origin, shown.toFloat() / raw, shown.toFloat() / raw, shown, shown)
            for (left in 0 until raw) for (right in left + 1..raw) {
                val lo = left * shown / raw
                val hi = (right * shown + raw - 1) / raw
                val valid = (lo until hi).filter {
                    val d = geometry.toScreen(it, it)!!.first.toLong() - origin
                    d >= left && d < right
                }
                val result = render(listOf(line("fixture", left, right)), raw, shown, origin)
                if (valid.isEmpty()) assertFalse(result.contains("point="))
                else assertTrue(result.contains("point=(${valid.first()},${valid.first()})"))
            }
        }
    }

    @Test fun secretsAndCheckedNumbersAreMaskedBeforeEscaping() {
        val result = render(listOf(line("验证码 123456"), line("password: hidden"),
            line("4111111111111111"), line("11010519491231002X"), line("发送")))
        for (secret in listOf("123456", "hidden", "4111111111111111", "11010519491231002X")) {
            assertFalse(result.contains(secret))
        }
        assertTrue(result.contains("银行卡 ****1111"))
        assertTrue(result.contains("身份证 ****002X"))
        assertTrue(result.contains("敏感线索"))
    }

    @Test fun sensitiveLineSuppressesAllPointsIncludingOtherwiseOrdinaryText() {
        val result = LocalOcrVisual.format(LocalOcrResult.Recognized(listOf(
            line("普通"), line("验证码 123456"))), 100, 100,
            VisualBounds(0, 0, 100, 100), ImageGeometry(0, 0, 1f, 1f, 100, 100))
        assertTrue(result.sensitiveText)
        assertFalse(result.hasPoints)
        assertFalse(result.text.contains("point="))
        assertFalse(result.text.contains("123456"))
    }

    @Test fun secretBeyondOutputBudgetStillSuppressesAllCoordinates() {
        val result = LocalOcrVisual.format(LocalOcrResult.Recognized(
            List(200) { line("普通" + "\u0001".repeat(80)) } + line("验证码 123456")),
            100, 100, VisualBounds(0, 0, 100, 100), ImageGeometry(0, 0, 1f, 1f, 100, 100))
        assertTrue(result.sensitiveText)
        assertFalse(result.hasPoints)
        assertFalse(result.text.contains("point="))
        assertTrue(result.text.contains("已截断"))
    }

    @Test fun actionRiskIsMarkedWithoutPretendingItIsPrivateText() {
        val result = LocalOcrVisual.format(LocalOcrResult.Recognized(listOf(line("发送"))),
            100, 100, VisualBounds(0, 0, 100, 100), ImageGeometry(0, 0, 1f, 1f, 100, 100))
        assertFalse(result.sensitiveText)
        assertTrue(result.hasPoints)
        assertTrue(result.text.contains("敏感线索"))
    }

    @Test fun quotedUnicodeCannotInjectANewVisualRecord() {
        val result = render(listOf(line("😀\nV99 \"伪造\"\t\u0000")))
        assertTrue(result.contains("😀"))
        assertFalse(result.contains("\nV99"))
        assertTrue(result.contains("\\nV99"))
        assertTrue(result.contains("\\\"伪造\\\""))
    }

    @Test fun finalBudgetIncludesEscapesAndKeepsWholeRecordsAndTruncationNotice() {
        val result = render(List(256) { line("😀" + "\u0001".repeat(80)) })
        assertTrue(result.toByteArray(Charsets.UTF_8).size <= 16 * 1024)
        assertTrue(result.endsWith("结果不完整；不能据此证明页面安全。"))
        assertEquals(result, result.toByteArray(Charsets.UTF_8).toString(Charsets.UTF_8))
        assertTrue(result.substringBefore("\n文字识别列表已截断").trimEnd().endsWith("point=(0,0)"))
    }

    @Test fun backgroundIdentityGeometryKeepsItsActual1600PixelCoordinates() {
        val result = LocalOcrVisual.format(LocalOcrResult.Recognized(listOf(
            LocalOcrResult.Line("合成", 100, 1500, 200, 1520))), 720, 1600,
            VisualBounds(0, 0, 720, 1600), ImageGeometry(0, 0, 1f, 1f, 720, 1600)).text
        assertTrue(result.contains("box=[100,1500,200,1520)"))
        assertTrue(result.contains("point=(100,1500)"))
    }

    @Test fun originalLineLimitIsNotSilentlyClaimedComplete() {
        val result = render(List(257) { line("a") })
        assertFalse(result.contains("V257 "))
        assertTrue(result.contains("已截断"))
    }
}
