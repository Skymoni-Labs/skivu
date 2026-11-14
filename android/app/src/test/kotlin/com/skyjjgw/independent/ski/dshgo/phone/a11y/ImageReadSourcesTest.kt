package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.view.accessibility.AccessibilityWindowInfo
import com.skyjjgw.independent.ski.dshgo.phone.PhonePolicies
import com.skyjjgw.independent.ski.dshgo.phone.PhoneTasks
import com.skyjjgw.independent.ski.dshgo.phone.SafetyGate
import com.skyjjgw.independent.ski.dshgo.phone.ScreenSnapshot
import org.junit.Assert.*
import org.junit.Test

class ImageReadSourcesTest {
    private val own = "example.own"
    private val app = AccessibilityWindowInfo.TYPE_APPLICATION
    private val overlay = AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY
    private val box = Box(0, 0, 100, 200)
    private fun cap(metadata: List<CapturedImageWindow>, windows: List<UiWindow> = emptyList()) = Capture(
        windows, emptyList(), false, box, "example.a", false, false, false,
        takenAt = 0L, imageWindows = metadata,
    )
    private fun shot(windowId: Int? = null, hidden: Set<Int> = emptySet(), bytes: ByteArray? = byteArrayOf(1)) =
        Shot(bytes, if (bytes == null) null else "image/jpeg", null, false, null,
            capturedWindowId = windowId, hiddenOverlayWindowIds = hidden)
    private fun window(id: Int, pkg: String?) = UiWindow(id, WindowKind.APP, pkg, null, box, null)

    @Test fun actualWindowTargetIncludesOnlyThatIdAndKeepsBothKnownPackages() {
        val source = cap(listOf(CapturedImageWindow(1, app, "example.a"),
            CapturedImageWindow(2, app, "example.denied")), listOf(window(1, "example.a2"), window(2, "example.denied")))
        assertEquals(setOf("example.a", "example.a2"), ImageReadSources.knownPackages(source, shot(1), own))
    }

    @Test fun displayKeepsAllKnownMetadataEvenOutsideTheContentSubset() {
        val metadata = (1..5).map { CapturedImageWindow(it, app, "example.a$it") } + listOf(
            CapturedImageWindow(6, AccessibilityWindowInfo.TYPE_INPUT_METHOD, "example.ime"),
            CapturedImageWindow(7, AccessibilityWindowInfo.TYPE_SYSTEM, "example.system"),
            CapturedImageWindow(8, overlay, own), CapturedImageWindow(9, overlay, "example.other"))
        assertEquals((1..5).map { "example.a$it" }.toSet() + setOf("example.ime", "example.system", own, "example.other"),
            ImageReadSources.knownPackages(cap(metadata, listOf(window(1, "example.a1"))), shot(), own))
    }

    @Test fun onlyThisDisplayHiddenOwnOverlayIdCanBeOmitted() {
        val hidden = CapturedImageWindow(7, overlay, own)
        assertEquals(emptySet<String>(), ImageReadSources.knownPackages(cap(listOf(hidden)), shot(hidden = setOf(7)), own))
        assertEquals(setOf(own), ImageReadSources.knownPackages(cap(listOf(hidden)), shot(hidden = setOf(8)), own))
        assertEquals(setOf(own), ImageReadSources.knownPackages(cap(listOf(hidden.copy(type = app))), shot(hidden = setOf(7)), own))
        assertEquals(setOf("example.other"), ImageReadSources.knownPackages(cap(listOf(hidden.copy(packageName = "example.other"))), shot(hidden = setOf(7)), own))
        assertEquals(setOf(own), ImageReadSources.knownPackages(cap(listOf(hidden)), shot(windowId = 7, hidden = setOf(7)), own))
        assertEquals(setOf(own), ImageReadSources.knownPackages(cap(listOf(hidden, hidden.copy(id = 8))), shot(hidden = setOf(7)), own))
    }

    @Test fun sameCaptureContentKnowledgeSurvivesUnknownMetadata() {
        val source = cap(listOf(CapturedImageWindow(1, app, null)), listOf(window(1, "example.a")))
        assertEquals(setOf("example.a"), ImageReadSources.knownPackages(source, shot(), own))
        assertEquals(setOf("example.a"), ImageReadSources.knownPackages(source, shot(1), own))
    }

    @Test fun missingImageAndUnknownMetadataDoNotInventSources() {
        val source = cap(listOf(CapturedImageWindow(1, app, null), CapturedImageWindow(2, app, " ")))
        assertEquals(emptySet<String>(), ImageReadSources.knownPackages(source, shot(), own))
        assertEquals(emptySet<String>(), ImageReadSources.knownPackages(cap(listOf(CapturedImageWindow(1, app, "example.a"))), shot(bytes = null), own))
    }

    @Test fun actualMappingFeedsTheOriginalSafetyGateWithoutChangingTextSources() {
        val capture = cap(listOf(CapturedImageWindow(1, app, "example.a"), CapturedImageWindow(2, app, "example.b")))
        val gate = SafetyGate({ PhonePolicies(denyPackages = listOf("example.b")) }, PhoneTasks(), { null })
        fun result(shot: Shot) = ScreenSnapshot("s1", "合法正文", "A", "example.a", image = shot.bytes,
            imageMime = shot.mime, readPackages = setOf("example.a"),
            imageReadPackages = ImageReadSources.knownPackages(capture, shot, own))
        val display = result(shot())
        val filtered = gate.filterScreen(display)
        assertTrue(filtered.text.startsWith("合法正文"))
        assertEquals(setOf("example.a"), filtered.readPackages)
        assertNull(filtered.image)
        val window = result(shot(1))
        assertSame(window, gate.filterScreen(window))
    }
}
