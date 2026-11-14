package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillInstallResult
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillBundleInstaller
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillWrite
import java.lang.ref.WeakReference
import java.text.Normalizer
import java.util.UUID

/** One local editor. Manager -> write is the only nested lock order; never calls Runtime or performs IO. */
internal class PhoneSkillDrafts(private val newId: () -> String = { UUID.randomUUID().toString().replace("-", "") }) {
    class Client internal constructor(internal val issuer: Any) { internal var active = true }
    private val issuer = Any()
    @Synchronized fun attachClient(): Client = Client(issuer)

    enum class Code { STALE, BUSY, CONFIRMATION_REQUIRED, UNAVAILABLE, INVALID, SENSITIVE, TOO_LARGE,
        NO_HOME, CONFLICT, IO, CANNOT_CANCEL }
    data class Candidate(val owner: PhoneTaskTrace.OwnerKey, val steps: Int)
    data class Edit(val goal: String, val prerequisites: String, val checkpoints: List<String>, val stepOrder: List<Int>)
    data class View(val draftId: String, val owner: PhoneTaskTrace.OwnerKey, val revision: Long,
        val skillName: String, val markdown: String, val stepOrder: List<Int>, val parameterizedFields: List<String>,
        val phase: PhoneSkillWrite.Phase?, val bundleRevision: String? = null)
    sealed interface Reply
    sealed interface SaveReply
    data class Shown(val view: View) : Reply
    data class Rejected(val code: Code) : Reply, SaveReply
    sealed interface Terminal : Reply, SaveReply
    data class Saved(val name: String, val relativePath: String,
        val bundle: PhoneSkillBundleInstaller.Identity? = null) : Terminal
    data class Unverified(val bundle: PhoneSkillBundleInstaller.Identity,
        val publication: PhoneSkillBundleInstaller.Publication,
        val code: PhoneSkillBundleInstaller.Verification) : Terminal
    data object Discarded : Reply
    data class Started(val write: PhoneSkillWrite) : SaveReply
    /** Already queued: the caller must not invoke Runtime a second time. */
    data class Existing(val write: PhoneSkillWrite) : SaveReply
    private class Editor(val id: String, val client: Client, val source: PhoneTaskTrace.Snapshot,
        var document: PhoneSkillDraft.Ready, var order: List<Int>) {
        var revision = 1L
        var parameters = emptyList<String>()
        var bundle: PhoneSkillBundleInstaller.Document? = null
        var write: PhoneSkillWrite? = null
        var retired = false
    }
    internal class Receipt(val owner: PhoneTaskTrace.OwnerKey, var value: Terminal, val client: Client,
        val write: WeakReference<PhoneSkillWrite>, val binding: PhoneSkillWrite.SaveBinding?) {
        var queryInFlight = false
    }
    private val candidates = LinkedHashMap<PhoneTaskTrace.OwnerKey, PhoneTaskTrace.Snapshot>()
    private val receipts = LinkedHashMap<String, Receipt>()
    private var editor: Editor? = null
    private var epoch = 0L

    /** Capture when the native task starts, never when its delayed completion callback arrives. */
    @Synchronized fun currentEpoch(): Long = epoch

    @Synchronized fun offer(expectedEpoch: Long, snapshot: PhoneTaskTrace.Snapshot): Boolean {
        if (expectedEpoch != epoch || !snapshot.canDraft || snapshot.steps.size > PhoneTaskTrace.MAX_STEPS ||
            receipts.values.any { it.owner == snapshot.owner }) return false
        candidates[snapshot.owner] = snapshot.copy(steps = snapshot.steps.toList())
        while (candidates.size > MAX_CANDIDATES) candidates.remove(candidates.keys.first())
        return true
    }

    @Synchronized fun candidates(): List<Candidate> = candidates.values.map { Candidate(it.owner, it.steps.size) }

