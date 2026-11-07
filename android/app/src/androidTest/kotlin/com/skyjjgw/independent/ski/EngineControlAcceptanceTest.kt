package com.skyjjgw.independent.ski

import android.app.Activity
import android.content.Context
import android.os.Build
import androidx.test.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test
import org.skivu.engine.adb.EmbeddedAdbEngine

/** Actual host API only; no UI input or permission bootstrapping. */
class EngineControlAcceptanceTest {
    private class HostContext(context: Context) : Activity() {
        init { attachBaseContext(context) }
    }
    private class ApiMessenger : BinaryMessenger {
        private val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) { callback?.reply(null) }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }
        fun call(method: String, params: Map<String, Any?> = emptyMap()): CompletableFuture<Any?> {
            val future = CompletableFuture<Any?>()
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                val bytes = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, params))
                bytes.flip()
                handlers.getValue("skivu/device_engine").onMessage(bytes) { response ->
                    try {
                        check(response != null); response.flip()
                        future.complete(StandardMethodCodec.INSTANCE.decodeEnvelope(response))
                    } catch (error: Throwable) { future.completeExceptionally(error) }
                }
            }
            return future
        }
    }

    @Test fun authorizationReadsStayResponsiveAndRevocationStopsTheOwnedJob() {
        assertEquals("emulator-5554", InstrumentationRegistry.getArguments().getString("skivuEngineAcceptance"))
        assertTrue(Build.HARDWARE in setOf("ranchu", "goldfish"))
        val target = InstrumentationRegistry.getTargetContext()
        val prefs = target.getSharedPreferences("skivu.device-engine.v1", 0)
        val original = linkedMapOf<String, Any?>(
            "enabled" to prefs.getBoolean("enabled", false),
            "system" to prefs.getBoolean("system", false),
            "control" to prefs.getBoolean("control", false),
            "shell" to prefs.getBoolean("shell", false),
            "packages" to prefs.getStringSet("packages", emptySet()).orEmpty().toList()
        )
        assertEquals("Activate through the normal App UI before acceptance", true, original["enabled"])
        assertEquals("No test grant bootstrapping", true, original["shell"])
        val activity = AtomicReference<Activity>()
        InstrumentationRegistry.getInstrumentation().runOnMainSync { activity.set(HostContext(target)) }
        val messenger = ApiMessenger()
        val host = EmbeddedDevicePlatform(activity.get())
        host.register(messenger)
        val observer = EmbeddedAdbEngine(target)
        val nonce = UUID.randomUUID().toString().replace("-", "")
        val file = "/data/local/tmp/skivu-control-$nonce"
        val d = '$'
        val command = "sleep 90 & child=${d}!; printf '%s %s\\n' \"${d}${d}\" \"${d}child\" > '$file'; wait \"${d}child\"; printf done > '$file.finished'"
        val running = messenger.call("invoke", linkedMapOf(
            "version" to 1, "owner" to "qa:control", "requestId" to "control_$nonce",
            "tool" to "shell.execute", "arguments" to mapOf("command" to command, "timeoutSeconds" to 120)
        ))
        try {
            var started = false
            for (attempt in 0 until 30) {
                if (observer.execute("test -s '$file'", 10)["exitCode"] == 0) { started = true; break }
                Thread.sleep(100)
            }
            assertTrue("Real owned job must be active", started)
            assertFalse(running.isDone)
            val status = messenger.call("status").get(2, TimeUnit.SECONDS) as Map<*, *>
            assertEquals(true, status["enabled"])
            assertEquals(true, status["shell"])
            assertEquals(2000, status["shellUid"])
            assertEquals("execution_snapshot", status["shellStatusSource"])
            assertTrue(messenger.call("apps").get(2, TimeUnit.SECONDS) is List<*>)
            assertFalse("Read-only inspection must not stop the job", running.isDone)
            val revoked = messenger.call("configure", original + ("shell" to false)).get(12, TimeUnit.SECONDS) as Map<*, *>
            assertEquals(false, revoked["shell"])
            val result = running.get(10, TimeUnit.SECONDS) as Map<*, *>
            assertEquals("Revoked execution cannot report success", "unknown", result["outcome"])
            val proof = observer.execute("read -r p c < '$file'; test ! -d /proc/${d}p && test ! -d /proc/${d}c && test ! -e '$file.finished'", 10)
            assertEquals("Owned processes must exit without reaching completion", 0, proof["exitCode"])
        } finally {
            try { messenger.call("stop").get(12, TimeUnit.SECONDS) } catch (_: Exception) {}
            try { running.get(12, TimeUnit.SECONDS) } catch (_: Exception) {}
            try { messenger.call("configure", original).get(12, TimeUnit.SECONDS) }
            finally {
                observer.execute("rm -f -- '$file' '$file.finished'", 10)
                observer.close(); host.close()
            }
        }
    }
}
