package com.skyjjgw.independent.ski.dshgo.phone.a11y

/** Finite text evidence after one attempted selection replacement; never a dispatch receipt.
 * The caller separately validates the original owner/editor and obtains composition-handling consent.
 * Even a match proves neither causality, the unobserved field, nor application success. */
internal object FocusReadback {
    enum class Kind { LOCAL_CONSISTENT, LOCAL_DIFFERENT, UNKNOWN }
    data class Sample(val text: String, val selectionStart: Int, val selectionEnd: Int, val offset: Int)
    /** False means alignment uses the current caret, not a verified absolute field position. */
    data class Result(val kind: Kind, val absoluteAlignment: Boolean)

    // Local memory budgets, not Android limits. Selected text may exceed a requested window.
    private const val MAX_SAMPLE_UNITS = 4096
    private const val MAX_INSERT_UNITS = 500

    fun compare(before: Sample?, after: Sample?, inserted: String): Result {
        val absolute = before != null && after != null && before.offset >= 0 && after.offset >= 0
        fun answer(kind: Kind) = Result(kind, absolute)
        if (before == null || after == null || !valid(before) || !valid(after) ||
            inserted.length > MAX_INSERT_UNITS || !wellFormed(inserted)) return answer(Kind.UNKNOWN)
        if (after.selectionStart != after.selectionEnd) return answer(Kind.UNKNOWN)

        val left = minOf(before.selectionStart, before.selectionEnd)
        val right = maxOf(before.selectionStart, before.selectionEnd)
        val expected = before.text.substring(0, left) + inserted + before.text.substring(right)
        val caret = left + inserted.length
        if (absolute && after.offset.toLong() + after.selectionStart != before.offset.toLong() + caret)
            return answer(Kind.LOCAL_DIFFERENT)

        // Positions below are relative to expected. Unknown offsets are never converted to zero.
        val shift = if (absolute) after.offset.toLong() - before.offset.toLong()
            else caret.toLong() - after.selectionStart
        val overlapStart = maxOf(0L, shift)
        val afterEnd = shift + after.text.length
        val overlapEnd = minOf(expected.length.toLong(), afterEnd)
        if (overlapStart < overlapEnd) {
            // The intersection guarantees both conversions/indexes are inside the bounded strings.
            for (i in overlapStart.toInt() until overlapEnd.toInt()) {
                if (expected[i] != after.text[(i.toLong() - shift).toInt()])
                    return answer(Kind.LOCAL_DIFFERENT)
            }
        }
        // Seeing only a suffix of inserted is insufficient, even when that suffix matches.
        if (shift > left || afterEnd < caret) return answer(Kind.UNKNOWN)
        return answer(Kind.LOCAL_CONSISTENT)
    }

    private fun valid(sample: Sample): Boolean = sample.offset >= -1 &&
        sample.text.length <= MAX_SAMPLE_UNITS &&
        sample.selectionStart in 0..sample.text.length && sample.selectionEnd in 0..sample.text.length &&
        boundary(sample.text, sample.selectionStart) && boundary(sample.text, sample.selectionEnd)

    /** Edge half-surrogates away from the selection remain literal UTF-16 evidence, not anchors. */
    private fun boundary(text: String, at: Int): Boolean {
        if (at == 0) return text.isEmpty() || !Character.isLowSurrogate(text[0])
        if (at == text.length) return !Character.isHighSurrogate(text[at - 1])
        return !(Character.isHighSurrogate(text[at - 1]) && Character.isLowSurrogate(text[at]))
    }

    private fun wellFormed(text: String): Boolean {
        var i = 0
        while (i < text.length) {
            val c = text[i++]
            if (Character.isHighSurrogate(c)) {
                if (i == text.length || !Character.isLowSurrogate(text[i++])) return false
            } else if (Character.isLowSurrogate(c)) return false
        }
        return true
    }
}
