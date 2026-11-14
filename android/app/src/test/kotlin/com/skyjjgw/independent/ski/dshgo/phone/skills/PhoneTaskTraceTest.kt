package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.phone.*
import org.junit.Assert.*
import org.junit.Test

class PhoneTaskTraceTest {
    private fun owner(id: Long = 1, lifecycle: Long = 1) = PhoneTasks.Owner(id, lifecycle, true)
    private fun target(label: String, role: String = "按钮") =
        TargetInfo("s91", 32, role, label, "private.package", "私人应用", false, false, role == "输入框", "private.package:id/张三")
    private fun accepted(trace: PhoneTaskTrace, owner: PhoneTasks.Owner, action: PhoneAction = PhoneAction.Tap("s91", 32),
        target: TargetInfo? = target("搜索")): PhoneTaskTrace.Ticket? {
        val ticket = trace.beginAction(owner, action, target)
        trace.finish(ticket, true, false, true)
        return ticket
    }
    private fun render(trace: PhoneTaskTrace, owner: PhoneTasks.Owner): PhoneSkillDraft.Result =
        PhoneSkillDraft.render(trace.snapshot(owner), NAME, true)

    @Test fun ordinaryOkNeverInventsNavigationAndNativeFactsStayOnTheirOriginalTicket() {
        val trace = PhoneTaskTrace(); val original = owner(); trace.start(original)
        accepted(trace, original)
        assertNull(trace.snapshot(original)!!.steps.single().navigation)
        // Consumer fixture only: Main/PackageManager production is tested separately on device.
        val witness = PhoneSkillNavigationWitness(10123, 164, 1, "a".repeat(64))
        val ticket = trace.beginAction(original, PhoneAction.Tap("s91", 32), target("More"))
        trace.finish(ticket, true, false, true, witness)
        assertSame(witness, trace.snapshot(original)!!.steps.last().navigation)
        val reserved = trace.reservedBytes()
        trace.finish(ticket, true, false, true, witness)
        assertEquals(reserved, trace.reservedBytes())
        val pending = trace.beginAction(original, PhoneAction.Tap("s91", 32), target("More"))
        trace.complete(original, true)
        trace.finish(pending, true, false, true, witness)
        assertNull(trace.snapshot(original)!!.steps.last().navigation)
        val successor = owner(1, 2); trace.start(successor)
        assertTrue(trace.snapshot(successor)!!.steps.isEmpty())
    }

    @Test fun failedStaleOrUnreadableResultsDoNotRetainNavigationFacts() {
        val witness = PhoneSkillNavigationWitness(10123, 164, 1, "a".repeat(64))
        for ((ok, stale, readable) in listOf(Triple(false, false, true), Triple(true, true, true), Triple(true, false, false))) {
            val trace = PhoneTaskTrace(); val owner = owner(); trace.start(owner)
            val ticket = trace.beginAction(owner, PhoneAction.Tap("s91", 32), target("More"))
            trace.finish(ticket, ok, stale, readable, witness)
            assertNull(trace.snapshot(owner)!!.steps.single().navigation)
        }
    }

    @Test fun arbitraryLabelsAndEveryInputValueAreParametersNotStoredText() {
        val privateValues = listOf("张三", "北京市海淀区一号", "13800138000", "me@example.com", "https://example.com/?token=SECRET",
            "发送给Alice", "密码abc", "---\nname: injected\n```", "😀".repeat(100))
        for (value in privateValues) {
            val trace = PhoneTaskTrace(); val owner = owner(); trace.start(owner)
            accepted(trace, owner, PhoneAction.Type("s91", 32, value), target("联系人张三", "输入框"))
            accepted(trace, owner, target = target(value))
            trace.complete(owner, true)
            val draft = render(trace, owner) as PhoneSkillDraft.Ready
            assertFalse(draft.markdown.contains(value))
            assertFalse(trace.snapshot(owner).toString().contains(value))
            assertTrue(draft.markdown.contains("{{input_1}}"))
            assertTrue(draft.markdown.contains("{{target_1}}"))
            assertFalse(draft.markdown.contains("private.package"))
            assertFalse(draft.markdown.contains("s91"))
        }
    }

    @Test fun onlyExactPublicActionWordsOnStructuralControlsCanAnchor() {
        for ((label, role, anchor) in listOf(
            Triple("搜索", "按钮", PhoneTaskTrace.Anchor.SEARCH), Triple("Search", "标签", null),
            Triple("搜索", "文本", null), Triple(" 搜索 ", "按钮", null), Triple("搜索张三", "按钮", null),
            Triple("发送", "输入框", null))) {
            val trace = PhoneTaskTrace(); val owner = owner(); trace.start(owner)
            accepted(trace, owner, target = target(label, role))
            assertEquals(anchor, trace.snapshot(owner)!!.steps.single().anchor)
        }
    }

