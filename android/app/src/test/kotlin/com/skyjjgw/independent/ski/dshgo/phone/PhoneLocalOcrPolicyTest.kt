package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

/** Calls the same single-key transaction that setPolicies uses; no fake settings algorithm. */
class PhoneLocalOcrPolicyTest {
    @Test fun oldPolicyShapesDoNotTouchOcrOrItsPreferences() {
        for (value in listOf(null, emptyMap<String, Any?>(), mapOf("confirmMode" to "always"))) {
            assertNull(applyLocalOcrPolicyUpdate(value, { fail("unexpected publication") }, {
                fail("unexpected OCR preference write"); false
            }))
        }
    }

    @Test fun malformedOrMixedOcrUpdatesHaveNoSideEffects() {
        val malformed = listOf(null, 1, 1.0, "true", emptyList<Boolean>()).map {
            mapOf<String, Any?>("localOcrEnabled" to it)
        } + listOf(mapOf("localOcrEnabled" to false, "confirmMode" to "always"),
            mapOf<Any, Any?>("localOcrEnabled" to true, 1 to false))
        for (value in malformed) {
            assertEquals(false, applyLocalOcrPolicyUpdate(value, { fail("unexpected publication") }, {
                fail("unexpected OCR preference write"); false
            }))
        }
    }

    @Test fun offRevokesAdmissionBeforeCommitAndDoesNotRollbackOnFailedSave() {
        for (throws in listOf(false, true)) {
            var enabled = true
            var writes = 0
            val saved = applyLocalOcrPolicyUpdate(mapOf("localOcrEnabled" to false),
                publish = { enabled = it }, commit = {
                    writes++
                    assertFalse(it)
                    assertFalse(enabled)
                    if (throws) throw IllegalStateException("storage unavailable")
                    false
                })
            assertEquals(false, saved)
            assertFalse(enabled)
            assertEquals(1, writes)
        }
    }

    @Test fun onPublishesOnlyAfterSuccessfulCommit() {
        for (saveResult in listOf(false, true)) {
            var enabled = false
            var committed = false
            val saved = applyLocalOcrPolicyUpdate(mapOf("localOcrEnabled" to true),
                publish = { assertTrue(committed); enabled = it }, commit = {
                    assertTrue(it)
                    assertFalse(enabled)
                    committed = saveResult
                    saveResult
                })
            assertEquals(saveResult, saved)
            assertEquals(saveResult, enabled)
        }
    }

    @Test fun throwingOnCommitKeepsPreviousAdmissionAndReportsFailure() {
        var publications = 0
        val saved = applyLocalOcrPolicyUpdate(mapOf("localOcrEnabled" to true),
            publish = { publications++ }, commit = { throw IllegalStateException("storage unavailable") })
        assertEquals(false, saved)
        assertEquals(0, publications)
    }

    @Test fun sameValueRequestsStillAttemptPersistenceWithoutInventingAnAck() {
        var writes = 0
        for (enabled in listOf(false, true)) {
            var published = enabled
            repeat(2) {
                assertEquals(true, applyLocalOcrPolicyUpdate(mapOf("localOcrEnabled" to enabled),
                    publish = { published = it }, commit = { writes++; true }))
                assertEquals(enabled, published)
            }
        }
        assertEquals(4, writes)
    }
}
