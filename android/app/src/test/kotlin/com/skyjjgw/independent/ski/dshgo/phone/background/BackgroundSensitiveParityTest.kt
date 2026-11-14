package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.*
import org.junit.Assert.*
import org.junit.Test

class BackgroundSensitiveParityTest {
    @Test fun backgroundAndMainUseTheSameActionAndHintRules() {
        for (label in listOf("Send", "Delete", "Submit", "Buy now", "发送", "Buyer guide",
            "A guide showing how to buy supplies from local shops")) {
            assertEquals(label, SensitiveWords.confirmHit(label, null) != null, BackgroundTree.isSensitiveLabel(label))
        }
        for (hint in listOf("Verification code", "Passcode", "OTP", "One-time code", "验证码", "hotpot search", "搜索")) {
            assertEquals(hint, SensitiveWords.secretHit(hint, null, null) != null, BackgroundTree.isSecretHint(hint))
        }
    }

    @Test fun englishCodeContentsAreMaskedAndRequireTheSecretUnlock() {
        val code = "135790"
        val tasks = PhoneTasks().apply { begin(); approve("example.app") }
        for (hint in listOf("Verification code", "Passcode", "OTP", "One-time code")) {
            val secret = BackgroundTree.isSecretHint(hint)
            val label = BackgroundTree.label(code, hint, true, false, secret)
            assertFalse(hint, label.contains(code))
            assertTrue(label.contains(SafetyRules.MASK))
            val field = TargetInfo("b1", 1, "输入框", label, "example.app", "Example", false, secret, true)
            val locked = SafetyGate({ PhonePolicies() }, tasks, { null })
            val refused = locked.checkWrite(WriteKind.TYPE, field, "example.app", null, typed = code)
            assertEquals("secret-field", (refused as SafetyGate.Verdict.Refuse).rule)
            val unlocked = SafetyGate({ PhonePolicies(unlocks = PhoneUnlocks(secretFields = true)) }, tasks, { null })
            val confirm = unlocked.checkWrite(WriteKind.TYPE, field, "example.app", null, typed = code, submit = true)
                as SafetyGate.Verdict.Confirm
            assertFalse(confirm.request.sentence.contains(code))
            assertTrue(confirm.request.sentence.contains(SafetyRules.MASK))
        }
    }
}
