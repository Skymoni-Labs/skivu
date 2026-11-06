package org.skivu.engine.adb

import android.content.Context
import android.os.Build
import org.lsposed.hiddenapibypass.HiddenApiBypass
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** On-device authenticated ADB transport; no manager package or exported API. */
class EmbeddedAdbEngine(context: Context) {
    private val prefs = context.getSharedPreferences("skivu.embedded-adb.v1", 0)
    private val keyStore = PreferenceAdbKeyStore(prefs)
    private val timers = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var active: AdbClient? = null
    @Volatile private var pairing: AdbPairingClient? = null
    private val cancellationEpoch = java.util.concurrent.atomic.AtomicLong()
    @Volatile private var verifiedUid: Int? = null
    private val host = "127.0.0.1"

    private fun supported() {
        require(Build.VERSION.SDK_INT >= 30) { "内嵌无线配对需要 Android 11 或更新系统。" }
        // Only the Conscrypt TLS exporter used by Android's pairing protocol.
        HiddenApiBypass.addHiddenApiExemptions("Lcom/android/org/conscrypt/")
    }
    private fun validPort(port: Int) { require(port in 1024..65535) { "端口无效。" } }

    fun pair(port: Int, code: String): Map<String, Any?> {
        val epoch = cancellationEpoch.get()
        supported()
        validPort(port)
        require(Regex("^[0-9]{6}$").matches(code)) { "请输入系统显示的六位配对码。" }
        require(active == null && pairing == null) { "已有设备连接任务，请先停止。" }
        val key = AdbKey(keyStore, "Skivu@android", pairingHandshake = true)
        AdbPairingClient(host, port, code, key).use { client ->
            pairing = client
            try {
                check(epoch == cancellationEpoch.get()) { "配对已取消。" }
                require(client.start()) { "系统没有完成配对。" }
                val pin = client.verifiedPeerCertificatePin ?: error("没有取得经配对验证的设备证书。")
                check(epoch == cancellationEpoch.get()) { "配对已取消。" }
                check(prefs.edit().putString("peerPin", pin).commit())
                verifiedUid = null
                return mapOf("paired" to true, "connected" to false,
                    "summary" to "配对已完成，请使用无线调试连接端口连接。")
            } finally { pairing = null }
        }
    }

    private fun client(port: Int, legacy: Boolean): AdbClient {
        supported()
        validPort(port)
        val pin = prefs.getString("peerPin", null)
        require(legacy || pin != null) { "请先完成系统无线配对。" }
        return AdbClient(host, port, AdbKey(keyStore, "Skivu@android", expectedServerPin = pin), requireTls = !legacy)
    }

    fun connect(port: Int, legacy: Boolean = false, allowRoot: Boolean = false): Map<String, Any?> {
        val epoch = cancellationEpoch.get()
        client(port, legacy).use { connection ->
            active = connection
            try {
                connection.connect()
                val probe = connection.executeScript("/system/bin/id -u", 5000)
                val uid = probe.stdout.trim().toIntOrNull()
                require(probe.exitCode == 0 && (uid == 2000 || allowRoot && uid == 0)) {
                    "执行进程不是已授权的 shell/root 身份。"
                }
                check(epoch == cancellationEpoch.get()) { "连接已取消。" }
                check(prefs.edit().putInt("port", port).putBoolean("legacy", legacy)
                    .putBoolean("allowRoot", allowRoot).commit())
                verifiedUid = uid
                return mapOf("paired" to (prefs.getString("peerPin", null) != null),
                    "connected" to true, "uid" to uid, "mode" to if (uid == 0) "root" else "adb",
                    "summary" to "已通过真实执行回执验证设备身份。")
            } finally { active = null }
        }
    }

    fun probe(): Map<String, Any?> {
        val port = prefs.getInt("port", -1)
        if (port < 0 || Build.VERSION.SDK_INT < 30) return mapOf("connected" to false, "uid" to null)
        return try {
            connect(port, prefs.getBoolean("legacy", false), prefs.getBoolean("allowRoot", false))
        } catch (_: Exception) {
            verifiedUid = null
            mapOf("connected" to false, "uid" to null,
                "paired" to (prefs.getString("peerPin", null) != null))
        }
    }

    fun execute(command: String, timeoutSeconds: Int): Map<String, Any?> {
        val epoch = cancellationEpoch.get()
        require(timeoutSeconds in 1..600 && command.toByteArray().size <= 32768)
        val port = prefs.getInt("port", -1)
        val legacy = prefs.getBoolean("legacy", false)
        // Verify identity on a separate completed stream before sending user code.
        val state = connect(port, legacy, prefs.getBoolean("allowRoot", false))
        check(state["connected"] == true && epoch == cancellationEpoch.get())
        client(port, legacy).use { connection ->
            active = connection
            val timedOut = java.util.concurrent.atomic.AtomicBoolean(false)
            val timeout = timers.schedule({ timedOut.set(true); connection.close() }, timeoutSeconds.toLong(), TimeUnit.SECONDS)
            try {
                connection.connect()
                check(epoch == cancellationEpoch.get())
                val result = connection.executeScript(command, timeoutSeconds * 1000)
                return mapOf("uid" to verifiedUid, "exitCode" to result.exitCode,
                    "stdout" to result.stdout, "stderr" to result.stderr, "truncated" to result.truncated)
            } catch (e: Exception) {
                if (timedOut.get()) throw IllegalStateException("设备代码执行超时，结果需要核对。", e)
                if (epoch != cancellationEpoch.get()) throw IllegalStateException("已请求停止设备代码，已执行的操作需要核对。", e)
                throw e
            } finally {
                timeout.cancel(false)
                active = null
            }
        }
    }

    fun stop() {
        cancellationEpoch.incrementAndGet()
        active?.close()
        pairing?.cancel()
        verifiedUid = null
    }
    fun disconnect() { stop(); check(prefs.edit().remove("port").commit()) }
    fun close() { stop(); timers.shutdownNow() }
}