    @Synchronized fun open(client: Client, owner: PhoneTaskTrace.OwnerKey, userConfirmed: Boolean): Reply {
        if (!attached(client)) return Rejected(Code.STALE)
        settle()
        receipts.values.firstOrNull { it.owner == owner }?.let { return it.value }
        if (!userConfirmed) return Rejected(Code.CONFIRMATION_REQUIRED)
        val previous = editor
        val source = candidates[owner] ?: return Rejected(Code.UNAVAILABLE)
        val id = uniqueId() ?: return Rejected(Code.INVALID)
        val nameId = newId().takeIf { HEX.matches(it) } ?: return Rejected(Code.INVALID)
        val document = PhoneSkillDraft.render(source, "phone-task-$nameId", true) as? PhoneSkillDraft.Ready
            ?: return Rejected(Code.UNAVAILABLE)
        val prospective = Editor(id, client, source, document, source.steps.indices.toList())
        // No editor is exposed or old write cancelled until the complete group is validated.
        val descriptors = PhoneSkillReplayApps.descriptors
        val route = if (descriptors.isEmpty()) PhoneSkillNavigationRoute.Result.NotEligible
            else PhoneSkillNavigationRoute.build(source, document, newId(), prospective.revision + 1, descriptors)
        when (route) {
            PhoneSkillNavigationRoute.Result.NotEligible -> Unit
            is PhoneSkillNavigationRoute.Result.Invalid -> return Rejected(
                if (route.reason == com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillBundleReader.Reason.SIZE)
                    Code.TOO_LARGE else Code.INVALID)
            is PhoneSkillNavigationRoute.Result.Ready ->
                if (!bind(prospective, route.bundle, route.preview)) return Rejected(Code.INVALID)
        }
        if (previous != null && !cancel(previous)) return Rejected(Code.BUSY)
        editor = prospective
        return shown(prospective)
    }

    /** Native witness producer only; no bridge action accepts a route or descriptor from Flutter.
     * Binding changes what is saved, so it MUST invalidate an already displayed confirmation. */
    @Synchronized fun bindBundle(expectedEpoch: Long, owner: PhoneTaskTrace.OwnerKey, draftId: String,
        expectedRevision: Long, bundle: PhoneSkillBundleInstaller.Document,
        preview: PhoneSkillDraft.Ready? = null): Reply {
        val e = editor ?: return Rejected(Code.STALE)
        if (epoch != expectedEpoch || e.retired || !attached(e.client) || e.source.owner != owner ||
            e.id != draftId || e.revision != expectedRevision) return Rejected(Code.STALE)
        if (e.write != null) return Rejected(Code.BUSY)
        if (!bind(e, bundle, preview ?: e.document)) return Rejected(Code.INVALID)
        return shown(e)
    }

    /** Same bounded identity mutation for an unexposed prospective editor and explicit native binding. */
    private fun bind(e: Editor, bundle: PhoneSkillBundleInstaller.Document, document: PhoneSkillDraft.Ready): Boolean {
        if (document.owner != e.source.owner || document.skillName != e.document.skillName ||
            e.revision == Long.MAX_VALUE || bundle.identity.name != e.document.skillName ||
            bundle.identity.draftRevision != e.revision + 1 ||
            !bundle.bytes()[0].contentEquals(document.markdown.toByteArray(Charsets.UTF_8))) return false
        e.document = document
        e.bundle = bundle
        e.revision++
        return true
    }

