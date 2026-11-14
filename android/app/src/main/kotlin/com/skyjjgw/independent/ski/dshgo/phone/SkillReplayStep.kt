package com.skyjjgw.independent.ski.dshgo.phone

import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillReplaySelections
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute

/** Native typed relation and current user-selected installation; never a tool argument object. */
class SkillReplayStep internal constructor(internal val app: PhoneSkillReplaySelections.App,
    internal val relation: PhoneSkillRoute.Step)
enum class SkillReplayPost { UNKNOWN, DIFFERENT, SATISFIED }
interface SkillReplayPlan : AutoCloseable {
    val before: ScreenSnapshot
    val target: TargetInfo?
    val alreadySatisfied: Boolean
    /** Actual native action attempt, not merely a transport send. */
    val attempted: Boolean
    /** A sent write lacks a trustworthy reply; never set for inspect or a known unsent call. */
    val dispatchUncertain: Boolean get() = false
    val post: SkillReplayPost
    fun perform(allowed: () -> Boolean): ActionResult
    override fun close()
}

/** Executable subset, not descriptor registration or current-page permission. */
internal object SkillReplaySupport {
    private val mainMore = PhoneSkillRoute.Step(PhoneSkillRoute.Op.SELECT_OPTION, "app1", PhoneScreen.MAIN,
        "navigation", "bottom-tabs", PhoneSkillRoute.Value.OptionLiteral("more"), PhoneSkillRoute.Post.OptionSelected)

    fun screen(route: PhoneSkillRoute.Route): PhoneScreen? {
        if (route.descriptorId != "markor-navigation-v1" || route.slots != listOf("app1") ||
            route.parameters.isNotEmpty() || route.steps.size !in 1..16) return null
        val screen = route.steps.first().screen
        val relation = mainMore.copy(screen = screen)
        return screen.takeIf { route.steps.all { it == relation } }
    }
}
