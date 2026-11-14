package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.i18n.AppStrings
import com.skyjjgw.independent.ski.R
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityManager
import com.skyjjgw.independent.ski.dshgo.phone.AppVisibility
import com.skyjjgw.independent.ski.dshgo.phone.ConfirmRequest
import com.skyjjgw.independent.ski.dshgo.phone.PhoneAppIdentity
import com.skyjjgw.independent.ski.dshgo.phone.background.Reasons
import com.skyjjgw.independent.ski.dshgo.phone.PhoneAction
import com.skyjjgw.independent.ski.dshgo.phone.PhoneControl
import java.io.File
import java.util.concurrent.Executors

/**
 * Debug builds only (FLAG_DEBUGGABLE): drives the MAIN driver and the overlay from
 * `adb shell am broadcast` so the service can be checked on an emulator without the
 * bridge. The broadcast must come from a holder of android.permission.DUMP (adb shell);
 * apps, including code in DSH's own Linux environment, can't send it. Results go to
 * `files/a11y-probe/last.txt` (+ `last.jpg`), read with `run-as`.
 *
 *   am broadcast -a com.skyjjgw.independent.ski.dshgo.A11Y_PROBE --es cmd screen [--ez image true] [--ez detail true] --ei seq 1
 *   cmd: screen | target sid id | tap sid id [long] | type sid id text [submit] | scroll sid [id] dir |
 *        key back|home|recents|notifications | tapxy sid x y | open pkg | collect sid id [pages] [until] |
 *        fg | windows | status [text] | confirm sentence [app] [first] | handoff reason [ms] | injecttest [relax] | guard |
 *        begin (a task starts, as on a tool call) | finish [session] [host] [reopen] (what Dart's finishTask does) |
 *        overlay [opacity 0.3–1] [auto true|false] (the 悬浮条 settings, as the settings page writes them) |
 *        palette dark|light|auto (the overlay's palette against the system's, for contrast checks) |
 *        form ball|capsule|card (as the person's taps would) | press key=pause|stop|steer|done |
 *        unlocks none|system|secrets|all|real (lifted limits to show) | freeze true|false (no timer changes the form) |
 *        app [name] (the task's app for the card) | state (what the control shows) | task (task lifetime) |
 *        interrupt (requests feedback interruption from ALL bound accessibility services;
 *        asynchronous: inspect the service callback log, then task; own test devices only)
 */
