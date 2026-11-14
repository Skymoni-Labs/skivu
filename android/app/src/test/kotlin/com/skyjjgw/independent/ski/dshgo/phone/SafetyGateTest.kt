package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

class SafetyGateTest {
    private fun target(label: String = "打开", password: Boolean = false, secret: Boolean = false) =
        TargetInfo("s1", 1, "按钮", label, "example.app", "Example", password, secret, password || secret)

    @Test fun hardRulesRefuseWhileLockedEvenWhenConfirmationsAreWaived() {
        for (mode in listOf(ConfirmMode.ASK, ConfirmMode.ALWAYS)) {
            val gate = SafetyGate({ PhonePolicies(confirmMode = mode) }, PhoneTasks(), { null })
            fun rule(pkg: String, target: TargetInfo = target()) =
                (gate.checkWrite(WriteKind.TAP, target, pkg, null) as SafetyGate.Verdict.Refuse).rule
            assertEquals("deny-list", rule("com.icbc"))
            assertEquals("own-app", rule(SafetyRules.OWN_PACKAGE))
            assertEquals("system-page", rule("com.android.settings"))
            assertEquals("secret-field", rule("example.app", target(password = true)))
            assertEquals("secret-field", rule("example.app", target(secret = true)))
            assertEquals("deny-list", gate.checkRead("com.icbc", null)?.rule)
            assertEquals("own-app", gate.checkRead(SafetyRules.OWN_PACKAGE, null)?.rule)
            assertEquals("own-app", gate.checkOpen(SafetyRules.OWN_PACKAGE, null)?.rule)
        }
    }

    @Test fun eachLiftedRuleLetsOnlyItsOwnKindThrough() {
        val all = PhoneUnlocks(systemPages = true, secretFields = true, ownApp = true)
        for (mode in listOf(ConfirmMode.ASK, ConfirmMode.ALWAYS)) {
            fun gate(unlocks: PhoneUnlocks) = SafetyGate({ PhonePolicies(confirmMode = mode, unlocks = unlocks) }, PhoneTasks(), { null })
            fun verdict(unlocks: PhoneUnlocks, pkg: String, target: TargetInfo = target()) =
                gate(unlocks).checkWrite(WriteKind.TAP, target, pkg, null)
            fun refused(v: SafetyGate.Verdict) = (v as? SafetyGate.Verdict.Refuse)?.rule

            // System pages: through once lifted (asked like any app in ASK, straight in ALWAYS).
            assertNull(refused(verdict(PhoneUnlocks(systemPages = true), "com.android.settings")))
            assertNull(refused(verdict(PhoneUnlocks(systemPages = true), "com.android.systemui")))
            assertEquals("secret-field", refused(verdict(PhoneUnlocks(systemPages = true), "example.app", target(password = true))))
            assertEquals("own-app", refused(verdict(PhoneUnlocks(systemPages = true), SafetyRules.OWN_PACKAGE)))

            // Password and code fields.
            for (t in listOf(target(password = true), target(secret = true))) {
                assertNull(refused(verdict(PhoneUnlocks(secretFields = true), "example.app", t)))
            }
            assertEquals("system-page", refused(verdict(PhoneUnlocks(secretFields = true), "com.android.settings")))

            // DSH Go itself: read, open, write, and its screens come back whole.
            val own = gate(PhoneUnlocks(ownApp = true))
            assertNull(refused(own.checkWrite(WriteKind.TAP, target(), SafetyRules.OWN_PACKAGE, null)))
            assertNull(own.checkRead(SafetyRules.OWN_PACKAGE, null))
            assertNull(own.checkOpen(SafetyRules.OWN_PACKAGE, null))
            val screen = ScreenSnapshot("s1", "对话列表", "DSH Go", SafetyRules.OWN_PACKAGE)
            assertSame(screen, own.filterScreen(screen))
            assertEquals("system-page", refused(own.checkWrite(WriteKind.TAP, target(), "com.android.settings", null)))

            // The 不碰 list is the person's own list, not one of these: it still refuses.
            assertEquals("deny-list", refused(verdict(all, "com.icbc")))
            assertEquals("deny-list", gate(all).checkRead("com.icbc", null)?.rule)
            if (mode == ConfirmMode.ALWAYS) {
                assertSame(SafetyGate.Verdict.Allow, verdict(all, "com.android.settings"))
                assertSame(SafetyGate.Verdict.Allow, verdict(all, "example.app", target(password = true)))
            }
        }
    }

