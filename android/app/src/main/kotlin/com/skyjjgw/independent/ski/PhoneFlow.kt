package com.skyjjgw.independent.ski

/** Platform-independent local UI planner. It never calls a model or replays an uncertain action. */
internal object PhoneFlow {
    class Blocked(val outcome: String, message: String) : IllegalStateException(message)
    class NotDispatched(val failure: Exception) : IllegalStateException(failure.message, failure)
    class ObservationUnavailable(message: String) : IllegalStateException(message)

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
        // A capture backend can absorb this wait into its own earliest-frame deadline.
        fun awaitObservation(milliseconds: Long) = awaitChange(milliseconds)
    }
    data class Result(val outcome: String, val summary: String, val value: Map<String, Any?>)

    private val selectorKeys = setOf("text", "textContains", "description", "descriptionContains", "viewId", "className", "clickable", "editable", "scrollable", "checked", "selected", "enabled", "within", "source", "region")
    private val booleanKeys = setOf("clickable", "editable", "scrollable", "checked", "selected", "enabled")
    private val actions = setOf("tap", "set_checked", "input", "scroll", "swipe", "back", "wait")
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
        require(kind in setOf("exists", "absent", "checked", "visual_checked", "selected", "text", "changed", "all", "any")) { "核对条件类型无效。" }
        val fields = when (kind) {
            "all", "any" -> setOf("kind", "conditions")
            "checked", "selected", "text" -> setOf("kind", "selector", kind as String)
            "visual_checked" -> setOf("kind", "selector", "checked")
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
            if (kind in setOf("checked", "visual_checked", "selected")) require(condition[if(kind=="visual_checked")"checked" else kind] is Boolean) { "核对状态必须是布尔值。" }
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
            val step = normalizeStep(map(it, "step"))
            require(step.keys.all { k -> k in setOf("id", "action", "selector", "text", "direction", "checked", "guard", "when", "expect", "timeoutMs", "stableMs") }) { "流程步骤含未知字段。" }
            val id = step["id"] as? String ?: error("缺少步骤编号。")
            require(Regex("^[a-zA-Z0-9_-]+$").matches(id) && ids.add(id)) { "步骤编号无效或重复。" }
            val action = step["action"]
            require(action in actions) { "本地流程动作无效。" }
            if(action=="set_checked")require(step["checked"] is Boolean){"目标勾选状态必须是布尔值。"}
            else require(!step.containsKey("checked")){"此动作不接受目标勾选状态。"}
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

    private fun normalizeStep(step:Map<String,Any?>):Map<String,Any?> {
        if(step["action"]!="set_checked")return step
        require(step["checked"] is Boolean){"目标勾选状态必须是布尔值。"}
        val required=mapOf("kind" to "checked","selector" to step["selector"],"checked" to step["checked"])
        val expected=step["expect"]?.let{mapOf("kind" to "all","conditions" to listOf(required,it))}?:required
        return step+mapOf("expect" to expected)
    }

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
    fun targets(snapshot: Snapshot, selector: Map<String, Any?>): List<Map<String, Any?>> {
        val matched = snapshot.rows.filter { matches(it, selector, snapshot.rows) }
        if ("source" in selector) return matched
        val nativeIds = matched.filter { (it["source"] ?: "accessibility") == "accessibility" }
            .mapNotNull { it["id"] as? String }.toSet()
        return matched.filterNot { row ->
            row["source"] == "ocr" && row["nativeElementId"] in nativeIds
        }
    }
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
            "checked", "visual_checked" -> found.size == 1 && checkedState(snapshot,found.single(),kind=="visual_checked")==condition["checked"]
            "selected" -> found.size == 1 && selectedState(found.single())==condition[kind]
            else -> false
        }
    }

    /** Text recognition and Android's default false flags do not establish state capabilities. */
    fun checkedState(snapshot:Snapshot,row:Map<String,Any?>,visualOnly:Boolean=false):Boolean? {
        val nativeRow=if(row["source"]!="ocr")row else snapshot.rows.singleOrNull{it["source"]!="ocr" && it["id"]==row["nativeElementId"]}
        val native=if(nativeRow?.get("checkable")==true)nativeRow["checked"] as? Boolean else null
        val visual=visualCheckedState(snapshot,row)
        if(native!=null && visual!=null && native!=visual)return null
        return if(visualOnly)visual else native?:visual
    }

    private fun visualCheckedState(snapshot:Snapshot,row:Map<String,Any?>):Boolean? {
        val observation=snapshot.observation
        val confidence=(row["visualStateConfidence"] as? Number)?.toDouble()?:return null
        val mark=(row["visualMarkBounds"] as? List<*>)?.map{(it as? Number)?.toDouble()?:return null}?:return null
        if(mark.size!=4 || mark.any{!it.isFinite() || it<0} || mark[2]<=mark[0] || mark[3]<=mark[1])return null
        if(row["visualChecked"] !is Boolean || !confidence.isFinite() || confidence<0.9 ||
            row["visualStateKind"] !in setOf("radio","checkbox") ||
            row["visualStateObservationId"] !is String || row["visualStateObservationId"]!=observation["observationId"] ||
            row["visualStateCapturedAtMs"] !is Number || row["visualStateCapturedAtMs"]!=observation["capturedAtMs"] ||
            observation["imageHash"] !is String || (observation["imageHash"] as String).isEmpty() ||
            row["visualStateImageHash"]!=observation["imageHash"])return null
        return row["visualChecked"] as Boolean
    }

    private fun selectedState(row:Map<String,Any?>):Boolean? {
        if(row["source"]=="ocr")return null
        val selected=row["selected"] as? Boolean?:return null
        return selected.takeIf{it || row["selectionSupported"]==true}
    }

    private data class Completion(val matched:Boolean,val proven:Boolean,val kind:String="unverified")
    private fun sameTarget(snapshot:Snapshot,step:Map<String,Any?>,row:Map<String,Any?>,beforeTarget:Map<String,Any?>?=null):Boolean {
        val selector=step["selector"]?.let{map(it,"selector")}?:return false
        val target=targets(snapshot,selector).singleOrNull()
        if(target!=null) {
            val targetIds=listOfNotNull(target["id"],target["nativeElementId"]).toSet()
            if(row["id"] in targetIds || row["nativeElementId"] in targetIds || row==target)return true
        }
        val viewId=beforeTarget?.get("viewId") as? String
        return !viewId.isNullOrEmpty() && row["viewId"]==viewId && row["class"]==beforeTarget?.get("class")
    }

    private fun targetEvidence(snapshot:Snapshot,step:Map<String,Any?>):Map<String,Any?>? {
        val selector=step["selector"]?.let{map(it,"selector")}?:return null
        val target=targets(snapshot,selector).singleOrNull()?:return null
        return mapOf("viewId" to target["viewId"],"class" to target["class"])
    }

    private fun targetSignature(row:Map<String,Any?>)=listOf("viewId","class","text","description","checked","selected","editable","enabled").map{row[it]}
    private fun conditionBefore(snapshot:Snapshot,condition:Map<String,Any?>):Map<String,Any?> {
        if(condition["kind"] in setOf("all","any"))return mapOf("conditions" to (condition["conditions"] as List<*>).map{conditionBefore(snapshot,map(it,"condition"))})
        val row=condition["selector"]?.let{targets(snapshot,map(it,"selector")).singleOrNull()}
        return mapOf("matched" to if(condition["kind"]=="changed")false else satisfied(snapshot,condition),
            "selected" to (row?.get("selected")==true && row?.get("source")!="ocr"),
            "signature" to row?.let(::targetSignature))
    }

    fun completionEvidence(snapshot:Snapshot,step:Map<String,Any?>):Map<String,Any?> = mapOf(
        "condition" to conditionBefore(snapshot,map(step["expect"],"expect")),"target" to targetEvidence(snapshot,step))

    private fun completion(snapshot:Snapshot,step:Map<String,Any?>,condition:Map<String,Any?>,before:Map<String,Any?>?,beforeTarget:Map<String,Any?>?):Completion {
        val kind=condition["kind"]
        if(kind in setOf("all","any")) {
            val old=before?.get("conditions") as? List<*>
            val results=(condition["conditions"] as List<*>).mapIndexed{i,value->completion(snapshot,step,map(value,"condition"),old?.getOrNull(i)?.let{map(it,"before")},beforeTarget)}
            val matched=if(kind=="all")results.all{it.matched}else results.any{it.matched}
            val proof=results.firstOrNull{it.matched && it.proven}
            return Completion(matched,matched && proof!=null,proof?.kind?:"unverified")
        }
        val rows=condition["selector"]?.let{targets(snapshot,map(it,"selector"))}.orEmpty()
        val row=rows.singleOrNull()
        if(kind=="changed") {
            val changed=row!=null && row["source"]!="ocr" && before?.get("signature")!=null && targetSignature(row)!=before["signature"]
            return Completion(changed,changed && sameTarget(snapshot,step,row!!,beforeTarget),"target_changed")
        }
        val matched=if(kind=="selected" && condition["selected"]==false && before?.get("selected")==true)
            row!=null && row["source"]!="ocr" && row["selected"]==false else satisfied(snapshot,condition)
        if(!matched)return Completion(false,false)
        val related=row!=null && sameTarget(snapshot,step,row,beforeTarget)
        return when(kind) {
            "checked","visual_checked" -> Completion(true,related,if(row?.get("source")=="ocr" || kind=="visual_checked")"visual_checked"else"native_checked")
            "selected" -> Completion(true,related,"native_selected")
            "text" -> if(step["action"]=="input" && related && row?.get("editable")==true && condition["text"]==step["text"])
                Completion(true,true,"input_text") else Completion(true,before?.get("matched")==false,"predicate_transition")
            else -> Completion(true,before?.get("matched")==false,"predicate_transition")
        }
    }

    private fun validateCompletion(snapshot:Snapshot,step:Map<String,Any?>,condition:Map<String,Any?>) {
        if(condition["kind"] in setOf("all","any")) {
            (condition["conditions"] as List<*>).forEach{validateCompletion(snapshot,step,map(it,"condition"))};return
        }
        if(condition["kind"] !in setOf("checked","visual_checked","selected","changed"))return
        val row=condition["selector"]?.let{targets(snapshot,map(it,"selector")).singleOrNull()}
        val supported=row!=null && sameTarget(snapshot,step,row) && when(condition["kind"]) {
            "checked","visual_checked" -> checkedState(snapshot,row,condition["kind"]=="visual_checked")!=null
            "selected" -> row["source"]!="ocr" && row["selected"] is Boolean && (condition["selected"]==true || row["selected"]==true || row["selectionSupported"]==true)
            else -> row["source"]!="ocr"
        }
        if(!supported)throw Blocked("failed","invalid_postcondition：核对条件缺少与动作目标关联的可信状态证据。")
    }

    /** All dispatch entry points use this rule, including refreshed native/visual targets. */
    fun shouldSkip(snapshot:Snapshot,step:Map<String,Any?>):Boolean {
        if(step["action"]=="wait")return false
        val expected=map(step["expect"],"expect")
        validateCompletion(snapshot,step,expected)
        val skipCondition=if(step["action"]=="set_checked")mapOf("kind" to "checked","selector" to step["selector"],"checked" to step["checked"])else expected
        val result=completion(snapshot,step,skipCondition,null,null)
        if(result.matched && !result.proven)throw Blocked("failed","invalid_postcondition：动作前已存在的题干、题号或普通文字不能证明操作完成。")
        return result.matched && result.proven
    }

    private fun completionResult(snapshot:Snapshot,step:Map<String,Any?>,before:Map<String,Any?>?):Completion {
        val condition=map(step["expect"],"expect")
        if(step["action"]=="wait")return Completion(satisfied(snapshot,condition),true,"wait_condition")
        return completion(snapshot,step,condition,before?.get("condition")?.let{map(it,"before")},before?.get("target")?.let{map(it,"target")})
    }

    fun completionSatisfied(snapshot:Snapshot,step:Map<String,Any?>,before:Map<String,Any?>?):Boolean {
        val result=completionResult(snapshot,step,before)
        return result.matched && result.proven
    }

    /** A checkpoint is persisted before dispatch. Restored in-flight steps can only be verified. */
    fun run(plan: Map<String, Any?>, rootId: String, backend: Backend, checkpoint: Map<String, Any?>? = null,
            save: (Map<String, Any?>) -> Unit): Result {
        val steps = validate(plan)
        val pkg = plan["package"] as String
        val records = steps.map { mutableMapOf<String, Any?>("id" to it["id"], "action" to it["action"], "state" to "queued",
            "attempted" to false,"dispatched" to false,"alreadySatisfied" to false,"businessVerified" to false,"verificationKind" to "unverified") }
        if (checkpoint != null) {
            require(checkpoint["flowVersion"] == 1 && checkpoint["rootRequestId"] == rootId && checkpoint["plan"] == plan) { "流程检查点不匹配。" }
            val old = checkpoint["steps"] as? List<*> ?: error("流程检查点缺少步骤。")
            require(old.size == records.size)
            old.forEachIndexed { i, item ->
                val record = map(item, "checkpoint"); require(record["id"] == steps[i]["id"]); records[i].putAll(record)
                if(record["state"] in setOf("in_flight","unknown") && !record.containsKey("dispatched")) {
                    records[i]["attempted"]=true;records[i]["dispatched"]=null
                }
            }
        }
        val started = backend.now()
        val metricsAtStart = backend.metrics()
        val previousElapsed = (checkpoint?.get("elapsedMs") as? Number)?.toLong() ?: 0
        var observations = 0
        var observationRetries = 0
        var latest: Snapshot? = null
        var reusable: Snapshot? = null
        fun state(outcome: String, reason: String, current: Int?): Map<String, Any?> = mapOf(
            "flowVersion" to 1, "rootRequestId" to rootId, "plan" to plan,
            "steps" to records.map { it.toMap() }, "state" to outcome, "reason" to reason,
            "currentStep" to current, "completedSteps" to records.count { it["state"] in setOf("verified", "skipped") },
            "totalSteps" to steps.size, "elapsedMs" to previousElapsed + backend.now() - started,
            "hasUnverifiedActions" to records.any { (it["attempted"] == true || it["dispatched"] == true) && (it["state"] !in setOf("verified", "rejected") || (it["state"]=="verified" && it["businessVerified"]!=true)) },
            "businessVerified" to (outcome=="verified" && records.all{it["state"]=="skipped" || it["businessVerified"]==true}),
            "observationCount" to observations, "observationRetryCount" to observationRetries,
            "modelRequestsDuringExecution" to 0,
            "performance" to backend.metrics().mapValues { (name, value) ->
                (value - (metricsAtStart[name] ?: 0L)).coerceAtLeast(0L)
            })
        fun snapshot(stepStarted: Long, timeout: Long): Snapshot {
            while (true) {
                backend.check()
                try {
                    return backend.snapshot(pkg).also { latest = it; observations++ }
                } catch (error: ObservationUnavailable) {
                    backend.check()
                    val remaining = if (timeout > 0) timeout - (backend.now() - stepStarted) else 100L
                    if (remaining <= 0) throw error
                    observationRetries++
                    backend.awaitChange(minOf(100L, remaining))
                }
            }
        }
        fun finish(outcome: String, reason: String, index: Int?): Result {
            val legacyUnknown=outcome=="verified" && records.any{it["state"]=="verified" && it["businessVerified"]!=true}
            val finalOutcome=if(legacyUnknown)"unknown"else outcome
            val finalReason=if(legacyUnknown)"旧流程缺少可信完成证据，保留待核对；未重放原操作。"else reason
            val stored = state(finalOutcome, finalReason, index); save(stored)
            val public = stored - "plan"
            return Result(finalOutcome, finalReason, public + (latest?.observation ?: emptyMap()) +
                mapOf("verifiedRequestId" to if (stored["businessVerified"]==true) rootId else null, "verification" to "local_state_or_transition"))
        }
        for ((index, step) in steps.withIndex()) {
            val record = records[index]
            if(record["state"]=="verified" && record["businessVerified"]!=true)
                return finish("unknown","旧步骤缺少可信完成证据，后续依赖步骤仍待核对；未重放原操作。",index)
            if (record["state"] in setOf("verified", "skipped")) continue
            val stepStarted = backend.now()
            val timeout = number(step["timeoutMs"])
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
                    backend.reuse(previousObservation, pkg)?.also { latest = it } ?: snapshot(stepStarted, timeout)
                } else snapshot(stepStarted, timeout)
                backend.check()
                val before = if (inFlight) record["before"] else evidence(observed, expect)
                val completionBefore=if(inFlight)record["completionBefore"]?.let{map(it,"completionBefore")}else completionEvidence(observed,step)
                val whenCondition = step["when"]?.let { map(it, "when") }
                if (!inFlight && whenCondition != null && !satisfied(observed, whenCondition)) {
                    record["state"] = "skipped"; record["verificationKind"]="branch_not_taken";record["reason"] = "分支条件不成立，未执行。"; save(state("running", "已跳过条件分支。", index)); continue
                }
                if (!inFlight) {
                    step["guard"]?.let { require(satisfied(observed, map(it, "guard"))) { "页面前置条件不匹配，未派发动作。" } }
                    record["before"] = before
                    record["completionBefore"] = completionBefore
                    if (step["action"] != "wait" && !shouldSkip(observed,step)) {
                        record["state"] = "in_flight"
                        record["attempted"] = true
                        record["dispatched"] = null
                        save(state("running", "执行前检查点已保存。", index))
                        val dispatch = backend.performPrepared(step, pkg, "${rootId}_$index", observed)
                        record["dispatched"] = dispatch.dispatched
                        record["attempted"] = dispatch.dispatched
                        record["alreadySatisfied"] = dispatch.accepted && !dispatch.dispatched
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
                val stable = number(step["stableMs"], 100)
                var since: Long? = null
                var lastSample: Long? = null
                var stableWindow: Int? = null
                var samples = 0
                while (true) {
                    backend.check()
                    observed = snapshot(stepStarted, timeout)
                    val now = backend.now()
                    samples++
                    val captured = (observed.observation["capturedAtMs"] as? Number)?.toLong()
                        ?.takeIf { it in stepStarted..now } ?: now
                    val completion=completionResult(observed,step,completionBefore)
                    if (completion.matched && completion.proven) {
                        if (since == null || stableWindow != observed.window || (lastSample != null && captured < lastSample!!)) {
                            since = captured
                            stableWindow = observed.window
                            record["firstMatchedCaptureMs"] = captured - stepStarted
                        }
                        // Recognition time is not screen stability. Re-reading a cached frame
                        // cannot supply a second sample, even when OCR took longer than stableMs.
                        if (stable == 0L || (lastSample != null && captured > lastSample!! && captured - since!! >= stable)) {
                            record["resultSamples"] = samples
                            record["stableConfirmedCaptureMs"] = captured - stepStarted
                            record["verificationKind"] = if(record["alreadySatisfied"]==true)"already_satisfied_${completion.kind}"else completion.kind
                            break
                        }
                    } else { since = null; stableWindow = null }
                    lastSample = captured
                    if (timeout > 0 && now - stepStarted >= timeout) {
                        record["state"] = if (record["dispatched"] == true || inFlight) "unknown" else "waiting"
                        record["elapsedMs"] = previousStepElapsed + now - stepStarted
                        return finish("unknown", "步骤 ${step["id"]} 等待结果超时；保留现场，未重放动作。", index)
                    }
                    val stableWait = since?.let { (it + stable - now).coerceIn(1, 100) } ?: 100L
                    backend.awaitObservation(if (timeout > 0) minOf(stableWait, (timeout - (now - stepStarted)).coerceAtLeast(1)) else stableWait)
                }
                record["state"] = "verified"
                record["businessVerified"] = true
                reusable = observed
                record["elapsedMs"] = previousStepElapsed + backend.now() - stepStarted
                record["waitMs"] = (record["elapsedMs"] as Long) - (record["dispatchMs"] as Long)
                save(state("running", "步骤 ${step["id"]} 已核验。", index))
            } catch (error: Exception) {
                if (error is NotDispatched) {
                    record["attempted"] = false; record["dispatched"] = false; record["state"] = "blocked"
                } else if (inFlight || record["state"] in setOf("in_flight", "waiting")) record["state"] = "unknown"
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
