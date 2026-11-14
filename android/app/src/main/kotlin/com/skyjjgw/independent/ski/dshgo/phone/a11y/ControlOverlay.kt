// Portions derived from Phase (https://github.com/CikeSeven/phase), used with the author's permission. See THIRD_PARTY_NOTICES.md.
// Local changes: a status control in the lower middle in three forms (ball, capsule, card) on one
// morphing surface; a beam round the screen's edge while it shows; separate confirm and handoff
// cards; buttons that refuse injected or obscured touches; pass-through and hide hooks for the
// Actuator and screenshots; blocking UserGate calls.

package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.i18n.AppStrings
import com.skyjjgw.independent.ski.R
import com.skyjjgw.independent.ski.dshgo.phone.background.BackgroundPreview
import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.content.res.Resources
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextUtils
import android.text.style.RelativeSizeSpan
import android.text.style.StyleSpan
import android.util.DisplayMetrics
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.Surface
import android.view.View
import android.view.ViewTreeObserver
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.skyjjgw.independent.ski.dshgo.phone.ConfirmRequest
import com.skyjjgw.independent.ski.dshgo.phone.Decision
import com.skyjjgw.independent.ski.dshgo.links.LinkTrampolineActivity
import com.skyjjgw.independent.ski.dshgo.phone.HandoffCause
import com.skyjjgw.independent.ski.dshgo.phone.HandoffResult
import com.skyjjgw.independent.ski.dshgo.phone.PhoneControl
import com.skyjjgw.independent.ski.dshgo.phone.PhoneRegistry
import com.skyjjgw.independent.ski.dshgo.phone.PhoneUnlocks
import com.skyjjgw.independent.ski.dshgo.phone.UserGate
import com.skyjjgw.independent.ski.dshgo.phone.PhonePromptPresenter
import com.skyjjgw.independent.ski.dshgo.phone.PhonePromptUi
import com.skyjjgw.independent.ski.dshgo.phone.PromptPresentation
import com.skyjjgw.independent.ski.dshgo.phone.MainThreadCall
import com.skyjjgw.independent.ski.dshgo.pet.SafeArea
import com.skyjjgw.independent.ski.dshgo.pet.WindowPos
import com.skyjjgw.independent.ski.dshgo.theme.ThemeAccent
import android.animation.ValueAnimator
import android.graphics.Rect
import android.view.accessibility.AccessibilityWindowInfo
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The main-screen [UserGate]: TYPE_ACCESSIBILITY_OVERLAY windows owned by the service
 * (no SYSTEM_ALERT_WINDOW). Blocking calls come from the bridge worker; all views live on
 * the main thread.
 *
 * While a task runs the person sees one control in the lower middle of the screen, in three forms
 * (docs/design/phone-overlay.md): the capsule with the line and 暂停 / 停止 ([OverlayCapsule]),
 * the card it grows up into, and the ball it folds into ([OverlayBall]), with a beam of light
 * round the screen's edge ([EdgeBeam]). [FoldClock] decides the form; this class plays the morphs
 * between them, keeps the control clear of the keyboard and the confirm card, and keeps 停止 one
 * step away in every form.
 */
internal class ControlOverlay(private val service: AccessibilityService) : UserGate, PhonePromptPresenter {
    private val main = Handler(Looper.getMainLooper())
    private val wm = service.getSystemService(WindowManager::class.java)
    private val a11y = service.getSystemService(AccessibilityManager::class.java)
    private val ime = service.getSystemService(InputMethodManager::class.java)

    /** 暂停 is on: the driver refuses actions until 继续. */
    @Volatile var paused = false
        private set

    /** The person is typing into 插话: actions wait so the keyboard isn't fought over. */
    @Volatile var editing = false
        private set

    /** Debug probe only: draw in the dark (true) or light (false) palette whatever the system says. */
    @Volatile var debugDark: Boolean? = null

    /** Debug probe only: show these lifted limits instead of the person's. */
    @Volatile var debugUnlocks: PhoneUnlocks? = null

    /** Debug probe only: the task's app, as the core would have set it. */
    @Volatile var debugApp: String? = null

    /** Debug probe only: no timer changes the form (screenshots of the card). */
    @Volatile var debugFreeze = false

    /** Debug probe only: let an injected tap reach a guarded button to observe the other checks. */
    @Volatile var debugIgnoreInjectGuard = false

    /** Last guarded-button verdict, for the debug probe. */
    @Volatile var lastGuardVerdict: String? = null
        private set

    // ---- main-thread state ----
    private var statusText: String? = null
    private val statusOwnership = StatusOwnership()
    private var line: StatusLine? = null
    private val steps = StepHistory()
    private var stoppedNote = false

    /** 「已发给 DSH：…」 for a moment after 插话, in the line's place. */
    private var steerNote: String? = null
    private var pill: OverlayCapsule? = null
    private val previewOwner = Any()
    private var previewTaskId: Long? = null
    private var previewPill: OverlayCapsule? = null
    @Volatile private var destroying = false
    private val previewDecoder = OverlayPreviewDecoder { bitmap ->
        val target = previewPill
        if (target == null || destroying) bitmap?.recycle()
        else target.showPreview(bitmap, s(if (bitmap == null) R.string.overlay_preview_unavailable else R.string.overlay_preview_readonly))
    }
    private var confirmCard: Card? = null
    private var handoffCard: Card? = null
    private var pendingConfirm: Pending<Decision>? = null
    private var pendingHandoff: Pending<HandoffResult>? = null
    @Volatile private var sharedPrompt: PromptPresentation? = null
    private var passThrough = false
    private val captureVisibility = CaptureVisibility()
    private val captureHidden: Boolean get() = captureVisibility.hidden
    private var darkBuilt: Boolean? = null

    // The form: FoldClock decides, the morphs follow.
    private val fold = FoldClock()
    private var ball: OverlayBall? = null

    /** The beam round the screen's edge, on exactly while the control shows for a live task (§12). */
    private val beam = EdgeBeam(service, wm)

    /** The top of a keyboard on screen (any app's, or 插话's), from the service's windows; null when none shows. */
    private var imeTop: Int? = null
    private val imeRect = Rect()

    /** The capsule moving up over (or back down from) the keyboard or the confirm card. */
    private var lift: ValueAnimator? = null