    @Test fun aSecretTypedOnceAllowedIsMaskedInItsConfirmation() {
        val tasks = PhoneTasks()
        tasks.begin()
        val gate = SafetyGate({ PhonePolicies(unlocks = PhoneUnlocks(secretFields = true)) }, tasks, { null })
        val field = TargetInfo("s1", 2, "输入框", "支付密码", "example.app", "Example", true, true, true)
        val v = gate.checkWrite(WriteKind.TYPE, field, "example.app", "Example", typed = "135790", submit = true) as SafetyGate.Verdict.Confirm
        assertFalse(v.request.sentence.contains("135790"))
        assertTrue(v.request.sentence.contains(SafetyRules.MASK))
    }

    @Test fun unlocksReadAsOffUnlessStoredAsTrue() {
        assertFalse(PhonePolicies().unlocks.any)
        assertFalse(PhonePolicies.fromMap(null).unlocks.any)
        assertFalse(PhonePolicies.fromMap(mapOf("unlocks" to "yes")).unlocks.any)
        val odd = PhonePolicies.fromMap(mapOf("unlocks" to mapOf("systemPages" to "true", "secretFields" to 1, "ownApp" to null)))
        assertEquals(PhoneUnlocks(), odd.unlocks)
        // A partial update keeps what it doesn't name, the other way round too.
        val one = PhonePolicies.fromMap(mapOf("unlocks" to mapOf("secretFields" to true)))
        assertEquals(PhoneUnlocks(secretFields = true), one.unlocks)
        val both = PhonePolicies.fromMap(mapOf("unlocks" to mapOf("ownApp" to true)), base = one)
        assertEquals(PhoneUnlocks(secretFields = true, ownApp = true), both.unlocks)
        val off = PhonePolicies.fromMap(mapOf("unlocks" to mapOf("secretFields" to false)), base = both)
        assertEquals(PhoneUnlocks(ownApp = true), off.unlocks)
        // Other settings leave them alone, and they leave the others alone.
        assertEquals(both.unlocks, PhonePolicies.fromMap(mapOf("confirmMode" to "always"), base = both).unlocks)
        assertEquals(both.denyPackages, PhonePolicies.fromMap(mapOf("unlocks" to mapOf("ownApp" to false)), base = both).denyPackages)
        // Stored and read back as written.
        val stored = Json.parse(Json.write(both.toMap())) as Map<*, *>
        assertEquals(both, PhonePolicies.fromMap(stored))
    }

    @Test fun liftingARuleIsRefusedWhileAnyTaskMayActButTighteningNeverIs() {
        val base = PhonePolicies(unlocks = PhoneUnlocks(ownApp = true))
        val lift = mapOf("unlocks" to mapOf("secretFields" to true))
        assertNull(PhonePolicies.update(lift, base) { true })
        assertEquals(PhoneUnlocks(secretFields = true, ownApp = true), PhonePolicies.update(lift, base) { false }!!.unlocks)
        assertNull(PhonePolicies.update(mapOf("unlocks" to mapOf("ownApp" to false, "systemPages" to true)), base) { true })
        var asked = false
        val busy = { asked = true; true }
        assertEquals(PhoneUnlocks(), PhonePolicies.update(mapOf("unlocks" to mapOf("ownApp" to false)), base, busy)!!.unlocks)
        assertEquals(base.unlocks, PhonePolicies.update(mapOf("unlocks" to mapOf("ownApp" to true)), base, busy)!!.unlocks)
        assertEquals(listOf("a.b"), PhonePolicies.update(mapOf("denyPackages" to listOf("a.b")), base, busy)!!.denyPackages)
        assertFalse(asked)
    }

    @Test fun handoffCauseComesOnlyFromHardRefusals() {
        assertEquals(HandoffCause.SECRET, HandoffCause.ofDecision("refused:secret-field"))
        assertEquals(HandoffCause.SYSTEM, HandoffCause.ofDecision("refused:system-page"))
        assertEquals(HandoffCause.DENY_LIST, HandoffCause.ofDecision("refused:deny-list"))
        for (d in listOf(null, "ok", "denied", "refused:no-gate", "refused:own-app", "secret-field")) {
            assertNull(d, HandoffCause.ofDecision(d))
        }
    }

    @Test fun firstAppSensitiveWordsAndWechatRequireConfirmation() {
        val tasks = PhoneTasks()
        tasks.begin()
        val gate = SafetyGate({ PhonePolicies() }, tasks, { null })
        fun confirm(pkg: String, target: TargetInfo = target()) =
            gate.checkWrite(WriteKind.TAP, target, pkg, null) as SafetyGate.Verdict.Confirm
        assertEquals("first-in-app", confirm("example.app").reason)
        tasks.approve("example.app")
        assertSame(SafetyGate.Verdict.Allow, gate.checkWrite(WriteKind.TAP, target(), "example.app", null))
        assertTrue(confirm("example.app", target("发送")).reason.startsWith("sensitive:"))
        tasks.approve("com.tencent.mm")
        repeat(2) { assertEquals("every-write", confirm("com.tencent.mm").reason) }
    }

