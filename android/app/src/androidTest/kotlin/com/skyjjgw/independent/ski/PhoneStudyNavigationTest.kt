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

/** Two authorized question-navigation taps through the normal local flow entry point. */
class PhoneStudyNavigationTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = InstrumentationRegistry.getTargetContext()
    private val studyPackage = "com.chaoxing.mobile"
    private val allowed = setOf(studyPackage)
    private val owner = "qa:study-navigation"
    private val headingRegion = listOf(0.0, 0.10, 0.4, 0.20)
    private var original = mapOf<String, Any?>()
    private var originalMode: String? = null
    private lateinit var service: SkivuAccessibilityService
    private lateinit var platform: EmbeddedDevicePlatform

    private fun shell(command: String) = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        .executeShellCommand(command).use { descriptor ->
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
                assertEquals("The prepared study page must stay foreground", studyPackage, root.packageName?.toString())
            } finally {
                @Suppress("DEPRECATION") root.recycle()
            }
        }
    }

    @Before fun setup() {
        assertTrue("Navigation requires the independent QA target", context.packageName.endsWith(".phoneflowqa"))
        assertEquals("confirmed", InstrumentationRegistry.getArguments().getString("skivuPhysicalQa"))
        val prefs = context.getSharedPreferences("skivu.device-engine.v1", 0)
        original = listOf("enabled", "control", "allApplications", "packages", "recognitionMode").associateWith { prefs.all[it] }
        prefs.edit().putBoolean("enabled", true).putBoolean("control", true).putBoolean("allApplications", false)
            .putStringSet("packages", allowed).putString("recognitionMode", "auto").commit()
        originalMode = ExecutionHub.mode(context)
        ExecutionHub.setMode(context, "hidden")
        val component = "${context.packageName}/${SkivuAccessibilityService::class.java.name}"
        val enabled = android.provider.Settings.Secure.getString(context.contentResolver, "enabled_accessibility_services").orEmpty()
            .split(':').filter { it.isNotBlank() && it != "null" && it != component }
        if(InstrumentationRegistry.getArguments().getString("skivuFastCapture")!="confirmed" || PhoneScreenCaptureService.active==null) {
            shell("settings put secure enabled_accessibility_services ${if (enabled.isEmpty()) "null" else enabled.joinToString(":")}")
            repeat(40) { if (SkivuAccessibilityService.connected != null) Thread.sleep(25) }
            shell("settings put secure enabled_accessibility_services ${(enabled + component).joinToString(":")}")
            shell("settings put secure accessibility_enabled 1")
        }
        val deadline = SystemClock.uptimeMillis() + 10_000
        while (SkivuAccessibilityService.connected == null && SystemClock.uptimeMillis() < deadline) Thread.sleep(25)
        service = SkivuAccessibilityService.connected ?: error("QA accessibility service did not connect")
        assertStudyForeground()
        platform = EmbeddedDevicePlatform(context)
    }

    @After fun restore() {
        if (::platform.isInitialized) platform.close()
        val edit = context.getSharedPreferences("skivu.device-engine.v1", 0).edit()
        for ((key, value) in original) when (value) {
            null -> edit.remove(key)
            is Boolean -> edit.putBoolean(key, value)
            is String -> edit.putString(key, value)
            is Set<*> -> edit.putStringSet(key, value.filterIsInstance<String>().toSet())
        }
        edit.commit()
        originalMode?.let { ExecutionHub.setMode(context, it) }
        PhoneControlArbiter.release(owner)
    }

    private fun call(tool: String, arguments: Map<String, Any?>): Map<String, Any?> = platform.invokeLeased(mapOf(
        "version" to 1,
        "owner" to owner,
        "requestId" to "study_nav_${System.nanoTime()}",
        "tool" to tool,
        "arguments" to arguments,
    ), {
        check(SkivuAccessibilityService.connected === service) { "QA accessibility service changed during navigation" }
    })

    private fun heading(question: Int): Map<String, Any?> = mapOf("kind" to "exists", "selector" to mapOf(
        "textContains" to question.toString(), "source" to "ocr", "region" to headingRegion,
    ))

    private fun navigationStep(id: String, button: String, from: Int, to: Int): Map<String, Any?> = mapOf(
        "id" to id,
        "action" to "tap",
        "selector" to mapOf("textContains" to button),
        "guard" to heading(from),
        "expect" to heading(to),
        "stableMs" to 100,
        "timeoutMs" to 15_000,
    )

    private fun preparedCounterIsSix(): Boolean {
        val deadline=SystemClock.uptimeMillis()+3000
        var attempts=0
        var candidates=emptyList<String>()
        do {
            assertStudyForeground()
            val observed = call("ui.observe", mapOf("recognitionMode" to "visual", "pageSize" to 1000))
            assertEquals("Heading observation must succeed before navigation", "verified", observed["outcome"])
            val value = PhoneFlow.map(observed["value"], "value")
            val rows = (value["elements"] as List<*>).map { PhoneFlow.map(it, "row") }
            candidates=rows.map{PhoneVision.text(it["text"])}.filter{it.contains('/') || it.any(Char::isDigit)}
            val matched=rows.any { it["source"] == "ocr" && Regex("(?<!\\d)6/20(?!\\d)").containsMatchIn(PhoneVision.text(it["text"])) }
            attempts++
            if(matched) {
                instrumentation.sendStatus(0,Bundle().apply{putString("phoneStudy_counter",JSONObject(mapOf("matched" to true,"attempts" to attempts,"candidates" to candidates)).toString())})
                return true
            }
            Thread.sleep(75)
        }while(SystemClock.uptimeMillis()<deadline)
        instrumentation.sendStatus(0,Bundle().apply{putString("phoneStudy_counter",JSONObject(mapOf("matched" to false,"attempts" to attempts,"candidates" to candidates)).toString())})
        return false
    }

    @Test fun navigateNextQuestionAndReturnToPreparedQuestion() {
        assertTrue("Prepare question 6/20 before starting the two navigation steps", preparedCounterIsSix())
        val result = call("ui.flow", mapOf(
            "package" to studyPackage,
            "recognitionMode" to "auto",
            "steps" to listOf(navigationStep("next_to_7", "下一题", 6, 7), navigationStep("previous_to_6", "上一题", 7, 6)),
        ))
        val value = (result["value"] as? Map<*, *>).orEmpty()
        val aggregate = mapOf("outcome" to result["outcome"]) + value.filterKeys {
            it in setOf("elapsedMs", "observationCount", "performance", "completedSteps", "steps")
        }
        instrumentation.sendStatus(0, Bundle().apply {
            putString("phoneStudy_navigation", JSONObject(aggregate).toString())
        })
        assertEquals("verified", result["outcome"])
        assertEquals(2, value["completedSteps"])
        assertTrue("Navigation must finish at the original question 6/20", preparedCounterIsSix())
    }
}
