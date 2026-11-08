package com.skyjjgw.independent.ski

import android.app.Activity
import android.content.Context
import android.os.Build
import androidx.test.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Only inserts private receipt fixtures; never invokes an external tool. */
class EffectReceiptAcceptanceTest {
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
        fun lookup(tool: String, args: Map<String, Any?>): Map<*, *> {
            val future = CompletableFuture<Map<*, *>>()
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                val data = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall("effect.lookup", mapOf("tool" to tool, "arguments" to args)))
                data.flip()
                handlers.getValue("skivu/device_engine").onMessage(data) { response ->
                    try {
                        check(response != null); response.flip()
                        future.complete(StandardMethodCodec.INSTANCE.decodeEnvelope(response) as Map<*, *>)
                    } catch (error: Throwable) { future.completeExceptionally(error) }
                }
            }
            return future.get(10, TimeUnit.SECONDS)
        }
    }
    @Test fun historicalEffectsAreFoundWithoutDispatchAndFailuresAreNotReplayed() {
        assertEquals("emulator-5554", InstrumentationRegistry.getArguments().getString("skivuEngineAcceptance"))
        assertTrue(Build.HARDWARE in setOf("ranchu", "goldfish"))
        val target = InstrumentationRegistry.getTargetContext()
        assertTrue(target.packageName.endsWith(".engineqa"))
        val activity = AtomicReference<Activity>()
        InstrumentationRegistry.getInstrumentation().runOnMainSync { activity.set(HostContext(target)) }
        val messenger = ApiMessenger()
        val host = EmbeddedDevicePlatform(activity.get())
        val store = DeviceReceiptStore(target)
        val nonce = UUID.randomUUID().toString()
        val id = "effect-fixture-$nonce"
        host.register(messenger)
        try {
            for (tool in listOf("clock.alarm.create", "shell.execute", "apps.launch")) {
                val args: Map<String, Any?> = when (tool) {
                    "clock.alarm.create" -> linkedMapOf("hour" to 9, "minute" to 9, "label" to nonce)
                    "shell.execute" -> linkedMapOf("command" to "fixture-only-$nonce")
                    else -> linkedMapOf("package" to "qa.fixture.$nonce")
                }
                // Legacy fingerprints use the map decoded by StandardMessageCodec.
                val decoded = java.util.HashMap<String, Any?>()
                for ((key, value) in args) decoded[key] = value
                val fingerprint = MessageDigest.getInstance("SHA-256").digest("$tool:${JSONObject(decoded)}".toByteArray())
                    .joinToString("") { "%02x".format(it) }
                assertEquals(false, messenger.lookup(tool, args)["found"])
                for (outcome in listOf("failed", "permission_required", "dispatched", "verified", "unknown")) {
                    store.write(id, JSONObject(mapOf("fingerprint" to fingerprint, "outcome" to outcome, "summary" to "fixture")))
                    val found = messenger.lookup(tool, args)
                    assertEquals(outcome in setOf("dispatched", "verified", "unknown"), found["found"])
                    if (found["found"] == true) assertEquals(outcome, found["outcome"])
                    assertEquals(outcome, store.read(id)!!.getString("outcome"))
                }
                store.remove(id)
            }
        } finally {
            store.remove(id); store.close(); host.close()
        }
    }
}
