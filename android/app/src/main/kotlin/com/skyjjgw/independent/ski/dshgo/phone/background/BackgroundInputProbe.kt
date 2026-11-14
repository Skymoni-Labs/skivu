package com.skyjjgw.independent.ski.dshgo.phone.background

import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.os.SystemClock
import android.view.Display
import java.util.UUID

/** Core owns injection and the receipt matcher; a normal app Activity owns the receiving window. */
internal class BackgroundInputProbe(private val context: Context, private val display: Display) : AutoCloseable {
    private val ui = Handler(Looper.getMainLooper())
    private val probe = InputProbe(display.displayId, SystemClock::uptimeMillis)
    private val session = ProbeActivitySession()
    private val nonce = UUID.randomUUID().toString()
    private var connected = false // Callback looper only.
    private var armed = false // Callback looper only; never replace an armed target.
    var failureDetail: String? = null
        private set

    private val receiver = object : ResultReceiver(ui) {
        override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
            val data = resultData ?: return
            if (data.get(ProbeActivityContract.NONCE) != nonce) return
            try {
                if (resultCode == ProbeActivityContract.CREATED) {
                    val finish = data.get(ProbeActivityContract.RECEIVER) as? ResultReceiver ?: return
                    if (!session.connected { finish.send(ProbeActivityContract.FINISH, Bundle().apply {
                        putString(ProbeActivityContract.NONCE, nonce)
                    }) }) return
                    connected = true
                    probe.entered(InputProbeDiagnostics.Stage.ACTIVITY_READY_WAIT)
                    if (data.get(ProbeActivityContract.DISPLAY) != display.displayId) probe.fail(IllegalStateException())
                    return
                }
                if (!connected) return
                if (resultCode == ProbeActivityContract.DETACHED) { session.detached(); return }
                if (session.isSealed) return
                if (resultCode == ProbeActivityContract.FAILED) { probe.fail(IllegalStateException()); return }
                if (data.get(ProbeActivityContract.DISPLAY) != display.displayId || !display.isValid) return
                when (resultCode) {
                    ProbeActivityContract.ARMED -> {
                        if (armed) return
                        val x = data.get(ProbeActivityContract.X) as? Int ?: return
                        val y = data.get(ProbeActivityContract.Y) as? Int ?: return
                        val size = android.graphics.Point().also { display.getRealSize(it) }
                        if (x !in 1 until size.x || y !in 1 until size.y) { probe.fail(IllegalStateException()); return }
                        armed = true
                        probe.ready(InputProbe.Target(display.displayId, x, y))
                    }
                    ProbeActivityContract.TOUCH -> {
                        if (!armed) return
                        probe.accept(display.displayId,
                            data.get(ProbeActivityContract.TIME) as? Long ?: return,
                            data.get(ProbeActivityContract.ACTION) as? Int ?: return,
                            data.get(ProbeActivityContract.X) as? Float ?: return,
                            data.get(ProbeActivityContract.Y) as? Float ?: return)
                    }
                }
            } catch (e: Exception) { probe.fail(e) }
        }
    }

    fun verify(send: (InputProbe.Target, Long) -> Unit) {
        try {
            if (Looper.myLooper() == ui.looper || display.displayId <= Display.DEFAULT_DISPLAY || !display.isValid)
                throw probe.failure("inputWindowNotReady")
            probe.entered(InputProbeDiagnostics.Stage.ACTIVITY_START)
            val intent = Intent().apply {
                component = ComponentName(ProbeActivityContract.PACKAGE, ProbeActivityContract.ACTIVITY)
                identifier = nonce
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
                putExtra(ProbeActivityContract.NONCE, nonce)
                putExtra(ProbeActivityContract.DISPLAY, display.displayId)
                putExtra(ProbeActivityContract.RECEIVER, receiver)
            }
            val options = ActivityOptions.makeBasic().apply { launchDisplayId = display.displayId }
            // Binder endpoints stay in Android's Intent delivery, never in Bundles.marshal's byte stream.
            val pending = PendingIntent.getActivity(context.createDisplayContext(display), display.displayId,
                intent, PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE)
            try {
                session.starting()
                pending.send(context, 0, null, null, null, null, options.toBundle())
            } catch (e: PendingIntent.CanceledException) { session.rejected(); probe.fail(e) }
            catch (e: SecurityException) { session.rejected(); probe.fail(e) }
            finally { pending.cancel() }
            probe.verify(now = SystemClock::uptimeMillis, send = { target, time ->
                if (session.isSealed || !display.isValid) throw probe.failure("inputWindowNotReady")
                send(target, time)
            })
        } catch (e: Exception) {
            failureDetail = probe.observation(e).encode()
            throw e
        }
    }

    override fun close() {
        probe.entered(InputProbeDiagnostics.Stage.CLEANUP)
        var interrupted = Thread.interrupted()
        try { session.close() }
        catch (e: Exception) {
            if (e is InterruptedException) interrupted = true
            val failure = probe.failure("inputProbeCleanupFailed", e)
            failureDetail = failure.observation?.encode()
            throw failure
        } finally { if (interrupted) Thread.currentThread().interrupt() }
    }
}
