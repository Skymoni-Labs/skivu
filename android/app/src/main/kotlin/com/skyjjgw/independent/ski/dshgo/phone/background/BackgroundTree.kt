package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.SafetyRules
import com.skyjjgw.independent.ski.dshgo.phone.SensitiveWords

// The compact screen text format, shared with the main-screen reader. Pure Kotlin:
// an [Element] model plus [render], role words, sensitive-word detection and number
// redaction, so it can be unit-tested on the JVM and reused by the a11y module.
// The virtual-display engine walks AccessibilityNodeInfo into [Element]s (that part
// is Android-only) and calls [render] here.

/** Vertical zone a line sits in (顶部 / 中部 / 底部). */
enum class Region { TOP, MIDDLE, BOTTOM }

/** Screen-pixel bounds, only supplied by explicit detailed background observations. */
data class ElementBounds(val left: Int, val top: Int, val right: Int, val bottom: Int)

/**
 * One rendered element: already collapsed to a TalkBack-style unit (child text merged
 * into the clickable parent). Produced by the engine, consumed by [render].
 */
data class Element(
    /** 1-based number, valid only for the snapshot it belongs to. */
    val id: Int,
    /** Chinese role word (按钮, 输入框, 开关, 勾选框, 标签, 图片, 链接, 列表, 文本). */
    val role: String,
    /** Visible text / description / hint, length-capped and redacted. Never password contents. */
    val label: String,
    val region: Region,
    /** One indent level when inside a scrollable container. */
    val indent: Int = 0,
    /** State words: 已聚焦, 已选, 已勾选, 不可用, 可下滑, 密码·不可代填. */
    val states: List<String> = emptyList(),
    /** Hit by the SafetyGate sensitive-word list: rendered with a ⚠ prefix. */
    val sensitive: Boolean = false,
    /** First seen in the snapshot returned after an action (the "+" marker, set by the driver). */
    val isNew: Boolean = false,
    val packageName: String? = null,
    val isPassword: Boolean = false,
    val isSecretField: Boolean = false,
    val isEditable: Boolean = false,
    val viewId: String? = null,
    /** Raw accessibility scrollability; role text alone does not establish a container. */
    val isScrollable: Boolean = false,
    val bounds: ElementBounds? = null,
)

object BackgroundTree {
    const val LINE_CAP = 60
    const val SCREEN_CAP = 3000
    const val DETAIL_TEXT_BYTES = 32 * 1024
    const val DETAIL_PARCEL_BYTES = 128 * 1024

    /** Preserve a contiguous prefix: the privileged action resolver uses the original index.
     * Reserve 1 KiB for the bounded header, region labels, privacy and truncation notes.
     * The separate wire-string budget avoids first allocating an oversized Parcel. The
     * actual element Bundle is also measured before it is attached to a response. */
    internal fun detailPrefixCount(elements: List<Element>): Int {
        var textBytes = 1024L
        var wireBytes = 1024L
        for ((index, element) in elements.take(600).withIndex()) {
            val strings = listOf(element.role, element.label, element.viewId.orEmpty()) + element.states
            // Check length before UTF-8 conversion; never shorten an action fingerprint.
            if (strings.any { it.length > 4096 }) return index
            val nextWire = strings.sumOf { it.toByteArray(Charsets.UTF_8).size.toLong() + it.length * 2L + 16 } + 64
            // A zone can change for every row. Include its newline as well as the row's.
            val nextText = renderLine(element).toByteArray(Charsets.UTF_8).size.toLong() + 8
            if (wireBytes + nextWire > 96 * 1024 || textBytes + nextText > DETAIL_TEXT_BYTES) return index
            wireBytes += nextWire
            textBytes += nextText
        }
        return minOf(elements.size, 600)
    }

    /** Selects the element owner and proposes the order for a full viewport privacy scan.
     * Selection alone does not establish that any root can be completely read. */
    internal data class WindowSelection(val index: Int, val scanOrder: List<Int>)

    internal fun selectApplicationWindow(packages: List<String?>, target: String): WindowSelection? {
        val index = packages.indexOfFirst { it == target }
        if (index < 0) return null
        // Preserve the first exact target as the sole element owner. Every other
        // application root, including one with an unknown package, still needs scanning.
        return WindowSelection(index, listOf(index) + packages.indices.filter { it != index })
    }

    fun isSensitiveLabel(label: String): Boolean = SensitiveWords.confirmHit(label, null) != null

    fun isSecretHint(text: String): Boolean = SensitiveWords.secretHit(text, null, null) != null

