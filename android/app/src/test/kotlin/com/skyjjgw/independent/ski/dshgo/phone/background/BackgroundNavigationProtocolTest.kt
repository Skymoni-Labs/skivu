package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundNavigationProtocolTest {
    private val app = BackgroundNavigationProtocol.Installation(1L, 2L, "a".repeat(64))
    private fun facts(attempted: Boolean, selected: String, post: String) = mapOf<String, Any>(
        "version" to 1, "mode" to "execute", "windowId" to 3,
        "selected" to selected, "targetLabel" to "More", "targetClickable" to true,
        "attempted" to attempted, "post" to post, "appVersion" to 1L,
        "appUpdated" to 2L, "appSigningDigest" to app.signers)
    private fun parse(values: Map<String, Any>, readOnly: Boolean = false) =
        BackgroundNavigationProtocol.facts(values.keys, values::get,
            BackgroundNavigationProtocol.Request(true, app,
                BackgroundNavigationProtocol.Expectation(3,
                    if (readOnly) "nav_more" else "nav_notebook", "More", readOnly)))

    @Test fun zeroAttemptCannotProveDifferentButAlreadySatisfiedIsValid() {
        assertNull(parse(facts(false, "nav_notebook", "different")))
        assertNotNull(parse(facts(false, "nav_more", "satisfied")))
        assertNotNull(parse(facts(false, "nav_more", "satisfied"), true))
    }

    @Test fun actualAttemptAndExactReceiptRemainRequiredForPostClassification() {
        assertNotNull(parse(facts(true, "nav_notebook", "different")))
        assertNotNull(parse(facts(true, "nav_more", "satisfied")))
        assertNull(parse(facts(true, "nav_more", "satisfied"), true))
        assertNull(parse(facts(true, "nav_more", "different")))
        assertNull(parse(facts(true, "nav_more", "satisfied") + ("windowId" to 4)))
        assertNull(parse(facts(true, "nav_more", "satisfied") - "attempted"))
    }
}
