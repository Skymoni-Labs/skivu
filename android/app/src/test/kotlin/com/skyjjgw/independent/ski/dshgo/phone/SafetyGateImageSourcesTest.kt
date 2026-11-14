package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

class SafetyGateImageSourcesTest {
    private fun screen() = ScreenSnapshot(
        "s1", "合法正文", "A", "example.a",
        image = byteArrayOf(1, 2), imageMime = "image/jpeg",
        readPackages = setOf("example.a"),
        imageReadPackages = linkedSetOf("example.a", "example.b"),
    )

    @Test fun deniedImageSourceDropsOnlyAttachmentAndKeepsSourceFacts() {
        val gate = SafetyGate({ PhonePolicies(denyPackages = listOf("example.b")) }, PhoneTasks(), { null })
        val original = screen()
        val result = gate.filterScreen(original)
        assertNotSame(original, result)
        assertTrue(result.text.startsWith(original.text + "\n"))
        assertTrue(result.text.contains("这次没有附截图"))
        assertNull(result.image)
        assertNull(result.imageMime)
        assertEquals(original.id, result.id)
        assertEquals(original.packageName, result.packageName)
        assertEquals(original.readPackages, result.readPackages)
        assertEquals(original.imageReadPackages, result.imageReadPackages)
        assertNotNull(original.image)
    }

    @Test fun wholeScreenRefusalsStillTakePriorityOverImageOnlyRefusal() {
        val gate = SafetyGate({ PhonePolicies(denyPackages = listOf("example.b")) }, PhoneTasks(), { null })
        for (original in listOf(
            screen().copy(packageName = "example.b"),
            screen().copy(packageName = SafetyRules.OWN_PACKAGE),
            screen().copy(readPackages = setOf("example.b")),
            screen().copy(secure = true),
        )) {
            val result = gate.filterScreen(original)
            assertFalse(result.text.contains("合法正文"))
            assertFalse(result.text.contains("这次没有附截图"))
            assertNull(result.image)
            assertNull(result.imageMime)
            assertNull(result.focus)
        }
    }

    @Test fun imageSourcesUseOnePolicySnapshotRatherThanCombiningPermissions() {
        var reads = 0
        val gate = SafetyGate({
            reads++
            PhonePolicies(denyPackages = listOf(if (reads == 1) "example.b" else "example.a"))
        }, PhoneTasks(), { null })
        val result = gate.filterScreen(screen())
        assertTrue(result.text.startsWith("合法正文\n"))
        assertNull(result.image)
        assertNull(result.imageMime)
        assertEquals(1, reads)
    }

    @Test fun explicitPolicyAndAllAllowedReturnTheSameObject() {
        val gate = SafetyGate({ error("The supplied output policy must not be sampled again") }, PhoneTasks(), { null })
        val original = screen()
        assertSame(original, gate.filterScreen(original, PhonePolicies(denyPackages = emptyList())))
        val textOnly = original.copy(image = null, imageMime = null)
        assertSame(textOnly, gate.filterScreen(textOnly, PhonePolicies(denyPackages = listOf("example.b"))))
        val legacy = original.copy(imageReadPackages = emptySet())
        assertSame(legacy, gate.filterScreen(legacy, PhonePolicies(denyPackages = listOf("example.b"))))
    }

    @Test fun ownAppImageSourceRequiresItsExistingUnlockAndMaskingStillDropsImages() {
        val gate = SafetyGate({ PhonePolicies() }, PhoneTasks(), { null })
        val own = screen().copy(imageReadPackages = setOf(SafetyRules.OWN_PACKAGE))
        val locked = gate.filterScreen(own)
        assertTrue(locked.text.startsWith("合法正文\n"))
        assertNull(locked.image)
        assertSame(own, gate.filterScreen(own, PhonePolicies(unlocks = PhoneUnlocks(ownApp = true))))
        val masked = screen().copy(text = "«银行卡 ****»", imageReadPackages = emptySet())
        val result = gate.filterScreen(masked)
        assertTrue(result.text.startsWith(masked.text))
        assertNull(result.image)
        assertNull(result.imageMime)
    }
}
