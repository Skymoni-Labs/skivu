package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.phone.PhoneScreen
import com.skyjjgw.independent.ski.dshgo.phone.PhoneTasks
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillInstallResult
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillWrite
import com.skyjjgw.independent.ski.dshgo.runtime.PhoneSkillBundleInstaller as B
import org.junit.Assert.*
import org.junit.Test

class PhoneSkillBridgeTest {
    private class Fixture {
        val drafts = PhoneSkillDrafts()
        val client = drafts.attachClient()
        val writes = ArrayList<PhoneSkillWrite>()
        val done = ArrayList<(PhoneSkillInstallResult) -> Unit>()
        var notifications = 0
        val bridge = PhoneSkillBridge(drafts, { write, callback -> writes += write; done += callback }, { notifications++ })
        init {
            val trace = PhoneTaskTrace(); val owner = PhoneTasks.Owner(7, 11, true)
            trace.start(owner)
            trace.finish(trace.beginOpen(owner, PhoneScreen.MAIN), true, false, true)
            trace.complete(owner, true)
            assertTrue(drafts.offer(drafts.currentEpoch(), trace.snapshot(owner)!!))
        }
        fun call(method: String, args: Map<String, Any?>, client: PhoneSkillDrafts.Client = this.client) = bridge.call(client, method, args)
        fun open(): Map<*, *> = call("skillDraft", mapOf("taskId" to 7L, "generation" to 11, "confirmed" to true))["draft"] as Map<*, *>
        fun identity(view: Map<*, *>) = mapOf("taskId" to view["taskId"], "draftId" to view["draftId"])
        fun save(view: Map<*, *>) = call("saveSkillDraft", identity(view) + mapOf("revision" to view["revision"], "confirmed" to true))
    }

    @Test fun strictWireRejectsMalformedIdentityAndArbitraryMarkdownWithoutCreatingADraft() {
        val f = Fixture()
        for (args in listOf(
            mapOf("taskId" to 7.0, "generation" to 11, "confirmed" to true),
            mapOf("taskId" to 7, "generation" to "11", "confirmed" to true),
            mapOf("taskId" to 7, "generation" to 11, "confirmed" to true, "markdown" to "PRIVATE_INPUT"),
            mapOf("taskId" to 7, "generation" to 11, "action" to "execute", "confirmed" to true),
        )) assertEquals(mapOf("kind" to "rejected", "code" to "invalid"), f.call("skillDraft", args))
        assertEquals("confirmation_required", f.call("skillDraft", mapOf("taskId" to 7, "generation" to 11))["code"])
        assertTrue(f.writes.isEmpty())
    }

    @Test fun duplicateSaveQueuesOnceAndOnlyTheActualInstallerResultBecomesSaved() {
        val f = Fixture(); val view = f.open()
        assertEquals("shown", f.call("skillDraft", f.identity(view) + ("action" to "view"))["kind"])
        assertEquals(mapOf("kind" to "saving", "phase" to "staging"), f.save(view))
        assertEquals("saving", f.save(view)["kind"]); assertEquals(1, f.writes.size)
        val write = f.writes.single(); assertTrue(write.beginCommit())
        assertEquals("committing", f.save(view)["phase"])
        val result = PhoneSkillInstallResult.Saved(write.document.skillName)
        write.finish(result); f.done.single()(result)
        assertEquals(mapOf("kind" to "saved", "name" to result.name, "relativePath" to result.relativePath), f.save(view))
        assertEquals(1, f.notifications); assertEquals(1, f.writes.size)
    }

    @Test fun asynchronousIoNotificationRemainsVisibleToTheEditorsViewRequest() {
        val f = Fixture(); val view = f.open()
        assertEquals("saving", f.save(view)["kind"])
        val write = f.writes.single(); assertTrue(write.beginCommit())
        write.finish(PhoneSkillInstallResult.Refused.IO)
        f.done.single()(PhoneSkillInstallResult.Refused.IO)
        assertEquals(1, f.notifications)
        repeat(2) {
            assertEquals(mapOf("kind" to "rejected", "code" to "io"),
                f.call("skillDraft", f.identity(view) + ("action" to "view")))
            assertEquals("io", f.save(view)["code"])
        }
        assertEquals(1, f.writes.size)
    }

    @Test fun finalEditPreviewContainsNoRawValuesAndOldRevisionCannotSave() {
        val f = Fixture(); val old = f.open()
        val edited = f.call("skillDraft", f.identity(old) + mapOf("action" to "edit", "revision" to 1,
            "goal" to "PRIVATE_PERSON", "prerequisites" to "PRIVATE_ADDRESS", "checkpoints" to listOf("PRIVATE_TEXT"), "stepOrder" to listOf(0L)))
        val view = edited["draft"] as Map<*, *>
        assertEquals(2L, view["revision"]); assertFalse(view["markdown"].toString().contains("PRIVATE_"))
        assertEquals("stale", f.save(old)["code"])
        assertEquals("saving", f.save(view)["kind"])
    }

    @Test fun retiredQueuedAttachmentCannotOpenAndCannotCancelANewerDialog() {
        val f = Fixture(); f.drafts.retireClient(f.client)
        assertEquals("stale", f.call("skillDraft", mapOf("taskId" to 7, "generation" to 11, "confirmed" to true))["code"])
        val fresh = f.drafts.attachClient()
        val view = f.call("skillDraft", mapOf("taskId" to 7, "generation" to 11, "confirmed" to true), fresh)["draft"] as Map<*, *>
        assertEquals("stale", f.call("discardSkillDraft", f.identity(view))["code"])
        assertEquals("shown", f.call("skillDraft", f.identity(view) + ("action" to "view"), fresh)["kind"])
    }

