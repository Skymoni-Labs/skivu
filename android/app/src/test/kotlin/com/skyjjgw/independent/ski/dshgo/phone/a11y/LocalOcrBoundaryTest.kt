package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.*
import org.junit.Test

/** Tests the same pure boundary called by ScreenShooter; no fake Android classes or bitmap claims. */
class LocalOcrBoundaryTest {
    private fun line(text: String = "合成文字") = LocalOcrResult.Line(text, 1, 1, 20, 10)
    private fun read(requested: Boolean = true, privacy: Boolean = true,
        clock: () -> Long = { 1 }, cancelled: () -> Boolean = { false },
        recognize: () -> LocalOcrResult) = LocalOcrBoundary.read(
        requested, privacy, 100, 100, 10, clock, cancelled, recognize)

    @Test fun noRequestOrPrivacyDenialDoesNotCallTheEngine() {
        var calls = 0
        val engine = { calls++; LocalOcrResult.Recognized(emptyList()) }
        assertEquals(LocalOcrResult.Unavailable(LocalOcrResult.Reason.NOT_REQUESTED), read(requested = false, recognize = engine))
        assertEquals(LocalOcrResult.Unavailable(LocalOcrResult.Reason.PRIVACY_UNVERIFIED), read(privacy = false, recognize = engine))
        assertEquals(0, calls)
    }

    @Test fun cancellationAndDeadlineBeforeEntryDoNotReadPixels() {
        val forbidden = { error("engine must not run") }
        assertEquals(LocalOcrResult.Unavailable(LocalOcrResult.Reason.CANCELLED), read(cancelled = { true }, recognize = forbidden))
        assertEquals(LocalOcrResult.Unavailable(LocalOcrResult.Reason.DEADLINE), read(clock = { 10 }, recognize = forbidden))
    }

    @Test fun lateResultIsRejectedForBothCancellationAndDeadline() {
        var cancelled = false
        assertEquals(LocalOcrResult.Unavailable(LocalOcrResult.Reason.CANCELLED), read(cancelled = { cancelled }) {
            cancelled = true
            LocalOcrResult.Recognized(listOf(line()))
        })
        var now = 1L
        assertEquals(LocalOcrResult.Unavailable(LocalOcrResult.Reason.DEADLINE), read(clock = { now }) {
            now = 10L
            LocalOcrResult.Recognized(listOf(line()))
        })
    }

    @Test fun unavailableIsDistinctFromSuccessfulEmptyRecognition() {
        val missing = LocalOcrResult.Unavailable(LocalOcrResult.Reason.NOT_INSTALLED)
        val empty = LocalOcrResult.Recognized(emptyList())
        assertEquals(missing, read { missing })
        assertEquals(empty, read { empty })
        assertTrue(LocalOcrBoundary.message(missing).contains("尚未安装"))
        assertTrue(LocalOcrBoundary.message(empty).contains("未提供视觉元素"))
    }

    @Test fun exceptionsBecomeFixedFailureWithoutTheirMessage() {
        val result = read { throw IllegalStateException("private raw OCR content") }
        assertEquals(LocalOcrResult.Failed(LocalOcrResult.Failure.ENGINE), result)
        assertFalse(LocalOcrBoundary.message(result).contains("private"))
    }

    @Test fun interruptedAdapterPreservesInterruptAndCannotPublish() {
        try {
            assertEquals(LocalOcrResult.Unavailable(LocalOcrResult.Reason.CANCELLED), read { throw InterruptedException() })
            assertTrue(Thread.currentThread().isInterrupted)
        } finally { Thread.interrupted() }
    }

    @Test fun resultBudgetUsesActualUtf8AndLimitsCountBeforeCopy() {
        val chinese = line("中".repeat(6000)) // 6000 chars, 18000 UTF-8 bytes.
        assertEquals(LocalOcrResult.Failed(LocalOcrResult.Failure.RESULT_LIMIT), read { LocalOcrResult.Recognized(listOf(chinese)) })
        assertEquals(LocalOcrResult.Failed(LocalOcrResult.Failure.RESULT_LIMIT), read { LocalOcrResult.Recognized(List(257) { line() }) })
    }

    @Test fun boxesAndConfidenceMustBelongToThisFrame() {
        for (invalid in listOf(line().copy(left = -1), line().copy(right = 101),
            line().copy(bottom = 1), line().copy(confidence = Float.NaN), line().copy(confidence = 1.1f))) {
            assertEquals(LocalOcrResult.Failed(LocalOcrResult.Failure.INVALID_RESULT), read { LocalOcrResult.Recognized(listOf(invalid)) })
        }
    }

    @Test fun acceptedResultCopiesTheListButNeverFormatsItsTextOrCoordinates() {
        val original = mutableListOf(line("private-test-secret"))
        val result = read { LocalOcrResult.Recognized(original) } as LocalOcrResult.Recognized
        original.clear()
        assertEquals(1, result.lines.size)
        val message = LocalOcrBoundary.message(result)
        assertFalse(message.contains("private-test-secret"))
        assertFalse(message.contains("20"))
        assertEquals(message, LocalOcrBoundary.message(LocalOcrResult.Recognized(emptyList())))
    }
}
