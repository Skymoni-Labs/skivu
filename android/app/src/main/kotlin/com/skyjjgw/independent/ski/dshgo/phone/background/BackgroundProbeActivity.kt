package com.skyjjgw.independent.ski.dshgo.phone.background

import android.app.Activity
import android.graphics.Canvas
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.view.Display
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import java.util.UUID

/** No user content or commands. The manifest admits only holders of the system INJECT_EVENTS permission. */
class BackgroundProbeActivity : Activity() {
    private val ui = Handler(Looper.getMainLooper())
    private var receiver: ResultReceiver? = null
    private var nonce: String? = null
    private var expectedDisplay = Display.INVALID_DISPLAY
    private var resumed = false
    private var frameCommitted = false
    private var armed = false
    private var reportedDetached = false
    private var view: View? = null
    private val expire = Runnable { finishAndRemoveTask() }

    private val finishReceiver = object : ResultReceiver(ui) {
        override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
            if (resultCode == ProbeActivityContract.FINISH && resultData?.getString(ProbeActivityContract.NONCE) == nonce)
                finishAndRemoveTask()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        receiver = intent.getParcelableExtra(ProbeActivityContract.RECEIVER)
        nonce = intent.getStringExtra(ProbeActivityContract.NONCE)
        expectedDisplay = intent.getIntExtra(ProbeActivityContract.DISPLAY, Display.INVALID_DISPLAY)
        if (receiver == null || nonce?.let { runCatching { UUID.fromString(it).toString() == it }.getOrDefault(false) } != true) {
            finishAndRemoveTask()
            return
        }
        report(ProbeActivityContract.CREATED, Bundle().apply {
            putParcelable(ProbeActivityContract.RECEIVER, finishReceiver)
        })
        ui.postDelayed(expire, 8_000)
        // A misrouted launch must never arm or draw the test window on the main screen.
        if (savedInstanceState != null || expectedDisplay <= Display.DEFAULT_DISPLAY || actualDisplayId() != expectedDisplay) {
            report(ProbeActivityContract.FAILED)
            finishAndRemoveTask()
            return
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED)
        window.setWindowAnimations(0)
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN)
        val body = object : View(this) {
            private var frameRequested = false
            override fun onDraw(canvas: Canvas) { canvas.drawColor(Color.BLACK) }
            override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
                super.onSizeChanged(w, h, oldw, oldh)
                if (frameRequested || w < 4 || h < 4) return
                frameRequested = true
                viewTreeObserver.registerFrameCommitCallback {
                    ui.post { frameCommitted = true; maybeArm() }
                }
            }
            override fun onTouchEvent(event: MotionEvent): Boolean {
                // The receiving View supplies its actual display, as in the local receipt matcher.
                val receiverDisplay = this.display?.displayId ?: Display.INVALID_DISPLAY
                if (armed && !isFinishing && !isDestroyed) report(ProbeActivityContract.TOUCH, Bundle().apply {
                    putInt(ProbeActivityContract.DISPLAY, receiverDisplay)
                    putInt(ProbeActivityContract.ACTION, event.actionMasked)
                    putLong(ProbeActivityContract.TIME, event.downTime)
                    putFloat(ProbeActivityContract.X, event.rawX)
                    putFloat(ProbeActivityContract.Y, event.rawY)
                })
                return true
            }
        }
        view = body
        setContentView(body)
    }

    override fun onResume() { super.onResume(); resumed = true; maybeArm() }
    override fun onPause() {
        resumed = false
        if (armed && !isFinishing) report(ProbeActivityContract.FAILED)
        super.onPause()
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus && armed && !isFinishing) report(ProbeActivityContract.FAILED)
        maybeArm()
    }

    private fun actualDisplayId(): Int = windowManager.defaultDisplay.displayId

    private fun maybeArm() {
        val body = view ?: return
        if (armed || !resumed || !frameCommitted || !hasWindowFocus() || isFinishing || isDestroyed ||
            !body.isAttachedToWindow || expectedDisplay <= Display.DEFAULT_DISPLAY ||
            actualDisplayId() != expectedDisplay || body.display?.displayId != expectedDisplay) return
        val location = IntArray(2)
        body.getLocationOnScreen(location)
        armed = true
        report(ProbeActivityContract.ARMED, Bundle().apply {
            putInt(ProbeActivityContract.X, location[0] + body.width / 2)
            putInt(ProbeActivityContract.Y, location[1] + body.height / 2)
        })
    }

    private fun report(code: Int, data: Bundle = Bundle()) {
        data.putString(ProbeActivityContract.NONCE, nonce)
        if (!data.containsKey(ProbeActivityContract.DISPLAY)) data.putInt(ProbeActivityContract.DISPLAY, actualDisplayId())
        receiver?.send(code, data)
    }

    override fun onDestroy() {
        ui.removeCallbacks(expire)
        super.onDestroy()
        val decor = window.decorView
        // finish() and onDestroy() alone are not proof that WindowManager removed the window.
        fun detached() {
            ui.post {
                if (!reportedDetached && !decor.isAttachedToWindow) {
                    reportedDetached = true
                    report(ProbeActivityContract.DETACHED)
                }
            }
        }
        if (!decor.isAttachedToWindow) detached()
        else decor.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: View) = Unit
            override fun onViewDetachedFromWindow(v: View) { v.removeOnAttachStateChangeListener(this); detached() }
        })
    }
}

/** Private Binder messages, never marshalled into the adb/root byte stream. */
internal object ProbeActivityContract {
    const val PACKAGE = com.skyjjgw.independent.ski.BuildConfig.APPLICATION_ID
    // The installed applicationId can differ from the rebased class namespace.
    const val ACTIVITY = "com.skyjjgw.independent.ski.dshgo.phone.background.BackgroundProbeActivity"
    const val RECEIVER = "receiver"
    const val NONCE = "nonce"
    const val DISPLAY = "display"
    const val X = "x"
    const val Y = "y"
    const val ACTION = "action"
    const val TIME = "time"
    const val CREATED = 1
    const val ARMED = 2
    const val TOUCH = 3
    const val FAILED = 4
    const val DETACHED = 5
    const val FINISH = 6
}
