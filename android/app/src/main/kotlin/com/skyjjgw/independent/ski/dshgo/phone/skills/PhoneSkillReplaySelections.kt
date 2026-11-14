package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.phone.PhoneCaller
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillBundleReader
import java.util.UUID

/** Bounded private selections and first managed-run claims; no scheduler or execution grant.
 * Runtime/PM/Tasks checks are outside this monitor and repeated at actual execution. */
internal class PhoneSkillReplaySelections(private val clock: () -> Long) {
    data class Request(val name: String, val revision: String, val session: String,
        val packageName: String, val uid: Int) {
        companion object {
            fun parse(raw: Any?): Request? {
                val a = raw as? Map<*, *> ?: return null
                if (a.keys != setOf("skillId", "revision", "sessionId", "parameters")) return null
                val name = (a["skillId"] as? String)?.takeIf { NAME.matches(it) } ?: return null
                val revision = (a["revision"] as? String)?.takeIf { ID.matches(it) } ?: return null
                val session = PhoneCaller.identifier(a["sessionId"]) ?: return null
                val parameters = a["parameters"] as? Map<*, *> ?: return null
                if (parameters.keys != setOf("appSlots", "values")) return null
                val values = parameters["values"] as? Map<*, *> ?: return null
                if (values.isNotEmpty()) return null
                val slots = parameters["appSlots"] as? Map<*, *> ?: return null
                if (slots.keys != setOf("app1")) return null
                val app = slots["app1"] as? Map<*, *> ?: return null
                if (app.keys != setOf("packageName", "uid")) return null
                val pkg = PhoneCaller.identifier(app["packageName"]) ?: return null
                val uid = when (val value = app["uid"]) { is Int -> value.toLong(); is Long -> value; else -> return null }
                if (uid !in 0..Int.MAX_VALUE.toLong()) return null
                return Request(name, revision, session, pkg, uid.toInt())
            }
        }
    }
    /** Actual current PM identity, not recording metadata or a route assertion. */
    data class App(val packageName: String, val uid: Int, val version: Long,
        val updated: Long, val signers: String)
    class Selection internal constructor(val invocation: String, val client: PhoneSkillDrafts.Client,
        val draftEpoch: Long, private val currentSource: () -> Boolean, val request: Request,
        val bundle: PhoneSkillBundleReader.Read.Accepted, val app: App) {
        /** Invoke outside registry/Tasks locks; native closure retains the original read origin. */
        fun sourceCurrent(): Boolean = currentSource()
        internal var run: String? = null
        internal var cancelled = false
        internal var terminal = false
        internal var state = "running"
        internal var dispatch = "not_dispatched"
        internal var completed = 0
        internal var reason: String? = null
        internal var attempted = false
        internal var uncertain = false
        internal var failedPost = false
        internal var verified = false
        internal var outcome: PhoneSkillOutcomes.Outcome? = null
        internal var accounting: Accounting? = null
    }
    sealed interface Claim {
        data class Start(val selection: Selection) : Claim
        data class Existing(val result: Map<String, Any?>) : Claim
        data object Refused : Claim
    }
    /** Small accounting responsibility, independent of the public selection/source lifetime.
     * Reserved before first execution; no route, callbacks, App identity or action authority. */
    internal class Accounting(val invocation: String, val key: PhoneSkillOutcomes.Key) {
        var outcome: PhoneSkillOutcomes.Outcome? = null
        var ready = false
        var settled = false
        var suggestDisable = false
    }
    private val accounting = LinkedHashMap<String, Accounting>()
    private val lock = Any()
    private val records = LinkedHashMap<String, Selection>()

