package com.skyjjgw.independent.ski

/** Platform-independent local UI planner. It never calls a model or replays an uncertain action. */
internal object PhoneFlow {
    class Blocked(val outcome: String, message: String) : IllegalStateException(message)
    class NotDispatched(val failure: Exception) : IllegalStateException(failure.message, failure)

    data class Snapshot(val pkg: String, val window: Int, val rows: List<Map<String, Any?>>, val observation: Map<String, Any?>)
    data class Dispatch(val accepted: Boolean, val dispatched: Boolean)
    interface Backend {
        fun prepare(step: Map<String, Any?>) {}
        fun awaitingResult() {}
        fun check()
        fun now(): Long
        fun snapshot(pkg: String): Snapshot
        // Implementations resolve the semantic target again atomically with dispatch.
        fun perform(step: Map<String, Any?>, pkg: String, requestId: String): Dispatch
        fun performPrepared(step: Map<String, Any?>, pkg: String, requestId: String, prepared: Snapshot): Dispatch =
            perform(step, pkg, requestId)
        // The backend checks whether the previous observation covers the newly prepared step.
        fun reuse(snapshot: Snapshot, pkg: String): Snapshot? = null
        fun metrics(): Map<String, Long> = emptyMap()
        fun awaitChange(milliseconds: Long)
    }
    data class Result(val outcome: String, val summary: String, val value: Map<String, Any?>)

    private val selectorKeys = setOf("text", "textContains", "description", "descriptionContains", "viewId", "className", "clickable", "editable", "scrollable", "checked", "selected", "enabled", "within", "source", "region")
    private val booleanKeys = setOf("clickable", "editable", "scrollable", "checked", "selected", "enabled")
    private val actions = setOf("tap", "input", "scroll", "swipe", "back", "wait")
    @Suppress("UNCHECKED_CAST")
    fun map(value: Any?, name: String): Map<String, Any?> = value as? Map<String, Any?> ?: error("$name 必须是对象。")
    fun number(value: Any?, fallback: Long = 0): Long {
        if (value == null) return fallback
        require(value is Int || value is Long) { "等待时间必须为非负整数。" }
        return (value as Number).toLong().also { require(it >= 0) { "等待时间不能为负数。" } }
    }
    fun validateSelector(selector: Map<String, Any?>) {
        require(selector.isNotEmpty() && selector.keys.all { it in selectorKeys }) { "控件选择条件无效。" }
        require(selector.keys.any { it != "within" }) { "请选择具体控件。" }
        for ((key, value) in selector) when {
            key == "source" -> require(value in setOf("ocr", "accessibility")) { "识别来源无效。" }
            key == "region" -> PhoneVision.region(value)
            key == "within" -> validateSelector(map(value, "within"))
            key in booleanKeys -> require(value is Boolean) { "$key 必须是布尔值。" }
            else -> require(value is String && value.isNotBlank()) { "$key 不能为空。" }
        }
    }
    fun validateCondition(condition: Map<String, Any?>) {
        val kind = condition["kind"]
        require(kind in setOf("exists", "absent", "checked", "selected", "text", "changed", "all", "any")) { "核对条件类型无效。" }
        val fields = when (kind) {
            "all", "any" -> setOf("kind", "conditions")
            "checked", "selected", "text" -> setOf("kind", "selector", kind as String)
            "changed" -> setOf("kind", "selector")
            else -> setOf("kind", "selector")
        }
        require(condition.keys.all { it in fields }) { "核对条件含未知字段。" }
        if (kind == "all" || kind == "any") {
            val children = condition["conditions"] as? List<*> ?: error("缺少子条件。")
            require(children.isNotEmpty()) { "子条件不能为空。" }
            children.forEach { validateCondition(map(it, "condition")) }
        } else {
            if (condition.containsKey("selector")) validateSelector(map(condition["selector"], "selector"))
            else require(kind == "changed") { "缺少核对控件条件。" }
            if (kind == "text") require(condition["text"] is String) { "核对文字必须是字符串。" }
            if (kind == "checked" || kind == "selected") require(condition[kind] is Boolean) { "核对状态必须是布尔值。" }
        }
    }
    fun validate(plan: Map<String, Any?>): List<Map<String, Any?>> {
        require(plan.keys.all { it in setOf("package", "steps", "recognitionMode") }) { "本地流程参数含未知字段。" }
        PhoneVision.mode(plan["recognitionMode"])
        require(plan["package"] is String && Regex("^[a-zA-Z][a-zA-Z0-9_]*(\\.[a-zA-Z0-9_]+)+$").matches(plan["package"] as String)) { "请选择流程软件包名。" }
        val raw = plan["steps"] as? List<*> ?: error("缺少流程步骤。")
        require(raw.isNotEmpty()) { "流程步骤不能为空。" }
        val ids = mutableSetOf<String>()
        return raw.map {
            val step = map(it, "step")
            require(step.keys.all { k -> k in setOf("id", "action", "selector", "text", "direction", "guard", "when", "expect", "timeoutMs", "stableMs") }) { "流程步骤含未知字段。" }
            val id = step["id"] as? String ?: error("缺少步骤编号。")
            require(Regex("^[a-zA-Z0-9_-]+$").matches(id) && ids.add(id)) { "步骤编号无效或重复。" }
            val action = step["action"]
            require(action in actions) { "本地流程动作无效。" }
            if (action !in setOf("back", "wait")) validateSelector(map(step["selector"], "selector"))
            else require(!step.containsKey("selector")) { "此动作不接受目标控件。" }
            if (action == "input") require(step["text"] is String && !(step["text"] as String).contains('\u0000')) { "输入文字无效。" }
            else require(!step.containsKey("text")) { "此动作不接受输入文字。" }
            if (action == "scroll") require(step["direction"] in setOf("forward", "backward")) { "滚动方向无效。" }
            else if (action == "swipe") require(step["direction"] in setOf("up", "down", "left", "right")) { "滑动方向无效。" }
            else require(!step.containsKey("direction")) { "此动作不接受方向。" }
            validateCondition(map(step["expect"], "expect"))
            step["guard"]?.let { guard -> validateCondition(map(guard, "guard")); require(!hasChanged(map(guard, "guard"))) { "页面前置条件不能使用 changed。" } }
            step["when"]?.let { condition -> validateCondition(map(condition, "when")); require(!hasChanged(map(condition, "when"))) { "分支条件不能使用 changed。" } }
            number(step["timeoutMs"]); number(step["stableMs"], 100)
            step
        }
    }
    private fun hasChanged(c: Map<String, Any?>): Boolean = c["kind"] == "changed" ||
        (c["conditions"] as? List<*>)?.any { hasChanged(map(it, "condition")) } == true

