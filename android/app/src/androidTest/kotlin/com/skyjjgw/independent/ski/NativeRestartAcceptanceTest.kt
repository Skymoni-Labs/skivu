package com.skyjjgw.independent.ski

import android.app.Activity
import android.content.Context
import android.os.Build
import androidx.test.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

/** Native API acceptance only. It never opens or operates an Android UI. */
class NativeRestartAcceptanceTest {
    private class HostContext(context: Context) : Activity() {
        init { attachBaseContext(context) }
    }
    private class ApiMessenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            callback?.reply(null)
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }
        fun invoke(params: Map<String, Any?>): CompletableFuture<Map<String, Any?>> {
            val future = CompletableFuture<Map<String, Any?>>()
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                val bytes = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall("invoke", params))
                bytes.flip()
                handlers.getValue("skivu/device_engine").onMessage(bytes) { response ->
                    try {
                        check(response != null)
                        response.flip()
                        @Suppress("UNCHECKED_CAST")
                        future.complete(StandardMethodCodec.INSTANCE.decodeEnvelope(response) as Map<String, Any?>)
                    } catch (error: Throwable) { future.completeExceptionally(error) }
                }
            }
            return future
        }
    }

    @Test fun actualDispatchSurvivesAsUnknownWithoutReplay() {
        val options = InstrumentationRegistry.getArguments()
        assertEquals("emulator-5554", options.getString("skivuEngineAcceptance"))
        assertTrue(Build.HARDWARE in setOf("ranchu", "goldfish"))
        val nonce = options.getString("nonce").orEmpty()
        require(Regex("^[a-f0-9]{16}$").matches(nonce))
        val phase = options.getString("phase")
        require(phase in setOf("start", "replay", "suspend"))
        val context = AtomicReference<Activity>()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            context.set(HostContext(InstrumentationRegistry.getTargetContext()))
        }
        val messenger = ApiMessenger()
        val host = EmbeddedDevicePlatform(context.get())
        host.register(messenger)
        val base = "/data/local/tmp/skivu-restart-$nonce"
        val d = '$'
        val command = """
            skivu_count=${d}(cat '$base.count' 2>/dev/null)
            skivu_count=${d}{skivu_count:-0}
            printf '%s\n' "${d}((skivu_count + 1))" > '$base.count'
            sleep 120 &
            skivu_child=${d}!
            printf '%s %s\n' "${d}${d}" "${d}skivu_child" > '$base.pids'
            wait "${d}skivu_child"
            printf done > '$base.finished'
        """.trimIndent()
        try {
            val answer = messenger.invoke(linkedMapOf(
                "version" to 1, "owner" to "qa:restart", "requestId" to "restart_$nonce",
                "tool" to "shell.execute", "arguments" to linkedMapOf("command" to command, "timeoutSeconds" to 180)
            )).get(150, TimeUnit.SECONDS)
            if (phase == "start") {
                fail("The controller must interrupt the confirmed running request; result was ${answer["outcome"]}")
            } else if (phase == "suspend") {
                assertEquals("An expired lease cannot be reported as success", "unknown", answer["outcome"])
                assertTrue(answer["summary"].toString().contains("续约中断"))
            } else {
                assertEquals("An interrupted write must remain unknown, never re-executed", "unknown", answer["outcome"])
                assertTrue(answer["summary"].toString().contains("不会自动重放"))
            }
        } finally { host.close() }
    }
}