    @Test fun finishedFailureRemainsFixedAndDiscardedStagingCannotCommit() {
        val f = Fixture(); val first = f.open(); f.save(first)
        val failed = f.writes.single(); failed.finish(PhoneSkillInstallResult.Refused.IO)
        f.done.single()(PhoneSkillInstallResult.Refused.IO)
        assertEquals("io", f.save(first)["code"])
        val second = f.open(); f.save(second); val pending = f.writes.last()
        assertEquals("discarded", f.call("discardSkillDraft", f.identity(second))["kind"])
        assertFalse(pending.beginCommit())
        pending.finish(PhoneSkillInstallResult.Refused.STALE); f.done.last()(PhoneSkillInstallResult.Refused.STALE)
        assertEquals("stale", f.call("skillDraft", f.identity(second) + ("action" to "view"))["code"])
    }

    @Test fun oversizedAndUntrustedEditShapesNeverReplaceTheAcceptedRevision() {
        val f = Fixture(); val view = f.open()
        val base = f.identity(view) + mapOf("action" to "edit", "revision" to 1, "goal" to "", "prerequisites" to "", "checkpoints" to listOf(""), "stepOrder" to listOf(0))
        for (extra in listOf(mapOf("stepOrder" to listOf(0.0)), mapOf("checkpoints" to listOf(17)), mapOf("stepOrder" to listOf(Long.MAX_VALUE)))) {
            assertEquals("invalid", f.call("skillDraft", base + extra)["code"])
        }
        assertEquals("too_large", f.call("skillDraft", base + ("goal" to "x".repeat(2001)))["code"])
        assertEquals(view, f.call("skillDraft", f.identity(view) + ("action" to "view"))["draft"])
    }
    @Test fun synchronousInstallerRefusalIsReturnedAsFixedFailureAndNotSaving() {
        val f = Fixture(); val view = f.open(); var writes = 0
        val bridge = PhoneSkillBridge(f.drafts, { write, done ->
            writes++
            val refused = PhoneSkillInstallResult.Refused.STALE
            write.finish(refused); done(refused)
        }, {})
        val args = f.identity(view) + mapOf("revision" to view["revision"], "confirmed" to true)
        assertEquals(mapOf("kind" to "rejected", "code" to "stale"), bridge.call(f.client, "saveSkillDraft", args))
        assertEquals("stale", bridge.call(f.client, "saveSkillDraft", args)["code"])
        assertEquals(1, writes)
    }

    @Test fun bundleWireUsesNewRevisionAndKeepsPublishedUnverifiedDistinctFromSaved() {
        val f = Fixture(); val old = f.open()
        val view = (f.drafts.view(f.client, old["draftId"] as String, 7) as PhoneSkillDrafts.Shown).view
        val revision = "d".repeat(32)
        val route = """{"schema":1,"skillName":"${view.skillName}","bundleRevision":"$revision",
            "descriptorSet":"fixture-only","appSlots":[{"key":"app1","kind":"user_selected_app"}],
            "parameters":[],"steps":[{"op":"open_app","appSlot":"app1","screen":"main",
            "post":{"kind":"page_is","pageKey":"home"}}]}""".toByteArray()
        val descriptor = PhoneSkillRoute.Descriptor("fixture-only", setOf("app1"), emptyList(),
            setOf(PhoneSkillRoute.Step(PhoneSkillRoute.Op.OPEN_APP, "app1", PhoneScreen.MAIN,
                post = PhoneSkillRoute.Post.PageIs("home"))))
        val doc = (B.freeze(view.skillName, revision, view.revision + 1, view.markdown.toByteArray(), route,
            mapOf("fixture-only" to descriptor)) as B.Frozen.Ready).document
        assertTrue(f.drafts.bindBundle(f.drafts.currentEpoch(), view.owner, view.draftId,
            view.revision, doc) is PhoneSkillDrafts.Shown)
        assertEquals("stale", f.save(old)["code"])
        assertTrue(f.writes.isEmpty())
        val bound = f.call("skillDraft", f.identity(old) + ("action" to "view"))["draft"] as Map<*, *>
        assertEquals(revision, bound["bundleRevision"])
        assertEquals(mapOf("kind" to "saving", "phase" to "staging", "name" to view.skillName,
            "bundleRevision" to revision), f.save(bound))
        val write = f.writes.single(); assertSame(doc, write.bundle); assertTrue(write.beginCommit())
        val result = PhoneSkillInstallResult.BundleUnverified(doc.identity, B.Publication.PUBLISHED,
            B.Verification.VERIFICATION_UNAVAILABLE)
        write.finish(result); f.done.single()(result)
        val expected = mapOf("kind" to "unverified", "name" to view.skillName,
            "relativePath" to "skills/${view.skillName}/SKILL.md", "bundleRevision" to revision,
            "publication" to "published", "code" to "verification_unavailable")
        assertEquals(expected, f.save(bound))
        assertEquals(expected, f.call("skillDraft", f.identity(bound) + ("action" to "view")))
        assertEquals(1, f.writes.size)
        assertEquals(1, f.notifications)
    }

    @Test fun flutterCannotAttachARouteOrChooseBundleRevisionThroughExistingSaveWire() {
        val f = Fixture(); val view = f.open()
        for (extra in listOf(mapOf("route" to "{}"), mapOf("bundleRevision" to "d".repeat(32)),
            mapOf("descriptorSet" to "fixture-only"))) {
            assertEquals(mapOf("kind" to "rejected", "code" to "invalid"), f.call("saveSkillDraft",
                f.identity(view) + mapOf("revision" to view["revision"], "confirmed" to true) + extra))
        }
        assertEquals(mapOf("kind" to "saving", "phase" to "staging"), f.save(view))
        assertNull(f.writes.single().bundle)
    }

}
