package org.skivu.engine.adb

import android.content.Context
import android.os.Build
import org.lsposed.hiddenapibypass.HiddenApiBypass
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.Future

/** On-device authenticated ADB transport; no manager package or exported API. */
class EmbeddedAdbEngine(context: Context) {
    private val prefs = context.getSharedPreferences("skivu.embedded-adb.v1", 0)
    private val keyStore = PreferenceAdbKeyStore(prefs)
    private val timers = Executors.newSingleThreadScheduledExecutor()
    private val cancellations = Executors.newSingleThreadExecutor()
    private val executionLock = Any()
    @Volatile private var activeJob: OwnedAdbJob? = null
    @Volatile private var stopping: Future<Map<String, Any?>>? = null
    @Volatile private var active: AdbClient? = null
    @Volatile private var pairing: AdbPairingClient? = null
    private val cancellationEpoch = java.util.concurrent.atomic.AtomicLong()
    @Volatile private var verifiedUid: Int? = null
    private val host = "127.0.0.1"
    fun isPaired() = prefs.getString("peerPin", null) != null

    /** Last genuinely authenticated identity while an invocation owns the worker.
     * No extra probe may replace the active connection used by Stop.
     * Every execute still establishes and verifies its own authenticated stream.
     */
    fun executionSnapshot(): Map<String, Any?> {
        val uid = verifiedUid
        return mapOf("paired" to isPaired(), "connected" to (uid != null), "uid" to uid)
    }

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
        val key = AdbKey(keyStore, "Skivu@android", allowUnpinnedPeer = true)
        AdbPairingClient(host, port, code, key).use { client ->
            pairing = client
            val deadline = timers.schedule({ client.cancel() }, 45, TimeUnit.SECONDS)
            try {
                check(epoch == cancellationEpoch.get()) { "配对已取消。" }
                require(client.start()) { "系统没有完成配对。" }
                val pin = client.verifiedPeerCertificatePin ?: error("没有取得经配对验证的设备证书。")
                check(epoch == cancellationEpoch.get()) { "配对已取消。" }
                check(prefs.edit().putString("peerPin", pin).commit())
                verifiedUid = null
                return mapOf("paired" to true, "connected" to false,
                    "summary" to "配对已完成，请使用无线调试连接端口连接。")
            } finally { deadline.cancel(false); pairing = null }
        }
    }

    private fun client(port: Int, legacy: Boolean, trustPeer: Boolean = false): AdbClient {
        supported()
        validPort(port)
        require(legacy || isPaired()) { "请先完成系统无线配对。" }
        val pin = prefs.getString("adbdPeerPin", null)
        require(legacy || pin != null || trustPeer) { "首次连接请先在系统设置核对端口，再确认信任本机调试证书。" }
        return AdbClient(host, port, AdbKey(keyStore, "Skivu@android",
            expectedServerPin = if(trustPeer) null else pin, allowUnpinnedPeer = trustPeer), requireTls = !legacy)
    }

    fun connect(port: Int, legacy: Boolean = false, allowRoot: Boolean = false, trustPeer: Boolean = false): Map<String, Any?> {
        val epoch = cancellationEpoch.get()
        client(port, legacy, trustPeer).use { connection ->
            active = connection
            try {
                connection.connect()
                val probe = connection.executeScript("/system/bin/id -u", 5000)
                val uid = probe.stdout.trim().toIntOrNull()
                require(probe.exitCode == 0 && (uid == 2000 || allowRoot && uid == 0)) {
                    "执行进程不是已授权的 shell/root 身份。"
                }
                check(epoch == cancellationEpoch.get()) { "连接已取消。" }
                val edit = prefs.edit().putInt("port", port).putBoolean("legacy", legacy)
                    .putBoolean("allowRoot", allowRoot)
                if(!legacy) edit.putString("adbdPeerPin", connection.serverPeerPin ?: error("缺少调试证书。"))
                check(edit.commit())
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

    fun execute(command: String, timeoutSeconds: Long = 0,
                stdout: java.io.OutputStream? = null, stderr: java.io.OutputStream? = null,
                canExecute: () -> Boolean = { true }): Map<String, Any?> {
        val epoch = cancellationEpoch.get()
        require(timeoutSeconds >= 0 && timeoutSeconds <= Long.MAX_VALUE/1000)
        val port = prefs.getInt("port", -1)
        val legacy = prefs.getBoolean("legacy", false)
        // Verify identity on a separate completed stream before sending user code.
        val state = connect(port, legacy, prefs.getBoolean("allowRoot", false))
        check(state["connected"] == true && epoch == cancellationEpoch.get())
        client(port, legacy).use { connection ->
            active = connection
            val job = OwnedAdbJob(port, legacy)
            val timedOut = java.util.concurrent.atomic.AtomicBoolean(false)
            val timeout = if(timeoutSeconds==0L)null else timers.schedule({
                timedOut.set(true)
                synchronized(executionLock) {
                    if (activeJob === job) scheduleCancellation(job)
                    connection.close()
                }
            }, timeoutSeconds.toLong(), TimeUnit.SECONDS)
            try {
                connection.connect()
                synchronized(executionLock) {
                    check(epoch == cancellationEpoch.get() && canExecute())
                    activeJob = job
                }
                var leaseExpired=false
                val observedError=object:java.io.OutputStream(){private var tail="";override fun write(value:Int){write(byteArrayOf(value.toByte()))};override fun write(bytes:ByteArray,offset:Int,length:Int){stderr?.write(bytes,offset,length);tail=(tail+String(bytes,offset,length,Charsets.ISO_8859_1));if(tail.contains(job.expiredMarker))leaseExpired=true;tail=tail.takeLast(job.expiredMarker.length)}}
                val result = connection.executeScript(job.script(command), timeoutSeconds * 1000, job.heartbeat,stdout,if(stderr==null)null else observedError)
                if (result.exitCode == 125 && (leaseExpired || result.stderr.contains(job.expiredMarker))) {
                    throw IllegalStateException("设备执行会话续约中断，已执行的操作需要核对。")
                }
                check(epoch == cancellationEpoch.get()) { "设备代码已停止，已执行的操作需要核对。" }
                return mapOf("uid" to verifiedUid, "exitCode" to result.exitCode,
                    "stdout" to result.stdout, "stderr" to result.stderr, "truncated" to result.truncated)
            } catch (e: Exception) {
                synchronized(executionLock) { if (activeJob === job) scheduleCancellation(job) }
                if (timedOut.get()) throw IllegalStateException("设备代码执行超时，结果需要核对。", e)
                if (epoch != cancellationEpoch.get()) throw IllegalStateException("已请求停止设备代码，已执行的操作需要核对。", e)
                throw e
            } finally {
                timeout?.cancel(false)
                synchronized(executionLock) {
                    if (activeJob === job) activeJob = null
                    if (active === connection) active = null
                }
            }
        }
    }

    private fun scheduleCancellation(job: OwnedAdbJob): Future<Map<String, Any?>>? {
        if (!job.cancellationScheduled.compareAndSet(false, true)) return stopping
        val future = cancellations.submit<Map<String, Any?>> {
            try {
                client(job.port, job.legacy).use { connection ->
                    val deadline = timers.schedule({ connection.close() }, 6, TimeUnit.SECONDS)
                    try {
                        connection.connect()
                        val result = connection.executeScript(job.cancellationScript(), 5000)
                        if (result.exitCode == 0 && result.stdout.trim() == "SKIVU_OWNED_GROUP_STOPPED") {
                            mapOf("outcome" to "cancelled", "groupStopped" to true,
                                "summary" to "本次脚本进程组已退出；已生效的操作请核对。")
                        } else stopUncertain()
                    } finally { deadline.cancel(false) }
                }
            } catch (_: Exception) { stopUncertain() }
        }
        stopping = future
        return future
    }
    private fun stopUncertain() = mapOf<String, Any?>("outcome" to "unknown", "groupStopped" to false,
        "summary" to "已停止后续派发，但未能确认脚本全部进程退出；请核对设备状态。")
    fun stop(): Future<Map<String, Any?>>? = synchronized(executionLock) {
        cancellationEpoch.incrementAndGet()
        val future = activeJob?.let { scheduleCancellation(it) }
        active?.close()
        pairing?.cancel()
        verifiedUid = null
        future
    }
    fun awaitStop(future: Future<Map<String, Any?>>?): Map<String, Any?> = try {
        future?.get(8, TimeUnit.SECONDS) ?: mapOf("outcome" to "cancelled", "groupStopped" to true,
            "summary" to "本次请求已停止；已生效的操作请核对。")
    } catch (_: Exception) { stopUncertain() }
    fun awaitCleanup(): Map<String, Any?> = awaitStop(stopping)
    fun disconnect() { stop(); check(prefs.edit().remove("port").commit()) }
    fun close() {
        stop()
        cancellations.shutdown()
        Thread {
            try { cancellations.awaitTermination(9, TimeUnit.SECONDS) } finally { timers.shutdownNow() }
        }.start()
    }
}
