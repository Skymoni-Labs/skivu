// Portions derived from Phase (https://github.com/CikeSeven/phase), used with the author's permission. See THIRD_PARTY_NOTICES.md.
// Local changes: blocking calls with timeouts; clickable-ancestor lookup before the gesture
// fallback; directional scrolls; IME enter; injected gestures pass through the overlay and are
// recorded in InjectGuard so its confirm buttons can refuse them.

package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction
import com.skyjjgw.independent.ski.dshgo.phone.PhoneAction
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** When this service last injected input; the overlay's guarded buttons ignore touches inside it. */
internal object InjectGuard {
    @Volatile var until = 0L
        private set

    fun mark(durationMs: Long) { until = maxOf(until, SystemClock.uptimeMillis() + durationMs + 400) }

    fun active() = SystemClock.uptimeMillis() < until
}

internal class Actuator(private val service: AccessibilityService, private val overlay: ControlOverlay) {
    private val gestureThread = HandlerThread("dsh-a11y-gesture").apply { start() }
    private val gestureHandler = Handler(gestureThread.looper)
    private val main = Handler(Looper.getMainLooper())

    enum class Via { NODE, ANCESTOR, GESTURE }

    class Outcome(val accepted: Boolean, val via: Via?)

    fun close() { gestureThread.quitSafely() }

    /** Try one node action; use a tap gesture only when neither node nor ancestor offers one. */
    fun click(node: AccessibilityNodeInfo, bounds: Box, screen: Box, long: Boolean, allowed: () -> Boolean): Outcome {
        val action = if (long) AccessibilityNodeInfo.ACTION_LONG_CLICK else AccessibilityNodeInfo.ACTION_CLICK
        fun able(n: AccessibilityNodeInfo) = n.isEnabled && if (long) n.isLongClickable else n.isClickable
        // A node click is our input too: confirm cards refuse accessibility clicks while it lasts.
        InjectGuard.mark(0)
        if (able(node)) {
            if (!allowed()) return Outcome(false, null)
            val ok = node.performAction(action)
            return Outcome(ok, if (ok) Via.NODE else null)
        }
        // A text inside a clickable row: a finger there would hit the row.
        val rect = Rect()
        var parent: AccessibilityNodeInfo? = node.parent
        var depth = 0
        while (parent != null && depth < 4) {
            parent.getBoundsInScreen(rect)
            if (able(parent) && rect.contains(bounds.centerX, bounds.centerY)) {
                if (!allowed()) return Outcome(false, null)
                val ok = parent.performAction(action)
                return Outcome(ok, if (ok) Via.ANCESTOR else null)
            }
            parent = parent.parent
            depth++
        }
        val point = visiblePoint(bounds, screen) ?: return Outcome(false, null)
        val ok = tap(point.first, point.second, long, start = { send -> allowed() && send() })
        // Ordinary fallback keeps await's throw-and-clear interruption contract.
        if (Thread.interrupted()) throw InterruptedException()
        return Outcome(ok, if (ok) Via.GESTURE else null)
    }

    /** A point of [bounds] that is on screen, preferring the centre. */
    private fun visiblePoint(bounds: Box, screen: Box): Pair<Int, Int>? {
        val clipped = bounds.intersect(screen)
        if (clipped.isEmpty) return null
        return clipped.centerX to clipped.centerY
    }

