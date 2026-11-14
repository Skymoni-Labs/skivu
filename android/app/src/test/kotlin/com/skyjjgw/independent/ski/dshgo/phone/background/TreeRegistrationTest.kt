package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

/** Exercises production retention with controlled RPC outcomes; not an Android Binder test. */
class TreeRegistrationTest {
    @Test fun failedRegisterReplyRetainsTheOriginalClientForCleanup() {
        val original = Any()
        val removed = ArrayList<Any>()
        val registration = TreeRegistration<Any> { removed.add(it) }
        val failure = IllegalStateException("reply lost")
        try {
            registration.register(original) { throw failure }
            fail("register must expose its failure to the caller")
        } catch (caught: IllegalStateException) { assertSame(failure, caught) }
        assertTrue(registration.close { })
        assertEquals(1, removed.size)
        assertSame(original, removed.single())
    }

    @Test fun disconnectCallingUnregisterDoesNotDispatchItTwice() {
        val original = Any()
        val removed = ArrayList<Any>()
        val registration = TreeRegistration<Any> { removed.add(it) }
        registration.register(original) { }
        assertTrue(registration.close { registration.unregister() })
        assertTrue(registration.close { })
        assertEquals(listOf(original), removed)
    }

    @Test fun failedProxyUnregisterWaitsForTheNextCloseBeforeRetryingSameClient() {
        val original = Any()
        val removed = ArrayList<Any>()
        var failure = true
        val registration = TreeRegistration<Any> {
            removed.add(it)
            if (failure) throw IllegalStateException("unconfirmed")
        }
        registration.register(original) { }
        assertFalse(registration.close { registration.unregister() })
        assertEquals(1, removed.size) // No automatic second attempt in this close.
        failure = false
        // Models the documented subsequent UiAutomation DISCONNECTED early return.
        assertTrue(registration.close { })
        assertEquals(2, removed.size)
        removed.forEach { assertSame(original, it) }
    }

    @Test fun lostSuccessfulUnregisterReplyAndNotRegisteredErrorRemainUnconfirmed() {
        val original = Any()
        var platformHasClient = true
        var calls = 0
        val registration = TreeRegistration<Any> {
            assertSame(original, it)
            calls++
            if (platformHasClient) {
                platformHasClient = false
                throw IllegalStateException("reply lost after removal")
            }
            throw IllegalStateException("not registered")
        }
        registration.register(original) { }
        assertFalse(registration.close { registration.unregister() })
        assertFalse(registration.close { })
        assertFalse(registration.close { })
        assertEquals(3, calls)
    }

    @Test fun unknownRegistrationCannotBeOverwrittenByAnotherClient() {
        val original = Any()
        val removed = ArrayList<Any>()
        val registration = TreeRegistration<Any> { removed.add(it) }
        runCatching { registration.register(original) { error("reply unknown") } }
        var replacementCalled = false
        val replaced = runCatching { registration.register(Any()) { replacementCalled = true } }
        assertTrue(replaced.isFailure)
        assertFalse(replacementCalled)
        assertTrue(registration.close { })
        assertSame(original, removed.single())
    }

    @Test fun preparationWithoutRegistrationDoesNotInventRemoteCleanup() {
        var calls = 0
        val registration = TreeRegistration<Any> { calls++ }
        assertTrue(registration.close { error("local preparation failed") })
        assertEquals(0, calls)
    }

    @Test fun disconnectFailureBeforeProxyInvocationStillTriesTheRetainedClientOnce() {
        var calls = 0
        val original = Any()
        val registration = TreeRegistration<Any> { assertSame(original, it); calls++ }
        registration.register(original) { }
        assertTrue(registration.close { error("local disconnect unavailable") })
        assertEquals(1, calls)
    }

    @Test fun successfulRemoteCleanupIsNotUndoneByLaterLocalDisconnectFailure() {
        var calls = 0
        val registration = TreeRegistration<Any> { calls++ }
        registration.register(Any()) { }
        assertTrue(registration.close { registration.unregister(); error("local teardown") })
        assertTrue(registration.close { })
        assertEquals(1, calls)
    }
}
