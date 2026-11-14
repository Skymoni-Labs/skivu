package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

class PhonePromptNoticeTest {
    private var now = 1_000L
    private val arbiter = PromptArbiter({ now })
    private val owner = Any()
    private val posted = linkedMapOf<Int, PromptContent>()
    private var nextId = 0

    private fun begin(kind: PromptKind = PromptKind.REVIEW, current: () -> Boolean = { true }): PromptTicket =
        arbiter.begin(null, owner, PromptContent(kind, "private request"), 30_000, current)!!

    private fun shown(ticket: PromptTicket, surface: PromptSurface = PromptSurface.OVERLAY): PromptPresentation =
        ticket.attempt(surface)!!.also { assertTrue(it.markShown()) }

    private fun notice(p: PromptPresentation) = p.showNotice {
        val id = ++nextId
        posted[id] = p.ticket.content
        ({ posted.remove(id); Unit })
    }

    @Test fun overlayAndAppNoticesRetainTheOriginalAnsweringPresentation() {
        for (surface in listOf(PromptSurface.OVERLAY, PromptSurface.APP)) {
            val ticket = begin(PromptKind.APPROVAL)
            val p = shown(ticket, surface)
            notice(p)
            assertEquals(listOf(ticket.content), posted.values.toList())
            assertSame(p, ticket.presentation(p.nonce))
            assertEquals(surface, ticket.finalPresentationSurface())
            assertFalse(p.choose(PromptChoice.ALLOW_TASK))
            assertTrue(p.choose(PromptChoice.ALLOW_ONCE))
            assertTrue(posted.isEmpty())
            assertEquals(PromptOutcome.ALLOW_ONCE, ticket.finalResult().outcome)
        }
    }

    @Test fun notificationFallbackDoesNotCreateASecondNotice() {
        val ticket = begin()
        val p = shown(ticket, PromptSurface.NOTIFICATION)
        notice(p)
        assertEquals(0, nextId)
        assertTrue(p.choose(PromptChoice.OPEN))
        assertEquals(PromptOutcome.OPEN, ticket.finalResult().outcome)
    }

    @Test fun unshownAndRetiredPresentationsCannotPost() {
        val ticket = begin()
        val unshown = ticket.attempt(PromptSurface.OVERLAY)!!
        notice(unshown)
        assertEquals(0, nextId)
        unshown.retire()
        val current = shown(ticket, PromptSurface.APP)
        notice(unshown)
        assertEquals(0, nextId)
        notice(current)
        assertEquals(1, nextId)
        ticket.stop()
        assertTrue(posted.isEmpty())
    }

    @Test fun cancellationAndDeadlineRemoveOnlyTheirOwnNotices() {
        val first = begin()
        notice(shown(first))
        first.stop()
        assertTrue(posted.isEmpty())
        val second = begin(PromptKind.HANDOFF)
        notice(shown(second))
        assertEquals(setOf(2), posted.keys)
        first.stop()
        assertEquals(setOf(2), posted.keys)
        now += 30_000
        second.check()
        assertTrue(posted.isEmpty())
        assertEquals(PromptOutcome.TIMEOUT, second.finalResult().outcome)
    }

    @Test fun ownerRetirementBeforePostingProducesNoNotice() {
        var current = true
        val ticket = begin { current }
        val p = shown(ticket)
        current = false
        notice(p)
        assertEquals(0, nextId)
        assertEquals(PromptOutcome.STOPPED, ticket.finalResult().outcome)
    }

    @Test fun completionDuringPlatformPostClosesTheReturnedNotice() {
        val ticket = begin()
        val p = shown(ticket)
        var closed = 0
        p.showNotice {
            ticket.stop()
            ({ closed++ })
        }
        assertEquals(1, closed)
        assertFalse(p.live)
    }

    @Test fun unavailableNotificationDoesNotDismissTheRealPrompt() {
        val ticket = begin()
        val p = shown(ticket)
        p.showNotice { null }
        assertTrue(p.live)
        assertTrue(p.choose(PromptChoice.LATER))
        assertEquals(PromptOutcome.DISMISSED, ticket.finalResult().outcome)
    }
}