    /**
     * An element's label from its best [text] (text → description → hint). A password shows
     * nothing. Another secret element (a code field: [isSecretHint] on its hint / description)
     * shows its [name] (description or hint) and, when [filled] with text of its own,
     * [SafetyRules.MASK]: the field can be found, the code never read.
     */
    fun label(text: String, name: String, filled: Boolean, password: Boolean, secret: Boolean): String = when {
        password -> ""
        secret -> cap(if (filled) "$name ${SafetyRules.MASK}".trim() else name)
        else -> redact(cap(text))
    }

    /** Mask bank-card / ID-card runs to «银行卡 ****1234» style. Pure. */
    fun redact(text: String): String {
        var out = text
        // Mainland ID card first (17 digits + digit/X), so the broader card pattern can't swallow it.
        out = Regex("(?<!\\d)\\d{17}[\\dXx](?!\\d)").replace(out) { m ->
            // l10n:keep model screen format and matchers
            "«身份证 ****" + m.value.takeLast(4) + "»"
        }
        // 13–19 digit card numbers (optionally spaced/dashed); greedy so a long run is taken whole.
        out = Regex("(?<!\\d)(?:\\d[ -]?){12,18}\\d(?!\\d)").replace(out) { m ->
            val digits = m.value.filter(Char::isDigit)
            // l10n:keep model screen format and matchers
            "«银行卡 ****" + digits.takeLast(4) + "»"
        }
        return out
    }

    fun cap(text: String, max: Int = LINE_CAP): String {
        val clean = text.replace('\n', ' ').trim()
        return if (clean.length <= max) clean else clean.take(max - 1) + "…"
    }

    /**
     * Render the screen text. [screenId] e.g. "b1"; background screens carry the 后台屏 marker.
     * [overflow] is the count dropped past [SCREEN_CAP]; when > 0 a trailing hint is appended.
     */
    fun render(
        screenId: String,
        appLabel: String?,
        portrait: Boolean,
        keyboardUp: Boolean,
        elements: List<Element>,
        background: Boolean,
        poorTree: Boolean,
        overflow: Int = 0,
        detailed: Boolean = false,
        treeComplete: Boolean? = null,
    ): String {
        val header = buildString {
            // l10n:keep model screen format and matchers
            append("屏幕 ").append(screenId)
            // l10n:keep model screen format and matchers
            if (background) append(" · 后台屏")
            appLabel?.let { append(" · ").append(it) }
            // l10n:keep model screen format and matchers
            append(" · ").append(if (portrait) "竖屏" else "横屏")
            // l10n:keep model screen format and matchers
            append(" · ").append(if (keyboardUp) "键盘弹出" else "键盘收起")
            // l10n:keep model screen format and matchers
            append(" · 共 ").append(elements.size).append(" 项")
        }
        val lines = ArrayList<String>()
        lines.add(header)
        // l10n:keep model screen format and matchers
        if (poorTree) lines.add("（本页文字信息不足，可能是游戏、画布或小程序）")
        var lastRegion: Region? = null
        for (e in elements) {
            if (e.region != lastRegion) {
                lines.add(regionLabel(e.region))
                lastRegion = e.region
            }
            lines.add(renderLine(e))
        }
        // l10n:keep model screen format and matchers
        if (overflow > 0) {
            // l10n:keep model screen format
            if (detailed) lines.add("（本次已读取的元素中另有 $overflow 项未列出；未列出的元素没有可用编号）")
            else lines.add("  …另有 $overflow 项，用 collect 或 scroll")
        }
        // This is the bounded accessibility scan, never a claim about all app/web content.
        // l10n:keep model screen format
        if (detailed && treeComplete == false) lines.add("（控件树扫描未完整结束；未读取的节点数量未知）")
        return lines.joinToString("\n")
    }

    private fun regionLabel(region: Region): String = when (region) {
        // l10n:keep model screen format and matchers
        Region.TOP -> "顶部"
        // l10n:keep model screen format and matchers
        Region.MIDDLE -> "中部"
        // l10n:keep model screen format and matchers
        Region.BOTTOM -> "底部"
    }

    private fun renderLine(e: Element): String {
        val sb = StringBuilder()
        sb.append("  ".repeat(1 + e.indent))
        if (e.isNew) sb.append("+ ")
        if (e.sensitive) sb.append("⚠ ")
        sb.append('[').append(e.id).append("] ")
        sb.append(e.role)
        val label = cap(e.label)
        if (label.isNotEmpty()) sb.append(' ').append(label)
        if (e.states.isNotEmpty()) sb.append("（").append(e.states.joinToString("，")).append("）")
        e.bounds?.let { sb.append(" @[").append(it.left).append(',').append(it.top)
            .append(',').append(it.right).append(',').append(it.bottom).append(']') }
        return sb.toString()
    }
}