    fun matches(row: Map<String, Any?>, selector: Map<String, Any?>, rows: List<Map<String, Any?>>): Boolean {
        for ((key, expected) in selector) {
            val actual = row[if (key == "className") "class" else key]
            when (key) {
                "text" -> if (if(row["source"]=="ocr")PhoneVision.ocrText(actual)!=PhoneVision.ocrText(expected)else actual!=expected)return false
                "source" -> if ((row["source"] ?: "accessibility") != expected) return false
                "region" -> {
                    val width = (row["screenWidth"] as? Number)?.toInt() ?: return false
                    val height = (row["screenHeight"] as? Number)?.toInt() ?: return false
                    if (!PhoneVision.inRegion(row, PhoneVision.region(expected)!!, width, height)) return false
                }
                "within" -> {
                    val ancestor = map(expected, "within")
                    var parent = row["parentId"] as? String
                    val visited = mutableSetOf<String>()
                    var found = false
                    while (parent != null && visited.add(parent)) {
                        val candidate = rows.firstOrNull { it["id"] == parent } ?: break
                        if (matches(candidate, ancestor, rows)) { found = true; break }
                        parent = candidate["parentId"] as? String
                    }
                    if (!found) return false
                }
                "textContains" -> if (row["source"]=="ocr") { if(!PhoneVision.ocrText(row["text"]).contains(PhoneVision.ocrText(expected)))return false } else if (!(row["text"] as? String).orEmpty().contains(expected as String)) return false
                "descriptionContains" -> if (!(row["description"] as? String).orEmpty().contains(expected as String)) return false
                else -> if (actual != expected) return false
            }
        }
        return row["password"] != true
    }
    fun targets(snapshot: Snapshot, selector: Map<String, Any?>) = snapshot.rows.filter { matches(it, selector, snapshot.rows) }
    fun unique(snapshot: Snapshot, selector: Map<String, Any?>): Map<String, Any?> {
        val matches = targets(snapshot, selector)
        require(matches.size == 1) { "控件应唯一匹配，实际为 ${matches.size} 个；请细化选择条件。" }
        return matches.single()
    }
    // IDs, timer nodes outside the selected region and transient coordinates are not identity.
    private fun signature(snapshot: Snapshot, selector: Map<String, Any?>?): Any {
        val roots = if (selector == null) snapshot.rows else targets(snapshot, selector)
        val included = roots.mapNotNull { it["id"] as? String }.toMutableSet()
        var grew: Boolean
        do { grew = false; for (row in snapshot.rows) if (row["parentId"] in included && included.add(row["id"] as String)) grew = true } while (grew)
        val selected=snapshot.rows.filter { it["id"] in included }
        if(selected.any{it["source"]=="ocr"})return mapOf("unsupportedOcrChange" to true)
        return listOf(snapshot.pkg, snapshot.window, selected.map { row ->
            listOf("viewId", "class", "text", "description", "checked", "selected", "editable", "enabled").map { row[it] }
        })
    }
    fun evidence(snapshot: Snapshot, condition: Map<String, Any?>): Any? {
        val selector = condition["selector"]?.let { map(it, "selector") }
        return when (condition["kind"]) {
            "changed" -> signature(snapshot, selector)
            "all", "any" -> (condition["conditions"] as List<*>).map { evidence(snapshot, map(it, "condition")) }
            else -> null
        }
    }
    fun satisfied(snapshot: Snapshot, condition: Map<String, Any?>, before: Any? = null): Boolean {
        val kind = condition["kind"]
        if (kind == "all" || kind == "any") {
            val conditions = condition["conditions"] as List<*>
            val values = conditions.mapIndexed { index, child -> satisfied(snapshot, map(child, "condition"), (before as? List<*>)?.getOrNull(index)) }
            return if (kind == "all") values.all { it } else values.any { it }
        }
        val selector = condition["selector"]?.let { map(it, "selector") }
        if (kind == "changed") {
            val after=signature(snapshot,selector)
            require((before as? Map<*,*>)?.get("unsupportedOcrChange")!=true && (after as? Map<*,*>)?.get("unsupportedOcrChange")!=true){"OCR文字不能以笼统画面变化核验，请明确核对目标文字出现、消失或内容。"}
            return before != null && after != before
        }
        val found = targets(snapshot, selector!!)
        return when (kind) {
            "exists" -> found.isNotEmpty()
            "absent" -> found.isEmpty()
            "text" -> found.size == 1 && if(found.single()["source"]=="ocr")PhoneVision.ocrText(found.single()["text"])==PhoneVision.ocrText(condition["text"])else found.single()["text"]==condition["text"]
            "checked", "selected" -> found.size == 1 && found.single()[kind] == condition[kind]
            else -> false
        }
    }

