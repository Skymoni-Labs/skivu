package com.skyjjgw.independent.ski.dshgo.phone.skills

import android.content.Context
import com.skyjjgw.independent.ski.dshgo.phone.SkillReplaySupport
import com.skyjjgw.independent.ski.dshgo.phone.a11y.MarkorNavigation

/** Static native registration only. 3255 requires device evidence before adding an active entry.
 * Source-reviewed candidate code alone does not enable an App. */
internal object PhoneSkillReplayApps {
    val descriptors: Map<String, PhoneSkillRoute.Descriptor> = emptyMap()
    data class Choice(val app: PhoneSkillReplaySelections.App, val label: String)

    fun choices(context: Context, descriptorId: String): List<Choice> {
        if (descriptorId !in descriptors) return emptyList()
        // The only source-reviewed candidate relation; still NOT registered above.
        if (descriptorId != "markor-navigation-v1") return emptyList()
        return try {
            val info = context.packageManager.getApplicationInfo(MarkorNavigation.PACKAGE, 0)
            val observed = MarkorNavigation.selectedApp(context, MarkorNavigation.PACKAGE, info.uid) ?: return emptyList()
            listOf(Choice(PhoneSkillReplaySelections.App(MarkorNavigation.PACKAGE, observed.uid,
                observed.version, observed.updated, observed.signers), context.packageManager.getApplicationLabel(info).toString()))
        } catch (_: Exception) { emptyList() }
    }
    fun summary(route: PhoneSkillRoute.Route): String? {
        if (route.descriptorId !in descriptors || SkillReplaySupport.screen(route) == null) return null
        return route.steps.indices.joinToString("\n") { index ->
            "${index + 1}. 核对当前所选应用、导航页面和唯一更多选项；已选中不再点击，否则只尝试一次，并核对实际选中状态。"
        }
    }
}
