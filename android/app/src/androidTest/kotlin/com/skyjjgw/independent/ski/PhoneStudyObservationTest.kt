package com.skyjjgw.independent.ski

import android.app.UiAutomation
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.test.InstrumentationRegistry
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** Reads an already foreground study page and reports aggregate timings without page content. */
class PhoneStudyObservationTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = InstrumentationRegistry.getTargetContext()
    private val automation get() = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
    private val studyPackage = "com.chaoxing.mobile"
    private val allowed = setOf(studyPackage)
    private val owner = "qa:study-observation"
    private var originalMode: String? = null
    private lateinit var service: SkivuAccessibilityService
    private var nativeText = emptyList<String>()
    private var nativeHasWebView = false
    private val nativeOcrCoverage = linkedMapOf<String, Map<String, Any?>>()

    private fun shell(command: String) = automation.executeShellCommand(command).use { descriptor ->
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { it.readBytes() }
    }

    private fun <T> ui(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val task = FutureTask(block)
        Handler(Looper.getMainLooper()).post(task)
        return task.get(10, TimeUnit.SECONDS)
    }

    private fun assertStudyForeground() {
        ui {
            val root = service.current(allowed)
            try {
                assertEquals("The prepared study page must stay in the foreground", studyPackage, root.packageName?.toString())
            } finally {
                @Suppress("DEPRECATION") root.recycle()
            }
        }
    }

    @Before fun setup() {
        assertTrue("Observation is restricted to the independent QA target", context.packageName.endsWith(".phoneflowqa"))
        assertEquals("confirmed", InstrumentationRegistry.getArguments().getString("skivuPhysicalQa"))
        originalMode = ExecutionHub.mode(context)
        ExecutionHub.setMode(context, "hidden")
        val component = "${context.packageName}/${SkivuAccessibilityService::class.java.name}"
        val enabled = android.provider.Settings.Secure.getString(context.contentResolver, "enabled_accessibility_services").orEmpty()
            .split(':').filter { it.isNotBlank() && it != "null" && it != component }
        shell("settings put secure enabled_accessibility_services ${if (enabled.isEmpty()) "null" else enabled.joinToString(":")}")
        repeat(40) { if (SkivuAccessibilityService.connected != null) Thread.sleep(25) }
        shell("settings put secure enabled_accessibility_services ${(enabled + component).joinToString(":")}")
        shell("settings put secure accessibility_enabled 1")
        val deadline = SystemClock.uptimeMillis() + 10_000
        while (SkivuAccessibilityService.connected == null && SystemClock.uptimeMillis() < deadline) Thread.sleep(25)
        service = SkivuAccessibilityService.connected ?: error("QA accessibility service did not connect")
        assertStudyForeground()
    }

    @After fun restore() {
        nativeText = emptyList()
        originalMode?.let { ExecutionHub.setMode(context, it) }
    }

    private fun nativeStructure(rows: List<Map<String, Any?>>): Map<String, Any?> {
        val byId = rows.associateBy { it["id"] }
        val childCounts = rows.groupingBy { it["parentId"] }.eachCount()
        val textAncestors = mutableSetOf<Any?>()
        for (row in rows.filter { PhoneVision.text(it["text"]).isNotEmpty() || PhoneVision.text(it["description"]).isNotEmpty() }) {
            var parent = row["parentId"]
            val visited = mutableSetOf<Any?>()
            while (parent != null && visited.add(parent)) {
                textAncestors.add(parent)
                parent = byId[parent]?.get("parentId")
            }
        }
        var largestBlankLeafAreaRatio = 0.0
        val elements = rows.map { row ->
            val textLength = row["text"]?.toString().orEmpty().length
            val descriptionLength = row["description"]?.toString().orEmpty().length
            val children = childCounts[row["id"]] ?: 0
            val bounds = (row["bounds"] as? List<*>)?.mapNotNull { (it as? Number)?.toInt() }
            if (children == 0 && textLength == 0 && descriptionLength == 0 && bounds != null && bounds.size == 4) {
                val width = (row["screenWidth"] as? Number)?.toDouble() ?: 0.0
                val height = (row["screenHeight"] as? Number)?.toDouble() ?: 0.0
                if (width > 0 && height > 0) {
                    val area = (bounds[2] - bounds[0]).coerceAtLeast(0).toDouble() * (bounds[3] - bounds[1]).coerceAtLeast(0)
                    largestBlankLeafAreaRatio = maxOf(largestBlankLeafAreaRatio, (area / (width * height)).coerceIn(0.0, 1.0))
                }
            }
            mapOf(
                "class" to row["class"],
                "bounds" to bounds,
                "textLength" to textLength,
                "descriptionLength" to descriptionLength,
                "childCount" to children,
                "hasTextDescendant" to (row["id"] in textAncestors),
            )
        }
        return mapOf("elements" to elements, "largestBlankLeafAreaRatio" to largestBlankLeafAreaRatio)
    }

    private fun read(label: String, mode: String): Map<String, Any?> {
        assertStudyForeground()
        val before = service.visionMetrics.snapshot()
        val started = SystemClock.uptimeMillis()
        val observation = service.vision.observe(allowed, mapOf("pageSize" to 1000), mode, owner, {
            check(SkivuAccessibilityService.connected === service) { "QA accessibility service changed during observation" }
        })
        val elapsed = SystemClock.uptimeMillis() - started
        assertStudyForeground()
        assertEquals(studyPackage, observation["package"])
        val rows = (observation["elements"] as List<*>).map { PhoneFlow.map(it, "row") }
        val recognition = PhoneFlow.map(observation["recognition"], "recognition")
        val after = service.visionMetrics.snapshot()
        if (mode == "controls") {
            nativeHasWebView = rows.any { it["class"]?.toString()?.endsWith(".WebView") == true }
            nativeText = rows.filter { it["password"] != true }.flatMap { row ->
                listOf(PhoneVision.text(row["text"]), PhoneVision.text(row["description"]))
            }.filter { it.isNotEmpty() }
        }
        if (mode == "visual") {
            val lines = rows.filter { it["source"] == "ocr" }
                .map { PhoneVision.text(it["text"]) }.filter { it.isNotEmpty() }
            val combinedNative = nativeText.joinToString("")
            val covered = lines.filter { line ->
                nativeText.any { it.contains(line) } || combinedNative.contains(line)
            }
            val totalCharacters = lines.sumOf { it.codePointCount(0, it.length) }
            val coveredCharacters = covered.sumOf { it.codePointCount(0, it.length) }
            nativeOcrCoverage[label] = mapOf(
                "nativeTextSegments" to nativeText.size,
                "totalOcrLines" to lines.size,
                "coveredOcrLines" to covered.size,
                "totalOcrCharacters" to totalCharacters,
                "coveredOcrCharacters" to coveredCharacters,
                "lineCoverageRatio" to if (lines.isEmpty()) null else covered.size.toDouble() / lines.size,
                "characterCoverageRatio" to if (totalCharacters == 0) null else coveredCharacters.toDouble() / totalCharacters,
            )
        }
        val boundsCount = rows.count { row ->
            val bounds = (row["bounds"] as? List<*>)?.mapNotNull { (it as? Number)?.toInt() }
            bounds != null && bounds.size == 4 && bounds[2] > bounds[0] && bounds[3] > bounds[1]
        }
        val structure = if (mode == "controls") mapOf("nativeStructure" to nativeStructure(rows)) else emptyMap()
        val autoConflict = if (mode == "auto") {
            val byId = rows.associateBy { it["id"] }
            val pairs = rows.filter { it["source"] == "ocr" && it["nativeElementId"] != null }.mapNotNull { visual ->
                val native = byId[visual["nativeElementId"]] ?: return@mapNotNull null
                val visibleLabel = Regex("^([abcd])").find(PhoneVision.text(visual["text"]))?.groupValues?.get(1)
                    ?: return@mapNotNull null
                val accessibilityText = PhoneVision.text(native["accessibilityText"])
                val accessibilityLabel = Regex("选项([abcd])").find(accessibilityText)?.groupValues?.get(1)
                    ?: Regex("^([abcd])").find(accessibilityText)?.groupValues?.get(1)
                    ?: return@mapNotNull null
                mapOf("visibleLabel" to visibleLabel.uppercase(),
                    "accessibilityLabel" to accessibilityLabel.uppercase(),
                    "labelsDiffer" to (visibleLabel != accessibilityLabel))
            }
            mapOf("textConflictElements" to rows.count { it["textConflict"] == true },
                "textConflictOcrLines" to rows.count { it["source"] == "ocr" && it["textConflict"] == true },
                "optionLabelPairs" to pairs)
        } else emptyMap()
        return mapOf(
            "label" to label,
            "mode" to mode,
            "elapsedMs" to elapsed,
            "totalElements" to observation["total"],
            "returnedElements" to rows.size,
            "complete" to observation["complete"],
            "ocrLines" to rows.count { it["source"] == "ocr" },
            "accessibilityElements" to rows.count { it["source"] == "accessibility" },
            "nonemptyTextElements" to rows.count { it["text"]?.toString()?.isNotBlank() == true },
            "elementsWithBounds" to boundsCount,
            "recognition" to recognition.filterKeys {
                it in setOf("mode", "source", "captureMs", "ocrMs", "elapsedMs", "recognitionCacheHit", "ocrAvailable")
            },
            "performance" to after.mapValues { (key, value) -> value - (before[key] ?: 0L) },
        ) + structure + autoConflict
    }

    @Test fun observePreparedStudyPageWithControlsVisualAndAuto() {
        val readings = listOf(
            read("controls", "controls"),
            read("visual", "visual"),
            read("warmVisual", "visual"),
            read("auto", "auto"),
        )
        val aggregate = mapOf(
            "package" to studyPackage,
            "readings" to readings,
            "nativeOcrCoverage" to nativeOcrCoverage.toMap(),
            "modelRequests" to 0,
            "actionsDispatched" to 0,
        )
        instrumentation.sendStatus(0, Bundle().apply {
            putString("phoneStudy_reading", JSONObject(aggregate).toString())
        })
        if (nativeHasWebView) {
            assertTrue("Auto mode must include OCR lines for the observed WebView page",
                (readings.last()["ocrLines"] as Number).toInt() > 0)
        }
    }

    @Test fun queriedAutoObservationKeepsVisibleTextAndRawHybridStateCannotPrepareAnotherAction() {
        val aggregate = linkedMapOf<String, Any?>()
        val check = {
            kotlin.check(SkivuAccessibilityService.connected === service) { "QA accessibility service changed during observation" }
        }
        try {
            assertStudyForeground()
            val before = service.visionMetrics.snapshot()
            val started = SystemClock.uptimeMillis()
            val queried = service.vision.observe(allowed, mapOf("query" to "A", "pageSize" to 1000), "auto", owner, check)
            aggregate["queryElapsedMs"] = SystemClock.uptimeMillis() - started
            assertStudyForeground()
            val queryRows = (queried["elements"] as List<*>).map { PhoneFlow.map(it, "row") }
            val after = service.visionMetrics.snapshot()
            val queryHasOcr = queryRows.any { it["source"] == "ocr" }
            val publicAliasRemoved = queryRows.none {
                it["source"] == "accessibility" && PhoneVision.text(it["text"]).contains("选项a")
            }
            aggregate["queryReturnedElements"] = queryRows.size
            aggregate["queryOcrLines"] = queryRows.count { it["source"] == "ocr" }
            aggregate["queryHasOcr"] = queryHasOcr
            aggregate["publicAliasRemoved"] = publicAliasRemoved
            aggregate["queryPerformance"] = after.mapValues { (key, value) -> value - (before[key] ?: 0L) }
            assertTrue("A filtered WebView observation must still include the OCR result", queryHasOcr)
            assertTrue("Public visible text must omit the conflicting native option alias", publicAliasRemoved)

            val stateStep = mapOf<String, Any?>(
                "action" to "tap",
                "selector" to mapOf("text" to "A", "source" to "ocr"),
                "expect" to mapOf("kind" to "checked", "selector" to mapOf("source" to "accessibility", "textContains" to "选项"),
                    "checked" to true),
            )
            val raw = service.vision.snapshot(allowed, studyPackage, "auto", owner, check, stateStep)
            assertStudyForeground()
            val projected = PhoneVision.visibleProjection(raw.rows)
            val aliased = projected.filter {
                it["source"] == "accessibility" && PhoneVision.text(it["accessibilityText"]).startsWith("选项")
            }
            aggregate["rawElements"] = raw.rows.size
            aggregate["rawOcrLines"] = raw.rows.count { it["source"] == "ocr" }
            aggregate["projectedOptionAliases"] = aliased.size
            assertTrue("The prepared study page must expose a mapped native option alias", aliased.isNotEmpty())
            val alias = aliased.first()["accessibilityText"] as String
            val matching = PhoneFlow.targets(raw, mapOf("text" to alias, "source" to "accessibility"))
            val rawIdentityPreserved = matching.size == 1 && matching.single()["id"] == aliased.first()["id"]
            aggregate["rawIdentityPreserved"] = rawIdentityPreserved
            assertTrue("State observations must retain the original native identity", rawIdentityPreserved)
            val nextStep = mapOf<String, Any?>(
                "action" to "tap",
                "selector" to mapOf("text" to alias),
                "expect" to mapOf("kind" to "exists", "selector" to mapOf("source" to "ocr", "text" to "qa_missing_expected_heading")),
            )
            val reused = service.vision.reuseSnapshot(raw, studyPackage, "auto", owner, nextStep, allowed, check)
            aggregate["rawHybridReuseRejected"] = reused == null
            aggregate["actionsDispatched"] = 0
            aggregate["modelRequests"] = 0
            assertTrue("Raw hybrid state must not become the next action's visible semantic snapshot", reused == null)
        } finally {
            instrumentation.sendStatus(0, Bundle().apply {
                putString("phoneStudy_query", JSONObject(aggregate).toString())
            })
        }
    }
}
