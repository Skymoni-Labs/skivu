package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

class SensitiveWordsRegressionTest {
    @Test fun englishActionsMatchWholeWordsAndPhrasesWithoutAResourceId() {
        for (label in listOf("Send", "DELETE", "Buy now", "Submit", "Pay", "Publish", "Sign out", "Log out", "Place order")) {
            assertNotNull(label, SensitiveWords.confirmHit(label, null))
        }
        assertEquals("发送", SensitiveWords.confirmHit("发送", null))
        assertEquals("send", SensitiveWords.confirmHit("", "example.app:id/btnSend"))
    }

    @Test fun ordinaryProseAndEmbeddedWordFragmentsDoNotBecomeActions() {
        for (label in listOf("Buyer guide", "Paymentology", "Resend history", "Calling hours",
            "A guide showing how to buy supplies from local shops")) {
            assertNull(label, SensitiveWords.confirmHit(label, null))
        }
        assertNotNull(SensitiveWords.confirmHit("Delete all saved messages permanently", null))
    }

    @Test fun sharedSecretHintsKeepOtpCompatibilityWithoutHotpotFalsePositives() {
        for (hint in listOf("Verification code", "Passcode", "OTP", "Enter otp code", "One-time code", "验证码", "校验码")) {
            assertNotNull(hint, SensitiveWords.secretHit(hint, null, null))
        }
        assertNotNull(SensitiveWords.secretHit(null, "Security passcode", null))
        assertNotNull(SensitiveWords.secretHit(null, null, "example.app:id/smsCode"))
        assertNotNull(SensitiveWords.secretHit(null, null, "example.app:id/otp"))
        for (hint in listOf("hotpot search", "Hotpot", "Search", "order number")) {
            assertNull(hint, SensitiveWords.secretHit(hint, null, null))
        }
        assertNull(SensitiveWords.secretHit(null, null, "example.app:id/hotpotSearch"))
    }
}
