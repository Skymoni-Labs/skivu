package com.skyjjgw.independent.ski.dshgo.phone

/**
 * Minimal JSON for the phone bridge (MCP framing, guest config, policies). Plain Kotlin so the
 * protocol code runs on the JVM tests too; Android's org.json differs in small ways we don't want
 * on the wire. Objects parse to [LinkedHashMap] (key order kept), arrays to [List], integers that
 * fit to [Long], other numbers to [Double].
 */
object Json {
    class JsonException(message: String) : Exception(message)

    fun parse(text: String): Any? {
        val p = Parser(text)
        p.ws()
        val v = p.value(0)
        p.ws()
        if (p.i != text.length) throw JsonException("trailing data at ${p.i}")
        return v
    }

    /** Bounded internal documents only. The caller must decode bytes with UTF-8 REPORT.
     * Root value is depth 0; each object value/array item adds 1 (including empty containers).
     * Decimal/exponent numbers remain Double; callers requiring integers must require Long. */
    internal fun parseStrict(text: String, maxDepth: Int = 8): Any? {
        require(maxDepth in 0..64)
        val p = Parser(text, strict = true, maxDepth = maxDepth)
        p.ws()
        val v = p.value(0)
        p.ws()
        if (p.i != text.length) throw JsonException("trailing data at ${p.i}")
        return v
    }

    fun write(value: Any?): String = StringBuilder().also { write(it, value) }.toString()

    private fun write(out: StringBuilder, value: Any?) {
        when (value) {
            null -> out.append("null")
            is String -> quote(out, value)
            is Boolean -> out.append(value)
            is Int, is Long, is Short, is Byte -> out.append(value.toString())
            is Double -> number(out, value)
            is Float -> number(out, value.toDouble())
            is Number -> out.append(value.toString())
            is Map<*, *> -> {
                out.append('{')
                var first = true
                for ((k, v) in value) {
                    if (!first) out.append(',')
                    first = false
                    quote(out, k.toString())
                    out.append(':')
                    write(out, v)
                }
                out.append('}')
            }
            is Iterable<*> -> {
                out.append('[')
                var first = true
                for (v in value) {
                    if (!first) out.append(',')
                    first = false
                    write(out, v)
                }
                out.append(']')
            }
            is Array<*> -> write(out, value.asList())
            is Enum<*> -> quote(out, value.name)
            else -> quote(out, value.toString())
        }
    }

    private fun number(out: StringBuilder, d: Double) {
        when {
            d.isNaN() || d.isInfinite() -> out.append("null")
            d == Math.rint(d) && Math.abs(d) < 1e15 -> out.append(d.toLong())
            else -> out.append(d.toString())
        }
    }

    private fun quote(out: StringBuilder, s: String) {
        out.append('"')
        for (c in s) {
            when {
                c == '"' -> out.append("\\\"")
                c == '\\' -> out.append("\\\\")
                c == '\n' -> out.append("\\n")
                c == '\r' -> out.append("\\r")
                c == '\t' -> out.append("\\t")
                c < ' ' || c == ' ' || c == ' ' -> out.append(String.format(java.util.Locale.ROOT, "\\u%04x", c.code))
                else -> out.append(c)
            }
        }
        out.append('"')
    }

    private val STRICT_NUMBER = Regex("-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")

    private class Parser(val s: String, val strict: Boolean = false, val maxDepth: Int = 64) {
        var i = 0

        fun ws() {
            while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++
        }

        fun value(depth: Int): Any? {
            if (depth > maxDepth) throw JsonException("nested too deep")
            if (i >= s.length) throw JsonException("unexpected end")
            return when (val c = s[i]) {
                '{' -> obj(depth)
                '[' -> arr(depth)
                '"' -> str()
                't' -> lit("true", true)
                'f' -> lit("false", false)
                'n' -> lit("null", null)
                else -> if (c == '-' || c in '0'..'9') num() else throw JsonException("unexpected '$c' at $i")
            }
        }

        fun lit(word: String, v: Any?): Any? {
            if (!s.startsWith(word, i)) throw JsonException("bad literal at $i")
            i += word.length
            return v
        }

