package com.skyjjgw.independent.ski

/** Geometry and routing have no Android/model dependency and can be tested on the JVM. */
internal object PhoneVision {
    val modes = setOf("auto", "visual", "controls")
    fun mode(value: Any?, fallback: String = "auto"): String {
        val selected = value ?: fallback
        require(selected in modes) { "识别方式必须为 auto、visual 或 controls。" }
        return selected as String
    }
    fun region(value: Any?): List<Double>? {
        if (value == null) return null
        require(value is List<*> && value.size == 4) { "区域需要四个 0–1 的比例。" }
        val r = value.map { require(it is Number); it.toDouble().also { n -> require(n.isFinite() && n in 0.0..1.0) } }
        require(r[2] > r[0] && r[3] > r[1]) { "区域范围无效。" }
        return r
    }
    data class Geometry(val left: Int, val top: Int, val width: Int, val height: Int,
                        val imageWidth: Int, val imageHeight: Int) {
        init { require(left >= 0 && top >= 0 && minOf(width, height, imageWidth, imageHeight) > 0) }
        fun screen(box: List<Int>): List<Int> {
            require(box.size == 4 && box[0] >= 0 && box[1] >= 0 && box[2] > box[0] && box[3] > box[1])
            require(box[2] <= imageWidth && box[3] <= imageHeight)
            return listOf(left + box[0] * width / imageWidth, top + box[1] * height / imageHeight,
                left + (box[2].toLong() * width + imageWidth - 1).div(imageWidth).toInt(),
                top + (box[3].toLong() * height + imageHeight - 1).div(imageHeight).toInt())
        }
    }
    fun inRegion(row: Map<String, Any?>, region: List<Double>, width: Int, height: Int): Boolean {
        val b = (row["bounds"] as? List<*>)?.map { (it as Number).toDouble() } ?: return false
        val x = (b[0] + b[2]) / (2 * width); val y = (b[1] + b[3]) / (2 * height)
        return x >= region[0] && x <= region[2] && y >= region[1] && y <= region[3]
    }
    fun ocrText(value:Any?):String = java.text.Normalizer.normalize(value?.toString().orEmpty(),java.text.Normalizer.Form.NFKC)
        .replace(Regex("(?<=[\\u4e00-\\u9fff])ー(?=[\\u4e00-\\u9fff])"),"一")
        .replace(Regex("(?<=[\\u4e00-\\u9fff])\\s+(?=[\\u4e00-\\u9fff])"),"").trim()
    fun text(value: Any?) = ocrText(value).replace(Regex("\\s+"), "").lowercase()
    fun merge(native: List<Map<String, Any?>>, ocr: List<Map<String, Any?>>,
              requiredOcrSelectors: List<Map<String, Any?>> = emptyList()): List<Map<String, Any?>> {
        val allRows = native + ocr
        return native + ocr.mapNotNull { visual ->
            val duplicates = native.filter { node ->
                if (node["password"] == true || text(node["text"]).isEmpty() || text(node["text"]) != text(visual["text"])) false
                else {
                    val a = (node["bounds"] as List<*>).map { (it as Number).toInt() }
                    val b = (visual["bounds"] as List<*>).map { (it as Number).toInt() }
                    val x = (b[0] + b[2]) / 2; val y = (b[1] + b[3]) / 2
                    x in a[0]..a[2] && y in a[1]..a[3]
                }
            }
            if (duplicates.isEmpty()) visual
            else if (requiredOcrSelectors.none { PhoneFlow.matches(visual, it, allRows) }) null
            else {
                val nativeId = duplicates.singleOrNull()?.get("id") as? String
                if (nativeId == null) visual - "nativeElementId"
                else visual + ("nativeElementId" to nativeId)
            }
        }
    }
    fun needsOcr(rows: List<Map<String, Any?>>, query: String?, selectors: List<Map<String, Any?>>): Boolean {
        val webView = rows.any(::isWebView)
        if (!query.isNullOrBlank()) return webView || rows.none { listOf(it["text"], it["description"], it["viewId"]).any { v -> v?.toString()?.contains(query, true) == true } }
        if (selectors.isNotEmpty()) return selectors.any { s ->
            if (s["source"] == "accessibility") false
            else {
                val visibleText = listOf("text", "textContains", "description", "descriptionContains").any { s[it] != null }
                s["source"] == "ocr" || (visibleText && (webView || rows.none { PhoneFlow.matches(it, s, rows) }))
            }
        }
        return webView || rows.none { it["password"] != true && (it["text"]?.toString()?.isNotBlank() == true || it["description"]?.toString()?.isNotBlank() == true) }
    }

