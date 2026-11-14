package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.phone.*
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillBundleReader
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillBundleInstaller as B
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillInstallResult
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillWrite
import org.junit.Assert.*
import org.junit.Test

/** Real trace/freeze/editor consumers; local descriptors never change production registration. */
class PhoneSkillNavigationRouteTest {
    private val relation = PhoneSkillRoute.Step(PhoneSkillRoute.Op.SELECT_OPTION, "app1", PhoneScreen.MAIN,
        "navigation", "bottom-tabs", PhoneSkillRoute.Value.OptionLiteral("more"), PhoneSkillRoute.Post.OptionSelected)
    private val descriptors = mapOf("markor-navigation-v1" to PhoneSkillRoute.Descriptor(
        "markor-navigation-v1", setOf("app1"), emptyList(), setOf(relation)))
    private val name = "phone-task-" + "1".repeat(32)
    private val revision = "2".repeat(32)
    private fun source(count: Int = 1, openFirst: Boolean = false, scrollLast: Boolean = false,
                       missing: Boolean = false, changedInstallation: Boolean = false): PhoneTaskTrace.Snapshot {
        val owner = PhoneTasks.Owner(7, 1, true)
        val trace = PhoneTaskTrace(); trace.start(owner)
        if (openFirst) trace.finish(trace.beginOpen(owner, PhoneScreen.MAIN), true, false, false)
        repeat(count) { index ->
            val ticket = trace.beginAction(owner, PhoneAction.Tap("s1", 1),
                TargetInfo("s1", 1, "按钮", "更多", "public.app", "Public", false, false, false))
            trace.finish(ticket, true, false, true, if (missing) null else PhoneSkillNavigationWitness(
                10123, if (changedInstallation && index > 0) 2 else 1, 1, "a".repeat(64)))
        }
        if (scrollLast) trace.finish(trace.beginAction(owner,
            PhoneAction.Scroll("s1", null, PhoneAction.Direction.DOWN), null), true, false, true)
        trace.complete(owner, true)
        return checkNotNull(trace.snapshot(owner)).also { assertTrue(it.canDraft) }
    }
    private fun template(source: PhoneTaskTrace.Snapshot, skillName: String = name) =
        PhoneSkillDraft.render(source, skillName, true) as PhoneSkillDraft.Ready
    private fun build(source: PhoneTaskTrace.Snapshot, document: PhoneSkillDraft.Ready = template(source),
                      next: Long = 2) = PhoneSkillNavigationRoute.build(source, document, revision, next, descriptors)

