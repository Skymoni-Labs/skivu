// Portions derived from Phase (https://github.com/CikeSeven/phase), used with the author's permission. See THIRD_PARTY_NOTICES.md.
// Local changes: registers into PhoneRegistry; stops the task on screen off, interrupt and
// unbind through ControlListener; debug-only probe.

package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.res.Configuration
import android.hardware.display.DisplayManager
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.Display
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import com.skyjjgw.independent.ski.dshgo.phone.PhoneRegistry
import com.skyjjgw.independent.ski.dshgo.phone.PhoneTasks

/**
 * DSH's accessibility service (same process as the app). While connected it is the MAIN
 * [com.skyjjgw.independent.ski.dshgo.phone.PhoneDriver] and the overlay
 * [com.skyjjgw.independent.ski.dshgo.phone.UserGate]. It reads nothing on its own: the tree is
 * read only when the bridge calls the driver.
 */
class PhoneA11yService : AccessibilityService() {
    internal val clock = EventClock()
    internal val focusInputObservation = FocusInputObservation()
    private var focusInputMethod: FocusInputMethod33? = null
    private var focusInputRetired = false

    @android.annotation.TargetApi(33)
    override fun onCreateInputMethod(): android.accessibilityservice.InputMethod =
        FocusInputMethod33(this, focusInputObservation).also {
            focusInputMethod = it
            if (destroyed || focusInputRetired) focusInputObservation.retire()
        }

    @android.annotation.TargetApi(33)
    internal fun captureFocusInput(): FocusCapturedInput33? {
        check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
        if (destroyed || instance !== this || PhoneRegistry.mainDriver !== driver || driver == null) return null
        return focusInputMethod?.capture()
    }
    private var overlay: ControlOverlay? = null
    private var driver: MainScreenDriver? = null
    private var probe: A11yProbe? = null
    private var receiverRegistered = false
    private var overlayContext: Context? = null
    private var destroyed = false

    /** A dedicated manager whose default token comes from the live accessibility connection. */
    internal fun overlayWindowContext(): Context = overlayContext ?: run {
        val context = if (Build.VERSION.SDK_INT >= 30) {
            val display = getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
            // AccessibilityService's display/window wrappers obtain getOverlayWindowToken(displayId).
            // An application-derived window context cannot supply that accessibility token.
            createDisplayContext(display).createWindowContext(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY, null)
        } else this
        context.also { overlayContext = it }
    }

    internal fun invalidateOverlayWindowContext() { overlayContext = null }

    /** User-initiated display captures must omit the service's own controls too. */
    internal fun hideControlOverlayForPetScreenshot(hide: Boolean) { overlay?.hideForCapture(hide) }

    private val screenOff = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            // l10n:keep agent stop reason
            if (intent.action == Intent.ACTION_SCREEN_OFF) stopAll("屏幕关闭了", PhoneTasks.StopSource.SCREEN_OFF)
        }
    }

    override fun onServiceConnected() {
        if (destroyed) return
        super.onServiceConnected()
        // Re-init can reuse this service object. Retire the old driver/handler before publishing
        // the new one; coordinate starts are on this same main queue and check exact publication.
        instance?.takeIf { it !== this }?.teardown("无障碍连接已更换") // l10n:keep agent stop reason
        if (driver != null) teardown("无障碍连接已更换") // l10n:keep agent stop reason
        if (focusInputRetired) {
            if (Build.VERSION.SDK_INT >= 33) focusInputMethod?.reconnect()
            focusInputRetired = false
        }
        invalidateOverlayWindowContext()
        val o = ControlOverlay(this)
        val d = MainScreenDriver(this, o)
        overlay = o
        driver = d
        instance = this
        PhoneRegistry.mainDriver = d
        PhoneRegistry.overlayGate = o
        try {
            val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(screenOff, filter, Context.RECEIVER_NOT_EXPORTED) else registerReceiver(screenOff, filter)
            receiverRegistered = true
        } catch (e: Exception) { Log.w(TAG, "screen-off receiver", e) }
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) probe = A11yProbe(this, d, o).also { it.register() }
        Log.i(TAG, "accessibility service connected")
        PhoneRegistry.controlListener?.onAccessibilityChanged(true)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        clock.tick(event?.packageName)
        // A keyboard coming or going moves the control clear of it.
        if (event?.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED) overlay?.onWindowsChanged()
        // Window changes retire both coordinates and screenshot authorization. Only an identified
        // window of this service's controls is exempt; switching to DSH itself is still a transition.
        if (event != null && invalidatesVisual(event.eventType) {
            overlay?.ownsWindow(event.windowId) == true
        }) driver?.windowChanged()
    }

    /**
     * The system requests feedback interruption, not cancellation of the phone task.
     * We own no ongoing speech or vibration feedback; keep task ownership and actions intact.
     * Screen off, explicit stop and service teardown retain their separate stop paths.
     */
    override fun onInterrupt() {
        Log.i(TAG, "accessibility feedback interrupted; phone task unchanged")
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        overlay?.onConfigurationChanged()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        // l10n:keep agent stop reason
        teardown("无障碍服务已关闭")
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        destroyed = true
        // l10n:keep agent stop reason
        teardown("无障碍服务已停止")
        super.onDestroy()
    }

    /** Commit the ambient fence before cancelling prompts, whose STOP reply is not a user choice. */
    internal fun stopAll(reason: String, source: PhoneTasks.StopSource =
        PhoneTasks.StopSource.ENVIRONMENT) {
        try {
            PhoneRegistry.controlListener?.onStopAllRequested(reason, source)
        } finally {
            driver?.abort()
            overlay?.stopAll()
        }
    }

    private fun teardown(reason: String) {
        focusInputObservation.retire()
        focusInputRetired = true
        if (instance !== this && driver == null) return
        val d = driver
        val o = overlay
        if (PhoneRegistry.mainDriver === d) PhoneRegistry.mainDriver = null
        if (PhoneRegistry.overlayGate === o) PhoneRegistry.overlayGate = null
        if (instance === this) instance = null
        invalidateOverlayWindowContext()
        try {
            PhoneRegistry.controlListener?.onStopAllRequested(reason)
        } finally {
            d?.abort()
            o?.destroy()
            d?.close()
            probe?.unregister()
            probe = null
            if (receiverRegistered) { runCatching { unregisterReceiver(screenOff) }; receiverRegistered = false }
            driver = null
            overlay = null
            Log.i(TAG, "accessibility service gone: $reason")
            PhoneRegistry.controlListener?.onAccessibilityChanged(false)
        }
    }

    companion object {
        private const val TAG = "DshA11y"

        internal fun invalidatesVisual(eventType: Int, ownOverlay: () -> Boolean): Boolean =
            (eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
                eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED) && !ownOverlay()

        /** The connected service, if any. */
        @Volatile var instance: PhoneA11yService? = null
            private set

        fun isConnected(): Boolean = instance != null

        fun component(context: Context) = ComponentName(context.packageName, PhoneA11yService::class.java.name)

        /** Whether the person switched the service on in system settings (it may not be bound yet). */
        fun isEnabled(context: Context): Boolean {
            val list = try {
                Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            } catch (_: Exception) { null } ?: return false
            val me = component(context)
            return list.split(':').any { entry -> ComponentName.unflattenFromString(entry.trim()) == me }
        }
    }
}
