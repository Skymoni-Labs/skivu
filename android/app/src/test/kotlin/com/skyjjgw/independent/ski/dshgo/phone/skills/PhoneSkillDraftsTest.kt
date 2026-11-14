package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.phone.*
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillInstallResult
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillWrite
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillBundleInstaller as B
import org.junit.Assert.*
import org.junit.Test

class PhoneSkillDraftsTest {
    private fun candidate(id: Long = 1, count: Int = 2): PhoneTaskTrace.Snapshot {
        val owner = PhoneTasks.Owner(id, 1, true)
        val trace = PhoneTaskTrace(); trace.start(owner)
        repeat(count) {
            val action = if (it % 2 == 0) PhoneAction.Tap("s1", 1) else PhoneAction.Type("s1", 1, "PRIVATE_ORIGINAL")
            val target = TargetInfo("s1", 1, "按钮", "搜索", "private.app", "PRIVATE_APP", false, false, false)
            val ticket = trace.beginAction(owner, action, target)
            trace.finish(ticket, true, false, true)
        }
        trace.complete(owner, true)
        return trace.snapshot(owner)!!
    }
    private inner class Fixture {
        private var next = 0L
        val manager = PhoneSkillDrafts { (++next).toString(16).padStart(32, '0') }
        val client = manager.attachClient()
        val source = candidate()
        init { assertTrue(manager.offer(manager.currentEpoch(), source)) }
        fun open(client: PhoneSkillDrafts.Client = this.client) =
            (manager.open(client, source.owner, true) as PhoneSkillDrafts.Shown).view
        fun save(view: PhoneSkillDrafts.View, client: PhoneSkillDrafts.Client = this.client) =
            manager.beginSave(client, view.draftId, view.owner.taskId, view.revision, true)
    }
    private fun changes(order: List<Int> = listOf(0, 1), goal: String = "张三的待办") =
        PhoneSkillDrafts.Edit(goal, "北京市私人地址", order.map { "PRIVATE_CHECK_$it" }, order)
    private fun code(reply: Any) = (reply as PhoneSkillDrafts.Rejected).code

    @Test fun candidatesDoNotRenderUntilExplicitlyOpenedAndConfirmed() {
        val f = Fixture()
        assertEquals(1, f.manager.candidates().size)
        assertEquals(PhoneSkillDrafts.Code.CONFIRMATION_REQUIRED, code(f.manager.open(f.client, f.source.owner, false)))
        val view = f.open()
        assertEquals(1L, view.revision); assertNull(view.phase)
        assertFalse(view.markdown.contains("PRIVATE_"))
        assertEquals(PhoneSkillDrafts.Code.CONFIRMATION_REQUIRED,
            code(f.manager.beginSave(f.client, view.draftId, 1, 1, false)))
    }