    /** Raw editing strings live only in this call, never in a field, permit, error or rendered document. */
    @Synchronized fun edit(client: Client, draftId: String, taskId: Long, revision: Long, edit: Edit): Reply {
        val e = matching(client, draftId, taskId) ?: return Rejected(Code.STALE)
        if (revision != e.revision) return Rejected(Code.STALE)
        if (e.write?.phase() in setOf(PhoneSkillWrite.Phase.STAGING, PhoneSkillWrite.Phase.COMMITTING)) return Rejected(Code.BUSY)
        settle()?.let { return it }
        if (e.retired) return Rejected(Code.STALE)
        if (edit.stepOrder.isEmpty() || edit.stepOrder.size > PhoneTaskTrace.MAX_STEPS ||
            edit.stepOrder.distinct().size != edit.stepOrder.size || edit.stepOrder.any { it !in e.source.steps.indices } ||
            edit.checkpoints.size != edit.stepOrder.size) return Rejected(Code.INVALID)
        val fields = listOf("goal" to edit.goal, "prerequisites" to edit.prerequisites) +
            edit.checkpoints.mapIndexed { index, value -> "checkpoints[$index]" to value }
        if (fields.any { it.second.length > MAX_FIELD } || fields.sumOf { it.second.length } > MAX_EDIT_BYTES - EDIT_OVERHEAD ||
            fields.sumOf { it.second.toByteArray(Charsets.UTF_8).size } > MAX_EDIT_BYTES - EDIT_OVERHEAD) {
            return Rejected(Code.TOO_LARGE)
        }
        val clean = fields.map { (key, value) -> key to Normalizer.normalize(value, Normalizer.Form.NFKC).trim() }
        if (clean.any { it.second.length > MAX_FIELD } ||
            clean.sumOf { it.second.toByteArray(Charsets.UTF_8).size } > MAX_EDIT_BYTES - EDIT_OVERHEAD) return Rejected(Code.TOO_LARGE)
        if (clean.any { SECRET.containsMatchIn(it.second) }) return Rejected(Code.SENSITIVE)
        if (e.revision == Long.MAX_VALUE) return Rejected(Code.STALE)
        val ordered = e.source.copy(steps = edit.stepOrder.map { e.source.steps[it] })
        val document = PhoneSkillDraft.render(ordered, e.document.skillName, true, userEdited = true) as? PhoneSkillDraft.Ready
            ?: return Rejected(Code.TOO_LARGE)
        e.document = document
        e.bundle = null
        e.order = edit.stepOrder.toList()
        e.parameters = clean.filter { it.second.isNotEmpty() }.map { it.first }
        e.revision++ // Even identical sanitized text revokes the prior confirmation.
        e.write = null
        return shown(e)
    }

    @Synchronized fun view(client: Client, draftId: String, taskId: Long): Reply {
        if (!attached(client)) return Rejected(Code.STALE)
        receipts[draftId]?.takeIf { it.owner.taskId == taskId && it.client === client }?.let { return it.value }
        val e = matching(client, draftId, taskId) ?: return Rejected(Code.STALE)
        // finish publishes the result before FINISHED under the write monitor. Capture the
        // phase first so a concurrent finish cannot produce a Shown(FINISHED) without its result.
        val phase = e.write?.phase()
        if (phase == PhoneSkillWrite.Phase.FINISHED) return saved(e.id, e.write!!)
        return shown(e, phase)
    }

    @Synchronized fun beginSave(client: Client, draftId: String, taskId: Long, revision: Long, explicitConfirmed: Boolean): SaveReply {
        if (!attached(client)) return Rejected(Code.STALE)
        receipts[draftId]?.takeIf { it.owner.taskId == taskId && it.client === client }?.let { return it.value }
        val e = matching(client, draftId, taskId) ?: return Rejected(Code.STALE)
        if (revision != e.revision) return Rejected(Code.STALE)
        if (!explicitConfirmed) return Rejected(Code.CONFIRMATION_REQUIRED)
        val write = e.write
        if (write != null) {
            val result = write.result()
            if (result != null && result !is PhoneSkillInstallResult.Refused) return settle()!!
            if (result is PhoneSkillInstallResult.Refused) return Rejected(code(result))
            return Existing(write)
        }
        if (!reserveReceipt()) return Rejected(Code.BUSY)
        return PhoneSkillWrite(e.document, e.bundle).also { e.write = it }.let(::Started)
    }

    sealed interface Check {
        data class Immediate(val reply: Reply) : Check
        data class Saving(val write: PhoneSkillWrite) : Check
    }
    class Query internal constructor(internal val draftId: String, internal val receipt: Receipt,
        val binding: PhoneSkillWrite.SaveBinding, val publication: PhoneSkillBundleInstaller.Publication) : Check