    /** Public text projection. Raw accessibility identity and state stay in the original rows. */
    fun visibleProjection(rows: List<Map<String, Any?>>): List<Map<String, Any?>> {
        val native = rows.indices.filter { rows[it]["source"] == "accessibility" }
        val byId = native.mapNotNull { index -> (rows[index]["id"] as? String)?.let { it to rows[index] } }.toMap()
        val parents = native.mapNotNull { rows[it]["parentId"] as? String }.toSet()
        val leaves = native.filter { index ->
            val row = rows[index]
            val id = row["id"] as? String
            id != null && id !in parents && row["password"] != true &&
                listOf(row["text"], row["description"]).any { text(it).isNotEmpty() } && inWebView(row, byId)
        }
        val visual = rows.indices.filter { rows[it]["source"] == "ocr" && text(rows[it]["text"]).isNotEmpty() }
        val boxes = rows.map(::visibleBox)
        val matches = leaves.associateWith { node ->
            val a = boxes[node]
            visual.filter { image ->
                val b = boxes[image]
                a != null && b != null && b.containsCenter(a) && (a.containsCenter(b) || a.containsLeadingAnchor(b))
            }
        }
        val uses = matches.values.flatten().groupingBy { it }.eachCount()
        val projected = rows.toMutableList()
        for ((node, images) in matches) {
            val image = images.singleOrNull() ?: continue
            if (uses[image] != 1) continue
            val original = rows[node]
            val visible = text(rows[image]["text"])
            val conflicts = listOf("text", "description").filter { text(original[it]).isNotEmpty() && text(original[it]) != visible }
            if (conflicts.isEmpty()) continue
            val changes = mutableMapOf<String, Any?>("textConflict" to true)
            for (field in conflicts) {
                changes[if (field == "text") "accessibilityText" else "accessibilityDescription"] = original[field]
                changes[field] = ""
            }
            projected[node] = original + changes
            projected[image] = rows[image] + mapOf("nativeElementId" to original["id"], "textConflict" to true)
        }
        return projected
    }

    private fun isWebView(row: Map<String, Any?>): Boolean = (row["class"] as? String)?.endsWith(".WebView") == true

    private fun inWebView(row: Map<String, Any?>, byId: Map<String, Map<String, Any?>>): Boolean {
        var current: Map<String, Any?>? = row
        val visited = mutableSetOf<String>()
        while (current != null) {
            if (isWebView(current)) return true
            val parent = current["parentId"] as? String ?: return false
            if (!visited.add(parent)) return false
            current = byId[parent]
        }
        return false
    }

    private data class VisibleBox(val left: Double, val top: Double, val right: Double, val bottom: Double) {
        fun containsCenter(other: VisibleBox): Boolean =
            (other.left + other.right) / 2 in left..right && (other.top + other.bottom) / 2 in top..bottom

        fun containsLeadingAnchor(other: VisibleBox): Boolean =
            other.left in left..right && (other.top + other.bottom) / 2 in top..bottom
    }

    private fun visibleBox(row: Map<String, Any?>): VisibleBox? {
        val values = row["bounds"] as? List<*> ?: return null
        if (values.size != 4 || values.any { it !is Number || !it.toDouble().isFinite() }) return null
        val b = values.map { (it as Number).toDouble() }
        if (b[2] <= b[0] || b[3] <= b[1]) return null
        return VisibleBox(b[0], b[1], b[2], b[3])
    }
}