    fun prepare(client: PhoneSkillDrafts.Client, epoch: Long, currentSource: () -> Boolean,
        request: Request, bundle: PhoneSkillBundleReader.Read.Accepted, app: App): Selection? {
        if (!currentSource()) return null
        return synchronized(lock) {
        if (bundle.route.skillName != request.name || bundle.route.revision != request.revision ||
            app.packageName != request.packageName || app.uid != request.uid) return@synchronized null
        records.entries.removeAll { it.value.request.session == request.session && it.value.run == null }
        while (records.size >= MAX_RECORDS) {
            val old = records.entries.firstOrNull { it.value.terminal } ?: return@synchronized null
            records.remove(old.key)
        }
        val id = UUID.randomUUID().toString().replace("-", "")
        Selection(id, client, epoch, currentSource, request, bundle, app).also { records[id] = it }
        }
    }
    fun current(selection: Selection): Boolean = synchronized(lock) {
        records[selection.invocation] === selection && selection.run != null && !selection.cancelled && !selection.terminal
    }
    fun find(invocation: String): Selection? = synchronized(lock) { records[invocation] }
    fun claim(selection: Selection, caller: PhoneCaller): Claim {
        if (!selection.sourceCurrent()) return Claim.Refused
        return synchronized(lock) {
        if (records[selection.invocation] !== selection || caller.runLifecycle != 1 ||
            caller.sessionId != selection.request.session) return@synchronized Claim.Refused
        val run = selection.run
        if (run != null) return@synchronized if (run == caller.runId) Claim.Existing(snapshot(selection)) else Claim.Refused
        if (selection.cancelled || selection.terminal) return@synchronized Claim.Refused
        // A retired/evicted public record must not free an unsettled accounting reservation.
        if (accounting.size >= MAX_RECORDS) return@synchronized Claim.Refused
        Accounting(selection.invocation, PhoneSkillOutcomes.Key(selection.request.name,
            selection.request.revision, selection.bundle.routeSha256)).also {
            accounting[selection.invocation] = it
            selection.accounting = it
        }
        selection.run = caller.runId
        Claim.Start(selection)
        }
    }
    fun control(selection: Selection, caller: PhoneCaller, cancel: Boolean): Map<String, Any?>? = synchronized(lock) {
        if (records[selection.invocation] !== selection || caller.runLifecycle != 1 ||
            caller.sessionId != selection.request.session || selection.run != caller.runId) return@synchronized null
        if (cancel && !selection.terminal) selection.cancelled = true
        snapshot(selection)
    }
    fun discard(client: PhoneSkillDrafts.Client, invocation: String): Boolean = synchronized(lock) {
        val selection = records[invocation] ?: return@synchronized false
        if (selection.client !== client || selection.run != null) return@synchronized false
        records.remove(invocation)
        true
    }
    fun retire() = synchronized(lock) {
        records.values.forEach { it.cancelled = true }
        records.clear() // Another Runtime cannot claim or query this Runtime's records.
        // Original frozen outcomes and outstanding call reservations remain internal only.
    }
    fun retireClient(client: PhoneSkillDrafts.Client) = synchronized(lock) {
        records.values.filter { it.client === client }.forEach { it.cancelled = true }
        records.entries.removeAll { it.value.client === client && it.value.run == null }
    }
    fun terminalOutcome(selection: Selection): PhoneSkillOutcomes.Outcome? = synchronized(lock) { selection.outcome }
    /** Existing call executor only. Never invoked by the deadline callback. Storage IO occurs
     * outside this monitor; concurrent drains can only settle the same immutable outcome.
     * Ready means invoke's finally ran: a timeout alone cannot race a later begin() into an
     * absent-active UNCHANGED acknowledgement. No original source/owner grant is needed. */
    fun retryAccounting(outcomes: PhoneSkillOutcomes) {
        val debts = synchronized(lock) {
            accounting.values.filter { it.ready && it.outcome != null }.map { it to checkNotNull(it.outcome) }
        }
        if (!outcomes.retryStorage()) return
        for ((debt, terminal) in debts) {
            when (outcomes.settle(debt.invocation, terminal)) {
                PhoneSkillOutcomes.Result.SAVED, PhoneSkillOutcomes.Result.UNCHANGED -> {
                    val suggest = outcomes.counts(debt.key)?.suggestDisable == true
                    synchronized(lock) {
                        if (accounting[debt.invocation] === debt) {
                            debt.settled = true
                            debt.suggestDisable = suggest
                            accounting.remove(debt.invocation)
                        }
                    }
                }
                else -> return // Preserve this and all remaining debts; never re-run actions.
            }
        }
    }
    fun dispatched(selection: Selection) = synchronized(lock) {
        selection.attempted = true
        if (!selection.terminal) selection.dispatch = "dispatched"
    }
    /** Record uncertainty only; original finish/expire owns terminal/accounting readiness. */
    fun dispatchUncertain(selection: Selection) = synchronized(lock) {
        if (!selection.terminal) {
            selection.uncertain = true
            selection.dispatch = "unknown"
        }
    }
    fun completed(selection: Selection): Boolean = synchronized(lock) {
        if (records[selection.invocation] !== selection || selection.cancelled || selection.terminal) false
        else { selection.completed++; selection.dispatch = "verified"; true }
    }
    fun failedPost(selection: Selection) = synchronized(lock) { selection.failedPost = true }
    fun verified(selection: Selection) = synchronized(lock) {
        if (!selection.cancelled && !selection.terminal && records[selection.invocation] === selection)
            selection.verified = true
    }
    /** Timer work is memory-only. It does not settle preferences or claim physical drain. */
    fun expire(selection: Selection): Map<String, Any?> = synchronized(lock) {
        if (!selection.terminal) {
            selection.uncertain = true
            selection.terminal = true
            selection.state = "unknown"
            selection.dispatch = "unknown"
            selection.reason = "调用期限结束，原物理步骤可能仍在排空；不要重新执行。"
            selection.outcome = PhoneSkillOutcomes.Outcome.UNKNOWN
            selection.accounting?.outcome = PhoneSkillOutcomes.Outcome.UNKNOWN
        }
        snapshot(selection)
    }
    /** Only typed before/after evidence may set verified; a successful ToolOutput alone cannot.
     * This clock sample under the terminal lock is the local decision point. Production uses
     * the same elapsedRealtime clock and original absolute deadline as Sessions/CallWork.
     * null is only the no-admission failure path and can never grant SUCCESS. */
    fun finish(selection: Selection, normal: Boolean, deadlineMs: Long?): PhoneSkillOutcomes.Outcome = synchronized(lock) {
        // finish is called by the original invoke finally (or failed admission), after any
        // preparation/begin call has returned. Retiring the public record does not remove it.
        selection.accounting?.ready = true
        selection.outcome?.let { return@synchronized it }
        val expired = deadlineMs != null && clock() >= deadlineMs
        val value = when {
            expired -> PhoneSkillOutcomes.Outcome.UNKNOWN
            normal && deadlineMs != null && selection.verified && !selection.cancelled && records[selection.invocation] === selection -> PhoneSkillOutcomes.Outcome.SUCCESS
            selection.failedPost -> PhoneSkillOutcomes.Outcome.FAILURE
            selection.attempted || selection.uncertain || selection.verified -> PhoneSkillOutcomes.Outcome.UNKNOWN
            selection.cancelled -> PhoneSkillOutcomes.Outcome.CANCEL
            else -> PhoneSkillOutcomes.Outcome.NOT_STARTED
        }
        if (expired) { selection.uncertain = true; selection.dispatch = "unknown" }
        selection.outcome = value
        selection.accounting?.outcome = value
        selection.terminal = true
        selection.state = when (value) {
            PhoneSkillOutcomes.Outcome.SUCCESS -> "succeeded"
            PhoneSkillOutcomes.Outcome.FAILURE -> "failed"
            PhoneSkillOutcomes.Outcome.UNKNOWN -> "unknown"
            PhoneSkillOutcomes.Outcome.CANCEL -> "stopped"
            PhoneSkillOutcomes.Outcome.NOT_STARTED -> "handed_back"
        }
        selection.reason = if (expired) "调用期限在终态冻结前结束，不能提交路线完成结论；请重新观察，不要自动重试。" else when (value) {
            PhoneSkillOutcomes.Outcome.SUCCESS -> "全部步骤取得有限后置状态证明；不等于外部业务成功。"
            PhoneSkillOutcomes.Outcome.FAILURE -> "步骤后读明确不满足预期，已停止；不自动重复。"
            PhoneSkillOutcomes.Outcome.UNKNOWN -> "已开始步骤的结果未完整核对，交回模型；不自动重复。"
            PhoneSkillOutcomes.Outcome.CANCEL -> "已停止开始后续步骤；不撤销已经发生的效果。"
            PhoneSkillOutcomes.Outcome.NOT_STARTED -> "路线未取得继续资格，没有开始动作；请重新观察并交回用户或模型。"
        }
        value
    }