internal class A11yProbe(private val service: PhoneA11yService, private val driver: MainScreenDriver, private val overlay: ControlOverlay) {
    private val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-a11y-probe") }
    private val dir = File(service.filesDir, "a11y-probe").apply { mkdirs() }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val seq = intent.getIntExtra("seq", 0)
            val cmd = intent.getStringExtra("cmd") ?: return
            val args = Args(intent)
            executor.execute { run(seq, cmd, args) }
        }
    }

    private class Args(val intent: Intent) {
        fun s(name: String) = intent.getStringExtra(name)
        fun i(name: String) = intent.getStringExtra(name)?.toIntOrNull() ?: intent.getIntExtra(name, -1).takeIf { it >= 0 }
        fun b(name: String) = intent.getStringExtra(name)?.toBooleanStrictOrNull() ?: intent.getBooleanExtra(name, false)
    }

    fun register() {
        val filter = IntentFilter(ACTION)
        if (Build.VERSION.SDK_INT >= 33) service.registerReceiver(receiver, filter, "android.permission.DUMP", null, Context.RECEIVER_EXPORTED)
        else service.registerReceiver(receiver, filter, "android.permission.DUMP", null)
        Log.i(TAG, "debug probe listening for $ACTION")
    }

    fun unregister() {
        runCatching { service.unregisterReceiver(receiver) }
        executor.shutdownNow()
    }

    private fun run(seq: Int, cmd: String, a: Args) {
        if (cmd == "navigation-material") {
            // Never enter the generic body/Throwable logging or image output path below.
            try {
                PhoneControl.get(service).collectNavigationMaterial(driver, seq) { bytes ->
                    val tmp = File(dir, "last.tmp")
                    tmp.writeBytes(bytes)
                    check(tmp.renameTo(File(dir, "last.txt")))
                }
            } catch (_: Exception) { /* No exception text or stale body is exported. */ }
            return
        }
        val t0 = SystemClock.uptimeMillis()
        var image: ByteArray? = null
        val out = try {
            when (cmd) {
                "screen" -> driver.observe(a.b("detail"), a.b("image")).let { s ->
                    image = s.image
                    "id=${s.id} pkg=${s.packageName} secure=${s.secure} poor=${s.poorTree} image=${s.image?.size ?: 0}B ${s.imageMime ?: ""}\n${s.text}"
                }
                "target" -> driver.target(a.s("sid")!!, a.i("id")!!).toString()
                "tap" -> result(driver.perform(PhoneAction.Tap(a.s("sid")!!, a.i("id")!!, a.b("long"))))
                "type" -> result(driver.perform(PhoneAction.Type(a.s("sid")!!, a.i("id")!!, a.s("text") ?: "", a.b("submit"))))
                "scroll" -> result(driver.perform(PhoneAction.Scroll(a.s("sid")!!, a.i("id"), PhoneAction.Direction.valueOf((a.s("dir") ?: "down").uppercase()))))
                "key" -> result(driver.perform(PhoneAction.Key(a.s("sid") ?: "s0", PhoneAction.GlobalKey.valueOf((a.s("key") ?: "back").uppercase()))))
                "tapxy" -> result(driver.perform(PhoneAction.TapXY(a.s("sid")!!, a.i("x")!!, a.i("y")!!)))
                "open" -> {
                    val pkg = a.s("pkg")!!
                    val pm = service.packageManager
                    val intent = pm.getLaunchIntentForPackage(pkg)
                    val info = intent?.let { pm.resolveActivity(it, 0)?.activityInfo }
                    if (info == null || info.applicationInfo.uid < 0) Reasons.of("targetIdentityUnavailable")
                    else if (info.packageName != pkg) Reasons.of("targetIdentityChanged")
                    else result(driver.open(PhoneAppIdentity(info.packageName, info.applicationInfo.uid)))
                }
                "collect" -> driver.collect(a.s("sid")!!, a.i("id")!!, a.i("pages") ?: 10, a.s("until")).let { r ->
                    "pages=${r.pages} stop=${r.stopReason} items=${r.items.size}\n" + r.items.joinToString("\n") { "- $it" } +
                        "\n----\n${r.screen?.text}"
                }
                "fg" -> "fg=${driver.foregroundPackage()} availability=${driver.availability()} enabled=${PhoneA11yService.isEnabled(service)}"
                "status" -> { overlay.status(a.s("text")); "ok" }
                "confirm" -> overlay.confirm(ConfirmRequest(a.s("sentence") ?: AppStrings.get(service, R.string.overlay_probe_confirm), a.s("app"), null, a.b("first"), (a.i("ms") ?: 30_000).toLong())).name
                "handoff" -> overlay.handoff(a.s("reason") ?: AppStrings.get(service, R.string.overlay_probe_password), (a.i("ms") ?: 60_000).toLong()).name
                "injecttest" -> injectTest(a.b("relax"))
                "guard" -> "lastGuardVerdict=${overlay.lastGuardVerdict}"
                "task" -> PhoneControl.get(service).tasks.snapshot().toString()
                "interrupt" -> {
                    val before = PhoneControl.get(service).tasks.snapshot()
                    val manager = service.getSystemService(AccessibilityManager::class.java)
                    if (!manager.isEnabled) "requested=false accessibility-disabled before=$before" else {
                        manager.interrupt()
                        "requested=true callback=pending before=$before"
                    }
                }
                "begin" -> PhoneControl.get(service).tasks.let { t -> t.begin(); t.snapshot().toMap().toString() }
                "finish" -> finish(a.s("session"), a.s("host"), a.intent.getBooleanExtra("reopen", true))
                "palette" -> {
                    overlay.debugDark = when (a.s("mode")) { "dark" -> true; "light" -> false; else -> null }
                    overlay.onConfigurationChanged()
                    "palette=${overlay.debugDark}"
                }
                "overlay" -> OverlayPrefs.write(
                    service,
                    buildMap {
                        a.s("opacity")?.toFloatOrNull()?.let { put("idleOpacity", it) }
                        a.s("auto")?.toBooleanStrictOrNull()?.let { put("autoCollapse", it) }
                    },
                ).toString()
                "form" -> { overlay.debugForm(a.s("form") ?: "capsule"); "ok" }
                "press" -> { overlay.debugKey(a.s("key") ?: "pause"); "ok" }
                "unlocks" -> {
                    overlay.debugUnlocks = when (a.s("set")) {
                        "none" -> com.skyjjgw.independent.ski.dshgo.phone.PhoneUnlocks()
                        "system" -> com.skyjjgw.independent.ski.dshgo.phone.PhoneUnlocks(systemPages = true)
                        "secrets" -> com.skyjjgw.independent.ski.dshgo.phone.PhoneUnlocks(secretFields = true)
                        "all" -> com.skyjjgw.independent.ski.dshgo.phone.PhoneUnlocks(systemPages = true, secretFields = true, ownApp = true)
                        else -> null
                    }
                    "unlocks=${overlay.debugUnlocks}"
                }
                "app" -> { overlay.debugApp = a.s("name"); "app=${overlay.debugApp}" }
                "freeze" -> { overlay.debugFreeze = a.b("on"); "freeze=${overlay.debugFreeze}" }
                "state" -> overlay.debugState()
                "windows" -> windows()
                else -> "unknown cmd $cmd"
            }
        } catch (e: Throwable) {
            Log.w(TAG, "probe $cmd failed", e)
            "ERROR ${e.javaClass.simpleName}: ${e.message}"
        }
        val text = "seq=$seq cmd=$cmd ms=${SystemClock.uptimeMillis() - t0}\n$out\n"
        image?.let { File(dir, "last.jpg").writeBytes(it) }
        val tmp = File(dir, "last.tmp")
        tmp.writeText(text)
        tmp.renameTo(File(dir, "last.txt"))
        text.chunked(3_000).forEach { Log.i(TAG, it) }
    }

    private fun result(r: com.skyjjgw.independent.ski.dshgo.phone.ActionResult) =
        "ok=${r.ok} msg=${r.message}\n----\n${r.screen?.let { "id=${it.id}\n${it.text}" }}"

    /**
     * Shows a confirm card, then injects a tap on 允许一次 through this service's own
     * dispatchGesture — the attack the card must refuse — and reports whether it resolved.
     * relax=true lifts the InjectGuard / pass-through layers: with nothing else checking event
     * fields (see PromptInputPolicy), the tap then gets through, which shows those layers are the guard.
     */
    private fun injectTest(relax: Boolean): String {
        val result = arrayOfNulls<String>(1)
        val thread = Thread {
            result[0] = overlay.confirm(ConfirmRequest(AppStrings.get(service, R.string.overlay_probe_injection), AppStrings.get(service, R.string.overlay_probe_app), null, false, 8_000)).name
        }
        thread.start()
        SystemClock.sleep(1_500) // past the 600 ms arming delay
        val button = overlay.debugButtonCenter(AppStrings.get(service, R.string.overlay_allow_once)) ?: return "allow button not found".also { thread.join(10_000) }
        overlay.debugIgnoreInjectGuard = relax
        val sent = try {
            if (relax) {
                // Bypass the Actuator (which makes the overlay untouchable first) to land on the button.
                val path = android.graphics.Path().apply { moveTo(button.first.toFloat(), button.second.toFloat()) }
                val gesture = android.accessibilityservice.GestureDescription.Builder()
                    .addStroke(android.accessibilityservice.GestureDescription.StrokeDescription(path, 0, 60)).build()
                val latch = java.util.concurrent.CountDownLatch(1)
                service.dispatchGesture(gesture, object : android.accessibilityservice.AccessibilityService.GestureResultCallback() {
                    override fun onCompleted(g: android.accessibilityservice.GestureDescription?) { latch.countDown() }
                    override fun onCancelled(g: android.accessibilityservice.GestureDescription?) { latch.countDown() }
                }, Handler(Looper.getMainLooper()))
                latch.await(3, java.util.concurrent.TimeUnit.SECONDS)
            } else {
                Actuator(service, overlay).let { act -> act.tap(button.first, button.second).also { act.close() } }
            }
        } finally { overlay.debugIgnoreInjectGuard = false }
        thread.join(12_000)
        return "button=${button.first},${button.second} sent=$sent relax=$relax decision=${result[0]} guard=${overlay.lastGuardVerdict}"
    }

    /** The native half of `finishTask`: close, then (app in the background) reopen and wait to see it. */
    private fun finish(session: String?, host: String?, reopen: Boolean): String {
        val control = PhoneControl.get(service)
        val closed = control.finishTask()
        if (!closed || !reopen || AppVisibility.visible) return "closed=$closed opened=${AppVisibility.visible} launched=false"
        val launched = control.reopen(session, host)
        val deadline = SystemClock.uptimeMillis() + 3_000
        while (launched && !AppVisibility.visible && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(50)
        return "closed=true opened=${AppVisibility.visible} launched=$launched after=${3_000 - (deadline - SystemClock.uptimeMillis())}ms"
    }

    /** Every window the service sees and whether its root can be fetched (null-root diagnosis). */
    private fun windows(): String {
        val sb = StringBuilder()
        val active = service.rootInActiveWindow
        sb.append("rootInActiveWindow: window=${active?.windowId} pkg=${active?.packageName} children=${active?.childCount}\n")
        for (w in service.windows.sortedByDescending { it.layer }) {
            val root = w.root
            sb.append("id=${w.id} type=${w.type} layer=${w.layer} active=${w.isActive} focused=${w.isFocused} title=${w.title} ")
            sb.append("root=${if (root == null) "NULL" else "${root.packageName} children=${root.childCount} visible=${root.isVisibleToUser}"}\n")
        }
        return sb.toString()
    }

    companion object {
        private const val TAG = "DshA11yProbe"
        const val ACTION = "com.skyjjgw.independent.ski.dshgo.A11Y_PROBE"
    }
}
