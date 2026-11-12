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
    fun merge(native: List<Map<String, Any?>>, ocr: List<Map<String, Any?>>): List<Map<String, Any?>> {
        return native + ocr.filter { visual -> native.none { node ->
            if (node["password"] == true || text(node["text"]).isEmpty() || text(node["text"]) != text(visual["text"])) false
            else {
                val a = (node["bounds"] as List<*>).map { (it as Number).toInt() }
                val b = (visual["bounds"] as List<*>).map { (it as Number).toInt() }
                val x = (b[0] + b[2]) / 2; val y = (b[1] + b[3]) / 2
                x in a[0]..a[2] && y in a[1]..a[3]
            }
        } }
    }
    fun needsOcr(rows: List<Map<String, Any?>>, query: String?, selectors: List<Map<String, Any?>>): Boolean {
        if (!query.isNullOrBlank()) return rows.none { listOf(it["text"], it["description"], it["viewId"]).any { v -> v?.toString()?.contains(query, true) == true } }
        if (selectors.isNotEmpty()) return selectors.any { s ->
            s["source"] == "ocr" || ((s["text"] != null || s["textContains"] != null) && rows.none { PhoneFlow.matches(it, s, rows) })
        }
        return rows.none { it["password"] != true && (it["text"]?.toString()?.isNotBlank() == true || it["description"]?.toString()?.isNotBlank() == true) }
    }
}