    @Test fun editedFreeTextIsRemovedAndEveryNewPreviewRevokesOldConfirmation() {
        val f = Fixture(); val view = f.open()
        val edited = (f.manager.edit(f.client, view.draftId, 1, 1, changes(listOf(1, 0))) as PhoneSkillDrafts.Shown).view
        assertEquals(2L, edited.revision); assertEquals(listOf(1, 0), edited.stepOrder)
        assertTrue(edited.markdown.contains("用户重新整理"))
        assertFalse(edited.markdown.contains("张三")); assertFalse(edited.markdown.contains("私人地址"))
        assertFalse(edited.markdown.contains("PRIVATE_"))
        assertEquals(listOf("goal", "prerequisites", "checkpoints[0]", "checkpoints[1]"), edited.parameterizedFields)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.save(view)))
        val again = (f.manager.edit(f.client, view.draftId, 1, 2, changes(listOf(1, 0))) as PhoneSkillDrafts.Shown).view
        assertEquals(3L, again.revision); assertEquals(edited.markdown, again.markdown)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.save(edited)))
        assertTrue(f.save(again) is PhoneSkillDrafts.Started)
    }

    @Test fun secretMarkersAndBadOrOverlongEditsDoNotAlterTheAcceptedPreview() {
        val f = Fixture(); val view = f.open()
        for (edit in listOf(changes(goal = "password=PRIVATE_SECRET"), changes(goal = "验证码123456"))) {
            assertEquals(PhoneSkillDrafts.Code.SENSITIVE, code(f.manager.edit(f.client, view.draftId, 1, 1, edit)))
        }
        for (edit in listOf(changes(goal = "x".repeat(2001)), changes(goal = "\ufb03".repeat(1000)))) {
            assertEquals(PhoneSkillDrafts.Code.TOO_LARGE, code(f.manager.edit(f.client, view.draftId, 1, 1, edit)))
        }
        for (order in listOf(emptyList(), listOf(0, 0), listOf(-1), listOf(2))) {
            assertEquals(PhoneSkillDrafts.Code.INVALID, code(f.manager.edit(f.client, view.draftId, 1, 1, changes(order))))
        }
        assertEquals(view, (f.manager.view(f.client, view.draftId, 1) as PhoneSkillDrafts.Shown).view)
    }

    @Test fun utf8RequestBudgetIsMeasuredAfterNormalization() {
        val f = Fixture(); val source = candidate(2, 16); f.manager.offer(f.manager.currentEpoch(), source)
        val view = (f.manager.open(f.client, source.owner, true) as PhoneSkillDrafts.Shown).view
        // Fullwidth A shrinks to ASCII under NFKC: both raw-request and normalized byte limits matter.
        for (character in listOf("汉", "Ａ")) {
            val edit = PhoneSkillDrafts.Edit("目标", "前提", List(16) { character.repeat(1000) }, (0..15).toList())
            assertEquals(PhoneSkillDrafts.Code.TOO_LARGE, code(f.manager.edit(f.client, view.draftId, 2, 1, edit)))
        }
        assertEquals(1L, (f.manager.view(f.client, view.draftId, 2) as PhoneSkillDrafts.Shown).view.revision)
    }

    @Test fun duplicateSaveSharesTheOnlyPermitAndSuccessIsIdempotent() {
        val f = Fixture(); val view = f.open()
        val write = (f.save(view) as PhoneSkillDrafts.Started).write
        assertSame(write, (f.save(view) as PhoneSkillDrafts.Existing).write)
        assertTrue(write.beginCommit())
        assertEquals(PhoneSkillDrafts.Code.CANNOT_CANCEL, code(f.manager.discard(f.client, view.draftId, 1)))
        write.finish(PhoneSkillInstallResult.Saved(write.document.skillName))
        val saved = f.manager.saved(view.draftId, write) as PhoneSkillDrafts.Saved
        assertEquals("skills/${write.document.skillName}/SKILL.md", saved.relativePath)
        assertEquals(saved, f.save(view)); assertEquals(saved, f.manager.saved(view.draftId, write))
        assertTrue(f.manager.candidates().isEmpty())
    }

    @Test fun discardBeforeCommitRevokesTheRealPermitAndLateCallbackDoesNotAttachToANewDraft() {
        val f = Fixture(); val old = f.open()
        val write = (f.save(old) as PhoneSkillDrafts.Started).write
        assertSame(PhoneSkillDrafts.Discarded, f.manager.discard(f.client, old.draftId, 1))
        assertFalse(write.beginCommit())
        val current = f.open()
        write.finish(PhoneSkillInstallResult.Refused.STALE)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.saved(old.draftId, write)))
        assertEquals(current.draftId, (f.manager.view(f.client, current.draftId, 1) as PhoneSkillDrafts.Shown).view.draftId)
    }

    @Test fun failedWriteKeepsPreviewAndRequiresANewRevisionForRetry() {
        val f = Fixture(); val view = f.open()
        val write = (f.save(view) as PhoneSkillDrafts.Started).write
        write.finish(PhoneSkillInstallResult.Refused.IO)
        assertEquals(PhoneSkillDrafts.Code.IO, code(f.manager.saved(view.draftId, write)))
        assertEquals(PhoneSkillDrafts.Code.IO, code(f.save(view)))
        val edited = (f.manager.edit(f.client, view.draftId, 1, 1, changes()) as PhoneSkillDrafts.Shown).view
        assertEquals(2L, edited.revision)
        assertNotSame(write, (f.save(edited) as PhoneSkillDrafts.Started).write)
    }

    @Test fun viewingAnAsynchronousFailureReportsTheFixedOutcomeWithoutRetrying() {
        for (failure in PhoneSkillInstallResult.Refused.values()) {
            val f = Fixture(); val view = f.open()
            val write = (f.save(view) as PhoneSkillDrafts.Started).write
            assertTrue(write.beginCommit())
            assertEquals(PhoneSkillWrite.Phase.COMMITTING,
                (f.manager.view(f.client, view.draftId, 1) as PhoneSkillDrafts.Shown).view.phase)
            write.finish(failure) // The installer may finish before its notification callback runs.
            val expected = PhoneSkillDrafts.Code.valueOf(failure.name)
            repeat(2) {
                assertEquals(expected, code(f.manager.view(f.client, view.draftId, 1)))
                assertEquals(expected, code(f.save(view)))
            }
            val edited = (f.manager.edit(f.client, view.draftId, 1, 1, changes()) as PhoneSkillDrafts.Shown).view
            assertEquals(2L, edited.revision)
            assertNotSame(write, (f.save(edited) as PhoneSkillDrafts.Started).write)
        }
    }

    @Test fun retiredQueuedClientCanNeverOpenAndOldDetachCannotCancelReplacement() {
        val f = Fixture(); f.manager.retireClient(f.client)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.open(f.client, f.source.owner, true)))
        val fresh = f.manager.attachClient(); val view = f.open(fresh)
        f.manager.retireClient(f.client)
        assertTrue(f.manager.view(fresh, view.draftId, 1) is PhoneSkillDrafts.Shown)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.discard(f.client, view.draftId, 1)))
        val foreign = PhoneSkillDrafts().attachClient()
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.open(foreign, f.source.owner, true)))
    }

    @Test fun engineRetirementCancelsStagingButCannotRetractCommittingWrites() {
        for (commit in listOf(false, true)) {
            val f = Fixture(); val view = f.open(); val write = (f.save(view) as PhoneSkillDrafts.Started).write
            if (commit) assertTrue(write.beginCommit())
            f.manager.retireClient(f.client)
            val fresh = f.manager.attachClient()
            if (!commit) {
                assertFalse(write.beginCommit())
                assertTrue(f.manager.open(fresh, f.source.owner, true) is PhoneSkillDrafts.Shown)
            } else {
                assertEquals(PhoneSkillDrafts.Code.BUSY, code(f.manager.open(fresh, f.source.owner, true)))
                write.finish(PhoneSkillInstallResult.Saved(write.document.skillName))
                assertTrue(f.manager.saved(view.draftId, write) is PhoneSkillDrafts.Saved)
                assertTrue(f.manager.open(fresh, f.source.owner, true) is PhoneSkillDrafts.Saved)
                assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.view(f.client, view.draftId, 1)))
            }
        }
    }

    @Test fun anotherClientExplicitlyReplacesEditableOrStagingAndWrongWriteCannotFinishIt() {
        val f = Fixture(); val old = f.open(); val oldWrite = (f.save(old) as PhoneSkillDrafts.Started).write
        val fresh = f.manager.attachClient(); val current = f.open(fresh)
        assertFalse(oldWrite.beginCommit())
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.view(f.client, old.draftId, 1)))
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.saved(current.draftId, oldWrite)))
        f.manager.retireClient(f.client)
        assertTrue(f.manager.view(fresh, current.draftId, 1) is PhoneSkillDrafts.Shown)
    }

    @Test fun reopeningSameTaskOnSameClientGivesNewIdentitySoOldDialogCleanupCannotCancelIt() {
        val f = Fixture(); val old = f.open(); val current = f.open()
        assertNotEquals(old.draftId, current.draftId)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.discard(f.client, old.draftId, 1)))
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.save(old)))
        val edited = f.manager.edit(f.client, current.draftId, 1, current.revision, changes()) as PhoneSkillDrafts.Shown
        assertEquals(current.draftId, edited.view.draftId)
        assertEquals(current.revision + 1, edited.view.revision)
    }

    @Test fun candidateRetentionIsBoundedAndDoesNotReplaceTheOpenEditorsSource() {
        val f = Fixture(); val view = f.open()
        for (id in 2L..10L) assertTrue(f.manager.offer(f.manager.currentEpoch(), candidate(id)))
        assertEquals(8, f.manager.candidates().size)
        assertFalse(f.manager.candidates().any { it.owner.taskId == 1L })
        assertTrue(f.manager.view(f.client, view.draftId, 1) is PhoneSkillDrafts.Shown)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.edit(f.client, view.draftId, 2, 1, changes())))
    }

    @Test fun engineExitClearsCandidatesAndCancelsQueuedWritesWithoutRetiringTheUiClient() {
        val f = Fixture(); val view = f.open(); val write = (f.save(view) as PhoneSkillDrafts.Started).write
        val oldEpoch = f.manager.currentEpoch()
        f.manager.onEngineRetired()
        assertTrue(f.manager.candidates().isEmpty()); assertFalse(write.beginCommit())
        assertFalse(f.manager.offer(oldEpoch, candidate(3)))
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.view(f.client, view.draftId, 1)))
        assertTrue(f.manager.offer(f.manager.currentEpoch(), candidate(2)))
        assertTrue(f.manager.open(f.client, candidate(2).owner, true) is PhoneSkillDrafts.Shown)
    }

    @Test fun engineExitDuringCommitPreservesSavedOutcomeButAFailedOldDraftCannotRetryOnNewRoot() {
        for (success in listOf(true, false)) {
            val f = Fixture(); val view = f.open(); val write = (f.save(view) as PhoneSkillDrafts.Started).write
            assertTrue(write.beginCommit()); f.manager.onEngineRetired()
            assertEquals(PhoneSkillDrafts.Code.CANNOT_CANCEL, code(f.manager.discard(f.client, view.draftId, 1)))
            write.finish(if (success) PhoneSkillInstallResult.Saved(write.document.skillName) else PhoneSkillInstallResult.Refused.IO)
            if (success) {
                assertTrue(f.manager.view(f.client, view.draftId, 1) is PhoneSkillDrafts.Saved)
                assertTrue(f.manager.saved(view.draftId, write) is PhoneSkillDrafts.Saved)
            } else {
                assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.edit(f.client, view.draftId, 1, 1, changes())))
                assertEquals(PhoneSkillDrafts.Code.IO, code(f.manager.saved(view.draftId, write)))
                assertEquals(PhoneSkillDrafts.Code.STALE, code(f.save(view)))
            }
        }
    }
    private fun bundle(view: PhoneSkillDrafts.View, revision: Long = view.revision + 1,
        markdown: String = view.markdown): B.Document {
        val rev = "b".repeat(32)
        val route = """{"schema":1,"skillName":"${view.skillName}","bundleRevision":"$rev",
            "descriptorSet":"fixture-only","appSlots":[{"key":"app1","kind":"user_selected_app"}],
            "parameters":[],"steps":[{"op":"open_app","appSlot":"app1","screen":"main",
            "post":{"kind":"page_is","pageKey":"home"}}]}""".toByteArray()
        val descriptor = PhoneSkillRoute.Descriptor("fixture-only", setOf("app1"), emptyList(),
            setOf(PhoneSkillRoute.Step(PhoneSkillRoute.Op.OPEN_APP, "app1", PhoneScreen.MAIN,
                post = PhoneSkillRoute.Post.PageIs("home"))))
        return (B.freeze(view.skillName, rev, revision, markdown.toByteArray(), route,
            mapOf("fixture-only" to descriptor)) as B.Frozen.Ready).document
    }

    @Test fun nativeBundleBindingRevokesTheAlreadyShownTemplateConfirmation() {
        val f = Fixture(); val old = f.open(); val doc = bundle(old)
        val current = (f.manager.bindBundle(f.manager.currentEpoch(), old.owner, old.draftId,
            old.revision, doc) as PhoneSkillDrafts.Shown).view
        assertEquals(old.revision + 1, current.revision)
        assertEquals(doc.identity.revision, current.bundleRevision)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.save(old)))
        val write = (f.save(current) as PhoneSkillDrafts.Started).write
        assertSame(doc, write.bundle)
        assertSame(write, (f.save(current) as PhoneSkillDrafts.Existing).write)
        assertEquals(PhoneSkillDrafts.Code.BUSY, code(f.manager.bindBundle(f.manager.currentEpoch(),
            current.owner, current.draftId, current.revision, bundle(current))))
    }

    @Test fun witnessBindingRequiresExactEpochOwnerNameMarkdownAndNextRevision() {
        val f = Fixture(); val old = f.open(); val epoch = f.manager.currentEpoch()
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.bindBundle(epoch + 1, old.owner,
            old.draftId, old.revision, bundle(old))))
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.bindBundle(epoch,
            old.owner.copy(lifecycle = old.owner.lifecycle + 1), old.draftId, old.revision, bundle(old))))
        for (doc in listOf(bundle(old, old.revision), bundle(old, markdown = old.markdown + "changed"),
            bundle(old.copy(skillName = "phone-task-" + "c".repeat(32))))) {
            assertEquals(PhoneSkillDrafts.Code.INVALID, code(f.manager.bindBundle(epoch, old.owner,
                old.draftId, old.revision, doc)))
        }
        assertEquals(old, (f.manager.view(f.client, old.draftId, old.owner.taskId) as PhoneSkillDrafts.Shown).view)
        assertNull((f.save(old) as PhoneSkillDrafts.Started).write.bundle) // No route is inferred from Trace.
    }

    @Test fun anyAcceptedEditDropsThePreviousRouteAndReturnsToTemplateSaving() {
        val f = Fixture(); val old = f.open()
        val bound = (f.manager.bindBundle(f.manager.currentEpoch(), old.owner, old.draftId, old.revision,
            bundle(old)) as PhoneSkillDrafts.Shown).view
        val edited = (f.manager.edit(f.client, bound.draftId, bound.owner.taskId, bound.revision,
            changes()) as PhoneSkillDrafts.Shown).view
        assertNull(edited.bundleRevision)
        assertEquals(bound.revision + 1, edited.revision)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.save(bound)))
        assertNull((f.save(edited) as PhoneSkillDrafts.Started).write.bundle)
    }

    @Test fun committingUnverifiedSurvivesRetirementAndReleasesTheEditorOnlyAfterPhysicalFinish() {
        for (publication in B.Publication.entries) {
            val f = Fixture(); val old = f.open(); val doc = bundle(old)
            val bound = (f.manager.bindBundle(f.manager.currentEpoch(), old.owner, old.draftId,
                old.revision, doc) as PhoneSkillDrafts.Shown).view
            val write = (f.save(bound) as PhoneSkillDrafts.Started).write
            assertTrue(write.beginCommit())
            f.manager.onEngineRetired()
            assertEquals(PhoneSkillWrite.Phase.COMMITTING, write.phase())
            assertFalse(write.cancel())
            assertEquals(PhoneSkillDrafts.Code.CANNOT_CANCEL,
                code(f.manager.discard(f.client, bound.draftId, bound.owner.taskId)))
            val result = PhoneSkillInstallResult.BundleUnverified(doc.identity, publication, B.Verification.BUNDLE_INVALID)
            write.finish(result)
            val receipt = f.manager.saved(bound.draftId, write) as PhoneSkillDrafts.Unverified
            assertEquals(doc.identity, receipt.bundle)
            assertEquals(publication, receipt.publication)
            assertEquals(receipt, f.manager.view(f.client, bound.draftId, bound.owner.taskId))
            assertEquals(receipt, f.manager.saved(bound.draftId, write))
            val next = candidate(2)
            assertTrue(f.manager.offer(f.manager.currentEpoch(), next))
            assertTrue(f.manager.open(f.client, next.owner, true) is PhoneSkillDrafts.Shown)
            assertEquals(receipt, f.manager.saved(bound.draftId, write)) // Late callback cannot replace new editor.
        }
    }

    @Test fun clientRetirementCannotErasePublishedBundleMetadataOrPermitAnotherCommit() {
        val f = Fixture(); val old = f.open(); val doc = bundle(old)
        val bound = (f.manager.bindBundle(f.manager.currentEpoch(), old.owner, old.draftId,
            old.revision, doc) as PhoneSkillDrafts.Shown).view
        val write = (f.save(bound) as PhoneSkillDrafts.Started).write
        assertTrue(write.beginCommit()); f.manager.retireClient(f.client)
        write.finish(PhoneSkillInstallResult.BundleSaved(doc.identity))
        val receipt = f.manager.saved(bound.draftId, write) as PhoneSkillDrafts.Saved
        assertEquals(doc.identity, receipt.bundle)
        assertFalse(write.beginCommit()); assertFalse(write.cancel())
        write.finish(PhoneSkillInstallResult.Refused.STALE)
        assertTrue(write.result() is PhoneSkillInstallResult.BundleSaved)
        assertEquals(receipt, f.manager.saved(bound.draftId, write))
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.view(f.client, bound.draftId, bound.owner.taskId)))
    }

    @Test fun cancellingBundleBeforePermissionKeepsTheRealWriteFromPublishing() {
        val f = Fixture(); val old = f.open()
        val bound = (f.manager.bindBundle(f.manager.currentEpoch(), old.owner, old.draftId,
            old.revision, bundle(old)) as PhoneSkillDrafts.Shown).view
        val write = (f.save(bound) as PhoneSkillDrafts.Started).write
        assertSame(PhoneSkillDrafts.Discarded, f.manager.discard(f.client, bound.draftId, bound.owner.taskId))
        assertFalse(write.canStage()); assertFalse(write.beginCommit())
        write.finish(PhoneSkillInstallResult.Refused.STALE)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.saved(bound.draftId, write)))
    }

    @Test fun nativePublicSummaryIsShownAndSavedAtTheSameNewRevision() {
        val f = Fixture(); val old = f.open()
        val original = PhoneSkillDraft.render(f.source, old.skillName, true) as PhoneSkillDraft.Ready
        val preview = PhoneSkillDraft.withRouteSummary(original, "1. 核对公共页面与唯一目标；执行后核对预期状态。")!!
        val doc = bundle(old, markdown = preview.markdown)
        val shown = (f.manager.bindBundle(f.manager.currentEpoch(), old.owner, old.draftId,
            old.revision, doc, preview) as PhoneSkillDrafts.Shown).view
        assertEquals(old.revision + 1, shown.revision)
        assertEquals(preview.markdown, shown.markdown)
        assertFalse(shown.markdown.contains("{{check_"))
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.save(old)))
        val write = (f.save(shown) as PhoneSkillDrafts.Started).write
        assertEquals(shown.markdown, write.document.markdown)
        assertArrayEquals(shown.markdown.toByteArray(Charsets.UTF_8), write.bundle!!.bytes()[0])
    }

    @Test fun mismatchedSummaryOrOwnerCannotChangeTheShownDocument() {
        val f = Fixture(); val old = f.open()
        val original = PhoneSkillDraft.render(f.source, old.skillName, true) as PhoneSkillDraft.Ready
        val preview = PhoneSkillDraft.withRouteSummary(original, "公开摘要")!!
        assertEquals(PhoneSkillDrafts.Code.INVALID, code(f.manager.bindBundle(f.manager.currentEpoch(),
            old.owner, old.draftId, old.revision, bundle(old), preview)))
        val foreign = PhoneSkillDraft.render(candidate(2), old.skillName, true) as PhoneSkillDraft.Ready
        val other = PhoneSkillDraft.withRouteSummary(foreign, "公开摘要")!!
        assertEquals(PhoneSkillDrafts.Code.INVALID, code(f.manager.bindBundle(f.manager.currentEpoch(),
            old.owner, old.draftId, old.revision, bundle(old, markdown = other.markdown), other)))
        assertEquals(old, (f.manager.view(f.client, old.draftId, old.owner.taskId) as PhoneSkillDrafts.Shown).view)
    }

    private fun frozenSave(manager: PhoneSkillDrafts, client: PhoneSkillDrafts.Client, task: Long,
        finish: Boolean = true): Pair<PhoneSkillDrafts.View, PhoneSkillWrite> {
        val source = candidate(task)
        assertTrue(manager.offer(manager.currentEpoch(), source))
        val old = (manager.open(client, source.owner, true) as PhoneSkillDrafts.Shown).view
        val bound = (manager.bindBundle(manager.currentEpoch(), old.owner, old.draftId, old.revision, bundle(old)) as PhoneSkillDrafts.Shown).view
        val write = (manager.beginSave(client, bound.draftId, task, bound.revision, true) as PhoneSkillDrafts.Started).write
        assertTrue(write.beginCommit())
        if (finish) {
            write.finish(PhoneSkillInstallResult.BundleUnverified(write.bundle!!.identity,
                B.Publication.PUBLISHED, B.Verification.VERIFICATION_UNAVAILABLE))
            assertTrue(manager.saved(bound.draftId, write) is PhoneSkillDrafts.Unverified)
        }
        return bound to write
    }
    private fun checkArgs(view: PhoneSkillDrafts.View) = mapOf<String, Any?>("action" to "check_save",
        "taskId" to view.owner.taskId, "draftId" to view.draftId, "name" to view.skillName, "bundleRevision" to view.bundleRevision)

    @Test fun actualBridgeCoalescesQueriesAndRetirementDoesNotReleaseTheOriginalPin() {
        val manager = PhoneSkillDrafts(); val oldClient = manager.attachClient()
        val (view, write) = frozenSave(manager, oldClient, 10)
        var reads = 0; var installs = 0
        var completed: ((PhoneSkillInstallResult) -> Unit)? = null
        val bridge = PhoneSkillBridge(manager, { _, _ -> installs++ }, {}, check = { _, _, done -> reads++; completed = done })
        var first: Map<String, Any?>? = null
        bridge.checkSave(oldClient, checkArgs(view)) { first = it }
        assertNull(first); assertEquals(1, reads)
        manager.retireClient(oldClient); manager.onEngineRetired()
        val current = manager.attachClient()
        var duplicate: Map<String, Any?>? = null
        bridge.checkSave(current, checkArgs(view)) { duplicate = it }
        assertEquals("unverified", duplicate!!["kind"]); assertEquals(1, reads)
        assertEquals(view.draftId, manager.saveResults().single()["draftId"])
        checkNotNull(completed)(PhoneSkillInstallResult.BundleSaved(write.bundle!!.identity))
        assertEquals("saved", first!!["kind"])
        bridge.checkSave(current, checkArgs(view)) { duplicate = it }
        assertEquals("saved", duplicate!!["kind"]); assertEquals(1, reads); assertEquals(0, installs)
        bridge.checkSave(oldClient, checkArgs(view)) { assertEquals("stale", it["code"]) }
        bridge.checkSave(PhoneSkillDrafts().attachClient(), checkArgs(view)) { assertEquals("stale", it["code"]) }
        assertEquals(1, reads)
    }

    @Test fun queryMetadataSurvivesWeakWriteAndWrongDigestCannotPromoteOriginalReceipt() {
        val manager = PhoneSkillDrafts(); val client = manager.attachClient()
        val (view, write) = frozenSave(manager, client, 20)
        fun begin() = manager.beginCheck(client, view.draftId, 20, view.skillName, view.bundleRevision!!) as PhoneSkillDrafts.Query
        val first = begin()
        val identity = write.bundle!!.identity
        first.receipt.write.clear() // Real WeakReference cleared; Receipt owns its original small metadata.
        assertEquals(identity, first.binding.identity)
        val bad = manager.completeCheck(first, PhoneSkillInstallResult.BundleSaved(identity.copy(skillSha256 = "0".repeat(64))))
        assertEquals(B.Verification.BUNDLE_INVALID, (bad as PhoneSkillDrafts.Unverified).code)
        assertEquals(B.Publication.PUBLISHED, bad.publication)
        val second = begin()
        val originUnavailable = manager.completeCheck(second, PhoneSkillInstallResult.BundleUnverified(identity,
            B.Publication.UNKNOWN, B.Verification.ORIGIN_UNAVAILABLE)) as PhoneSkillDrafts.Unverified
        assertEquals(B.Publication.PUBLISHED, originUnavailable.publication)
        assertEquals(B.Verification.ORIGIN_UNAVAILABLE, originUnavailable.code)
        assertTrue(manager.completeCheck(begin(), PhoneSkillInstallResult.BundleSaved(identity)) is PhoneSkillDrafts.Saved)
    }

    @Test fun allPinnedReceiptsBlockNewSaveButAnUnpinnedUnverifiedReceiptCanBeEvicted() {
        val manager = PhoneSkillDrafts(); val client = manager.attachClient()
        val pinned = (1L..8L).map { task ->
            val (view, _) = frozenSave(manager, client, task)
            manager.beginCheck(client, view.draftId, task, view.skillName, view.bundleRevision!!) as PhoneSkillDrafts.Query
        }
        val source = candidate(9); assertTrue(manager.offer(manager.currentEpoch(), source))
        val old = (manager.open(client, source.owner, true) as PhoneSkillDrafts.Shown).view
        val view = (manager.bindBundle(manager.currentEpoch(), old.owner, old.draftId, old.revision, bundle(old)) as PhoneSkillDrafts.Shown).view
        assertEquals(PhoneSkillDrafts.Code.BUSY, code(manager.beginSave(client, view.draftId, 9, view.revision, true)))
        val evicted = pinned.first()
        manager.completeCheck(evicted, PhoneSkillInstallResult.BundleUnverified(evicted.binding.identity,
            B.Publication.PUBLISHED, B.Verification.ORIGIN_UNAVAILABLE))
        val write = (manager.beginSave(client, view.draftId, 9, view.revision, true) as PhoneSkillDrafts.Started).write
        assertEquals(8, manager.saveResults().size) // Seven pinned receipts + one reserved in-flight write.
        assertTrue(write.beginCommit()); write.finish(PhoneSkillInstallResult.BundleSaved(write.bundle!!.identity))
        assertTrue(manager.saved(view.draftId, write) is PhoneSkillDrafts.Saved)
        assertEquals(8, manager.saveResults().size)
        val oldQuery = manager.beginCheck(client, evicted.draftId, 1, evicted.binding.identity.name, evicted.binding.identity.revision)
        assertEquals(PhoneSkillDrafts.Code.STALE, code((oldQuery as PhoneSkillDrafts.Check.Immediate).reply))
        assertTrue(pinned.drop(1).all { it.receipt.queryInFlight })
    }

    @Test fun aWriteReservesItsReceiptBeforeOtherQueriesPinAllExistingRecords() {
        val manager = PhoneSkillDrafts(); val client = manager.attachClient()
        val records = (1L..7L).map { frozenSave(manager, client, it).first }
        val (view, write) = frozenSave(manager, client, 8, finish = false)
        val queries = records.map { manager.beginCheck(client, it.draftId, it.owner.taskId, it.skillName, it.bundleRevision!!) as PhoneSkillDrafts.Query }
        assertEquals(8, manager.saveResults().size)
        manager.onEngineRetired()
        write.finish(PhoneSkillInstallResult.BundleUnverified(write.bundle!!.identity, B.Publication.PUBLISHED, B.Verification.BUNDLE_INVALID))
        assertTrue(manager.saved(view.draftId, write) is PhoneSkillDrafts.Unverified)
        assertEquals(8, manager.saveResults().size)
        assertTrue(queries.all { it.receipt.queryInFlight })
    }

    @Test fun checkSaveUsesFrozenIdentityAndNeverQueuesAnInFlightWriteAgain() {
        val manager = PhoneSkillDrafts(); val client = manager.attachClient()
        val (view, _) = frozenSave(manager, client, 30, finish = false)
        var reads = 0; var installs = 0
        val bridge = PhoneSkillBridge(manager, { _, _ -> installs++ }, {}, check = { _, _, _ -> reads++ })
        bridge.checkSave(client, checkArgs(view)) {
            assertEquals("saving", it["kind"]); assertEquals("committing", it["phase"])
            assertEquals(view.skillName, it["name"]); assertEquals(view.bundleRevision, it["bundleRevision"])
        }
        bridge.checkSave(client, checkArgs(view) + ("bundleRevision" to "0".repeat(32))) { assertEquals("stale", it["code"]) }
        bridge.checkSave(client, checkArgs(view) + ("root" to "/other")) { assertEquals("invalid", it["code"]) }
        assertEquals(0, reads); assertEquals(0, installs)
    }
}
