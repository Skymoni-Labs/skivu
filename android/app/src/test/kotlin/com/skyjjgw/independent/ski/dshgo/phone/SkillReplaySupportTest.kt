package com.skyjjgw.independent.ski.dshgo.phone

import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute as R
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillReplayApps
import org.junit.Assert.*
import org.junit.Test

class SkillReplaySupportTest {
    private val more = R.Step(R.Op.SELECT_OPTION, "app1", PhoneScreen.MAIN,
        "navigation", "bottom-tabs", R.Value.OptionLiteral("more"), R.Post.OptionSelected)
    private val route = R.Route("phone-task-" + "1".repeat(32), "2".repeat(32),
        "markor-navigation-v1", listOf("app1"), emptyList(), listOf(more))

    @Test fun mainMoreAllowsTheEntireBoundedRouteButDoesNotRegisterAnApp() {
        assertEquals(PhoneScreen.MAIN, SkillReplaySupport.screen(route))
        assertEquals(PhoneScreen.MAIN, SkillReplaySupport.screen(route.copy(steps = List(16) { more })))
        assertNull(SkillReplaySupport.screen(route.copy(steps = emptyList())))
        assertNull(SkillReplaySupport.screen(route.copy(steps = List(17) { more })))
        assertTrue(PhoneSkillReplayApps.descriptors.isEmpty())
        assertNull(PhoneSkillReplayApps.summary(route))
    }
    @Test fun everyRelationFieldAndEveryStepMustBelongToTheImplementedSubset() {
        val tails = listOf(
            more.copy(op = R.Op.TAP_NAVIGATION), more.copy(appSlot = "app2"),
            more.copy(screen = PhoneScreen.BACKGROUND), more.copy(page = "other"),
            more.copy(target = "other"), more.copy(value = R.Value.OptionLiteral("files")),
            more.copy(value = R.Value.Reference("choice")), more.copy(post = R.Post.PageIs("home")))
        for (tail in tails) {
            assertNull(SkillReplaySupport.screen(route.copy(steps = listOf(more, tail))))
        }
    }
    @Test fun shapeAndParametersCannotBorrowTheMoreDescriptorName() {
        assertNull(SkillReplaySupport.screen(route.copy(descriptorId = "another")))
        assertNull(SkillReplaySupport.screen(route.copy(slots = listOf("app1", "app2"))))
        assertNull(SkillReplaySupport.screen(route.copy(parameters = listOf(R.Parameter("p", R.ParameterKind.BOOLEAN)))))
        val background = more.copy(screen = PhoneScreen.BACKGROUND)
        assertEquals(PhoneScreen.BACKGROUND, SkillReplaySupport.screen(route.copy(steps = listOf(background))))
        assertEquals(PhoneScreen.BACKGROUND, SkillReplaySupport.screen(route.copy(steps = List(16) { background })))
        assertNull(SkillReplaySupport.screen(route.copy(steps = listOf(background.copy(op = R.Op.OPEN_APP)))))
        assertNull(SkillReplaySupport.screen(route.copy(steps = listOf(background, more))))
    }
}
