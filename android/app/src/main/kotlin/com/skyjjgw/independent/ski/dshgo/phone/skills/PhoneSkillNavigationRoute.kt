package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.phone.Json
import com.skyjjgw.independent.ski.dshgo.phone.PhoneScreen
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillBundleInstaller
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillBundleReader

/** Complete native trace only. Does not register a descriptor or infer facts from tool success. */
internal object PhoneSkillNavigationRoute {
    private const val ID = "markor-navigation-v1"
    private val relation = PhoneSkillRoute.Step(PhoneSkillRoute.Op.SELECT_OPTION, "app1", PhoneScreen.MAIN,
        "navigation", "bottom-tabs", PhoneSkillRoute.Value.OptionLiteral("more"), PhoneSkillRoute.Post.OptionSelected)
    sealed interface Result {
        data object NotEligible : Result
        data class Ready(val preview: PhoneSkillDraft.Ready, val bundle: PhoneSkillBundleInstaller.Document) : Result
        data class Invalid(val reason: PhoneSkillBundleReader.Reason) : Result
    }

    fun build(source: PhoneTaskTrace.Snapshot, template: PhoneSkillDraft.Ready,
        revision: String, draftRevision: Long,
        descriptors: Map<String, PhoneSkillRoute.Descriptor>): Result {
        val descriptor = descriptors[ID] ?: return Result.NotEligible
        if (relation !in descriptor.steps || "app1" !in descriptor.slots ||
            !source.canDraft || source.steps.size !in 1..16) return Result.NotEligible
        val first = source.steps.first().navigation ?: return Result.NotEligible
        if (source.steps.any { step ->
            val witness = step.navigation
            step.action != PhoneTaskTrace.Action.TAP || step.screen != PhoneScreen.MAIN ||
                !step.postObservationAvailable || witness == null || witness.uid != first.uid ||
                witness.version != first.version || witness.updated != first.updated ||
                witness.signingDigest != first.signingDigest
        }) return Result.NotEligible
        if (source.owner != template.owner) return Result.Invalid(PhoneSkillBundleReader.Reason.INTEGRITY)
        val summary = source.steps.indices.joinToString("\n") { index ->
            "${index + 1}. 核对当前所选应用、导航页面和唯一更多选项；已选中不再点击，否则只尝试一次，并核对实际选中状态。"
        }
        val preview = PhoneSkillDraft.withRouteSummary(template, summary)
            ?: return Result.Invalid(PhoneSkillBundleReader.Reason.SIZE)
        val route = Json.write(mapOf("schema" to 1, "skillName" to preview.skillName,
            "bundleRevision" to revision, "descriptorSet" to ID,
            "appSlots" to listOf(mapOf("key" to "app1", "kind" to "user_selected_app")),
            "parameters" to emptyList<Any>(), "steps" to source.steps.map {
                mapOf("op" to "select_option", "appSlot" to "app1", "screen" to "main",
                    "pageKey" to "navigation", "targetKey" to "bottom-tabs", "value" to mapOf("literal" to "more"),
                    "post" to mapOf("kind" to "option_selected"))
            })).toByteArray(Charsets.UTF_8)
        return when (val frozen = PhoneSkillBundleInstaller.freeze(preview.skillName, revision, draftRevision,
            preview.markdown.toByteArray(Charsets.UTF_8), route, descriptors)) {
            is PhoneSkillBundleInstaller.Frozen.Ready -> Result.Ready(preview, frozen.document)
            is PhoneSkillBundleInstaller.Frozen.Refused -> Result.Invalid(frozen.reason)
        }
    }
}