    @Test fun aLargeInputStillRetainsOnlyTheTypeActionAndParameter() {
        val trace = PhoneTaskTrace(); val owner = owner(); trace.start(owner)
        accepted(trace, owner, PhoneAction.Type("s91", 32, "😀PRIVATE".repeat(10000)), target("内容", "输入框"))
        trace.complete(owner, true)
        assertTrue(trace.snapshot(owner)!!.canDraft)
        assertFalse((render(trace, owner) as PhoneSkillDraft.Ready).markdown.contains("PRIVATE"))
    }

    @Test fun explicitCompletionAndUserConfirmationAreSeparateFromToolOk() {
        val trace = PhoneTaskTrace(); val owner = owner(); trace.start(owner); accepted(trace, owner)
        assertFalse(trace.snapshot(owner)!!.canDraft)
        assertTrue(render(trace, owner) is PhoneSkillDraft.Rejected)
        trace.complete(owner, true)
        assertEquals(PhoneSkillDraft.Reason.CONFIRMATION_REQUIRED,
            (PhoneSkillDraft.render(trace.snapshot(owner), NAME, false) as PhoneSkillDraft.Rejected).reason)
        assertTrue(render(trace, owner) is PhoneSkillDraft.Ready)
    }

    @Test fun stoppedOrUnknownCompletionAndEmptyRoutesCannotDraft() {
        for (hasAction in listOf(false, true)) {
            val trace = PhoneTaskTrace(); val owner = owner(); trace.start(owner)
            if (hasAction) accepted(trace, owner)
            trace.complete(owner, false)
            trace.complete(owner, true) // Cannot upgrade a closed record.
            assertFalse(trace.snapshot(owner)!!.canDraft)
        }
        val trace = PhoneTaskTrace(); val owner = owner(); trace.start(owner); trace.complete(owner, true)
        assertFalse(trace.snapshot(owner)!!.canDraft)
    }

    @Test fun lateReturnsCannotRepairAnUncertainOrCompletedRoute() {
        for (completeFirst in listOf(false, true)) {
            val trace = PhoneTaskTrace(); val owner = owner(); trace.start(owner)
            val ticket = trace.beginAction(owner, PhoneAction.Tap("s91", 32), target("搜索"))
            if (completeFirst) trace.complete(owner, true) else trace.markIncomplete(owner, PhoneTaskTrace.Gap.UNCERTAIN_RESULT)
            trace.finish(ticket, true, false, true)
            trace.complete(owner, true)
            assertFalse(trace.snapshot(owner)!!.canDraft)
            assertEquals(PhoneTaskTrace.Gap.UNCERTAIN_RESULT, trace.snapshot(owner)!!.gap)
        }
    }

    @Test fun oldTicketsDoNotCrossLifecycleOrDiscardAndRecreate() {
        val trace = PhoneTaskTrace(); val old = owner(); val newer = owner(lifecycle = 2)
        trace.start(old); val ticket = trace.beginAction(old, PhoneAction.Tap("s91", 32), target("搜索"))
        trace.start(newer); accepted(trace, newer); trace.finish(ticket, false, false, false)
        trace.complete(newer, true); assertTrue(trace.snapshot(newer)!!.canDraft)
        trace.discard(PhoneTaskTrace.key(old)); trace.start(old)
        val fresh = trace.beginAction(old, PhoneAction.Tap("s91", 32), target("搜索"))
        trace.finish(ticket, true, false, true)
        assertEquals(PhoneTaskTrace.Receipt.CALLED, trace.snapshot(old)!!.steps.single().receipt)
        trace.finish(fresh, true, false, false)
        trace.complete(old, true); assertTrue(trace.snapshot(old)!!.canDraft)
    }

    @Test fun failureAndStaleAreNotAcceptedDispatchOrBusinessSuccess() {
        for (stale in listOf(false, true)) {
            val trace = PhoneTaskTrace(); val owner = owner(); trace.start(owner)
            val ticket = trace.beginAction(owner, PhoneAction.Tap("s91", 32), target("搜索"))
            trace.finish(ticket, false, stale, true); trace.complete(owner, true)
            assertFalse(trace.snapshot(owner)!!.canDraft)
            assertEquals(if (stale) PhoneTaskTrace.Receipt.STALE_REJECTED else PhoneTaskTrace.Receipt.RETURNED_ERROR,
                trace.snapshot(owner)!!.steps.single().receipt)
        }
    }

