package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

class SafetyGateEnglishTest {
    private fun target(label: String) = TargetInfo("b1", 1, "按钮", label, "example.app", "Example", false, false, false)

    @Test fun askStillConfirmsAnEnglishSensitiveButtonAfterApprovingTheApp() {
        val tasks = PhoneTasks().apply { begin(); approve("example.app") }
        val gate = SafetyGate({ PhonePolicies(confirmMode = ConfirmMode.ASK) }, tasks, { null })
        for (label in listOf("Send", "Delete", "Submit", "Buy now")) {
            val verdict = gate.checkWrite(WriteKind.TAP, target(label), "example.app", "Example")
            assertTrue(label, verdict is SafetyGate.Verdict.Confirm)
            assertTrue((verdict as SafetyGate.Verdict.Confirm).reason.startsWith("sensitive:"))
        }
        assertSame(SafetyGate.Verdict.Allow, gate.checkWrite(WriteKind.TAP, target("Buyer guide"), "example.app", null))
    }

    @Test fun alwaysKeepsItsExistingConfirmationSemantics() {
        val gate = SafetyGate({ PhonePolicies(confirmMode = ConfirmMode.ALWAYS) }, PhoneTasks(), { null })
        assertSame(SafetyGate.Verdict.Allow, gate.checkWrite(WriteKind.TAP, target("Send"), "example.app", null))
        val secret = target("Passcode").copy(isEditable = true, isSecretField = true)
        val refused = gate.checkWrite(WriteKind.TYPE, secret, "example.app", null, typed = "135790")
        assertEquals("secret-field", (refused as SafetyGate.Verdict.Refuse).rule)
    }
}
