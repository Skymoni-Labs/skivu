package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundPreviewChoiceTest {
    private fun app(task: Long) = BackgroundPreview.Consumer(task, BackgroundPreview.ConsumerKind.APP_DIALOG) {}
    private fun overlay(task: Long) = BackgroundPreview.Consumer(task, BackgroundPreview.ConsumerKind.OVERLAY) {}

    @Test fun visibleAppWinsBeforeItsTargetIsReadyAndDoesNotConsultReadyOrder() {
        val requests = listOf(overlay(1), app(2))
        assertEquals(2L, choosePreviewTask(requests, 1))
        // No ready-target input exists in this production selector: late A readiness cannot win.
        assertEquals(2L, choosePreviewTask(requests, 2))
    }

    @Test fun samePriorityPreservesTheSelectedTaskUntilItsConsumerLeaves() {
        val first = app(1); val second = app(2)
        assertEquals(1L, choosePreviewTask(listOf(first, second), null))
        assertEquals(2L, choosePreviewTask(listOf(first, second), 2))
        assertEquals(1L, choosePreviewTask(listOf(first), 2))
    }

    @Test fun sameTaskAppAndOverlayShareSelectionAcrossEitherRemoval() {
        val requests = listOf(overlay(3), app(3))
        assertEquals(3L, choosePreviewTask(requests, 3))
        assertEquals(3L, choosePreviewTask(listOf(requests[0]), 3))
        assertEquals(3L, choosePreviewTask(listOf(requests[1]), 3))
        assertNull(choosePreviewTask(emptyList(), 3))
    }
}