    @Test fun completeTraceFreezesTheRealGroupWithoutRetainingInstallationParameters() {
        for (count in listOf(1, 16)) {
            val source = source(count); val original = source.steps.toList()
            val ready = build(source) as PhoneSkillNavigationRoute.Result.Ready
            val bytes = ready.bundle.bytes()
            val read = PhoneSkillBundleReader.validate(name, revision, bytes[0], bytes[1], bytes[2], descriptors)
                as PhoneSkillBundleReader.Read.Accepted
            assertEquals(count, read.route.steps.size); assertTrue(read.route.steps.all { it == relation })
            assertEquals(listOf("app1"), read.route.slots); assertTrue(read.route.parameters.isEmpty())
            assertEquals(2L, read.draftRevision)
            assertEquals(ready.preview.markdown, bytes[0].toString(Charsets.UTF_8))
            assertFalse(ready.preview.markdown.contains("{{goal}}"))
            assertFalse(bytes[1].toString(Charsets.UTF_8).contains("10123"))
            assertEquals(original, source.steps)
        }
    }
    @Test fun unsupportedStepsAndSeventeenthStepStayInTheWholeOriginalTemplate() {
        for (source in listOf(source(openFirst = true), source(scrollLast = true), source(missing = true),
            source(2, changedInstallation = true), source(17))) {
            val original = source.steps.toList(); val document = template(source)
            assertSame(PhoneSkillNavigationRoute.Result.NotEligible, build(source, document))
            assertEquals(original, source.steps); assertEquals(document.markdown, template(source).markdown)
        }
        assertEquals(17, source(17).steps.size)
    }
    @Test fun emptyRegistryKeepsQualifiedTraceAsTheOriginalPhaseOneEditor() {
        val source = source(); var id = 0
        val manager = PhoneSkillDrafts { (++id).toString(16).padStart(32, '0') }
        val client = manager.attachClient()
        assertTrue(PhoneSkillReplayApps.descriptors.isEmpty())
        assertTrue(manager.offer(manager.currentEpoch(), source))
        val view = (manager.open(client, source.owner, true) as PhoneSkillDrafts.Shown).view
        assertEquals(1L, view.revision); assertNull(view.bundleRevision)
        assertEquals(template(source, view.skillName).markdown, view.markdown)
        assertNull((manager.beginSave(client, view.draftId, 7, view.revision, true)
            as PhoneSkillDrafts.Started).write.bundle)
    }
    @Test fun strictFreezeFailureIsInvalidNotUnsupported() {
        val source = source(); val document = template(source)
        assertTrue(PhoneSkillNavigationRoute.build(source, document, "bad", 2, descriptors)
            is PhoneSkillNavigationRoute.Result.Invalid)
        assertTrue(build(source, document, 0) is PhoneSkillNavigationRoute.Result.Invalid)
        assertTrue(build(source, template(source.copy(owner = source.owner.copy(taskId = 8))))
            is PhoneSkillNavigationRoute.Result.Invalid)
        assertSame(PhoneSkillNavigationRoute.Result.NotEligible,
            PhoneSkillNavigationRoute.build(source, document, revision, 2, emptyMap()))
    }
    @Test fun builtBundleRequiresNewRevisionAndExplicitConfirmation() {
        val source = source(); var id = 0
        val manager = PhoneSkillDrafts { (++id).toString(16).padStart(32, '0') }
        val client = manager.attachClient(); val epoch = manager.currentEpoch(); manager.offer(epoch, source)
        val old = (manager.open(client, source.owner, true) as PhoneSkillDrafts.Shown).view
        val built = build(source, template(source, old.skillName), old.revision + 1) as PhoneSkillNavigationRoute.Result.Ready
        val view = (manager.bindBundle(epoch, old.owner, old.draftId, old.revision, built.bundle, built.preview)
            as PhoneSkillDrafts.Shown).view
        assertEquals(old.revision + 1, view.revision)
        assertEquals(built.preview.markdown, view.markdown); assertEquals(revision, view.bundleRevision)
        assertEquals(PhoneSkillDrafts.Code.STALE,
            (manager.beginSave(client, old.draftId, 7, old.revision, true) as PhoneSkillDrafts.Rejected).code)
        assertEquals(PhoneSkillDrafts.Code.CONFIRMATION_REQUIRED,
            (manager.beginSave(client, view.draftId, 7, view.revision, false) as PhoneSkillDrafts.Rejected).code)
        val write = (manager.beginSave(client, view.draftId, 7, view.revision, true) as PhoneSkillDrafts.Started).write
        assertSame(built.bundle, write.bundle)
        assertSame(write, (manager.beginSave(client, view.draftId, 7, view.revision, true) as PhoneSkillDrafts.Existing).write)
    }
    @Test fun editRevokesBuiltBundleAndViewDoesNotRebind() {
        val source = source(); var id = 0
        val manager = PhoneSkillDrafts { (++id).toString(16).padStart(32, '0') }
        val client = manager.attachClient(); val epoch = manager.currentEpoch(); manager.offer(epoch, source)
        val old = (manager.open(client, source.owner, true) as PhoneSkillDrafts.Shown).view
        val built = build(source, template(source, old.skillName)) as PhoneSkillNavigationRoute.Result.Ready
        val bound = (manager.bindBundle(epoch, old.owner, old.draftId, old.revision, built.bundle, built.preview)
            as PhoneSkillDrafts.Shown).view
        val edited = (manager.edit(client, bound.draftId, 7, bound.revision,
            PhoneSkillDrafts.Edit("", "", listOf(""), listOf(0))) as PhoneSkillDrafts.Shown).view
        assertEquals(bound.revision + 1, edited.revision); assertNull(edited.bundleRevision)
        assertEquals(edited, (manager.view(client, edited.draftId, 7) as PhoneSkillDrafts.Shown).view)
        assertEquals(PhoneSkillDrafts.Code.STALE,
            (manager.beginSave(client, bound.draftId, 7, bound.revision, true) as PhoneSkillDrafts.Rejected).code)
        assertNull((manager.beginSave(client, edited.draftId, 7, edited.revision, true) as PhoneSkillDrafts.Started).write.bundle)
    }
    @Test fun writeCommittingOrFinishingAfterOpenSettleKeepsItsOriginalEditorOrReceipt() {
        for (finish in listOf(false, true)) {
            val source = source(); var id = 0; var onId: () -> Unit = {}
            val manager = PhoneSkillDrafts { onId(); (++id).toString(16).padStart(32, '0') }
            val client = manager.attachClient(); val epoch = manager.currentEpoch(); manager.offer(epoch, source)
            val old = (manager.open(client, source.owner, true) as PhoneSkillDrafts.Shown).view
            val built = build(source, template(source, old.skillName)) as PhoneSkillNavigationRoute.Result.Ready
            val bound = (manager.bindBundle(epoch, old.owner, old.draftId, old.revision, built.bundle, built.preview)
                as PhoneSkillDrafts.Shown).view
            val write = (manager.beginSave(client, bound.draftId, 7, bound.revision, true) as PhoneSkillDrafts.Started).write
            onId = {
                onId = {}
                assertTrue(write.beginCommit())
                if (finish) write.finish(PhoneSkillInstallResult.BundleUnverified(built.bundle.identity,
                    B.Publication.PUBLISHED, B.Verification.VERIFICATION_UNAVAILABLE))
            }
            assertEquals(PhoneSkillDrafts.Code.BUSY,
                (manager.open(client, source.owner, true) as PhoneSkillDrafts.Rejected).code)
            if (finish) {
                val receipt = manager.view(client, bound.draftId, 7) as PhoneSkillDrafts.Unverified
                assertEquals(built.bundle.identity, receipt.bundle)
                assertEquals(B.Publication.PUBLISHED, receipt.publication)
                assertEquals(receipt, manager.open(client, source.owner, true))
            } else {
                assertEquals(PhoneSkillWrite.Phase.COMMITTING, write.phase())
                val retained = (manager.view(client, bound.draftId, 7) as PhoneSkillDrafts.Shown).view
                assertEquals(bound.draftId, retained.draftId); assertEquals(bound.revision, retained.revision)
                assertEquals(bound.markdown, retained.markdown); assertEquals(bound.bundleRevision, retained.bundleRevision)
                assertSame(write, (manager.beginSave(client, bound.draftId, 7, bound.revision, true)
                    as PhoneSkillDrafts.Existing).write)
            }
        }
    }

}
