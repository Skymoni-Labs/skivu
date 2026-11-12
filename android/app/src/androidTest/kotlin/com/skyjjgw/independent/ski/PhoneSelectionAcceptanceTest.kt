package com.skyjjgw.independent.ski

import android.app.UiAutomation
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.provider.Settings
import androidx.test.InstrumentationRegistry
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Real controls, screenshot OCR and same-frame selection evidence through the public flow path. */
class PhoneSelectionAcceptanceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = InstrumentationRegistry.getTargetContext()
    private val pkg get() = InstrumentationRegistry.getContext().packageName
    private val owner = "qa:phone-selection"
    private lateinit var platform: EmbeddedDevicePlatform
    private var originalPrefs = emptyMap<String, Any?>()
    private var originalMode = "hidden"
    private var originalServices: String? = null
    private var originalEnabled: String? = null
    private var capturedSettings = false
    private var setupStartedAt = 0L

    private fun setupStatus(stage: String, details: Map<String, Any?> = emptyMap()) {
        instrumentation.sendStatus(0, Bundle().apply {
            putString("phoneSelection_setup", JSONObject(mapOf<String, Any?>(
                "stage" to stage,
                "elapsedMs" to SystemClock.uptimeMillis() - setupStartedAt,
                "pid" to android.os.Process.myPid(),
                "fixturePackage" to pkg,
                "contextPackage" to context.packageName,
                "fixtureReceiver" to PhoneSelectionFixtureReceiver::class.java.name,
                "serviceConnected" to (SkivuAccessibilityService.connected != null)
            ) + details).toString())
        })
    }

    private fun shell(command: String): String = instrumentation
        .getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        .executeShellCommand(command).use { descriptor ->
            ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { String(it.readBytes()) }
        }

    private fun secure(key: String, value: String?) {
        require(key in setOf("enabled_accessibility_services", "accessibility_enabled"))
        if (value == null) shell("settings delete secure $key")
        else {
            // UiAutomation tokenizes the command directly; shell quotes become data.
            require(value.isNotEmpty() && value.all {
                it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it in "_./:\$-"
            }) { "Unexpected secure setting characters for $key" }
            shell("settings put secure $key $value")
        }
    }

    private fun secureEvidence(): Map<String, Any?> = mapOf(
        "actualServices" to shell("settings get secure enabled_accessibility_services").trim(),
        "actualEnabled" to shell("settings get secure accessibility_enabled").trim()
    )

    private fun fixture(operation: String = "read"): JSONObject {
        val result = CompletableFuture<String>()
        val intent = Intent().setComponent(ComponentName(pkg, PhoneSelectionFixtureReceiver::class.java.name))
            .putExtra("op", operation)
        context.sendOrderedBroadcast(intent, null, object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) { result.complete(resultData ?: "{}") }
        }, Handler(Looper.getMainLooper()), 0, null, null)
        return JSONObject(result.get(10, TimeUnit.SECONDS))
    }

    @Before fun setup() {
        setupStartedAt = SystemClock.uptimeMillis()
        setupStatus("started")
        assertTrue(context.packageName.endsWith(".phoneflowqa"))
        assertTrue(InstrumentationRegistry.getArguments().getString("skivuPhysicalQa") == "confirmed" ||
            Build.HARDWARE in setOf("ranchu", "goldfish"))
        assertNull("Ordinary capture tests require no active projection session", PhoneScreenCaptureService.active)
        originalServices = Settings.Secure.getString(context.contentResolver, "enabled_accessibility_services")
        originalEnabled = Settings.Secure.getString(context.contentResolver, "accessibility_enabled")
        originalMode = ExecutionHub.mode(context)
        val preferences = context.getSharedPreferences("skivu.device-engine.v1", 0)
        originalPrefs = listOf("enabled", "control", "allApplications", "packages", "recognitionMode")
            .associateWith { preferences.all[it] }
        capturedSettings = true
        setupStatus("state_captured")
        assertTrue(preferences.edit().putBoolean("enabled", true).putBoolean("control", true)
            .putBoolean("allApplications", false).putStringSet("packages", setOf(pkg))
            .putString("recognitionMode", "auto").commit())
        ExecutionHub.setMode(context, "hidden")
        platform = EmbeddedDevicePlatform(context)
        setupStatus("automation_connect_started")
        instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        setupStatus("automation_connected")
        // Use the same shell launch as the established OCR acceptance setup. A direct
        // background Context.startActivity was blocked on the physical QA device.
        setupStatus("fixture_launch_started")
        val launchOutput = shell("am start -W -n $pkg/${PhoneSelectionFixtureActivity::class.java.name} -f 0x10008000 --es mode native --ez multiple false")
        setupStatus("fixture_launch_returned", mapOf(
            "shellOutput" to launchOutput,
            "topResumed" to shell("dumpsys activity activities").lineSequence()
                .filter { it.contains("topResumedActivity") || it.contains("mResumedActivity") }
                .joinToString("\n")
        ))
        assertFalse(launchOutput, launchOutput.contains("Error:"))
        val fixtureDeadline = SystemClock.uptimeMillis() + 3000
        var visible = fixture()
        while (!visible.optBoolean("alive") && SystemClock.uptimeMillis() < fixtureDeadline) {
            Thread.sleep(25)
            visible = fixture()
        }
        assertTrue(visible.toString(), visible.optBoolean("alive"))
        setupStatus("fixture_visible", mapOf("fixture" to visible))
        val component = "${context.packageName}/${SkivuAccessibilityService::class.java.name}"
        val others = originalServices.orEmpty().split(':').filter { it.isNotBlank() && it != "null" && it != component }
        secure("enabled_accessibility_services", others.joinToString(":").ifBlank { "null" })
        val disconnected = SystemClock.uptimeMillis() + 3000
        while (SkivuAccessibilityService.connected != null && SystemClock.uptimeMillis() < disconnected) Thread.sleep(25)
        setupStatus("service_disconnected", secureEvidence())
        secure("enabled_accessibility_services", (others + component).joinToString(":"))
        secure("accessibility_enabled", "1")
        setupStatus("service_enabled", secureEvidence())
        val connected = SystemClock.uptimeMillis() + 5000
        while (SkivuAccessibilityService.connected == null && SystemClock.uptimeMillis() < connected) Thread.sleep(25)
        assertNotNull(SkivuAccessibilityService.connected)
        setupStatus("complete")
    }

    @After fun restore() {
        if (::platform.isInitialized) platform.close()
        PhoneControlArbiter.release(owner)
        if (!capturedSettings) return
        val edit = context.getSharedPreferences("skivu.device-engine.v1", 0).edit()
        for ((key, value) in originalPrefs) when (value) {
            null -> edit.remove(key)
            is Boolean -> edit.putBoolean(key, value)
            is String -> edit.putString(key, value)
            is Set<*> -> edit.putStringSet(key, value.filterIsInstance<String>().toSet())
        }
        assertTrue(edit.commit())
        ExecutionHub.setMode(context, originalMode)
        secure("enabled_accessibility_services", originalServices)
        secure("accessibility_enabled", originalEnabled)
        setupStatus("restored", secureEvidence())
    }

    private fun launch(mode: String, multiple: Boolean = false) {
        PhoneControlArbiter.release(owner)
        val output = shell("am start -W -n $pkg/${PhoneSelectionFixtureActivity::class.java.name} -f 0x10008000 --es mode $mode --ez multiple $multiple")
        assertFalse(output, output.contains("Error:"))
        Thread.sleep(500)
        val state = fixture()
        assertTrue(state.toString(), state.optBoolean("alive"))
        assertEquals(state.toString(), 1, state.getInt("page"))
        assertEquals(state.toString(), 0, state.getInt("optionTaps"))
        assertFalse(state.getJSONArray("selected").getBoolean(0))
        assertFalse(state.getJSONArray("selected").getBoolean(1))
    }

    private fun selector(label: String, mode: String) = mapOf(
        (if (mode == "canvas") "textContains" else "text") to label,
        "source" to if (mode == "canvas") "ocr" else "accessibility")

    private fun exists(text: String, mode: String) = mapOf("kind" to "exists", "selector" to selector(text, mode))

    private fun selection(id: String, label: String, checked: Boolean, mode: String) = mapOf(
        "id" to id, "action" to "set_checked", "selector" to selector(label, mode),
        "checked" to checked, "timeoutMs" to 5000, "stableMs" to 100)

    private fun next(mode: String) = mapOf("id" to "next", "action" to "tap",
        "selector" to selector("下一页", mode), "guard" to exists("第1页", mode),
        "expect" to exists("第2页", mode), "timeoutMs" to 5000, "stableMs" to 100)

    private fun run(name: String, mode: String, steps: List<Map<String, Any?>>): Map<String, Any?> {
        instrumentation.runOnMainSync {
            val service = SkivuAccessibilityService.connected!!
            val root = service.rootInActiveWindow
            setupStatus("flow_start", mapOf("rootPackage" to root?.packageName?.toString(),
                "allowedPackages" to context.getSharedPreferences("skivu.device-engine.v1", 0).getStringSet("packages", emptySet()),
                "windows" to service.windows.map { window ->
                    val windowRoot = window.root
                    val data = mapOf("type" to window.type, "active" to window.isActive,
                        "focused" to window.isFocused, "package" to windowRoot?.packageName?.toString())
                    @Suppress("DEPRECATION") windowRoot?.recycle()
                    data
                }))
            @Suppress("DEPRECATION") root?.recycle()
        }
        val started = SystemClock.uptimeMillis()
        val result = platform.invokeLeased(mapOf("version" to 1, "owner" to owner,
            "requestId" to "selection_${name}_${System.nanoTime()}", "tool" to "ui.flow", "arguments" to mapOf(
                "package" to pkg, "recognitionMode" to if (mode == "canvas") "visual" else "auto", "steps" to steps)), {})
        instrumentation.sendStatus(0, Bundle().apply {
            putString("phoneSelection_$name", JSONObject(mapOf("mode" to mode,
                "wallMs" to SystemClock.uptimeMillis() - started, "fixture" to fixture(), "result" to result)).toString())
        })
        return result
    }

    private fun value(result: Map<String, Any?>) = PhoneFlow.map(result["value"], "value")
    private fun records(result: Map<String, Any?>) = (value(result)["steps"] as List<*>).map { PhoneFlow.map(it, "step") }

    private fun single(mode: String) {
        launch(mode)
        val result = run("${mode}_single", mode, listOf(selection("pick", "苹果", true, mode),
            selection("same", "苹果", true, mode), next(mode)))
        assertEquals(result.toString(), "verified", result["outcome"])
        val state = fixture()
        assertEquals(state.toString(), 1, state.getInt("optionTaps"))
        assertEquals(state.toString(), 1, state.getInt("nextTaps"))
        assertEquals(state.toString(), 2, state.getInt("page"))
        assertTrue(state.toString(), state.getJSONArray("lastSelection").getBoolean(0))
        assertFalse(state.toString(), state.getJSONArray("lastSelection").getBoolean(1))
        val steps = records(result)
        assertEquals(true, steps[0]["dispatched"])
        assertEquals(true, steps[1]["alreadySatisfied"])
        assertEquals(false, steps[1]["dispatched"])
        assertEquals(true, steps[2]["dispatched"])
        assertEquals(true, value(result)["businessVerified"])
        assertEquals(0, value(result)["modelRequestsDuringExecution"])
        if (mode == "native") assertEquals(0L,
            (PhoneFlow.map(value(result)["performance"], "performance")["captureCount"] as Number).toLong())
    }

    private fun multiple(mode: String) {
        launch(mode, multiple = true)
        val result = run("${mode}_multiple", mode, listOf(selection("a_on", "苹果", true, mode),
            selection("b_on", "香蕉", true, mode), selection("a_off", "苹果", false, mode),
            selection("b_same", "香蕉", true, mode)))
        assertEquals(result.toString(), "verified", result["outcome"])
        val state = fixture()
        assertEquals(state.toString(), 3, state.getInt("optionTaps"))
        assertEquals(state.toString(), 0, state.getInt("nextTaps"))
        assertFalse(state.toString(), state.getJSONArray("selected").getBoolean(0))
        assertTrue(state.toString(), state.getJSONArray("selected").getBoolean(1))
        assertEquals(true, records(result)[3]["alreadySatisfied"])
        assertEquals(true, value(result)["businessVerified"])
        if (mode == "native") assertEquals(0L,
            (PhoneFlow.map(value(result)["performance"], "performance")["captureCount"] as Number).toLong())
    }

    @Test fun nativeSingleSelectionIsRealAndIdempotentBeforeNavigation() { single("native") }
    @Test fun canvasLetterCircleSelectionIsRealAndIdempotentBeforeNavigation() { single("canvas") }
    @Test fun nativeMultipleSelectionReachesTheExactTargetSet() { multiple("native") }
    @Test fun canvasCheckboxSelectionReachesTheExactTargetSet() { multiple("canvas") }

    @Test fun existingQuestionTextCannotVerifyOrSkipAnOptionClick() {
        for (mode in listOf("native", "canvas")) {
            launch(mode)
            val weak = mapOf("id" to "weak", "action" to "tap", "selector" to selector("苹果", mode),
                "guard" to exists("第1页", mode), "expect" to exists("第1页", mode), "timeoutMs" to 2000)
            val result = run("${mode}_weak", mode, listOf(weak, next(mode)))
            assertEquals(result.toString(), "failed", result["outcome"])
            assertTrue(result.toString(), result["summary"].toString().contains("invalid_postcondition"))
            assertEquals(0, fixture().getInt("optionTaps"))
            assertEquals(0, fixture().getInt("nextTaps"))
            assertEquals(false, records(result)[0]["dispatched"])
            assertEquals(false, value(result)["businessVerified"])
        }
    }

    @Test fun acceptedTouchesWithoutAStateChangeStayUnknownAndNeverNavigate() {
        for (mode in listOf("native", "canvas")) {
            launch(mode)
            fixture("ignore")
            val step = selection("ignored", "苹果", true, mode) + mapOf("timeoutMs" to 2400)
            val result = run("${mode}_ignored", mode, listOf(step, next(mode)))
            assertEquals(result.toString(), "unknown", result["outcome"])
            val state = fixture()
            assertEquals(state.toString(), 1, state.getInt("optionTaps"))
            assertEquals(state.toString(), 0, state.getInt("nextTaps"))
            assertEquals(state.toString(), 1, state.getInt("page"))
            assertFalse(state.getJSONArray("selected").getBoolean(0))
            assertEquals(true, records(result)[0]["dispatched"])
            assertEquals("queued", records(result)[1]["state"])
            assertEquals(false, value(result)["businessVerified"])
            assertEquals(true, value(result)["hasUnverifiedActions"])
        }
    }
}