    fun snapshot(selection: Selection): Map<String, Any?> = synchronized(lock) {
        linkedMapOf<String, Any?>("v" to 1, "invocation" to selection.invocation,
            "revision" to selection.request.revision, "state" to selection.state,
            "stepDispatch" to selection.dispatch, "completedSteps" to selection.completed,
            "cancelRequested" to selection.cancelled).also { selection.reason?.let { reason ->
                it["reason"] = reason + if (selection.accounting?.let { debt -> debt.outcome != null && !debt.settled } == true) " 计数落盘待确认，不会重执行动作。"
                    else if (selection.accounting?.suggestDisable == true) " 连续失败已达三次，建议停用或重录；未自动停用。" else ""
            } }
    }
    companion object {
        /** One frozen snapshot determines both the protocol state and MCP error flag. */
        fun output(snapshot: Map<String, Any?>) = com.skyjjgw.independent.ski.dshgo.phone.ToolOutput(
            com.skyjjgw.independent.ski.dshgo.phone.Json.write(snapshot),
            isError = snapshot["state"] in setOf("rejected", "failed", "unknown", "handed_back", "stopped"))
        private val NAME = Regex("phone-task-[a-f0-9]{32}")
        private val ID = Regex("[a-f0-9]{32}")
        private const val MAX_RECORDS = 64
    }
}
