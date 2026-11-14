package com.skyjjgw.independent.ski.dshgo.phone.skills

import org.junit.Assert.*
import org.junit.Test

class PhoneSkillReplayRequestTest {
    private fun arguments(uid: Any = 10001, values: Map<String, Any?> = emptyMap()) = mapOf(
        "skillId" to "phone-task-${"1".repeat(32)}", "revision" to "2".repeat(32), "sessionId" to "s1",
        "parameters" to mapOf("appSlots" to mapOf("app1" to mapOf("packageName" to "example.app", "uid" to uid)),
            "values" to values))

    @Test fun acceptsOnlyTheCurrentNativeSelectionEnvelopeWithoutGrantingAnApp() {
        val parsed = PhoneSkillReplaySelections.Request.parse(arguments())!!
        assertEquals("example.app", parsed.packageName); assertEquals(10001, parsed.uid)
        assertEquals("s1", parsed.session)
        assertEquals(parsed, PhoneSkillReplaySelections.Request.parse(arguments(10001L)))
        // Parsing is not PM verification and cannot register this arbitrary package.
        assertTrue(PhoneSkillReplayApps.descriptors.isEmpty())
    }
    @Test fun rejectsUnknownParameterNamespacesValuesAndExecutionClaims() {
        assertNull(PhoneSkillReplaySelections.Request.parse(arguments(values = mapOf("text" to "private"))))
        assertNull(PhoneSkillReplaySelections.Request.parse(arguments() + ("steps" to emptyList<Any>())))
        assertNull(PhoneSkillReplaySelections.Request.parse(arguments() + ("verified" to true)))
        assertNull(PhoneSkillReplaySelections.Request.parse(arguments() + ("parameters" to mapOf(
            "appSlots" to mapOf("app2" to mapOf("packageName" to "example.app", "uid" to 10001)),
            "values" to emptyMap<String, Any>()))))
        assertNull(PhoneSkillReplaySelections.Request.parse(arguments() + ("parameters" to mapOf(
            "appSlots" to mapOf("app1" to mapOf("packageName" to "example.app", "uid" to 10001, "verified" to true)),
            "values" to emptyMap<String, Any>()))))
    }
    @Test fun rejectsCoercedIdentityTypesPathsAndControlCharacters() {
        for (uid in listOf<Any>("10001", 10001.0, -1, Int.MAX_VALUE.toLong() + 1))
            assertNull(PhoneSkillReplaySelections.Request.parse(arguments(uid)))
        for ((key, value) in listOf("skillId" to "../../x", "revision" to "latest", "sessionId" to "s\n1"))
            assertNull(PhoneSkillReplaySelections.Request.parse(arguments() + (key to value)))
    }
}
