package com.skyjjgw.independent.ski

import android.os.Build
import androidx.test.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import java.io.File
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** Actual Android controls in the test APK; no model transport or real study account. */
class PhoneFlowAcceptanceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = InstrumentationRegistry.getTargetContext()
    private val testContext get() = InstrumentationRegistry.getContext()
    private val pkg get() = testContext.packageName
    private val allowed get() = setOf(pkg)
    private lateinit var platform: EmbeddedDevicePlatform
    private var original = mapOf<String, Any?>()
    private var originalMode = "hidden"
    private fun shell(command: String) = instrumentation.getUiAutomation(android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        .executeShellCommand(command).use { android.os.ParcelFileDescriptor.AutoCloseInputStream(it).use { stream -> stream.readBytes() } }
    private fun <T> ui(block: () -> T): T {
        val task = FutureTask(block); android.os.Handler(android.os.Looper.getMainLooper()).post(task)
        return task.get(10, TimeUnit.SECONDS)
    }
    private fun service(): SkivuAccessibilityService {
        repeat(200) { SkivuAccessibilityService.connected?.let { return it }; Thread.sleep(50) }
        error("QA accessibility service is not connected; setting=" + android.provider.Settings.Secure.getString(context.contentResolver,"enabled_accessibility_services"))
    }
    @Before fun setup() {
        assertTrue(context.packageName.endsWith(".phoneflowqa"))
        assertTrue(Build.HARDWARE in setOf("ranchu", "goldfish"))
        val prefs = context.getSharedPreferences("skivu.device-engine.v1", 0)
        original = listOf("enabled", "control", "allApplications", "packages").associateWith { prefs.all[it] }
        prefs.edit().putBoolean("enabled", true).putBoolean("control", true).putBoolean("allApplications", false).putStringSet("packages", allowed).commit()
        originalMode = ExecutionHub.mode(context); ExecutionHub.setMode(context, "hidden")
        platform = EmbeddedDevicePlatform(context)
        // Instrumentation recreates its target process. Rebind only this QA service
        // after connecting UiAutomation without suppressing accessibility services.
        val component = "${context.packageName}/${SkivuAccessibilityService::class.java.name}"
        val enabled = android.provider.Settings.Secure.getString(context.contentResolver, "enabled_accessibility_services").orEmpty()
            .split(':').filter { it.isNotBlank() && it != "null" && it != component }
        shell("settings put secure enabled_accessibility_services ${if(enabled.isEmpty()) "null" else enabled.joinToString(":")}")
        repeat(40) { if (SkivuAccessibilityService.connected != null) Thread.sleep(25) }
        shell("settings put secure enabled_accessibility_services ${(enabled + component).joinToString(":")}")
        shell("settings put secure accessibility_enabled 1")
        assertEquals((enabled + component).joinToString(":"),android.provider.Settings.Secure.getString(context.contentResolver,"enabled_accessibility_services"))
        shell("am start -W -n $pkg/${PhoneFlowFixtureActivity::class.java.name} -f 0x14000000")
        service(); Thread.sleep(150)
    }
    @After fun restore() {
        platform.close()
        val edit = context.getSharedPreferences("skivu.device-engine.v1", 0).edit()
        for ((key, value) in original) when (value) {
            null -> edit.remove(key)
            is Boolean -> edit.putBoolean(key, value)
            is Set<*> -> edit.putStringSet(key, value.filterIsInstance<String>().toSet())
        }
        edit.commit(); ExecutionHub.setMode(context, originalMode)
        PhoneControlArbiter.release("qa:phone-flow")
    }
    private fun call(tool: String, args: Map<String, Any?>, id: String): Map<String, Any?> = platform.invokeLeased(mapOf(
        "version" to 1, "owner" to "qa:phone-flow", "requestId" to id, "tool" to tool, "arguments" to args), {})
    private fun condition(kind: String, text: String, value: Any? = null): Map<String, Any?> =
        mapOf("kind" to kind, "selector" to mapOf("text" to text)) + if (value == null) emptyMap() else mapOf(kind to value)
    private fun tap(id: String, text: String, expect: Map<String, Any?>, guard: Map<String, Any?>? = null) =
        mapOf<String, Any?>("id" to id, "action" to "tap", "selector" to mapOf("text" to text), "expect" to expect, "timeoutMs" to 5000, "stableMs" to 0) +
            if (guard == null) emptyMap() else mapOf("guard" to guard)
    private fun plan(steps: List<Map<String, Any?>>) = mapOf("package" to pkg, "steps" to steps)
    private fun checked(text: String): Boolean = ui { service().flowSnapshot(allowed, pkg).rows.single { it["text"] == text }["checked"] == true }
    private fun report(name:String,value:Map<String,Any?>) {
        instrumentation.sendStatus(0,android.os.Bundle().apply{putString("phoneFlow_$name",org.json.JSONObject(value).toString())})
    }

    @Test fun twentyPagesSixtyActualActionsWithRapidContentChanges() {
        val steps = (1..20).flatMap { q ->
            val guard = condition("exists", "Question $q")
            listOf(tap("q${q}a", "Option A", condition("checked", "Option A", true), guard),
                tap("q${q}b", "Option B", condition("checked", "Option B", true), guard),
                tap("q${q}next", "Next", condition("exists", if (q == 20) "Completed 20 questions" else "Question ${q + 1}"), guard))
        }
        val result = call("ui.flow", plan(steps), "pages_${System.nanoTime()}")
        assertEquals(result.toString(), "verified", result["outcome"])
        val value = PhoneFlow.map(result["value"], "value")
        assertEquals(60, value["completedSteps"])
        assertEquals(0, value["modelRequestsDuringExecution"])
        assertEquals(false, value["hasUnverifiedActions"])
        report("twentyPages",value.filterKeys{it in setOf("completedSteps","totalSteps","elapsedMs","observationCount","modelRequestsDuringExecution","hasUnverifiedActions")})
        File(context.filesDir, "qa-phone-flow-20-pages.json").writeText(org.json.JSONObject(result).toString())
    }

    @Test fun unknownNativeResultSurvivesBackendRecreationWithoutReclicking() {
        val id = "resume_${System.nanoTime()}"
        val first = tap("a", "Option A", condition("exists", "Later confirmation")) + mapOf("timeoutMs" to 150)
        val result = call("ui.flow", plan(listOf(first, tap("b", "Option B", condition("checked", "Option B", true)))), id)
        assertEquals("unknown", result["outcome"]); assertTrue(checked("Option A"))
        val read = call("ui.flow.read", mapOf("originalRequestId" to id), "read_${System.nanoTime()}")
        assertEquals(true, PhoneFlow.map(read["value"], "value")["hasUnverifiedActions"])
        platform.close(); platform = EmbeddedDevicePlatform(context)
        shell("am start -W -n $pkg/${PhoneFlowFixtureActivity::class.java.name} --ez confirm true -f 0x30000000")
        val resumed = call("ui.flow.resume", mapOf("originalRequestId" to id), "continued_${System.nanoTime()}")
        assertEquals(resumed.toString(), "verified", resumed["outcome"])
        assertTrue("Option A must not be toggled off by replay", checked("Option A")); assertTrue(checked("Option B"))
        report("resume",mapOf("verified" to true,"originalSelectionPreserved" to true,"backendRecreated" to true))
        File(context.filesDir, "qa-phone-flow-resume.json").writeText(org.json.JSONObject(resumed).toString())
    }

    @Test fun stopInterruptsAnUnlimitedWaitAndRetainsTheUncertainStep() {
        val id = "cancel_${System.nanoTime()}"
        val flow = plan(listOf(tap("a", "Option A", condition("exists", "Never shown")) + mapOf("timeoutMs" to 0)))
        val task = FutureTask { call("ui.flow", flow, id) }
        Thread(task, "phone-flow-acceptance").start()
        var selected = false
        repeat(100) { if (!selected) { Thread.sleep(25); selected = checked("Option A") } }
        assertTrue(selected)
        val started = android.os.SystemClock.uptimeMillis()
        platform.cancelInvocation("qa:phone-flow", id)
        val result = task.get(5, TimeUnit.SECONDS)
        assertEquals("cancelled", result["outcome"])
        assertEquals(true, PhoneFlow.map(result["value"], "value")["hasUnverifiedActions"])
        report("stop",mapOf("stopMs" to android.os.SystemClock.uptimeMillis()-started,"cancelled" to true,"hasUnverifiedActions" to true))
        File(context.filesDir, "qa-phone-flow-stop.json").writeText(org.json.JSONObject(mapOf("stopMs" to android.os.SystemClock.uptimeMillis() - started, "result" to result)).toString())
    }

    @Test fun nativeInputAndGuardedRegionChangeUseSemanticTargets() {
        val input = mapOf<String, Any?>("id" to "input", "action" to "input", "selector" to mapOf("viewId" to "android:id/edit"), "text" to "Local flow input",
            "expect" to mapOf("kind" to "text", "selector" to mapOf("viewId" to "android:id/edit"), "text" to "Local flow input"), "timeoutMs" to 3000, "stableMs" to 0)
        val next = tap("next", "Next", mapOf("kind" to "changed", "selector" to mapOf("description" to "question-card")), condition("exists", "Question 1"))
        val result = call("ui.flow", plan(listOf(input, next)), "input_${System.nanoTime()}")
        assertEquals(result.toString(), "verified", result["outcome"])
        assertTrue(ui { service().flowSnapshot(allowed, pkg).rows.any { it["text"] == "Question 2" } })
        report("input",mapOf("inputReadBack" to true,"scopedPageChangeVerified" to true))
    }
}