    /** The confirm card's height settled or changed: the capsule and a resting ball keep clear of it. */
    private val obstacleWatch = View.OnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
        if (bottom - top != oldBottom - oldTop) main.post { avoidObstacles() }
    }

    /** What is on screen: the capsule (or card), or the ball (lags [fold] while a fold or unfold plays). */
    private var ballShown = false

    /** The ball is gliding back to the capsule's end; its glide's end swaps the windows. A finger stops it. */
    private var unfolding = false
    private val foldTick = Runnable { onFoldTick() }

    /** A narrower line may shrink the capsule now. */
    private val shrinkTick = Runnable { renderPill() }

    // 闲置时不透明度 (the ball's) and 「闲置时自动收起」 (设置 → 手机操控 → 悬浮条), live while showing.
    private val overlayPrefs = OverlayPrefs.prefs(service)
    private var idleOpacity = OverlayPrefs.from(overlayPrefs).idleOpacity
    private val prefsListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == OverlayPrefs.K_OPACITY || key == OverlayPrefs.K_AUTO_FOLD) main.post { onPrefsChanged() }
    }

    init {
        fold.setAutoFold(OverlayPrefs.from(overlayPrefs).autoFold, SystemClock.uptimeMillis())
        overlayPrefs.registerOnSharedPreferenceChangeListener(prefsListener)
    }

    private class Pending<T : Any> {
        private val latch = CountDownLatch(1)
        @Volatile var value: T? = null
            private set

        fun resolve(v: T): Boolean {
            synchronized(this) { if (value != null) return false; value = v }
            latch.countDown()
            return true
        }

        fun await(ms: Long): T? { latch.await(ms, TimeUnit.MILLISECONDS); return value }
    }

    private class Card(val root: FrameLayout, val params: WindowManager.LayoutParams, val tick: Runnable?)

    // ---- UserGate --------------------------------------------------------------------------------

    override fun status(text: String?) = status(text) { update -> update(); true }

    override fun status(text: String?, ifCurrent: (() -> Unit) -> Boolean) {
        main.post {
            // This runnable and close apply on the same queue. Never hold the task lock
            // over WindowManager work or enqueue a second, unguarded status runnable.
            // The pill's 暂停 / 停止 / 插话 are bound to this status's own task, captured inside its guard.
            if (!statusOwnership.publish(ifCurrent) { PhoneRegistry.controlListener?.shownControls() }) return@post
            if (editing && statusOwnership.editingControls == null) endEditing()
            statusText = text
            paused = statusOwnership.controls?.isPaused() == true
            setStopped(false)
            if (text == null) {
                statusOwnership.clear()
                paused = false
                line = null
                steps.clear()
                removePill(animated = true, preservePrompts = true)
            } else {
                val l = StatusLines(AppStrings.get(service, R.string.phone_waived_status), AppStrings.get(service, R.string.phone_acting)).parse(text)
                line = l
                steps.add(l)
                showPill()
            }
        }
    }

    override fun clearStatus(ifCurrent: (() -> Unit) -> Unit) {
        main.post {
            // The displayed status can be stale even if this cleanup request lost selection.
            // Prompt cards and their CONFIRM/HANDOFF holds belong to separate tickets.
            val stale = statusOwnership.takeStale()
            var accepted = false
            ifCurrent { accepted = true }
            if (stale || accepted) {
                statusOwnership.clear()
                statusText = null
                line = null
                steps.clear()
                setStopped(false)
                paused = false
                removePill(animated = true, preservePrompts = true)
            }
        }
    }

    /** The turn that drove the phone is over: every window goes, pending questions answer STOP. */
    override fun close(ifCurrent: (() -> Unit) -> Unit) {
        val shared = sharedPrompt
        val confirm = pendingConfirm
        val handoff = pendingHandoff
        main.post {
            // A -> stop -> B can invalidate A's cleanup ticket while A's status is
            // still displayed. Retire that status by its own owner, without touching B's cards.
            if (statusOwnership.takeStale()) {
                statusText = null
                line = null
                steps.clear()
                setStopped(false)
                removePill(animated = false, preservePrompts = true)
            }
            var cleanupCurrent = false
            ifCurrent { cleanupCurrent = true }
            if (cleanupCurrent) {
                // A new pre-tool engine prompt can share an inactive task id. Remove only the
                // questions captured by this cleanup, even when the task itself has not started.
                if (sharedPrompt === shared) {
                    shared?.ticket?.stop()
                    if (shared != null) { sharedPrompt = null; dismissConfirm() }
                }
                if (sharedPrompt == null && pendingConfirm === confirm) {
                    confirm?.resolve(Decision.STOP)
                    dismissConfirm()
                }
                if (pendingHandoff === handoff) {
                    handoff?.resolve(HandoffResult.STOP)
                    dismissHandoff()
                }
                statusOwnership.clear()
                statusText = null
                line = null
                steps.clear()
                setStopped(false)
                paused = false
                removePill(animated = true)
            }
        }
    }

    override fun confirm(request: ConfirmRequest): Decision {
        PhoneRegistry.promptGate?.let { return it.confirm(request) }
        if (Looper.myLooper() == Looper.getMainLooper()) { Log.w(TAG, "confirm() on the main thread: denied"); return Decision.DENY }
        val pending = Pending<Decision>()
        val shown = onMain(1_500) { showConfirm(request, pending) } == true
        if (!shown) {
            pending.resolve(Decision.UNAVAILABLE)
            main.post { if (pendingConfirm === pending) dismissConfirm() }
            Log.w(TAG, "confirm overlay could not be shown; falling back to the notification gate")
            return PhoneRegistry.notificationGate?.confirm(request) ?: Decision.DENY
        }
        val decision = try {
            pending.await(request.timeoutMs + 1_500) ?: run { pending.resolve(Decision.DENY); pending.value!! }
        } catch (_: InterruptedException) {
            // The core's stop interrupts the worker: answer STOP and keep the flag for the caller.
            pending.resolve(Decision.STOP)
            Thread.currentThread().interrupt()
            pending.value!!
        }
        main.post { if (pendingConfirm === pending) dismissConfirm() }
        return decision
    }

    override fun handoff(reason: String, timeoutMs: Long): HandoffResult = handoff(reason, timeoutMs, null)

    override fun handoff(reason: String, timeoutMs: Long, cause: HandoffCause?): HandoffResult {
        PhoneRegistry.promptGate?.let { return it.handoff(reason, timeoutMs, cause) }
        if (Looper.myLooper() == Looper.getMainLooper()) return HandoffResult.STOP
        val limit = timeoutMs.coerceIn(5_000, 10 * 60_000)
        val pending = Pending<HandoffResult>()
        val shown = onMain(1_500) { showHandoff(reason, limit, pending, cause) } == true
        if (!shown) {
            pending.resolve(HandoffResult.STOP)
            main.post { if (pendingHandoff === pending) dismissHandoff() }
            return PhoneRegistry.notificationGate?.handoff(reason, limit, cause) ?: HandoffResult.STOP
        }
        val result = try {
            pending.await(limit + 1_500) ?: run { pending.resolve(HandoffResult.TIMEOUT); pending.value!! }
        } catch (_: InterruptedException) {
            pending.resolve(HandoffResult.STOP)
            Thread.currentThread().interrupt()
            pending.value!!
        }
        main.post { if (pendingHandoff === pending) dismissHandoff() }
        return result
    }

    // ---- hooks for the driver ---------------------------------------------------------------------

    /** Makes every overlay window untouchable (true) so an injected stroke reaches the app below. */
    fun setPassThrough(on: Boolean) {
        // Cleanup must survive a busy main thread or an interrupted gesture worker.
        // Gesture calls are serialized; this stays ahead of the next queued enable.
        if (!on) { main.post { applyPassThrough(false) }; return }
        if (Looper.myLooper() == Looper.getMainLooper()) { applyPassThrough(on); return }
        val changed = onMain(500) { applyPassThrough(on) } == true
        if (changed) SystemClock.sleep(80) // input windows update a frame after the layout
    }

    /** Paired hides for full-display screenshots; captures may overlap. */
    fun hideForCapture(hide: Boolean) { captureHiddenResult(hide, false) }

    /** Null means the UI hide did not finish normally. An empty set is a normal result.
     * The IDs describe only this operation's invisible attached controls, not compositor pixels.
     * The caller must still pair this with hideForCapture(false), including on interruption. */
    internal fun hideForCaptureWithReceipt(): Set<Int>? = captureHiddenResult(true, true)

    private fun captureHiddenResult(hide: Boolean, includeWindowIds: Boolean): Set<Int>? {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            // The main-thread pet caller schedules its own delay before it shoots.
            applyCaptureHidden(hide)
            return if (includeWindowIds) hiddenWindowIds() else null
        }
        // Both halves run on the main queue in the order they were asked for and are never
        // cancelled: a release can't overtake its own hide, and recovery still runs if the
        // screenshot worker times out or is interrupted.
        val applied = CountDownLatch(1)
        var settle = false
        var windowIds: Set<Int>? = null
        main.post {
            try {
                settle = applyCaptureHidden(hide)
                if (includeWindowIds) windowIds = hiddenWindowIds()
            } catch (e: Exception) { Log.w(TAG, "overlay main-thread call failed", e) }
            finally { applied.countDown() }
        }
        if (!hide || !applied.await(500, TimeUnit.MILLISECONDS)) return null
        if (settle) SystemClock.sleep(120)
        return windowIds
    }

    @Suppress("DEPRECATION")
    private fun hiddenWindowIds(): Set<Int> = buildSet {
        for (root in ownRoots()) {
            val id = runCatching {
                if (!root.isAttachedToWindow || root.visibility == View.VISIBLE) null
                else {
                    val node = root.createAccessibilityNodeInfo()
                    if (node == null) null
                    else try { node.windowId.takeIf { it >= 0 } } finally { node.recycle() }
                }
            }.getOrNull()
            if (id != null) add(id)
        }
    }

    private fun applyCaptureHidden(hide: Boolean): Boolean {
        if (captureVisibility.update(hide)) {
            val v = if (captureHidden) View.INVISIBLE else View.VISIBLE
            syncWindows()
            confirmCard?.root?.visibility = v
            handoffCard?.root?.visibility = v
            beam.setHidden(captureHidden || passThrough)
        }
        return hide && (pill != null || confirmCard != null || handoffCard != null || beam.attached)
    }

    /** Screen off, lock, 停止 elsewhere, service going away: answer everything pending with STOP. */
    fun stopAll() {
        val shared = sharedPrompt
        val confirm = pendingConfirm
        val handoff = pendingHandoff
        shared?.ticket?.stop()
        main.post {
            if (sharedPrompt === shared) {
                if (shared != null) { sharedPrompt = null; dismissConfirm() }
            }
            if (sharedPrompt == null && pendingConfirm === confirm) { confirm?.resolve(Decision.STOP); dismissConfirm() }
            if (pendingHandoff === handoff) { handoff?.resolve(HandoffResult.STOP); dismissHandoff() }
            paused = false
            clearPreview()
            endEditing()
            if (statusText != null) { setStopped(true); renderPill(); clearStoppedLater() }
        }
    }

    /** "已停止" stays briefly; if the core doesn't clear or replace the status, the control (and its KEEP_SCREEN_ON) goes. */
    private fun clearStoppedLater() {
        main.postDelayed({ if (stoppedNote) { statusText = null; line = null; steps.clear(); setStopped(false); paused = false; removePill(animated = true) } }, 4_000)
    }

    /** The 已停止 note: holds the capsule (or the ball) as it is, the card folding back first. */
    private fun setStopped(on: Boolean) {
        stoppedNote = on
        if (on) holdFold(FoldClock.Hold.STOPPED) else releaseFold(FoldClock.Hold.STOPPED)
    }

    /** Debug probe: screen centre of the visible button labelled [label], if any. */
    fun debugButtonCenter(label: String): Pair<Int, Int>? = onMain(1_000) {
        fun find(v: View): View? {
            if ((v is TextView && v.text?.toString() == label) || v.contentDescription?.toString() == label) return v
            if (v is android.view.ViewGroup) for (i in 0 until v.childCount) find(v.getChildAt(i))?.let { return it }
            return null
        }
        val roots = listOfNotNull(confirmCard?.root, handoffCard?.root, pill?.root?.takeIf { it.isShown }, ball?.root?.takeIf { it.isShown })
        roots.firstNotNullOfOrNull { find(it) }?.let { v ->
            val loc = IntArray(2)
            v.getLocationOnScreen(loc)
            (loc[0] + v.width / 2) to (loc[1] + v.height / 2)
        }
    }

    /** Debug probe: puts the control in [form] (ball, capsule, card) as the person's taps would. */
    fun debugForm(form: String) {
        main.post {
            when (form) {
                "ball" -> if (!fold.folded) collapseByHand()
                "capsule" -> if (fold.folded) onBallTapped() else if (fold.expanded) onLineTapped()
                "card" -> if (fold.folded) { onBallTapped(); main.postDelayed({ onLineTapped() }, 700) } else if (!fold.expanded) onLineTapped()
            }
        }
    }

    /** Debug probe: 暂停 / 继续 / 停止 / the steer field, as the keys do. */
    fun debugKey(key: String) {
        main.post {
            when (key) {
                "pause" -> togglePause()
                "stop" -> stopFromPill()
                "steer" -> startSteer()
                "done" -> endEditing()
            }
        }
    }

    /** Debug probe: what the control is showing. */
    fun debugState(): String = onMain(1_000) {
        "form=${fold.form} ballShown=$ballShown shape=${pill?.shape} paused=$paused stopped=$stoppedNote line=${line?.text} " +
            "window=${pill?.params?.let { "${it.width}x${it.height}@${it.y}" }} ball=${ball?.let { "${it.pos}" }} steps=${steps.before(line, 3)}"
    } ?: "timeout"

    fun onConfigurationChanged() {
        main.post {
            val dark = isDark()
            if (darkBuilt != null && darkBuilt != dark) {
                // Rebuild in the new palette; pending questions keep their latches.
                pill?.let { removePill(animated = false); if (statusText != null) showPill() }
            } else {
                pill?.let { p ->
                    imeTop = imeWindowTop()
                    placeCapsule(p)
                    ball?.let { b -> if (ballResting()) b.move(b.dockPos()) }
                }
                beam.relayout()
                confirmCard?.let { place(it.root, it.params, top = false) }
                handoffCard?.let { place(it.root, it.params, top = true) }
            }
        }
    }

    fun destroy() {
        destroying = true
        sharedPrompt?.ticket?.stop()
        pendingConfirm?.resolve(Decision.STOP)
        pendingHandoff?.resolve(HandoffResult.STOP)
        overlayPrefs.unregisterOnSharedPreferenceChangeListener(prefsListener)
        main.post {
            clearPreview()
            dismissConfirm()
            dismissHandoff()
            removePill(animated = false)
        }
    }

    /** Subscription visibility follows the existing card, never the mere existence of its View. */
    private fun syncPreview() {
        val p = pill
        val control = PhoneControl.peek()
        val taskId = if (!destroying && p != null && p.root.isAttachedToWindow && fold.expanded &&
            !ballShown && !captureHidden && !stoppedNote && !waiting() &&
            confirmCard == null && handoffCard == null && pendingHandoff == null)
            control?.liveTask()?.id else null
        if (taskId == previewTaskId && (taskId == null || previewPill === p)) return
        clearPreview()
        if (taskId == null || p == null || control == null) return
        previewTaskId = taskId
        previewPill = p
        control.preview.addConsumer(previewOwner, taskId, BackgroundPreview.ConsumerKind.OVERLAY) { frame ->
            if (destroying || previewTaskId != taskId || previewPill !== p) return@addConsumer
            when (frame["state"]) {
                "frame" -> (frame["imageBytes"] as? ByteArray)?.let(previewDecoder::offer)
                else -> {
                    previewDecoder.clear()
                    val label = when (frame["state"]) {
                        "off" -> null
                        "inUse" -> s(R.string.overlay_preview_in_use)
                        "protected" -> s(R.string.overlay_preview_protected)
                        "waiting" -> s(R.string.overlay_preview_waiting)
                        else -> s(R.string.overlay_preview_unavailable)
                    }
                    p.showPreview(null, label)
                }
            }
        }
    }

    private fun clearPreview() {
        PhoneControl.peek()?.preview?.removeConsumer(previewOwner)
        previewDecoder.clear()
        previewPill?.showPreview(null, null)
        previewPill = null
        previewTaskId = null
    }

    // ---- capsule ----------------------------------------------------------------------------------

    private fun s(id: Int, vararg args: Any): String = AppStrings.get(service, id, *args)

    private fun unlocks(): PhoneUnlocks = debugUnlocks ?: PhoneRegistry.unlocks()

    /** A confirm (or a shared prompt) is up: the line points at it. */
    private fun waiting() = pendingConfirm != null || sharedPrompt != null

    private fun showPill() {
        if (pill == null) {
            darkBuilt = isDark()
            imeTop = imeWindowTop()
            val p = buildPill()
            // The beam's window first, so the control's windows come over it.
            beam.attach(s(R.string.overlay_window_title), isDark(), ThemeAccent.notificationColor(service), captureHidden || passThrough)
            if (!add(p.root, p.params)) { beam.detach(animated = false); return }
            pill = p
            ballShown = false
            fold.start(now())
            syncWindows()
            renderPill(animated = false)
            enter(p.root)
            scheduleFold()
            return
        }
        renderPill()
    }

    /** What the capsule, the card and the ball say now; [animated] cross-fades what changed. */
    private fun renderPill(animated: Boolean = true) {
        val p = pill ?: return
        val base = line ?: return
        val u = unlocks()
        val look = when {
            stoppedNote -> MarkLook.STOPPED
            waiting() -> MarkLook.WAITING
            paused -> MarkLook.PAUSED
            else -> MarkLook.RUNNING
        }
        val text = when {
            stoppedNote -> s(R.string.overlay_stopped)
            waiting() -> s(R.string.overlay_waiting)
            paused -> s(R.string.overlay_paused_short)
            else -> steerNote ?: base.text
        }
        val sep = s(R.string.overlay_meta_separator)
        val app = debugApp ?: PhoneControl.peek()?.liveTask()?.app
        val meta = listOfNotNull(app, if (base.waived) s(R.string.overlay_waived) else null).joinToString(sep).ifEmpty { null }
        val state = CapsuleState(
            line = text,
            look = look,
            paused = paused,
            stopped = stoppedNote,
            expandable = !stoppedNote && !waiting(),
            unlocked = u.any,
            unlockedLine = if (u.any) unlockedLine(u) else null,
            meta = meta,
            steps = steps.before(base, StepHistory.CAPACITY),
        )
        p.render(state, animated && p.root.isShown && !ballShown, now())
        main.removeCallbacks(shrinkTick)
        p.shrinkAt?.let { main.postAtTime(shrinkTick, it + 1) }
        ball?.setLook(
            look,
            s(
                when (look) {
                    MarkLook.STOPPED -> R.string.overlay_ball_stopped
                    MarkLook.WAITING -> R.string.overlay_ball_waiting
                    MarkLook.PAUSED -> R.string.overlay_ball_paused
                    MarkLook.RUNNING -> R.string.overlay_ball_running
                },
            ),
            badge = u.any && !stoppedNote,
            stopLabel = if (stoppedNote) null else s(R.string.overlay_stop_description),
        )
        syncPreview()
        syncBeam()
    }

    /**
     * The edge beam: on while the control shows for a live task (not once 已停止, not while the
     * handoff card has the screen), still and faint while paused, not drawn during a screenshot or
     * an injected stroke.
     */
    private fun syncBeam() {
        beam.set(on = pill != null && !stoppedNote && handoffCard == null, paused = paused)
        beam.setHidden(captureHidden || passThrough)
    }

    /** 「已解除限制」 in bold over what is lifted (「系统设置、密码和验证码」), a size smaller. */
    private fun unlockedLine(u: PhoneUnlocks): CharSequence {
        val names = listOfNotNull(
            if (u.systemPages) s(R.string.overlay_unlock_system) else null,
            if (u.secretFields) s(R.string.overlay_unlock_secrets) else null,
            if (u.ownApp) s(R.string.overlay_unlock_own_app) else null,
        ).joinToString(s(R.string.overlay_list_separator))
        val title = s(R.string.overlay_unlocked)
        return SpannableStringBuilder(title).apply {
            setSpan(StyleSpan(Typeface.BOLD), 0, title.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            append('\n')
            val at = length
            append(names)
            setSpan(RelativeSizeSpan(12f / 13f), at, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }

    /** Takes the control away; [animated]: it fades first (a task that ended, not a rebuild). */
    private fun removePill(animated: Boolean, preservePrompts: Boolean = false) {
        clearPreview()
        val p = pill ?: return
        endEditing()
        main.removeCallbacks(foldTick)
        main.removeCallbacks(shrinkTick)
        lift?.cancel()
        lift = null
        beam.detach(animated && animationsOn())
        fold.reset()
        if (preservePrompts) {
            if (waiting()) fold.hold(FoldClock.Hold.CONFIRM, now())
            if (handoffCard != null) fold.hold(FoldClock.Hold.HANDOFF, now())
        }
        val b = ball
        pill = null
        ball = null
        ballShown = false
        unfolding = false
        steerNote = null
        p.cancelMorph()
        val roots = listOfNotNull(p.root.takeIf { it.isShown }, b?.root?.takeIf { it.isShown })
        if (!animated || !animationsOn() || roots.isEmpty()) {
            remove(p.root)
            b?.detach()
            return
        }
        b?.cancelGlide()
        var left = roots.size
        for (r in roots) {
            r.animate().alpha(0f).scaleX(0.96f).scaleY(0.96f).setDuration(180).setInterpolator(OverlayMotion.emphasized).withEndAction {
                if (--left == 0) { remove(p.root); b?.detach() }
            }.start()
        }
    }

    private fun buildPill(): OverlayCapsule {
        val c = colors()
        val strings = OverlayCapsule.Strings(
            fold = s(R.string.overlay_fold), expand = s(R.string.overlay_expand), collapse = s(R.string.overlay_collapse),
            pause = s(R.string.overlay_pause_description), resume = s(R.string.overlay_resume_description),
            stop = s(R.string.overlay_stop_description), steerHint = s(R.string.overlay_steer_hint), send = s(R.string.overlay_send),
            unlocksDescription = s(R.string.overlay_unlocked_description), review = s(R.string.overlay_unlocks_review),
            foldRow = s(R.string.overlay_fold_row), holdHint = s(R.string.overlay_hold_hint),
        )
        lateinit var capsule: OverlayCapsule
        val actions = object : OverlayCapsule.Actions {
            override fun touched() = onPillTouched()
            override fun mark() = collapseByHand()
            override fun line() = onLineTapped()
            override fun pause() = togglePause()
            override fun stop() = stopFromPill()
            override fun unlocks() = openUnlocks()
            override fun steer() = startSteer()
            override fun send() = sendInterjection()
            override fun inputDone() = endEditing()
        }
        capsule = OverlayCapsule(service, c, strings, actions) { update(capsule.root, capsule.params) }
        capsule.root.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(view: View) = Unit
            override fun onViewDetachedFromWindow(view: View) {
                if (previewPill === capsule) clearPreview()
            }
        })
        // Hung from the bottom: the card grows up out of it and the header stays put.
        capsule.params = params(top = false, keepScreenOn = true)
        placeCapsule(capsule)
        return capsule
    }

    /** Centred in the lower middle, clear of the bars, a keyboard and the confirm card ([CapsulePlacement]); sizes for this screen. */
    private fun placeCapsule(p: OverlayCapsule) {
        val a = safeArea()
        lift?.cancel()
        lift = null
        p.params.y = capsuleY(p, a)
        p.place(a.screenW, a.screenH)
        update(p.root, p.params)
    }

    /** The capsule's centre y with nothing in the way: where a ball the person never moved rests too. */
    private fun capsuleCentre(a: SafeArea = safeArea(), obstacle: Int? = null) =
        CapsulePlacement.centreY(a, dp(CapsuleMetrics.HEIGHT_DP), dp(CapsulePlacement.GAP_DP), obstacle)

    /** The capsule window's offset clear of what is in the way; the card's room above it follows. */
    private fun capsuleY(p: OverlayCapsule, a: SafeArea): Int {
        val headerH = dp(CapsuleMetrics.HEIGHT_DP)
        val centre = capsuleCentre(a, obstacleTop())
        p.maxCardHeight = CapsulePlacement.cardRoom(a, centre, headerH, dp(CapsulePlacement.GAP_DP))
        return CapsulePlacement.windowY(a.screenH, centre, headerH, p.padBottom)
    }

    /** The higher of a keyboard's top and the confirm card's, on screen; null when neither shows. */
    private fun obstacleTop(): Int? = listOfNotNull(imeTop, confirmTop()).minOrNull()

    private fun confirmTop(): Int? {
        val card = confirmCard ?: return null
        val h = card.root.height.takeIf { it > 0 } ?: return null
        return CapsulePlacement.windowTop(safeArea().screenH, card.params.y, h)
    }

    /** The top of the keyboard window on screen, if one shows. */
    private fun imeWindowTop(): Int? = runCatching {
        service.windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }?.let { w ->
            w.getBoundsInScreen(imeRect)
            imeRect.top.takeIf { !imeRect.isEmpty }
        }
    }.getOrNull()

    /** The service's windows changed: a keyboard may have come or gone. */
    fun onWindowsChanged() {
        if (pill == null) return
        val top = imeWindowTop()
        if (top == imeTop) return
        imeTop = top
        avoidObstacles()
    }

    /** A keyboard or the confirm card came, went or changed height: the capsule glides over it or back, a resting ball too. */
    private fun avoidObstacles() {
        val p = pill ?: return
        val to = capsuleY(p, safeArea())
        lift?.cancel()
        lift = null
        if (to != p.params.y) {
            if (!animationsOn() || !p.root.isShown) {
                p.params.y = to
                update(p.root, p.params)
            } else {
                lift = ValueAnimator.ofInt(p.params.y, to).apply {
                    duration = OverlayMotion.RESIZE_MS
                    interpolator = OverlayMotion.glide
                    addUpdateListener { a -> p.params.y = a.animatedValue as Int; update(p.root, p.params) }
                    start()
                }
            }
        }
        ball?.let { b -> if (ballResting()) b.glideTo(b.dockPos(), animationsOn()) }
    }

    /**
     * The ball is the form on screen and not on its way back into the capsule: an unfold's glide
     * ends in the window swap, so nothing may move it (moving cancels the glide, and the swap with it).
     */
    private fun ballResting() = ballShown && !unfolding

    /** The 「已解除限制」 row: 设置 › 手机操控 › 解除限制, through the app's own page link. */
    private fun openUnlocks() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(UNLOCKS_LINK))
            .setClass(service, LinkTrampolineActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try { service.startActivity(intent) } catch (e: Exception) { Log.w(TAG, "unlocks page: ${e.javaClass.simpleName}") }
    }

    private fun togglePause() {
        if (stoppedNote) return
        val controls = statusOwnership.controls ?: return
        val next = !controls.isPaused()
        if (!controls.setPaused(next)) {
            announce(s(R.string.overlay_control_rejected))
            return
        }
        paused = next
        renderPill()
        announce(s(if (paused) R.string.overlay_paused_short else R.string.overlay_resume_description))
    }

    /** Stop only the displayed task; its native owner chain cancels its own prompt tickets. */
    private fun stopFromPill() {
        if (stoppedNote) return
        val controls = statusOwnership.controls ?: return
        // l10n:keep agent stop reason
        if (!controls.stop("你在悬浮条上点了停止")) {
            announce(s(R.string.overlay_control_rejected))
            return
        }
        paused = false
        endEditing()
        setStopped(true)
        renderPill()
        clearStoppedLater()
        announce(s(R.string.overlay_stopped))
    }

    private fun announce(text: String) {
        val v = if (ballShown) ball?.root else pill?.root
        if (a11y.isEnabled) v?.announceForAccessibility(text)
    }

    /** The line: the capsule opens into the card, the card closes. */
    private fun onLineTapped() {
        val p = pill ?: return
        if (stoppedNote || ballShown) return
        if (fold.expanded) {
            endEditing()
            if (fold.collapse(now())) p.collapse(animationsOn())
        } else if (fold.expand(now())) {
            applyIdle(animated = true)
            renderPill(animated = false)
            p.expand(animationsOn())
        }
        scheduleFold()
    }

    /** The steer field in the card: the window takes the keyboard until the text goes or is sent. */
    private fun startSteer() {
        val p = pill ?: return
        if (stoppedNote || !fold.expanded || editing || !statusOwnership.beginEditing()) return
        editing = true
        holdFold(FoldClock.Hold.EDITING)
        p.params.flags = p.params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
        update(p.root, p.params)
        p.startEditing()
        p.input.post { if (editing) ime.showSoftInput(p.input, InputMethodManager.SHOW_IMPLICIT) }
    }

    private fun endEditing() {
        statusOwnership.endEditing()
        val p = pill
        p?.input?.setText("")
        p?.input?.error = null
        if (p != null && (editing || p.editing)) {
            ime.hideSoftInputFromWindow(p.input.windowToken, 0)
            p.stopEditing()
            if (p.params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE == 0) {
                p.params.flags = p.params.flags or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                update(p.root, p.params)
            }
        }
        editing = false
        releaseFold(FoldClock.Hold.EDITING)
    }

    private fun sendInterjection() {
        val p = pill ?: return
        val text = p.input.text?.toString()?.trim().orEmpty()
        if (text.isEmpty()) return
        val controls = statusOwnership.editingControls
        if (controls == null || !controls.interject(text)) {
            val failure = s(R.string.overlay_steer_rejected)
            p.input.error = failure
            announce(failure)
            return
        }
        p.input.error = null
        endEditing()
        val note = s(R.string.overlay_steer_sent, text)
        steerNote = note
        // Back to the capsule: the note shows where the line is.
        if (fold.collapse(now())) p.collapse(animationsOn())
        renderPill()
        scheduleFold()
        main.postDelayed({ if (pill === p && steerNote == note) { steerNote = null; renderPill() } }, 2_500)
    }

    // ---- confirm --------------------------------------------------------------------------------

    /** Called only by the shared main-thread coordinator; no blocking or implicit fallback. */
    override fun showPrompt(presentation: PromptPresentation): (() -> Unit)? {
        val p = presentation
        if (Looper.myLooper() != Looper.getMainLooper() || !p.live || confirmCard != null || handoffCard != null) return null
        val root = FrameLayout(service).apply {
            setPadding(dp(6), dp(6), dp(6), dp(6))
            addView(PhonePromptUi.card(service, p), FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))
        }
        showWindow(root)
        val layout = params(top = false, keepScreenOn = true)
        place(root, layout, top = false)
        if (!p.live || !add(root, layout)) return null
        if (!p.markShown()) { remove(root); return null }
        sharedPrompt = p
        confirmCard = Card(root, layout, null)
        root.addOnLayoutChangeListener(obstacleWatch)
        holdFold(FoldClock.Hold.CONFIRM)
        renderPill()
        return {
            if (sharedPrompt === p) {
                sharedPrompt = null
                dismissConfirm()
            }
            p.retire()
        }
    }

    private fun showConfirm(request: ConfirmRequest, pending: Pending<Decision>): Boolean {
        if (sharedPrompt != null || pending.value != null) return false
        pendingConfirm?.resolve(Decision.DENY)
        dismissConfirm()
        val c = colors()
        darkBuilt = isDark()
        val deadline = SystemClock.uptimeMillis() + request.timeoutMs
        val root = FrameLayout(service).apply { setPadding(dp(6), dp(8), dp(6), dp(6)); clipToPadding = false }
        val card = LinearLayout(service).apply {
            orientation = LinearLayout.VERTICAL
            background = surface(c, dp(24).toFloat())
            elevation = dp(8).toFloat()
            setPadding(dp(18), dp(16), dp(18), dp(14))
        }
        val head = LinearLayout(service).apply { gravity = Gravity.CENTER_VERTICAL }
        val app = request.appLabel?.takeIf { it.isNotBlank() }
        head.addView(TextView(service).apply {
            text = if (request.firstInApp && app != null) AppStrings.get(service, R.string.overlay_first_app, app) else AppStrings.get(service, R.string.overlay_action_title)
            textSize = 12f; setTextColor(c.accent); typeface = Typeface.DEFAULT_BOLD
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        val countdown = TextView(service).apply { textSize = 12f; setTextColor(c.muted) }
        head.addView(countdown)
        card.addView(head)
        val body = TextView(service).apply {
            text = request.sentence
            textSize = 16f; setTextColor(c.ink); setLineSpacing(0f, 1.3f)
            setPadding(0, dp(8), 0, dp(4))
        }
        card.addView(ScrollView(service).apply { addView(body); isVerticalScrollBarEnabled = false },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        card.addView(TextView(service).apply {
            text = if (request.offerTaskWaiver) {
                AppStrings.get(service, R.string.overlay_waiver_hint)
            } else {
                AppStrings.get(service, R.string.overlay_timeout_hint)
            }
            textSize = 12f; setTextColor(c.faint); setLineSpacing(0f, 1.2f); setPadding(0, 0, 0, dp(10))
        })

        val armedAt = SystemClock.uptimeMillis() + ARM_MS
        val guarded = mutableListOf<GuardedButton>()
        fun decide(d: Decision) { if (pending.resolve(d)) main.post { if (pendingConfirm === pending) dismissConfirm() } }
        // 本任务免确认: the main choice waives the rest of the task. Otherwise, on the first action
        // in an app, the main choice allows that app for the rest of the task so later steps there
        // don't ask again. "Only this step" stays available as the quieter option either way.
        val wide = request.visualScope != null || request.offerTaskWaiver || request.firstInApp
        if (request.visualScope != null) {
            val visual = GuardedButton(service, armedAt).apply {
                text = AppStrings.get(service, R.string.phone_prompt_allow_visual)
                style(this, c.accent, c.onAccent, c)
                setOnClickListener { decide(Decision.ALLOW_VISUAL_FOR_TASK) }
            }
            guarded += visual
            card.addView(visual, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(46)).apply { bottomMargin = dp(8) })
        } else if (request.offerTaskWaiver) {
            val all4task = GuardedButton(service, armedAt).apply {
                text = AppStrings.get(service, R.string.overlay_allow_remaining)
                style(this, c.accent, c.onAccent, c)
                setOnClickListener { decide(Decision.ALLOW_ALL_FOR_TASK) }
            }
            guarded += all4task
            card.addView(all4task, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(46)).apply { bottomMargin = dp(8) })
        } else if (request.firstInApp) {
            val app4task = GuardedButton(service, armedAt).apply {
                text = if (app != null) AppStrings.get(service, R.string.overlay_allow_app_task, app) else AppStrings.get(service, R.string.overlay_allow_this_app_task)
                style(this, c.accent, c.onAccent, c)
                setOnClickListener { decide(Decision.ALLOW_APP_FOR_TASK) }
            }
            guarded += app4task
            card.addView(app4task, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(46)).apply { bottomMargin = dp(8) })
        }
        val row = LinearLayout(service).apply { gravity = Gravity.CENTER_VERTICAL }
        row.addView(textButton(AppStrings.get(service, R.string.overlay_stop), c.danger, c) { decide(Decision.STOP) })
        row.addView(View(service), LinearLayout.LayoutParams(0, 1, 1f))
        row.addView(textButton(AppStrings.get(service, R.string.overlay_decline), c.ink, c) { decide(Decision.DENY) }.apply { background = outlined(c) },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(46)).apply { marginEnd = dp(8) })
        val allow = GuardedButton(service, armedAt).apply {
            text = if (wide) AppStrings.get(service, R.string.overlay_allow_step) else AppStrings.get(service, R.string.overlay_allow_once)
            if (wide) style(this, c.accentSoft, c.onAccentSoft, c) else style(this, c.accent, c.onAccent, c)
            setOnClickListener { decide(Decision.ALLOW_ONCE) }
        }
        guarded += allow
        row.addView(allow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(46)))
        card.addView(row)
        root.addView(card, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))

        guarded.forEach { it.alpha = 0.5f }
        main.postDelayed({ guarded.forEach { it.animate().alpha(1f).setDuration(120).start() } }, ARM_MS)

        val tick = object : Runnable {
            override fun run() {
                val left = deadline - SystemClock.uptimeMillis()
                if (left <= 0) { decide(Decision.DENY); return }
                countdown.text = AppStrings.plural(service, R.plurals.overlay_seconds, ((left + 999) / 1000).toInt(), (left + 999) / 1000)
                main.postDelayed(this, 1_000)
            }
        }
        showWindow(root)
        val params = params(top = false, keepScreenOn = true)
        place(root, params, top = false)
        if (!add(root, params)) return false
        if (pending.value != null) { remove(root); return false }
        confirmCard = Card(root, params, tick)
        root.addOnLayoutChangeListener(obstacleWatch)
        pendingConfirm = pending
        tick.run()
        enter(root)
        holdFold(FoldClock.Hold.CONFIRM)
        renderPill()
        return true
    }

    private fun dismissConfirm() {
        val card = confirmCard ?: return
        card.tick?.let(main::removeCallbacks)
        card.root.removeOnLayoutChangeListener(obstacleWatch)
        remove(card.root)
        confirmCard = null
        pendingConfirm = null
        releaseFold(FoldClock.Hold.CONFIRM)
        renderPill()
        avoidObstacles()
    }

    // ---- handoff --------------------------------------------------------------------------------

    private fun showHandoff(reason: String, timeoutMs: Long, pending: Pending<HandoffResult>, cause: HandoffCause?): Boolean {
        if (sharedPrompt != null || pending.value != null) return false
        pendingHandoff?.resolve(HandoffResult.STOP)
        dismissHandoff()
        val c = colors()
        darkBuilt = isDark()
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        val root = FrameLayout(service).apply { setPadding(dp(6), dp(4), dp(6), dp(8)); clipToPadding = false }
        val card = LinearLayout(service).apply {
            orientation = LinearLayout.VERTICAL
            background = surface(c, dp(22).toFloat())
            elevation = dp(8).toFloat()
            setPadding(dp(18), dp(14), dp(14), dp(10))
        }
        val head = LinearLayout(service).apply { gravity = Gravity.CENTER_VERTICAL }
        head.addView(TextView(service).apply {
            text = cause?.let { PhonePromptUi.handoffCause(service, it) } ?: AppStrings.get(service, R.string.overlay_handoff_title)
            textSize = 12f; setTextColor(c.accent); typeface = Typeface.DEFAULT_BOLD
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        val countdown = TextView(service).apply { textSize = 12f; setTextColor(c.muted) }
        head.addView(countdown)
        card.addView(head)
        card.addView(TextView(service).apply {
            text = reason; textSize = 15f; setTextColor(c.ink); maxLines = 4; ellipsize = TextUtils.TruncateAt.END
            setLineSpacing(0f, 1.25f); setPadding(0, dp(6), 0, dp(2))
        })
        card.addView(TextView(service).apply {
            text = AppStrings.get(service, R.string.overlay_handoff_hint); textSize = 12f; setTextColor(c.faint); setPadding(0, 0, 0, dp(6))
        })
        fun finish(r: HandoffResult) { if (pending.resolve(r)) main.post { if (pendingHandoff === pending) dismissHandoff() } }
        val row = LinearLayout(service).apply { gravity = Gravity.CENTER_VERTICAL }
        row.addView(textButton(AppStrings.get(service, R.string.overlay_stop), c.danger, c) { finish(HandoffResult.STOP) })
        row.addView(View(service), LinearLayout.LayoutParams(0, 1, 1f))
        val armedAt = SystemClock.uptimeMillis() + ARM_MS
        val go = GuardedButton(service, armedAt).apply {
            text = AppStrings.get(service, R.string.overlay_continue)
            style(this, c.accent, c.onAccent, c)
            setOnClickListener { finish(HandoffResult.CONTINUE) }
        }
        row.addView(go, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(44)))
        card.addView(row)
        root.addView(card, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))

        val tick = object : Runnable {
            override fun run() {
                val left = deadline - SystemClock.uptimeMillis()
                if (left <= 0) { finish(HandoffResult.TIMEOUT); return }
                val s = (left + 999) / 1000
                countdown.text = if (s >= 60) AppStrings.get(service, R.string.overlay_time_remaining, "${s / 60}:${"%02d".format(s % 60)}") else AppStrings.plural(service, R.plurals.overlay_seconds_remaining, s.toInt(), s)
                main.postDelayed(this, 1_000)
            }
        }
        showWindow(root)
        val params = params(top = true, keepScreenOn = true)
        place(root, params, top = true)
        if (!add(root, params)) return false
        if (pending.value != null) { remove(root); return false }
        handoffCard = Card(root, params, tick)
        pendingHandoff = pending
        // The card says it all: capsule and ball step aside, and the capsule comes back after.
        holdFold(FoldClock.Hold.HANDOFF)
        syncWindows()
        tick.run()
        enter(root)
        return true
    }

    private fun dismissHandoff() {
        val card = handoffCard ?: return
        card.tick?.let(main::removeCallbacks)
        remove(card.root)
        handoffCard = null
        pendingHandoff = null
        syncWindows()
        releaseFold(FoldClock.Hold.HANDOFF)
    }

    // ---- guarded buttons ------------------------------------------------------------------------

    /**
     * A confirm button that only real fingers can press:
     *  - not in its first [ARM_MS] (a tap already in flight when the card appeared);
     *  - not while this service is injecting a gesture (InjectGuard);
     *  - not when the touch came through another window on top (tapjacking, FLAG_WINDOW_IS_OBSCURED);
     *  - ACTION_CLICK from an accessibility service only while touch exploration (TalkBack) is on,
     *    and never while this service is acting itself.
     * And the Actuator makes the overlay untouchable for every stroke it injects.
     * Event fields don't decide: on OPPO / realme a real finger arrives with device -1 and flags
     * 0x800, like our own dispatchGesture tap (#608, #296), so guessing from them locked real users
     * out. What the card guards against is the assistant, and every input it sends is ours and marked
     * (PromptInputPolicy has the full rule).
     */
    private inner class GuardedButton(context: Context, private val armedAt: Long) : TextView(context) {
        private var rejected = false

        init { filterTouchesWhenObscured = true; isClickable = true; isFocusable = true; gravity = Gravity.CENTER }

        override fun dispatchTouchEvent(event: MotionEvent): Boolean {
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                val why = rejectReason(event)
                rejected = why != null
                lastGuardVerdict = "${why ?: "accepted"} flags=0x${Integer.toHexString(event.flags)} device=${event.deviceId} source=0x${Integer.toHexString(event.source)} tool=${event.getToolType(0)}"
                Log.i(TAG, "guarded '$text': $lastGuardVerdict")
            }
            if (rejected) {
                if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) isPressed = false
                return true
            }
            return super.dispatchTouchEvent(event)
        }

        override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
            if ((action == AccessibilityNodeInfo.ACTION_CLICK || action == AccessibilityNodeInfo.ACTION_LONG_CLICK) &&
                (!a11y.isTouchExplorationEnabled || InjectGuard.active() || SystemClock.uptimeMillis() < armedAt)) {
                lastGuardVerdict = "accessibility-action"
                Log.i(TAG, "guarded '$text': refused accessibility click")
                return false
            }
            return super.performAccessibilityAction(action, arguments)
        }

        private fun rejectReason(event: MotionEvent): String? = when {
            SystemClock.uptimeMillis() < armedAt -> "too-early"
            InjectGuard.active() && !debugIgnoreInjectGuard -> "injecting"
            event.flags and MotionEvent.FLAG_WINDOW_IS_OBSCURED != 0 -> "obscured"
            else -> null
        }
    }

    // ---- forms -----------------------------------------------------------------------------------
    //
    // Folding: the surface narrows to the circle at its end on the ball's side, the row fading
    // first; the ball takes its place and glides to its dock. Unfolding: the ball glides back to
    // that end and the capsule grows out of it. Capsule ↔ card: the same surface grows up and
    // out from the header, the body fading in behind (OverlayCapsule). One window shows at a time, except a few
    // frames of overlap at the swap (both are the same circle there), so neither ever blinks.

    private fun now() = SystemClock.uptimeMillis()

    private fun scheduleFold() {
        syncPreview()
        main.removeCallbacks(foldTick)
        if (debugFreeze) return
        val at = fold.nextAt ?: return
        main.postAtTime(foldTick, at)
    }

    private fun onFoldTick() {
        if (debugFreeze) return
        when (fold.tick(now())) {
            FoldClock.Tick.FOLD -> foldPill(animationsOn())
            FoldClock.Tick.COLLAPSE -> pill?.collapse(animationsOn())
            FoldClock.Tick.DIM -> applyIdle(animated = true)
            FoldClock.Tick.NONE -> Unit
        }
        scheduleFold()
    }

    private fun onPillTouched() {
        // A touch on a capsule that is still shrinking into the ball opens it again.
        if (fold.folded && !ballShown) {
            fold.unfold(now())
            pill?.cancelMorph()
        } else if (fold.touch(now())) applyIdle(animated = true)
        scheduleFold()
    }

    private fun onBallTouched() {
        // A finger stops an unfold's glide: the capsule it had brought up (transparent) goes again.
        unfolding = false
        syncWindows()
        fold.touch(now())
        applyIdle(animated = true)
        scheduleFold()
    }

    private fun onBallTapped() {
        if (fold.unfold(now())) unfoldPill(animationsOn())
        applyIdle(animated = true)
        scheduleFold()
    }

    /** The mark (or the card's 收成小球): folded until the ball is tapped, for the rest of this task. */
    private fun collapseByHand() {
        endEditing()
        if (fold.foldByHand(now())) foldPill(animationsOn())
        scheduleFold()
    }

    private fun holdFold(hold: FoldClock.Hold) {
        // A handoff hides both anyway: change form without a show.
        if (fold.hold(hold, now())) syncForm(animationsOn() && hold != FoldClock.Hold.HANDOFF)
        applyIdle(animated = true)
        scheduleFold()
    }

    private fun releaseFold(hold: FoldClock.Hold) {
        fold.release(hold, now())
        scheduleFold()
    }

    /** Brings what is on screen to the form [fold] says. */
    private fun syncForm(animated: Boolean) {
        val p = pill ?: return
        when (fold.form) {
            FoldClock.Form.BALL -> if (!ballShown) foldPill(animated)
            FoldClock.Form.CAPSULE -> when {
                ballShown -> unfoldPill(animated)
                p.shape == OverlayCapsule.Shape.CARD -> { endEditing(); p.collapse(animated) }
            }
            FoldClock.Form.CARD -> if (!ballShown && p.shape != OverlayCapsule.Shape.CARD) p.expand(animated)
        }
    }

    private fun onPrefsChanged() {
        val p = OverlayPrefs.from(overlayPrefs)
        idleOpacity = p.idleOpacity
        fold.setAutoFold(p.autoFold, now())
        // A new 不透明度 shows at once on a faded ball or capsule.
        applyIdle(animated = false)
        scheduleFold()
    }

    /**
     * The ball or the capsule fades, all of it alike, to the idle opacity, or comes back to full:
     * slowly going idle, quickly on a touch. The card never fades. The form not on screen is kept
     * at full, ready for the next fold or unfold.
     */
    private fun applyIdle(animated: Boolean) {
        val target = if (fold.dimmed) idleOpacity else 1f
        val durationMs = if (target < 1f) DIM_FADE_MS else UNDIM_FADE_MS
        ball?.setIdle(if (fold.folded) target else 1f, animated, durationMs)
        pill?.setIdle(if (fold.folded) 1f else target, animated, durationMs)
    }

    /** The ball's window for this control, added (hidden) on first use; null when the system refused it. */
    private fun ensureBall(): OverlayBall? {
        ball?.let { return it }
        val b = OverlayBall(
            service, wm, ::safeArea, colors(), ::onBallTapped, ::stopFromPill, ::onBallTouched,
            capsuleCentre = { capsuleCentre() },
            bottomLimit = { obstacleTop()?.minus(dp(CapsulePlacement.GAP_DP)) },
        )
        if (!b.attach(s(R.string.overlay_window_title), passThrough, b.dockPos())) return null
        ball = b
        renderPill(animated = false)
        return b
    }

    /** The ball window over the surface's circle at ([circle]) in the capsule window. */
    private fun ballOver(p: OverlayCapsule, b: OverlayBall, circle: Pair<Int, Int>): WindowPos {
        val a = safeArea()
        return BallGeometry.ballOver(
            windowX = BallGeometry.centredX(a.screenW, p.params.width),
            windowY = CapsulePlacement.windowTop(a.screenH, p.params.y, p.params.height),
            padX = p.padX, padTop = p.padTop, circleLeft = circle.first, circleTop = circle.second, pad = b.pad,
        )
    }

    private fun foldPill(animated: Boolean) {
        val p = pill ?: return
        if (ballShown) return
        endEditing()
        val b = ensureBall()
        if (b == null) {
            // No second window: the capsule stays as it was.
            fold.unfold(now())
            scheduleFold()
            return
        }
        // Folding is a change worth seeing: at full from here, fading again later.
        applyIdle(animated = false)
        val shown = animated && p.root.isShown && p.surface.width > 0
        if (!shown) {
            p.cancelMorph()
            p.settle(OverlayCapsule.Shape.CAPSULE)
            b.move(b.dockPos())
            b.fadeMark(1f, animated = false)
            ballShown = true
            syncWindows()
            renderPill(animated = false)
            return
        }
        val side = b.dock.side
        b.move(ballOver(p, b, p.endCircle(side)))
        p.foldTo(side, animated = true) {
            ballShown = true
            b.fadeMark(0f, animated = false)
            showWindow(b.root)
            b.fadeMark(1f, animated = true)
            // The capsule goes (and gets its plain layout back) once the ball is surely drawn over it.
            b.root.postDelayed({ if (pill === p && ballShown) { syncWindows(); p.settle(OverlayCapsule.Shape.CAPSULE) } }, SWAP_MS)
            renderPill(animated = false)
            b.glideTo(b.dockPos(), animated = true)
        }
    }

    private fun unfoldPill(animated: Boolean) {
        val p = pill ?: return
        val b = ball
        if (b == null || !ballShown) {
            ballShown = false
            syncWindows()
            renderPill()
            return
        }
        if (!animated || captureHidden || !b.root.isShown) {
            p.settle(OverlayCapsule.Shape.CAPSULE)
            b.move(b.dockPos())
            ballShown = false
            syncWindows()
            renderPill(animated = false)
            return
        }
        // Only the ball shows from here (a fold may have just ended with both up).
        syncWindows()
        val side = b.dock.side
        // The capsule window comes up now, transparent, as the circle the ball is heading for:
        // drawn before the swap, so the morph starts on its first frame instead of popping in late.
        renderPill(animated = false)
        p.prepareUnfold(side)
        p.root.alpha = 0f
        p.root.visibility = if (captureHidden) View.INVISIBLE else View.VISIBLE
        // The ball goes back to the capsule's end first, its mark fading.
        b.fadeMark(0f, animated = true, durationMs = UNFOLD_GLIDE_MS)
        unfolding = true
        b.glideTo(ballOver(p, b, p.capsuleEndCircle(side)), animated = true, durationMs = UNFOLD_GLIDE_MS) {
            unfolding = false
            if (pill !== p || !ballShown) return@glideTo
            ballShown = false
            showWindow(p.root)
            p.unfoldFrom(side, animated = true) {}
            // The ball goes once the capsule is surely drawn over it, back to its dock for next time.
            b.root.postDelayed({
                if (pill === p && !ballShown) { syncWindows(); b.move(b.dockPos()); b.fadeMark(1f, animated = false) }
            }, SWAP_MS)
        }
    }

    /**
     * Capsule and ball visibility from the state: the handoff card hides both, a screenshot makes
     * them invisible for its moment, otherwise the one [ballShown] says. GONE windows take no
     * touches, so the hidden one is never in the way.
     */
    private fun syncWindows() {
        syncPreview()
        syncBeam()
        val p = pill ?: return
        val handoff = handoffCard != null
        val shown = if (captureHidden) View.INVISIBLE else View.VISIBLE
        p.root.visibility = if (handoff || ballShown) View.GONE else shown
        ball?.root?.visibility = if (handoff || !ballShown) View.GONE else shown
    }

    private fun showWindow(root: View) {
        root.alpha = 1f
        root.visibility = if (captureHidden) View.INVISIBLE else View.VISIBLE
    }

    /** The screen and its bars and cutout, in px (the ball's dock is kept clear of them). */
    private fun safeArea(): SafeArea {
        if (Build.VERSION.SDK_INT >= 30) {
            val m = wm.currentWindowMetrics
            val i = m.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            return SafeArea(m.bounds.width(), m.bounds.height(), i.left, i.top, i.right, i.bottom)
        }
        val dm = DisplayMetrics()
        @Suppress("DEPRECATION")
        val display = wm.defaultDisplay
        @Suppress("DEPRECATION")
        display.getRealMetrics(dm)
        val res = Resources.getSystem()
        fun dimen(name: String) = res.getIdentifier(name, "dimen", "android").takeIf { it != 0 }?.let(res::getDimensionPixelSize) ?: 0
        val status = dimen("status_bar_height")
        val nav = dimen("navigation_bar_height")
        return when (display.rotation) {
            Surface.ROTATION_90 -> SafeArea(dm.widthPixels, dm.heightPixels, 0, status, nav, 0)
            Surface.ROTATION_270 -> SafeArea(dm.widthPixels, dm.heightPixels, nav, status, 0, 0)
            else -> SafeArea(dm.widthPixels, dm.heightPixels, 0, status, 0, nav)
        }
    }

    // ---- window plumbing ------------------------------------------------------------------------

    private fun params(top: Boolean, keepScreenOn: Boolean) = WindowManager.LayoutParams(
        WindowManager.LayoutParams.MATCH_PARENT,
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            (if (keepScreenOn) WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON else 0) or
            (if (passThrough) WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE else 0),
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = (if (top) Gravity.TOP else Gravity.BOTTOM) or Gravity.CENTER_HORIZONTAL
        softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING
        title = s(R.string.overlay_window_title)
        if (Build.VERSION.SDK_INT >= 30) setFitInsetsTypes(0)
    }

    /** The confirm and handoff cards: nearly the screen's width, at the top or the bottom. */
    private fun place(root: View, params: WindowManager.LayoutParams, top: Boolean) {
        // Let the window manager lay the window out at the display's real width, then fix the card's
        // own width from what it got. Sizing it from metrics() (WindowManager.getCurrentWindowMetrics)
        // is what made this card 1192 px wide on a 1080 px screen: right after a cold start the
        // service can still hold a configuration from before the display rotated (it reported
        // 2207 × 1080 there), and the window manager's own layout cannot be that stale snapshot.
        params.width = WindowManager.LayoutParams.MATCH_PARENT
        fitCardWidth(root, params, if (top) CardMetrics.HANDOFF_DP else CardMetrics.CONFIRM_DP)
        val (_, insetTop, insetBottom) = metrics()
        params.y = if (top) insetTop + dp(2) else insetBottom + dp(6)
        if (root.isAttachedToWindow) update(root, params)
    }

    /**
     * Shrinks the card window from the display's width to [CardMetrics.windowWidthPx] once the
     * layout knows how wide the display really is, before that frame is drawn. A second
     * configuration change may already have fixed it; then this leaves the width alone.
     */
    private fun fitCardWidth(root: View, params: WindowManager.LayoutParams, capDp: Int) {
        root.viewTreeObserver.addOnPreDrawListener(object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                if (params.width != WindowManager.LayoutParams.MATCH_PARENT) {
                    root.viewTreeObserver.removeOnPreDrawListener(this)
                    return true
                }
                val displayW = root.width
                if (displayW <= 0) return true
                root.viewTreeObserver.removeOnPreDrawListener(this)
                params.width = CardMetrics.windowWidthPx(displayW, service.resources.displayMetrics.density, capDp)
                // This update also schedules the next traversal: the false below cancels the draw,
                // and without a fresh pass a hidden (screenshot) window would stay unsized.
                update(root, params)
                return false // nothing to see at the display's width: draw once it is the card's
            }
        })
    }

    private fun applyPassThrough(on: Boolean): Boolean {
        if (passThrough == on) return false
        passThrough = on
        var any = false
        for ((root, params) in windows()) {
            params.flags = if (on) params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
            else params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
            update(root, params)
            any = true
        }
        // The beam never takes a touch; while a stroke is injected it is not drawn at all.
        if (beam.attached) {
            beam.setHidden(captureHidden || on)
            any = true
        }
        return any
    }

    /** The windows whose touchability follows pass-through (the beam is never touchable). */
    private fun windows(): List<Pair<View, WindowManager.LayoutParams>> = listOfNotNull(
        pill?.let { it.root to it.params }, ball?.let { it.root to it.params },
        confirmCard?.let { it.root to it.params }, handoffCard?.let { it.root to it.params },
    )

    /** Every window of this control, the beam's included. */
    private fun ownRoots(): List<View> = windows().map { it.first } + listOfNotNull(beam.root.takeIf { beam.attached })

    /** Main-thread identity check, including invisible roots during a display capture. */
    internal fun ownsWindow(windowId: Int): Boolean = windowId >= 0 && ownRoots().any { root ->
        if (!root.isAttachedToWindow) return@any false
        val node = root.createAccessibilityNodeInfo() ?: return@any false
        try { node.windowId == windowId } finally { node.recycle() }
    }

    private fun add(view: View, params: WindowManager.LayoutParams): Boolean = try {
        wm.addView(view, params); true
    } catch (e: Exception) { Log.w(TAG, "overlay addView failed", e); false }

    private fun update(view: View, params: WindowManager.LayoutParams) {
        try { if (view.isAttachedToWindow) wm.updateViewLayout(view, params) } catch (e: Exception) { Log.w(TAG, "overlay update failed", e) }
    }

    private fun remove(view: View) {
        try { wm.removeView(view) } catch (_: Exception) {}
    }

    private fun enter(view: View) {
        if (!animationsOn()) return
        view.alpha = 0f
        view.translationY = -dp(6).toFloat()
        view.scaleX = 0.96f
        view.scaleY = 0.96f
        view.animate().alpha(1f).translationY(0f).scaleX(1f).scaleY(1f).setDuration(220).setInterpolator(OverlayMotion.emphasized).start()
    }

    /** Runs [block] on the main thread and waits for it; null on timeout. */
    private fun <T> onMain(timeoutMs: Long, block: () -> T): T? {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val call = MainThreadCall { try { block() } catch (e: Exception) { Log.w(TAG, "overlay main-thread call failed", e); null } }
        main.post { call.run() }
        return call.await(timeoutMs)
    }

    private fun metrics(): Triple<Int, Int, Int> {
        if (Build.VERSION.SDK_INT >= 30) {
            val m = wm.currentWindowMetrics
            val insets = m.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            return Triple(m.bounds.width(), insets.top, insets.bottom)
        }
        val res = Resources.getSystem()
        fun dimen(name: String) = res.getIdentifier(name, "dimen", "android").takeIf { it != 0 }?.let(res::getDimensionPixelSize) ?: 0
        @Suppress("DEPRECATION")
        val width = wm.defaultDisplay.width
        return Triple(width, dimen("status_bar_height"), dimen("navigation_bar_height"))
    }

    // ---- look -----------------------------------------------------------------------------------

    private fun isDark() = debugDark
        ?: (service.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES)
    private fun colors() = if (isDark()) OverlayPalette.DARK else OverlayPalette.LIGHT

    /** The confirm and handoff cards' surface: the control's, as a drawable. */
    private fun surface(c: OverlayPalette, radius: Float) = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(c.surfaceTop, c.surfaceBottom)).apply {
        cornerRadius = radius
        setStroke(1, c.hairline)
    }

    private fun outlined(c: OverlayPalette) = RippleDrawable(ColorStateList.valueOf(c.ripple), GradientDrawable().apply {
        cornerRadius = dp(14).toFloat(); setStroke(dp(1), c.outline); setColor(Color.TRANSPARENT)
    }, null)

    private fun style(button: TextView, fill: Int, ink: Int, c: OverlayPalette) {
        button.textSize = 15f
        button.setTextColor(ink)
        button.typeface = Typeface.DEFAULT_BOLD
        button.setPadding(dp(18), 0, dp(18), 0)
        button.background = RippleDrawable(ColorStateList.valueOf(c.ripple), GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(fill) }, null)
    }

    private fun textButton(label: String, ink: Int, c: OverlayPalette, action: () -> Unit) = TextView(service).apply {
        text = label
        textSize = 14f
        setTextColor(ink)
        gravity = Gravity.CENTER
        minimumHeight = dp(48)
        minimumWidth = dp(48)
        setPadding(dp(12), 0, dp(12), 0)
        background = RippleDrawable(ColorStateList.valueOf(c.ripple), null, GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(Color.WHITE) })
        isClickable = true
        isFocusable = true
        setOnClickListener { action() }
    }

    private fun animationsOn() = OverlayMotion.on()

    private fun dp(v: Int) = service.dp(v)

    companion object {
        private const val TAG = "DshA11y"
        private const val ARM_MS = 600L

        /** The app's page link for 解除限制 (lib/ui/settings/index/spots.dart). */
        private const val UNLOCKS_LINK = "dshgo://open/phone-unlocks"

        /** The ball's way back to the capsule on a tap: quicker than the way out. */
        private const val UNFOLD_GLIDE_MS = 220L

        /** Frames both windows show at a swap, so the one going is surely covered (≈ 3 frames). */
        private const val SWAP_MS = 48L

        /** Going idle is slow and quiet; a touch brings it back at once. */
        private const val DIM_FADE_MS = 400L
        private const val UNDIM_FADE_MS = 120L
    }
}