    fun tap(x: Int, y: Int, long: Boolean = false, start: ((() -> Boolean) -> Boolean)? = null): Boolean {
        val path = Path().apply { moveTo(x.toFloat(), y.toFloat()) }
        val duration = if (long) ViewConfiguration.getLongPressTimeout().toLong() + 300 else 60L
        return gesture(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, duration)).build(), duration, start)
    }

    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Long = 350, start: ((() -> Boolean) -> Boolean)? = null): Boolean {
        val path = Path().apply { moveTo(x1.toFloat(), y1.toFloat()); lineTo(x2.toFloat(), y2.toFloat()) }
        return gesture(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, durationMs)).build(), durationMs, start)
    }

    /**
     * Dispatches and waits for the gesture. The overlay is made untouchable first so the
     * stroke reaches the app underneath, never the overlay; InjectGuard covers the
     * time it is in flight.
     */
    fun gesture(description: GestureDescription, durationMs: Long, start: ((() -> Boolean) -> Boolean)? = null): Boolean {
        overlay.setPassThrough(true)
        try {
            InjectGuard.mark(durationMs)
            val latch = CountDownLatch(1)
            var completed = false
            val send = { service.dispatchGesture(description, object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) { completed = true; latch.countDown() }
                override fun onCancelled(gestureDescription: GestureDescription?) { latch.countDown() }
            }, gestureHandler) }
            val sent = if (start == null) send() else start(send)
            if (!sent) return false
            try { latch.await(durationMs + 2_000, TimeUnit.MILLISECONDS) }
            catch (e: InterruptedException) {
                if (start == null) throw e
                // The main start may already have sent the gesture. Preserve unknown effect,
                // never replay it or turn a cancelled callback wait into "not submitted".
                Thread.currentThread().interrupt()
                return false
            }
            return completed
        } finally {
            InjectGuard.mark(0)
            overlay.setPassThrough(false)
        }
    }

    fun coordinateStart(current: () -> Boolean, admission: ((() -> Boolean) -> Boolean), send: () -> Boolean): Boolean {
        val ticket = CoordinateDispatch(Thread.currentThread(), current, admission, send)
        if (!main.post(ticket)) ticket.cancelQueued()
        return ticket.awaitStart(2_000)
    }

    fun setText(node: AccessibilityNodeInfo, text: String, allowed: () -> Boolean): Boolean {
        val args = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text) }
        if (!node.isFocused) {
            if (!allowed()) return false
            node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        }
        if (!allowed()) return false
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    /** Node scroll action for [direction] if the node offers one, else a swipe inside [bounds]. */
    fun scroll(node: AccessibilityNodeInfo?, scrollBits: Int, horizontal: Boolean, bounds: Box, screen: Box, direction: PhoneAction.Direction, allowed: () -> Boolean): Outcome {
        if (node != null) {
            val action = scrollAction(scrollBits, horizontal, direction)
            if (action != null) {
                if (!allowed()) return Outcome(false, null)
                val ok = node.performAction(action)
                return Outcome(ok, if (ok) Via.NODE else null)
            }
        }
        // Keep clear of the status bar and the gesture-navigation strip at the bottom.
        val area = bounds.intersect(Box(screen.left, screen.top + screen.height / 20, screen.right, screen.bottom - screen.height * 6 / 100))
        if (area.isEmpty || area.height < 40 || area.width < 40) return Outcome(false, null)
        val cx = area.centerX
        val cy = area.centerY
        val dy = area.height * 3 / 10
        val dx = area.width * 3 / 10
        val start: (() -> Boolean) -> Boolean = { send -> allowed() && send() }
        val ok = when (direction) {
            // DOWN = show what is below: the finger moves up.
            PhoneAction.Direction.DOWN -> swipe(cx, cy + dy, cx, cy - dy, start = start)
            PhoneAction.Direction.UP -> swipe(cx, cy - dy, cx, cy + dy, start = start)
            PhoneAction.Direction.RIGHT -> swipe(cx + dx, cy, cx - dx, cy, start = start)
            PhoneAction.Direction.LEFT -> swipe(cx - dx, cy, cx + dx, cy, start = start)
        }
        if (Thread.interrupted()) throw InterruptedException()
        return Outcome(ok, if (ok) Via.GESTURE else null)
    }

    private fun scrollAction(bits: Int, horizontal: Boolean, direction: PhoneAction.Direction): Int? = when (direction) {
        PhoneAction.Direction.DOWN -> when {
            bits and Scroll.DOWN != 0 -> AccessibilityAction.ACTION_SCROLL_DOWN.id
            !horizontal && bits and Scroll.FORWARD != 0 -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
            else -> null
        }
        PhoneAction.Direction.UP -> when {
            bits and Scroll.UP != 0 -> AccessibilityAction.ACTION_SCROLL_UP.id
            !horizontal && bits and Scroll.BACKWARD != 0 -> AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
            else -> null
        }
        PhoneAction.Direction.RIGHT -> when {
            bits and Scroll.RIGHT != 0 -> AccessibilityAction.ACTION_SCROLL_RIGHT.id
            horizontal && bits and Scroll.FORWARD != 0 -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
            else -> null
        }
        PhoneAction.Direction.LEFT -> when {
            bits and Scroll.LEFT != 0 -> AccessibilityAction.ACTION_SCROLL_LEFT.id
            horizontal && bits and Scroll.BACKWARD != 0 -> AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
            else -> null
        }
    }

    fun global(key: PhoneAction.GlobalKey): Boolean = service.performGlobalAction(
        when (key) {
            PhoneAction.GlobalKey.BACK -> AccessibilityService.GLOBAL_ACTION_BACK
            PhoneAction.GlobalKey.HOME -> AccessibilityService.GLOBAL_ACTION_HOME
            PhoneAction.GlobalKey.RECENTS -> AccessibilityService.GLOBAL_ACTION_RECENTS
            PhoneAction.GlobalKey.NOTIFICATIONS -> AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS
        },
    )
}
