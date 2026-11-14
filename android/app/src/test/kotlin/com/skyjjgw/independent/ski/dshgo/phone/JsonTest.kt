package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

class JsonTest {
    @Test fun roundTripsObjectsArraysEscapesAndNumbers() {
        val value = linkedMapOf("line" to "a\n\"b\\c", "values" to listOf(null, true, false, 12L, -3L, 1.25), "nested" to mapOf("中文" to "值"))
        assertEquals(value, Json.parse(Json.write(value)))
    }

    @Test fun invalidSyntaxIsRejected() {
        for (bad in listOf("", "undefined", "[1,]", "{\"a\":}", "{\"a\" 1}", "\"unterminated", "true false", "\"\\q\"")) {
            try {
                Json.parse(bad)
                fail("accepted invalid syntax")
            } catch (_: Json.JsonException) {
            }
        }
    }

    private fun strictRejects(raw: String, depth: Int = 8) {
        assertThrows(Json.JsonException::class.java) { Json.parseStrict(raw, depth) }
    }

    @Test fun strictNumbersPreserveTheirTokenKindAndRejectInvalidLexemes() {
        assertEquals(0L, Json.parseStrict("-0"))
        assertEquals(Long.MAX_VALUE, Json.parseStrict("9223372036854775807"))
        assertEquals(Long.MIN_VALUE, Json.parseStrict("-9223372036854775808"))
        for (raw in listOf("1.0", "1e0", "1E+0")) {
            val value = Json.parseStrict(raw)
            assertTrue(value is Double) // A route integer validator must not coerce this to Long.
            assertEquals(1.0, value as Double, 0.0)
        }
        assertEquals(-0.125, Json.parseStrict("-1.25e-1") as Double, 0.0)
        assertTrue(Json.parseStrict("9223372036854775808") is Double)
        for (raw in listOf("01", "-01", "00", "+1", "1.", "-.1", ".1", "1.e1",
            "1e", "1e+", "1e-", "--1", "1e309", "-1e309", "NaN", "Infinity", "-Infinity")) {
            strictRejects(raw)
            strictRejects("[$raw]")
        }
    }

    @Test fun duplicateKeysAreComparedAfterDecodingIncludingNullValuesAndNestedObjects() {
        for (raw in listOf("""{"a":null,"a":1}""", """{"a":1,"\u0061":2}""",
            """{"outer":{"schema":1,"schem\u0061":2}}""")) strictRejects(raw)
        assertEquals(mapOf("left" to mapOf("a" to 1L), "right" to mapOf("a" to 2L)),
            Json.parseStrict("""{"left":{"a":1},"right":{"a":2}}"""))
    }

    @Test fun strictUnicodeAcceptsRawEscapedAndMixedSurrogatePairsForKeysAndValues() {
        val high = '\uD83D'; val low = '\uDE00'
        val expected = "$high$low"
        for (contents in listOf(expected, "\\uD83D\\uDE00", "\\uD83D$low", "$high\\uDE00")) {
            assertEquals(expected, Json.parseStrict("\"$contents\""))
            assertEquals(mapOf(expected to expected), Json.parseStrict("{\"$contents\":\"$contents\"}"))
        }
        assertEquals("中文", Json.parseStrict("\"\\u4e2d\\u6587\""))
        assertEquals("\b\u000c\n\r\t", Json.parseStrict("\"\\b\\f\\n\\r\\t\""))
    }

    @Test fun strictUnicodeRejectsUnpairedAndMalformedFourHexEscapes() {
        val high = '\uD800'; val low = '\uDC00'
        for (contents in listOf("$high", "$low", "$low$high", "${high}a", "$high$high",
            "\\uD800", "\\uDC00", "\\uD800a", "\\uDC00\\uD800", "\\u+061", "\\u-001", "\\u00g1", "\\u123")) {
            strictRejects("\"$contents\"")
            strictRejects("{\"$contents\":0}")
        }
        strictRejects("""{"schema":1,"schem\u+061":2}""")
    }

    @Test fun existingWhitespaceAndRawControlRulesStillApplyToStrictDocuments() {
        assertEquals(listOf(true, false, null), Json.parseStrict(" \t\r\n [true,false,null] \r\n"))
        for (space in listOf('\u000b', '\u000c', '\u00a0', '\ufeff', '\u2028', '\u2029')) {
            strictRejects("${space}null")
            strictRejects("[0,${space}1]")
            strictRejects("null$space")
        }
        for (value in 0..31) strictRejects("\"${value.toChar()}\"")
        // Valid characters inside a string are not mistaken for whitespace or malformed bytes.
        assertEquals("\u2028\ufffd", Json.parseStrict("\"\u2028\ufffd\""))
    }

    @Test fun strictDepthCountsRootAtZeroAndChecksEmptyContainersToo() {
        fun nested(n: Int, leaf: String) = "[".repeat(n) + leaf + "]".repeat(n)
        assertNotNull(Json.parseStrict(nested(8, "0")))
        strictRejects(nested(9, "0"))
        assertNotNull(Json.parseStrict(nested(8, "[]"))) // Deepest empty array is at depth 8.
        strictRejects(nested(9, "[]"))
        assertEquals(emptyMap<String, Any?>(), Json.parseStrict("{}", 0))
        assertEquals(emptyList<Any?>(), Json.parseStrict("[]", 0))
        strictRejects("[0]", 0)
        strictRejects("{\"a\":null}", 0)
        assertThrows(IllegalArgumentException::class.java) { Json.parseStrict("0", -1) }
        assertThrows(IllegalArgumentException::class.java) { Json.parseStrict("0", 65) }
    }

    @Test fun legacyParserRetainsItsExistingLenienciesAndSixtyFourDepthLimit() {
        assertEquals(mapOf("a" to 2L), Json.parse("""{"a":null,"\u0061":2}"""))
        assertEquals(1L, Json.parse("01"))
        assertEquals(-1L, Json.parse("-01"))
        assertEquals(1.0, Json.parse("1.") as Double, 0.0)
        assertEquals(-0.1, Json.parse("-.1") as Double, 0.0)
        assertTrue((Json.parse("1e309") as Double).isInfinite())
        assertEquals("a", Json.parse("\"\\u+061\""))
        assertEquals("\uFFFF", Json.parse("\"\\u-001\""))
        assertEquals("\uD800", Json.parse("\"\\uD800\""))
        assertNotNull(Json.parse("[".repeat(64) + "0" + "]".repeat(64)))
        assertThrows(Json.JsonException::class.java) { Json.parse("[".repeat(65) + "0" + "]".repeat(65)) }
    }
}