        fun obj(depth: Int): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            i++
            ws()
            if (i < s.length && s[i] == '}') { i++; return m }
            while (true) {
                ws()
                if (i >= s.length || s[i] != '"') throw JsonException("expected key at $i")
                val k = str()
                if (strict && m.containsKey(k)) throw JsonException("duplicate object key")
                ws()
                if (i >= s.length || s[i] != ':') throw JsonException("expected ':' at $i")
                i++
                ws()
                m[k] = value(depth + 1)
                ws()
                if (i >= s.length) throw JsonException("unexpected end")
                when (s[i]) {
                    ',' -> i++
                    '}' -> { i++; return m }
                    else -> throw JsonException("expected ',' or '}' at $i")
                }
            }
        }

        fun arr(depth: Int): List<Any?> {
            val l = ArrayList<Any?>()
            i++
            ws()
            if (i < s.length && s[i] == ']') { i++; return l }
            while (true) {
                ws()
                l += value(depth + 1)
                ws()
                if (i >= s.length) throw JsonException("unexpected end")
                when (s[i]) {
                    ',' -> i++
                    ']' -> { i++; return l }
                    else -> throw JsonException("expected ',' or ']' at $i")
                }
            }
        }

        fun str(): String {
            val b = StringBuilder()
            i++
            while (true) {
                if (i >= s.length) throw JsonException("unterminated string")
                val c = s[i++]
                when {
                    c == '"' -> {
                        val value = b.toString()
                        if (strict) unicode(value)
                        return value
                    }
                    c == '\\' -> {
                        if (i >= s.length) throw JsonException("bad escape")
                        when (val e = s[i++]) {
                            '"' -> b.append('"')
                            '\\' -> b.append('\\')
                            '/' -> b.append('/')
                            'b' -> b.append('\b')
                            'f' -> b.append('\u000c')
                            'n' -> b.append('\n')
                            'r' -> b.append('\r')
                            't' -> b.append('\t')
                            'u' -> {
                                if (i + 4 > s.length) throw JsonException("bad \\u escape")
                                val hex = s.substring(i, i + 4)
                                if (strict && hex.any { it !in '0'..'9' && it !in 'a'..'f' && it !in 'A'..'F' }) {
                                    throw JsonException("bad \\u escape")
                                }
                                b.append(hex.toIntOrNull(16)?.toChar() ?: throw JsonException("bad \\u escape"))
                                i += 4
                            }
                            else -> throw JsonException("bad escape \\$e")
                        }
                    }
                    c < ' ' -> throw JsonException("control character in string")
                    else -> b.append(c)
                }
            }
        }

        private fun unicode(value: String) {
            var offset = 0
            while (offset < value.length) {
                val c = value[offset]
                if (c.isHighSurrogate()) {
                    if (offset + 1 >= value.length || !value[offset + 1].isLowSurrogate()) {
                        throw JsonException("unpaired surrogate")
                    }
                    offset += 2
                } else {
                    if (c.isLowSurrogate()) throw JsonException("unpaired surrogate")
                    offset++
                }
            }
        }

        fun num(): Any {
            val start = i
            if (s[i] == '-') i++
            while (i < s.length && s[i] in '0'..'9') i++
            var integral = true
            if (i < s.length && s[i] == '.') {
                integral = false
                i++
                while (i < s.length && s[i] in '0'..'9') i++
            }
            if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
                integral = false
                i++
                if (i < s.length && (s[i] == '+' || s[i] == '-')) i++
                while (i < s.length && s[i] in '0'..'9') i++
            }
            val t = s.substring(start, i)
            if (strict && !STRICT_NUMBER.matches(t)) throw JsonException("bad number at $start")
            if (t == "-" || t.isEmpty()) throw JsonException("bad number at $start")
            if (integral) t.toLongOrNull()?.let { return it }
            val number = t.toDoubleOrNull() ?: throw JsonException("bad number at $start")
            if (strict && !number.isFinite()) throw JsonException("non-finite number")
            return number
        }
    }
}
