package com.skyjjgw.independent.ski

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.test.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Own-label fixtures only, isolated emulator QA package. */
class BackgroundAlarmAcceptanceTest {
    private class Host(context: Context) : Activity() {
        init { attachBaseContext(context) }
        var launches = 0
        override fun startActivity(intent: Intent) { launches++; error("Unexpected foreground launch") }
        override fun startActivity(intent: Intent, options: Bundle?) { launches++; error("Unexpected foreground launch") }
    }
    private class Api : BinaryMessenger {
        private val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) { callback?.reply(null) }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }
        fun call(method: String, args: Map<String, Any?>): Any? {
            val future = CompletableFuture<Any?>()
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                val buffer = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, args)); buffer.flip()
                handlers.getValue("skivu/device_engine").onMessage(buffer) { response ->
                    try { check(response != null); response.flip(); future.complete(StandardMethodCodec.INSTANCE.decodeEnvelope(response)) }
                    catch (error: Throwable) { future.completeExceptionally(error) }
                }
            }
            return future.get(15, TimeUnit.SECONDS)
        }
        fun invoke(tool: String, args: Map<String, Any?>, id: String, policy: String = "background"): Map<*, *> = call("invoke", mapOf(
            "version" to 1, "owner" to "assistant:qa", "requestId" to id, "tool" to tool, "arguments" to args, "executionPolicy" to policy)) as Map<*, *>
    }
    private fun target(): Context {
        assertEquals("emulator-5554", InstrumentationRegistry.getArguments().getString("skivuEngineAcceptance"))
        assertTrue(Build.HARDWARE in setOf("ranchu", "goldfish"))
        return InstrumentationRegistry.getTargetContext().also { assertTrue(it.packageName.endsWith(".engineqa")) }
    }
    @Test fun exactDatesIsoWeekdaysAndDstRemainFuture() {
        target()
        fun stamp(text: String, zone: String) = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.ROOT).apply { timeZone = TimeZone.getTimeZone(zone) }.parse(text)!!.time
        val zone = TimeZone.getTimeZone("Asia/Shanghai")
        val monday = JSONObject().put("hour", 7).put("minute", 30).put("days", JSONArray(listOf(1)))
        assertEquals(stamp("2026-11-09 07:30", "Asia/Shanghai"), BackgroundAlarms.nextWallTime(monday, stamp("2026-11-08 23:00", "Asia/Shanghai"), zone))
        assertEquals(stamp("2026-11-16 07:30", "Asia/Shanghai"), BackgroundAlarms.nextWallTime(monday, stamp("2026-11-09 07:31", "Asia/Shanghai"), zone))
        val dst = JSONObject().put("hour", 2).put("minute", 30).put("days", JSONArray())
        val before = stamp("2026-03-08 01:59", "America/New_York")
        assertTrue(BackgroundAlarms.nextWallTime(dst, before, TimeZone.getTimeZone("America/New_York")) > before)
        val explicit = JSONObject().put("hour", 7).put("minute", 30).put("date", "2026-11-09")
        try { BackgroundAlarms.nextWallTime(explicit, stamp("2026-11-10 01:00", "Asia/Shanghai"), zone); fail("Past date accepted") } catch (_: IllegalArgumentException) {}
    }
    @Test fun nativePolicyAndDurableResourceIdempotencyNeverLaunchActivities() {
        val context = target()
        lateinit var host: Host
        InstrumentationRegistry.getInstrumentation().runOnMainSync { host = Host(context) }
        val api = Api(); val platform = EmbeddedDevicePlatform(host)
        val prefs = context.getSharedPreferences("skivu.device-engine.v1", 0)
        val before = listOf("enabled", "system", "control", "shell").associateWith { prefs.getBoolean(it, false) }
        prefs.edit().putBoolean("enabled", true).putBoolean("system", true).putBoolean("control", false).putBoolean("shell", false).commit()
        platform.register(api)
        val nonce = "qa-bg-${UUID.randomUUID()}"
        val resources = mutableSetOf<String>()
        try {
            assertTrue(BackgroundAlarms(context).use { it.ready() })
            for ((index, tool) in listOf("apps.launch", "clock.alarm.create", "clock.timer.start", "clock.alarms.show", "settings.open", "ui.tap", "shell.execute").withIndex()) {
                val answer = api.invoke(tool, emptyMap(), "$nonce-deny-$index", "interactive")
                assertEquals("failed", answer["outcome"])
                assertTrue(answer["summary"].toString().contains("严格后台"))
            }
            assertEquals(0, host.launches)
            val next = Calendar.getInstance().apply { add(Calendar.HOUR_OF_DAY, 2) }
            val args = mapOf("hour" to next.get(Calendar.HOUR_OF_DAY), "minute" to next.get(Calendar.MINUTE), "label" to nonce, "vibrate" to false)
            val first = api.invoke("assistant.alarm.create", args, "$nonce-create")
            assertEquals("verified", first["outcome"])
            val item = first["value"] as Map<*, *>
            val id = item["id"] as String; resources.add(id)
            assertEquals("scheduled", item["state"])
            val replay = api.invoke("assistant.alarm.create", args, "$nonce-create")["value"] as Map<*, *>
            assertEquals(id, replay["id"]); assertEquals((item["revision"] as Number).toLong(), (replay["revision"] as Number).toLong())
            val duplicate = api.invoke("assistant.alarm.create", args, "$nonce-new-id")["value"] as Map<*, *>
            assertEquals(id, duplicate["id"]); assertEquals(true, duplicate["reusedResource"])
            BackgroundAlarms(context).use { assertEquals(1, it.list().count { row -> row["label"] == nonce && row["enabled"] == true }) }
            val updated = api.invoke("assistant.alarm.update", mapOf("id" to id, "minute" to ((next.get(Calendar.MINUTE) + 1) % 60)), "$nonce-update")
            assertEquals("verified", updated["outcome"])
            val changed = updated["value"] as Map<*, *>
            assertEquals(id, changed["id"]); assertTrue((changed["revision"] as Number).toLong() > (item["revision"] as Number).toLong())
            val cancel = api.invoke("assistant.alarm.cancel", mapOf("id" to id), "$nonce-cancel")
            assertEquals("verified", cancel["outcome"])
            assertEquals(false, (cancel["value"] as Map<*, *>)["enabled"])
            assertEquals(0, host.launches)
        } finally {
            BackgroundAlarms(context).use { alarms -> resources.forEach { alarms.cancel(it) } }
            prefs.edit().apply { for ((key, value) in before) putBoolean(key, value) }.commit()
            platform.close()
        }
    }
    @Test fun realTimerFiresNativelyAndCanBeStoppedWithoutOpeningUi() {
        val context = target()
        val nonce = "qa-ring-${UUID.randomUUID()}"
        var id: String? = null
        try {
            val item = BackgroundAlarms(context).use { alarms ->
                assertTrue(alarms.ready())
                alarms.execute("assistant.timer.start", mapOf("seconds" to 3, "label" to nonce, "vibrate" to false), nonce)
            }
            id = item["id"] as String
            val end = System.currentTimeMillis() + 15000
            var state: Map<String, Any?> = item
            while (System.currentTimeMillis() < end) {
                Thread.sleep(200)
                state = BackgroundAlarms(context).use { it.read(id) }
                if (state["ringState"] in setOf("playing", "playing_fallback")) break
            }
            assertEquals("fired", state["state"])
            assertTrue("Playback was not started: $state", state["ringState"] in setOf("playing", "playing_fallback"))
            BackgroundAlarms(context).use { alarms ->
                assertNull(alarms.claimFire(id, (item["revision"] as Number).toLong(), (item["nextAt"] as Number).toLong()))
                alarms.cancel(id)
            }
            Thread.sleep(300)
            assertEquals("stopped", BackgroundAlarms(context).use { it.read(id)["ringState"] })
        } finally { if (id != null) BackgroundAlarms(context).use { it.cancel(id) } }
    }
    @Test fun durableOutboxCompletesAnInterruptedScheduleWithoutAnotherUserRequest() {
        val context = target()
        val nonce = "qa-outbox-${UUID.randomUUID()}"
        var id: String? = null
        try {
            try {
                BackgroundAlarms(context, beforeSchedule = { error("simulated interruption after durable reservation") }).use {
                    it.execute("assistant.timer.start", mapOf("seconds" to 600, "label" to nonce, "vibrate" to false), nonce)
                }
                fail("Fixture interruption not reached")
            } catch (_: IllegalStateException) {}
            id = BackgroundAlarms(context).use { alarms -> alarms.list().single { it["label"] == nonce }["id"] as String }
            val deadline = System.currentTimeMillis() + 20000
            var state = ""
            while (System.currentTimeMillis() < deadline) {
                state = BackgroundAlarms(context).use { it.read(id)["state"] as String }
                if (state == "scheduled") break
                Thread.sleep(200)
            }
            assertEquals("scheduled", state)
        } finally { if (id != null) BackgroundAlarms(context).use { it.cancel(id) } }
    }
}