    /** Only this read-only operation admits a fresh active client from the same issuer. */
    @Synchronized fun beginCheck(client: Client, draftId: String, taskId: Long, name: String, revision: String): Check {
        fun stale() = Check.Immediate(Rejected(Code.STALE))
        if (!attached(client)) return stale()
        settle()
        val receipt = receipts[draftId]
        if (receipt != null) {
            val binding = receipt.binding ?: return stale()
            if (receipt.owner.taskId != taskId || binding.identity.name != name || binding.identity.revision != revision) return stale()
            val value = receipt.value
            if (value !is Unverified || receipt.queryInFlight) return Check.Immediate(value)
            receipt.queryInFlight = true
            return Query(draftId, receipt, binding, value.publication)
        }
        val e = editor?.takeIf { it.id == draftId && it.source.owner.taskId == taskId } ?: return stale()
        val identity = e.bundle?.identity ?: return stale()
        if (identity.name != name || identity.revision != revision) return stale()
        val write = e.write ?: return Check.Immediate(shown(e))
        return if (write.phase() in setOf(PhoneSkillWrite.Phase.STAGING, PhoneSkillWrite.Phase.COMMITTING)) Check.Saving(write)
            else Check.Immediate(saved(draftId, write))
    }

    /** Called only at actual query job completion (or proven submission rejection), never retirement. */
    @Synchronized fun completeCheck(query: Query, result: PhoneSkillInstallResult): Reply {
        val receipt = query.receipt
        if (receipts[query.draftId] !== receipt || !receipt.queryInFlight || receipt.binding !== query.binding)
            return Rejected(Code.STALE)
        try {
            val identity = query.binding.identity
            receipt.value = when (result) {
                is PhoneSkillInstallResult.BundleSaved -> if (result.identity == identity)
                    Saved(identity.name, "skills/${identity.name}/SKILL.md", identity)
                    else Unverified(identity, query.publication, PhoneSkillBundleInstaller.Verification.BUNDLE_INVALID)
                is PhoneSkillInstallResult.BundleUnverified -> Unverified(identity, query.publication,
                    if (result.identity == identity) result.code else PhoneSkillBundleInstaller.Verification.BUNDLE_INVALID)
                else -> Unverified(identity, query.publication, PhoneSkillBundleInstaller.Verification.VERIFICATION_UNAVAILABLE)
            }
            return receipt.value
        } finally { receipt.queryInFlight = false }
    }

    /** A bounded discovery projection, not a reconstructed draft or a file-read authorization. */
    @Synchronized fun saveResults(): List<Map<String, Any?>> {
        settle()
        val result = receipts.mapNotNull { (id, receipt) ->
            val identity = receipt.binding?.identity ?: return@mapNotNull null
            linkedMapOf<String, Any?>("taskId" to receipt.owner.taskId, "draftId" to id,
                "name" to identity.name, "bundleRevision" to identity.revision,
                "kind" to if (receipt.value is Saved) "saved" else "unverified").also { row ->
                (receipt.value as? Unverified)?.let {
                    row["publication"] = it.publication.name.lowercase(java.util.Locale.ROOT)
                    row["code"] = it.code.name.lowercase(java.util.Locale.ROOT)
                }
            }
        }.toMutableList()
        editor?.let { e ->
            val write = e.write
            val identity = write?.bundle?.identity
            val phase = write?.phase()
            if (identity != null && phase in setOf(PhoneSkillWrite.Phase.STAGING, PhoneSkillWrite.Phase.COMMITTING))
                result += linkedMapOf<String, Any?>("taskId" to e.source.owner.taskId, "draftId" to e.id,
                    "name" to identity.name, "bundleRevision" to identity.revision, "kind" to "saving",
                    "phase" to phase!!.name.lowercase(java.util.Locale.ROOT))
        }
        return result
    }

    /** Single Editor reserves its eventual receipt before any install can be queued. */
    private fun reserveReceipt(): Boolean {
        while (receipts.size >= MAX_CANDIDATES) {
            val evictable = receipts.entries.firstOrNull { !it.value.queryInFlight } ?: return false
            receipts.remove(evictable.key)
        }
        return true
    }

    /** Runtime already called write.finish; UI cannot provide or forge an install result. */
    @Synchronized fun saved(draftId: String, write: PhoneSkillWrite): Reply {
        val e = editor
        if (e == null || e.id != draftId || e.write !== write) {
            return receipts[draftId]?.takeIf { it.owner == write.document.owner && it.write.get() === write }?.value ?: Rejected(Code.STALE)
        }
        val result = write.result() ?: return Rejected(Code.BUSY)
        if (result !is PhoneSkillInstallResult.Refused) return settle()!!
        if (e.retired) editor = null
        return Rejected(code(result))
    }

