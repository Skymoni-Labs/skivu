// Portions derived from Phase (https://github.com/CikeSeven/phase), used with the author's permission. See THIRD_PARTY_NOTICES.md.
// Portions derived from DSHA (https://github.com/DSH-APP/DSHA), MIT, Copyright (c) 2026 qiannianhuanxiang. See THIRD_PARTY_NOTICES.md.
package com.skyjjgw.independent.ski.dshgo.phone.background

import android.annotation.SuppressLint
import android.content.Context
import android.os.Binder
import android.os.Bundle
import android.os.Looper
import android.os.Parcel
import android.os.Process

/**
 * The Shizuku UserService entry: Shizuku instantiates this class (shell or root uid) and
 * hands the app its Binder. Only this app's uid may call it; the real engine is
 * [PrivilegedDisplayCore], shared byte-for-byte with the adb path.
 */
@androidx.annotation.Keep
class PrivilegedDisplayService(context: Context) : IPrivilegedDisplay.Stub() {
    private val core = PrivilegedDisplayHost(context)
    private val appUid = context.applicationInfo.uid
    private val calls = PrivilegedCalls(3)

    override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
        if (code == SHIZUKU_DESTROY_TRANSACTION) {
            if (Binder.getCallingUid() != appUid && Binder.getCallingUid() != Process.myUid()) {
                throw SecurityException("identityChanged")
            }
            data.enforceInterface(IPrivilegedDisplay.DESCRIPTOR)
            // Official UserService lifecycle stop, not an owner RELEASE receipt. The manager
            // removes its record before sending this one-way transaction and has no kill fallback.
            kotlin.system.exitProcess(0)
        }
        return super.onTransact(code, data, reply, flags)
    }

    private companion object {
        // Shizuku API 13.1.5 UserService reserved destroy transaction (also used by Sui).
        const val SHIZUKU_DESTROY_TRANSACTION = 16777115
    }

    override fun execute(request: Bundle): Bundle {
        var result: Bundle? = null
        dispatch(request) { result = it }
        return checkNotNull(result)
    }

    override fun executeReply(request: Bundle, writeReply: (Bundle) -> Unit) = dispatch(request, writeReply)

    private fun dispatch(request: Bundle, writeReply: (Bundle) -> Unit) {
        // Identity is sampled on the original Binder thread, never a submitted worker.
        if (Binder.getCallingUid() != appUid && Binder.getCallingUid() != Process.myUid() ||
            request.getString("revision") != null && request.getString("revision") != Proto.REVISION) {
            writeReply(Bundle().apply { putBoolean(Proto.OK, false); putString(Proto.ERROR, "identityChanged") })
            return
        }
        val peer = core.peerInstance
        val optIn = MuxProtocol.isOptIn(request, peer)
        val envelope = if (!optIn && MuxProtocol.hasHeader(request)) MuxProtocol.unwrap(request, peer) else null
        val body = envelope?.value ?: request
        calls.execute(global = envelope == null || MuxProtocol.global(body)) {
            val response = if (optIn) MuxProtocol.capability(core.handle(Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) }), peer)
                else core.handle(body).also { if (envelope == null && body.get(Proto.OP) == Proto.OP_PROBE) MuxProtocol.capability(it, peer) }
            writeReply(if (envelope == null) response else MuxProtocol.wrap(response, peer, envelope.id))
        }
    }

}

/**
 * The self-ADB entry, started as `CLASSPATH=<apk> app_process /system/bin <thisClass>` over an
 * adb shell stream. It speaks the same request/response [Bundle]s as the Shizuku binder, but
 * framed over stdin/stdout ([Frames] + [Bundles]) because an adb-launched process has no Binder
 * the app can look up. One privileged engine, two transports.
 */
object PrivilegedDisplayMain {
    @JvmStatic
    @SuppressLint("PrivateApi")
    fun main(args: Array<String>) {
        // ActivityThread.systemMain() constructs Handlers, so prepare before systemContext().
        if (Looper.myLooper() == null) Looper.prepareMainLooper()
        val context = systemContext()
        val core = PrivilegedDisplayHost(context)
        System.err.println("DSH_VDISPLAY_READY uid=${Process.myUid()} rev=${Proto.REVISION}")
        System.err.flush()
        val worker = Thread({ serve(core) }, "dsh-vdisplay")
        worker.isDaemon = true
        worker.start()
        runCatching { Looper.loop() }
        runCatching { core.handle(Bundle().apply { putString(Proto.OP, Proto.OP_DESTROY) }) }
    }

    private fun serve(core: PrivilegedDisplayHost) {
        val input = System.`in`
        // PrintStream swallows write failures; frames must fail on the original stdout FD.
        val output = java.io.FileOutputStream(java.io.FileDescriptor.out)
        try {
            synchronized(output) { output.write(Frames.MAGIC); output.flush() }
            var businessSeen = false
            while (true) {
                val frame = Frames.read(input) ?: break
                val request = Bundles.unmarshal(frame)
                val optIn = MuxProtocol.isOptIn(request, core.peerInstance)
                if (optIn) {
                    check(!businessSeen)
                    val ack = MuxProtocol.capability(core.handle(Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) }), core.peerInstance)
                    Frames.write(output, Bundles.marshal(ack))
                    if (ack.get(Proto.OK) != true) continue
                    serveMux(core, input, output)
                    return
                }
                check(!MuxProtocol.hasHeader(request))
                if (request.get(Proto.OP) != Proto.OP_PROBE) businessSeen = true
                val response = core.handle(request).also {
                    if (request.get(Proto.OP) == Proto.OP_PROBE) MuxProtocol.capability(it, core.peerInstance)
                }
                synchronized(output) { Frames.write(output, Bundles.marshal(response)) }
                // A rejected destroy must leave this peer available for its owner's cleanup.
                if (request.getString(Proto.OP) == Proto.OP_DESTROY &&
                    (response.get(Proto.OK) as? Boolean) == true) break
            }
        } catch (_: Throwable) {
            // stream closed or malformed: fall through to exit
        } finally {
            runCatching { core.handle(Bundle().apply { putString(Proto.OP, Proto.OP_DESTROY) }) }
            runCatching { Looper.getMainLooper()?.quitSafely() }
            Process.killProcess(Process.myPid())
        }
    }

    private fun serveMux(core: PrivilegedDisplayHost, input: java.io.InputStream, output: java.io.OutputStream) {
        val peer = core.peerInstance
        FramedMuxServer(input, output,
            decode = { bytes -> MuxProtocol.unwrap(Bundles.unmarshal(bytes), peer).let {
                FramedMuxServer.Request(it.id, it.value, MuxProtocol.global(it.value))
            } }, handle = core::handle,
            encode = { id, value -> Bundles.marshal(MuxProtocol.wrap(value, peer, id)) },
            terminal = MuxProtocol::destroyed,
            abort = { Process.killProcess(Process.myPid()) }).run()
    }

    @SuppressLint("PrivateApi")
    private fun systemContext(): Context {
        val activityThread = Class.forName("android.app.ActivityThread")
        val thread = activityThread.getMethod("systemMain").invoke(null)
        return activityThread.getMethod("getSystemContext").invoke(thread) as Context
    }
}