    @Test fun missingUserGateRefusesInsteadOfApproving() {
        val gate = SafetyGate({ PhonePolicies() }, PhoneTasks(), { null })
        val verdict = gate.checkWrite(WriteKind.TAP, target(), "example.app", null)
        val result = gate.resolve(verdict, SerialWorker.Scope()) as SafetyGate.Result.No
        assertEquals("refused:no-gate", result.decision)
    }

    @Test fun filtersSensitiveImagesWithoutChangingOrdinaryScreens() {
        val gate = SafetyGate({ PhonePolicies() }, PhoneTasks(), { null })
        val plain = ScreenSnapshot("b1", "ordinary", "Example", "example.app", image = byteArrayOf(1, 2), imageMime = "image/png")
        assertSame(plain, gate.filterScreen(plain))
        for (text in listOf("«银行卡 ****1234»", "«身份证 ****1234»")) {
            val filtered = gate.filterScreen(plain.copy(text = text))
            assertNull(filtered.image)
            assertNull(filtered.imageMime)
            assertTrue(filtered.text.startsWith(text))
            assertTrue(filtered.text.length > text.length)
        }
        val refused = gate.filterScreen(plain.copy(packageName = SafetyRules.OWN_PACKAGE))
        assertNull(refused.image)
        assertFalse(refused.text.contains("ordinary"))
        val secure = gate.filterScreen(plain.copy(secure = true))
        assertNull(secure.image)
        assertFalse(secure.text.contains("ordinary"))
    }
    @Test fun unknownCoordinatesAndLongSwipeIgnoreOrdinaryWaivers() {
        for (mode in ConfirmMode.entries) {
            val tasks = PhoneTasks().apply { begin(); waive() }
            val gate = SafetyGate({ PhonePolicies(confirmMode = mode) }, tasks, { null })
            for (gesture in listOf(PhoneAction.CoordinateGesture.LONG, PhoneAction.CoordinateGesture.SWIPE)) {
                val action = PhoneAction.TapXY("s1", 10, 20, gesture, 30, 40, 400)
                repeat(2) {
                    val verdict = gate.checkWrite(WriteKind.TAP_XY, null, "example.app", "Example",
                        point = 10 to 20, coordinate = action) as SafetyGate.Verdict.Confirm
                    assertFalse(verdict.request.firstInApp)
                    assertFalse(verdict.request.offerTaskWaiver)
                }
            }
            assertTrue(gate.checkWrite(WriteKind.TAP_XY, null, "example.app", "Example",
                point = 10 to 20, coordinate = PhoneAction.TapXY("s1", 10, 20)) is SafetyGate.Verdict.Confirm)
        }
    }

    @Test fun backgroundCoordinatesAlwaysAskEvenAfterAppAndTaskApprovalInEveryMode() {
        for (mode in ConfirmMode.entries) {
            val tasks = PhoneTasks().apply { begin(); waive(); approve("example.app") }
            val gate = SafetyGate({ PhonePolicies(confirmMode = mode) }, tasks, { null })
            for (gesture in PhoneAction.CoordinateGesture.entries) {
                val action = PhoneAction.TapXY("b1", 10, 20, gesture, 30, 40, 400)
                repeat(2) {
                    val verdict = gate.checkWrite(WriteKind.TAP_XY, null, "example.app", "Example",
                        point = 10 to 20, coordinate = action, screen = PhoneScreen.BACKGROUND) as SafetyGate.Verdict.Confirm
                    assertFalse(verdict.request.offerTaskWaiver)
                    assertFalse(verdict.request.firstInApp)
                    assertTrue(verdict.request.sentence.contains("这是最近后台截图的位置"))
                }
            }
            assertTrue(gate.checkWrite(WriteKind.TAP_XY, null, SafetyRules.DEFAULT_DENY.first(), "Blocked",
                coordinate = PhoneAction.TapXY("b1", 1, 1), screen = PhoneScreen.BACKGROUND) is SafetyGate.Verdict.Refuse)
            assertTrue(gate.checkWrite(WriteKind.TAP_XY, null, "com.android.settings", "Settings",
                coordinate = PhoneAction.TapXY("b1", 1, 1), screen = PhoneScreen.BACKGROUND) is SafetyGate.Verdict.Refuse)
        }
    }

}
