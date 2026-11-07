package com.skyjjgw.independent.ski

import android.icu.text.Transliterator
import java.util.Locale

/** One instance per app-list query: ICU transliterators are not shared across workers. */
internal class AppAlphabet {
    private val romanizer by lazy { Transliterator.getInstance("Han-Latin; Latin-ASCII") }

    fun fields(name: String): Map<String, String> {
        val romanized = (if (name.any { it.code > 127 }) romanizer.transliterate(name) else name)
            .lowercase(Locale.ROOT)
        val words = romanized.split(Regex("[^a-z0-9]+")).filter { it.isNotEmpty() }
        val compact = words.joinToString("")
        val initials = words.joinToString("") { it.take(1) }
        return mapOf(
            "sortName" to compact.ifEmpty { name.lowercase(Locale.ROOT) },
            "searchName" to "$romanized $compact $initials"
        )
    }
}