    @Synchronized fun discard(client: Client, draftId: String, taskId: Long): Reply {
        if (!attached(client)) return Rejected(Code.STALE)
        receipts[draftId]?.takeIf { it.owner.taskId == taskId && it.client === client }?.let { return it.value }
        val e = matching(client, draftId, taskId) ?: return Rejected(Code.STALE)
        settle()?.let { return it }
        if (!cancel(e)) return Rejected(Code.CANNOT_CANCEL)
        editor = null
        return Discarded
    }

    @Synchronized fun retireClient(client: Client) {
        if (client.issuer !== issuer) return
        client.active = false
        val e = editor ?: return
        if (e.client === client) {
            settle()
            if (editor === e && cancel(e)) editor = null
        }
    }

    /** Old runtime candidates cannot be carried into another root. An already committing write remains observable. */
    @Synchronized fun onEngineRetired() {
        epoch++
        candidates.clear()
        val e = editor ?: return
        e.retired = true
        settle()
        if (editor === e && cancel(e)) editor = null
    }

    @Synchronized internal fun clientCurrent(client: Client): Boolean = attached(client)

    private fun attached(client: Client): Boolean = client.issuer === issuer && client.active
    private fun matching(client: Client, id: String, taskId: Long): Editor? {
        if (!attached(client)) return null
        return editor?.takeIf { it.client === client && it.id == id && it.source.owner.taskId == taskId }
    }
    private fun cancel(e: Editor): Boolean {
        val write = e.write ?: return true
        return when (write.phase()) {
            PhoneSkillWrite.Phase.STAGING -> write.cancel()
            PhoneSkillWrite.Phase.COMMITTING -> false
            PhoneSkillWrite.Phase.FINISHED -> write.result() is PhoneSkillInstallResult.Refused
            PhoneSkillWrite.Phase.CANCELLED -> true
        }
    }
    private fun settle(): Terminal? {
        val e = editor ?: return null
        val saved = when (val result = e.write?.result()) {
            is PhoneSkillInstallResult.Saved -> Saved(result.name, result.relativePath)
            is PhoneSkillInstallResult.BundleSaved -> Saved(result.identity.name,
                "skills/${result.identity.name}/SKILL.md", result.identity)
            is PhoneSkillInstallResult.BundleUnverified -> Unverified(result.identity, result.publication, result.code)
            is PhoneSkillInstallResult.Refused, null -> return null
        }
        receipts[e.id] = Receipt(e.source.owner, saved, e.client, WeakReference(e.write!!), e.write!!.saveBinding())
        candidates.remove(e.source.owner)
        editor = null
        return saved
    }
    private fun shown(e: Editor): Shown = shown(e, e.write?.phase())
    private fun shown(e: Editor, phase: PhoneSkillWrite.Phase?): Shown = Shown(View(e.id, e.source.owner, e.revision, e.document.skillName,
        e.document.markdown, e.order.toList(), e.parameters.toList(), phase, e.bundle?.identity?.revision))
    private fun uniqueId(): String? {
        val id = newId()
        return id.takeIf { HEX.matches(it) && it != editor?.id && it !in receipts }
    }
    private fun code(result: PhoneSkillInstallResult.Refused): Code = when (result) {
        PhoneSkillInstallResult.Refused.STALE -> Code.STALE
        PhoneSkillInstallResult.Refused.NO_HOME -> Code.NO_HOME
        PhoneSkillInstallResult.Refused.CONFLICT -> Code.CONFLICT
        PhoneSkillInstallResult.Refused.IO -> Code.IO
    }
    companion object {
        const val MAX_CANDIDATES = 8
        const val MAX_FIELD = 2000
        const val MAX_EDIT_BYTES = 32 * 1024
        private const val EDIT_OVERHEAD = 1024
        private val HEX = Regex("[a-f0-9]{32}")
        // Known markers only. Unknown names/values are still removed, never entrusted to a PII detector.
        private val SECRET = Regex("password|passwd|api[_ -]?key|access[_ -]?token|secret|密码|验证码|支付密码|cvv|安全码", RegexOption.IGNORE_CASE)
    }
}