    /** A checkpoint is persisted before dispatch. Restored in-flight steps can only be verified. */
    fun run(plan: Map<String, Any?>, rootId: String, backend: Backend, checkpoint: Map<String, Any?>? = null,
            save: (Map<String, Any?>) -> Unit): Result {
        val steps = validate(plan)
        val pkg = plan["package"] as String
        val records = steps.map { mutableMapOf<String, Any?>("id" to it["id"], "action" to it["action"], "state" to "queued") }
        if (checkpoint != null) {
            require(checkpoint["flowVersion"] == 1 && checkpoint["rootRequestId"] == rootId && checkpoint["plan"] == plan) { "流程检查点不匹配。" }
            val old = checkpoint["steps"] as? List<*> ?: error("流程检查点缺少步骤。")
            require(old.size == records.size)
            old.forEachIndexed { i, item -> val record = map(item, "checkpoint"); require(record["id"] == steps[i]["id"]); records[i].putAll(record) }
        }
        val started = backend.now()
        val metricsAtStart = backend.metrics()
        val previousElapsed = (checkpoint?.get("elapsedMs") as? Number)?.toLong() ?: 0
        var observations = 0
        var latest: Snapshot? = null
        var reusable: Snapshot? = null
        fun state(outcome: String, reason: String, current: Int?): Map<String, Any?> = mapOf(
            "flowVersion" to 1, "rootRequestId" to rootId, "plan" to plan,
            "steps" to records.map { it.toMap() }, "state" to outcome, "reason" to reason,
            "currentStep" to current, "completedSteps" to records.count { it["state"] in setOf("verified", "skipped") },
            "totalSteps" to steps.size, "elapsedMs" to previousElapsed + backend.now() - started,
            "hasUnverifiedActions" to records.any { (it["attempted"] == true || it["dispatched"] == true) && it["state"] !in setOf("verified", "rejected") },
            "observationCount" to observations, "modelRequestsDuringExecution" to 0,
            "performance" to backend.metrics().mapValues { (name, value) ->
                (value - (metricsAtStart[name] ?: 0L)).coerceAtLeast(0L)
            })
        fun snapshot(): Snapshot { backend.check(); return backend.snapshot(pkg).also { latest = it; observations++ } }
        fun finish(outcome: String, reason: String, index: Int?): Result {
            val stored = state(outcome, reason, index); save(stored)
            val public = stored - "plan"
            return Result(outcome, reason, public + (latest?.observation ?: emptyMap()) +
                mapOf("verifiedRequestId" to if (outcome == "verified") rootId else null, "verification" to "local_ui_predicates"))
        }
        for ((index, step) in steps.withIndex()) {
            val record = records[index]
            if (record["state"] in setOf("verified", "skipped")) continue
            val stepStarted = backend.now()
            val previousStepElapsed = (record["elapsedMs"] as? Number)?.toLong() ?: 0
            val previousDispatch = (record["dispatchMs"] as? Number)?.toLong() ?: 0
            val previous = record["state"]
            val inFlight = previous in setOf("in_flight", "waiting", "unknown")
            try {
                backend.prepare(step)
                backend.check()
                val expect = map(step["expect"], "expect")
                if(inFlight)backend.awaitingResult()
                val previousObservation = reusable
                reusable = null
                var observed = if (!inFlight && step["action"] != "wait" && previousObservation != null) {
                    backend.reuse(previousObservation, pkg)?.also { latest = it } ?: snapshot()
                } else snapshot()
                backend.check()
                val before = if (inFlight) record["before"] else evidence(observed, expect)
                val whenCondition = step["when"]?.let { map(it, "when") }
                if (!inFlight && whenCondition != null && !satisfied(observed, whenCondition)) {
                    record["state"] = "skipped"; record["reason"] = "分支条件不成立，未执行。"; save(state("running", "已跳过条件分支。", index)); continue
                }
                if (!inFlight) {
                    step["guard"]?.let { require(satisfied(observed, map(it, "guard"))) { "页面前置条件不匹配，未派发动作。" } }
                    record["before"] = before
                    if (!satisfied(observed, expect, before) && step["action"] != "wait") {
                        record["state"] = "in_flight"
                        record["attempted"] = true
                        save(state("running", "执行前检查点已保存。", index))
                        val dispatch = backend.performPrepared(step, pkg, "${rootId}_$index", observed)
                        record["dispatched"] = dispatch.dispatched
                        record["attempted"] = dispatch.dispatched
                        if (!dispatch.accepted) {
                            record["state"] = "rejected"
                            return finish("failed", "步骤 ${step["id"]} 未被系统接受。", index)
                        }
                    } else record["alreadySatisfied"] = step["action"] != "wait"
                }
                record["dispatchMs"] = previousDispatch + backend.now() - stepStarted
                record["state"] = "waiting"
                backend.awaitingResult()
                save(state("running", "正在本地核对结果。", index))
                val timeout = number(step["timeoutMs"])
                val stable = number(step["stableMs"], 100)
                var since: Long? = null
                while (true) {
                    backend.check()
                    observed = snapshot()
                    val now = backend.now()
                    if (satisfied(observed, expect, before)) {
                        if (since == null) since = now
                        if (now - since >= stable) break
                    } else since = null
                    if (timeout > 0 && now - stepStarted >= timeout) {
                        record["state"] = if (record["dispatched"] == true || inFlight) "unknown" else "waiting"
                        record["elapsedMs"] = previousStepElapsed + now - stepStarted
                        return finish("unknown", "步骤 ${step["id"]} 等待结果超时；保留现场，未重放动作。", index)
                    }
                    backend.awaitChange(if (timeout > 0) minOf(100, (timeout - (now - stepStarted)).coerceAtLeast(1)) else 100)
                }
                record["state"] = "verified"
                reusable = observed
                record["elapsedMs"] = previousStepElapsed + backend.now() - stepStarted
                record["waitMs"] = (record["elapsedMs"] as Long) - (record["dispatchMs"] as Long)
                save(state("running", "步骤 ${step["id"]} 已核验。", index))
            } catch (error: Exception) {
                if (error is NotDispatched) {
                    record["attempted"] = false; record["dispatched"] = false; record["state"] = "blocked"
                } else if (record["state"] in setOf("in_flight", "waiting")) record["state"] = "unknown"
                else record["state"] = "blocked"
                val cause = if (error is NotDispatched) error.failure else error
                val outcome = (cause as? Blocked)?.outcome ?: if (record["state"] == "unknown") "unknown" else "failed"
                record["reason"] = error.message ?: "流程中断。"
                record["elapsedMs"] = previousStepElapsed + backend.now() - stepStarted
                return finish(outcome, "步骤 ${step["id"]}：${record["reason"]}", index)
            }
        }
        return finish("verified", "本地流程 ${steps.size} 个步骤已完成核验。", null)
    }
}