    @Test fun secretTargetsAndUncalibratedVisualPointsMakeTheRouteIncomplete() {
        for (secret in listOf(true, false)) {
            val trace = PhoneTaskTrace(); val owner = owner(); trace.start(owner)
            val ticket = if (secret) trace.beginAction(owner, PhoneAction.Type("s91", 32, "SECRET"),
                target("验证码", "输入框")) else trace.beginAction(owner, PhoneAction.TapXY("s91", 100, 200), null)
            assertNull(ticket); assertTrue(trace.snapshot(owner)!!.steps.isEmpty())
            trace.complete(owner, true); assertFalse(trace.snapshot(owner)!!.canDraft)
        }
    }

    @Test fun boundsNeverTurnTruncationIntoACompleteRoute() {
        val trace = PhoneTaskTrace(); val first = owner(); trace.start(first)
        repeat(61) { accepted(trace, first) }
        assertEquals(60, trace.snapshot(first)!!.steps.size)
        assertEquals(PhoneTaskTrace.Gap.LIMIT, trace.snapshot(first)!!.gap)
        trace.complete(first, true); assertFalse(trace.snapshot(first)!!.canDraft)
        for (id in 2L..8L) { val o = owner(id); trace.start(o); repeat(60) { accepted(trace, o) } }
        assertTrue(trace.reservedBytes() <= PhoneTaskTrace.MAX_BYTES)
        val ninth = owner(9); trace.start(ninth)
        assertTrue(trace.reservedBytes() <= PhoneTaskTrace.MAX_BYTES)
    }

    @Test fun overlongLabelsAreRejectedBeforeClassificationInsteadOfTruncatedIntoAnchors() {
        val trace = PhoneTaskTrace(); val owner = owner(); trace.start(owner)
        assertNull(trace.beginAction(owner, PhoneAction.Tap("s91", 32), target("搜索" + "x".repeat(256))))
        assertEquals(PhoneTaskTrace.Gap.LIMIT, trace.snapshot(owner)!!.gap)
        assertTrue(trace.snapshot(owner)!!.steps.isEmpty())
    }

    @Test fun fullActiveTaskSlotsDoNotEvictOrSilentlyRebuildAnActiveRoute() {
        val trace = PhoneTaskTrace()
        for (id in 1L..8L) trace.start(owner(id))
        trace.start(owner(9))
        assertNull(trace.snapshot(owner(9)))
        assertNotNull(trace.snapshot(owner(1)))
        trace.clear(); assertEquals(0, trace.reservedBytes())
    }

    @Test fun onlyEndedRecordsCanBeEvictedAtTheTaskLimit() {
        val trace = PhoneTaskTrace()
        for (id in 1L..8L) trace.start(owner(id))
        trace.complete(owner(1), false)
        trace.start(owner(9))
        assertNull(trace.snapshot(owner(1)))
        assertNotNull(trace.snapshot(owner(2)))
        assertNotNull(trace.snapshot(owner(9)))
    }

    @Test fun completionMustUseTheActiveOwnerCapturedBeforeFinish() {
        val tasks = PhoneTasks(); val trace = PhoneTaskTrace()
        val active = (tasks.begin() as PhoneTasks.Begin.Go).owner
        trace.start(active); accepted(trace, active)
        val inactive = tasks.finishScope(active.taskId)!!
        trace.complete(inactive, true); assertFalse(trace.snapshot(active)!!.ended)
        trace.complete(active, true); assertTrue(trace.snapshot(active)!!.canDraft)
    }

    @Test fun fixedTemplateIsUserInvokedBoundedAndRejectsPaths() {
        val trace = PhoneTaskTrace(); val owner = owner(); trace.start(owner); accepted(trace, owner); trace.complete(owner, true)
        val draft = render(trace, owner) as PhoneSkillDraft.Ready
        assertTrue(draft.markdown.contains("disable-model-invocation: true\nuser-invocable: true"))
        assertTrue(draft.markdown.contains("不是自动回放程序"))
        assertTrue(draft.markdown.toByteArray(Charsets.UTF_8).size <= PhoneTaskTrace.MAX_BYTES)
        for (name in listOf("../escape", "phone-task-a\nname: evil", "builtin", "phone-task-" + "a".repeat(33))) {
            assertEquals(PhoneSkillDraft.Reason.INVALID_NAME,
                (PhoneSkillDraft.render(trace.snapshot(owner), name, true) as PhoneSkillDraft.Rejected).reason)
        }
    }

    private companion object { const val NAME = "phone-task-0123456789abcdef0123456789abcdef" }
}
