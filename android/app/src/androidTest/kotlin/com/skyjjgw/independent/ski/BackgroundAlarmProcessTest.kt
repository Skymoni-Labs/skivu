package com.skyjjgw.independent.ski

import android.content.Context
import android.os.Build
import androidx.test.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Called as two separate instrumentation runs, with the QA process killed between. */
class BackgroundAlarmProcessTest {
    private fun target(): Context {
        assertEquals("emulator-5554", InstrumentationRegistry.getArguments().getString("skivuEngineAcceptance"))
        assertTrue(Build.HARDWARE in setOf("ranchu", "goldfish"))
        return InstrumentationRegistry.getTargetContext().also { assertTrue(it.packageName.endsWith(".engineqa")) }
    }
    @Test fun prepareTimerBeforeProcessExit() {
        val context = target()
        val prefs = context.getSharedPreferences("qa.native-alarm-process-fixture", 0)
        assertFalse("Prior process fixture requires inspection", prefs.contains("id"))
        val nonce = "qa-process-${UUID.randomUUID()}"
        val delay = InstrumentationRegistry.getArguments().getString("delaySeconds")?.toIntOrNull() ?: 10
        require(delay in 10..120)
        val value = BackgroundAlarms(context).use { it.execute("assistant.timer.start", mapOf("seconds" to delay, "label" to nonce, "vibrate" to false), nonce) }
        assertTrue(prefs.edit().putString("id", value["id"] as String).commit())
        assertEquals("scheduled", value["state"])
    }
    @Test fun verifyTimerAfterProcessExitAndCleanUp() {
        val context = target()
        val prefs = context.getSharedPreferences("qa.native-alarm-process-fixture", 0)
        val id = prefs.getString("id", null) ?: error("Missing own process fixture")
        try {
            val value = BackgroundAlarms(context).use { it.read(id) }
            assertEquals("fired", value["state"])
            assertTrue(value.toString(), value["ringState"] in setOf("playing", "playing_fallback"))
        } finally {
            BackgroundAlarms(context).use { it.cancel(id) }
            assertTrue(prefs.edit().remove("id").commit())
        }
    }
}
