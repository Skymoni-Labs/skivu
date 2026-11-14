// Portions derived from Phase (https://github.com/CikeSeven/phase), used with the author's permission. See THIRD_PARTY_NOTICES.md.
// Local changes: the screen text format instead of JSON; fingerprints re-checked against a fresh
// capture; password fields marked rather than failing the screen; collect, open, numbered
// screenshots, tap_xy; blocking calls with time budgets.

package com.skyjjgw.independent.ski.dshgo.phone.a11y

import com.skyjjgw.independent.ski.dshgo.phone.background.Reasons
import com.skyjjgw.independent.ski.dshgo.phone.PhoneAppIdentity
import com.skyjjgw.independent.ski.dshgo.i18n.AppStrings
import com.skyjjgw.independent.ski.R
import android.app.KeyguardManager
import android.content.Intent
import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import android.view.Display
import android.view.accessibility.AccessibilityNodeInfo
import com.skyjjgw.independent.ski.dshgo.phone.ActionResult
import com.skyjjgw.independent.ski.dshgo.phone.Either
import com.skyjjgw.independent.ski.dshgo.phone.SkillReplayStep
import com.skyjjgw.independent.ski.dshgo.phone.SkillReplayPlan
import com.skyjjgw.independent.ski.dshgo.phone.SkillReplayPost
import com.skyjjgw.independent.ski.dshgo.phone.FocusInput
import com.skyjjgw.independent.ski.dshgo.phone.FocusObservation
import com.skyjjgw.independent.ski.dshgo.phone.Availability
import com.skyjjgw.independent.ski.dshgo.phone.CollectRejection
import com.skyjjgw.independent.ski.dshgo.phone.CollectResult
import com.skyjjgw.independent.ski.dshgo.phone.PhoneControl
import com.skyjjgw.independent.ski.dshgo.phone.PhoneAction
import com.skyjjgw.independent.ski.dshgo.phone.PhoneDriver
import com.skyjjgw.independent.ski.dshgo.phone.PhoneRegistry
import com.skyjjgw.independent.ski.dshgo.phone.PhoneUnlocks
import com.skyjjgw.independent.ski.dshgo.phone.PhoneScreen
import com.skyjjgw.independent.ski.dshgo.phone.SafetyRules
import com.skyjjgw.independent.ski.dshgo.phone.SensitiveWords
import com.skyjjgw.independent.ski.dshgo.phone.ScreenSnapshot
import com.skyjjgw.independent.ski.dshgo.phone.TargetInfo
import com.skyjjgw.independent.ski.dshgo.phone.VisualScope
import com.skyjjgw.independent.ski.dshgo.phone.VisualTarget
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The main screen, read and driven through [PhoneA11yService]. Calls block (bridge worker
 * thread); observe stays under ~5 s, actions under ~15 s, collect under ~100 s. Only the
 * latest snapshot's ids are valid; every action re-reads the tree and refuses when the
 * element's fingerprint no longer matches.
 */
internal class MainScreenDriver(private val service: PhoneA11yService, private val overlay: ControlOverlay) : PhoneDriver {
    override val screen = PhoneScreen.MAIN

    private val ownPackage: String = service.packageName

    /** 解除限制, read at each check: the person may lift or restore a rule between calls. */
    private val lifted: PhoneUnlocks get() = PhoneRegistry.unlocks()
    private val clock get() = service.clock
    private val actuator = Actuator(service, overlay)
    private val localOcr = MlKitLocalOcr.get(service.applicationContext)
    private val shooter = ScreenShooter(service, overlay, localOcr)
    private var actionDeadline = 0L
    private var actionBeforeImage: ImageObservation? = null
    private val power = service.getSystemService(PowerManager::class.java)
    private val keyguard = service.getSystemService(KeyguardManager::class.java)
    private val displays = service.getSystemService(DisplayManager::class.java)
    private val labels = ConcurrentHashMap<String, String>()

    /** Wall-clock form of a screenshot's system timestamp (only touched inside [lock]). */
    private val shotClock = SimpleDateFormat("HH:mm:ss", Locale.getDefault())
    private val lock = Any()
    @Volatile private var latest: Snapshot? = null
    private val visual = MainVisualState(Any())
    private val focusLock = Any()
    private var focusCandidate: FocusCandidate? = null
    @Volatile private var focusRevision = 0L
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Bumped by [abort] (stop, screen off): loops and waits started before it give up. */
    @Volatile private var abortGen = 0L

    private class Snapshot(
        val id: String,
        val screen: FormattedScreen,
        val packageName: String?,
        val appLabel: String?,
        val protectedPage: Boolean,
        val ownApp: Boolean,
        /** The front window hides its content from us (data-sensitive page): reported as secure. */
        val hidden: Boolean,
        /** The window is there but nothing under it was readable (filtered subtree, page still drawing). */
        val unreadable: Boolean,
        val observation: ScreenObservation,
        /** Notes already shown on this app's previous screen (not repeated). */
        val noteKeys: Set<String>,
        val visualEvidence: MainVisualEvidence?,
        val readPackages: Set<String>,
    ) {
        var focus: FocusObservation? = null
        @Volatile var image: ImageObservation? = null
        // Null denotes an actual public image; only OCR-only coordinates depend on the ON epoch.
        @Volatile var ocrOnlyEpoch: Long? = null
    }

    fun close() {
        abort()
        actuator.close()
        shooter.close()
    }

    fun abort() { abortGen++; visual.invalidate(); clearFocusCandidate() }

    /** Main thread, so it runs ahead of any coordinate start queued behind the event. */
    fun windowChanged() { visual.windowChanged(); clearFocusCandidate() }

    // ---- PhoneDriver ------------------------------------------------------------------------------

    private fun published() = PhoneA11yService.instance === service && PhoneRegistry.mainDriver === this

    override fun availability(): Availability = (when {
        !published() ->
            // l10n:keep agent screen result
            Availability(false, "DSH 的无障碍服务没有连接。请用户到 系统设置 → 无障碍 里重新打开「DSH 手机操控」。", AppStrings.get(service, R.string.phone_availability_disconnected))
        // l10n:keep agent screen result
        !power.isInteractive -> Availability(false, "屏幕已关闭。DSH 只在亮屏、解锁时操作手机，请用户点亮并解锁。", AppStrings.get(service, R.string.phone_availability_screen_off))
        // l10n:keep agent screen result
        keyguard.isKeyguardLocked -> Availability(false, "手机已锁屏。请用户解锁后再继续。", AppStrings.get(service, R.string.phone_availability_locked))
        else -> Availability(true)
    }).also { if (!it.ok) { visual.invalidate(); clearFocusCandidate() } }

    override fun foregroundPackage(): String? {
        if (!availability().ok) return null
        val pkg = TreeCapture.foregroundPackage(service, screenBox())
        val id = latest?.id
        if (id == null || visual.scope(id)?.packageName != pkg) visual.observed(null, null)
        return pkg
    }

    override fun visualScope(screenId: String): VisualScope? = if (published()) visual.scope(screenId) else null

    private fun coordinateEpochCurrent(snap: Snapshot): Boolean =
        mainOcrEpochCurrent(snap.ocrOnlyEpoch, localOcr.enabledEpoch())

    override fun acceptVisualObservation(screenId: String) {
        val snap = latest
        if (published() && snap?.id == screenId && coordinateEpochCurrent(snap)) visual.accept(screenId)
    }

    override fun coordinateTarget(action: PhoneAction.TapXY): VisualTarget? = synchronized(lock) {
        val snap = latest ?: return null
        if (snap.id != action.screenId || action.gesture != PhoneAction.CoordinateGesture.TAP ||
            !visual.imageAccepted(snap.id) || !coordinateEpochCurrent(snap) || !availability().ok) return null
        val image = snap.image ?: return null
        if (!image.isFresh(SystemClock.uptimeMillis())) return null
        val scope = visual.scope(snap.id) ?: return null
        val point = image.geometry.toScreen(action.x, action.y) ?: return null
        val node = snap.visualEvidence?.target(point.first, point.second) ?: return null
        VisualTarget(scope, TargetInfo(snap.id, 0, "按钮", ScreenFormat.clip(ScreenMask.mask(node.text?.takeIf { it.isNotBlank() }
            ?: node.description.orEmpty()), 160), scope.packageName, snap.appLabel,
            isPassword = false, isSecretField = false, isEditable = false, viewId = node.viewId))
    }

    override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot = observe(detail, image, automaticImage = false)

    override fun observe(detail: Boolean, image: Boolean, automaticImage: Boolean): ScreenSnapshot = synchronized(lock) {
        val start = SystemClock.uptimeMillis()
        val generation = abortGen
        availability().let { if (!it.ok) return blank(it.reason!!) }
        val cap = capture()
        try {
            val snap = publish(cap, detail)
            val publicImage = image || automaticImage && snap.screen.poorTree
            val text = StringBuilder(snap.screen.text)
            var bytes: ByteArray? = null
            var mime: String? = null
            var imageReadPackages: Set<String> = emptySet()
            var secure = false
            var localText = shooter.localTextWithoutFrame()
            var formatted: LocalOcrVisual.Output? = null
            val epoch = localOcr.enabledEpoch()
            val readLocal = snap.screen.poorTree && epoch != null && ocrAllowed(cap, snap, generation)
            if (snap.screen.poorTree && epoch != null && !readLocal) {
                localText = LocalOcrResult.Unavailable(LocalOcrResult.Reason.PRIVACY_UNVERIFIED)
            }
            if (publicImage || readLocal) {
                val left = OBSERVE_MS - (SystemClock.uptimeMillis() - start)
                when {
                    // l10n:keep agent screen result
                    snap.ownApp && !lifted.ownApp -> text.append("\n提示：DSH 自己的界面不截图。")
                    // l10n:keep agent screen result
                    ScreenFormat.index(cap.windows).any { it.fullText.contains("«银行卡") || it.fullText.contains("«身份证") } ->
                        // l10n:keep agent screen result
                        text.append("\n提示：本屏有银行卡号或身份证号，这次没有附截图。")
                    // l10n:keep agent screen result
                    left < 900 -> text.append("\n提示：读屏用时过长，这次没有附截图。")
                    else -> {
                        val window = if (cap.windows.size == 1) cap.windows[0] else null
                        val secrets = secretFieldBounds(cap.windows)
                        val capturedTransitions = visual.transitions()
                        val shot = shooter.shoot(window, cap.screen, snap.screen.elements, secrets, minOf(left - 300, 3_000),
                            image = publicImage,
                            readLocalText = readLocal,
                            localTextPrivacyAllowed = ocrAllowed(cap, snap, generation),
                            localTextCancelled = { !ocrAllowed(cap, snap, generation) || localOcr.enabledEpoch() != epoch })
                        localText = when {
                            snap.screen.poorTree && epoch == null -> shooter.localTextWithoutFrame()
                            snap.screen.poorTree && !readLocal -> LocalOcrResult.Unavailable(LocalOcrResult.Reason.PRIVACY_UNVERIFIED)
                            else -> shot.localText
                        }
                        val current = snap.screen.poorTree && epoch != null && epoch == localOcr.enabledEpoch() &&
                            verifyOcrContext(cap, snap, generation, start + OBSERVE_MS)
                        val decoded = if (snap.screen.poorTree) shot.visualText() else null
                        if (current && SystemClock.uptimeMillis() < start + OBSERVE_MS &&
                            epoch == localOcr.enabledEpoch() && ocrAllowed(cap, snap, generation)) formatted = decoded
                        val privateText = decoded?.sensitiveText == true
                        secure = shot.secure
                        if (secure) visual.observed(null, null)
                        if (shot.bytes != null && !privateText &&
                            visual.candidate(snap.id, capturedTransitions)) {
                            bytes = shot.bytes
                            mime = shot.mime
                            imageReadPackages = ImageReadSources.knownPackages(cap, shot, ownPackage)
                            snap.ocrOnlyEpoch = null
                            snap.image = shot.observation
                            // l10n:keep agent screen result
                            text.append("\n截图上的数字是元素编号；tap_xy 用截图像素（${shot.geometry!!.width}×${shot.geometry.height}）。")
                            // l10n:keep agent screen result
                            shot.takenAtMillis?.let { text.append("\n截图时间：${shotClock.format(Date(it))}（系统截图时间戳，设备时钟）。") }
                        // l10n:keep agent screen result
                        } else if (formatted?.hasPoints == true && !privateText && shot.observation != null &&
                            visual.candidate(snap.id, capturedTransitions)) {
                            snap.image = shot.observation
                            snap.ocrOnlyEpoch = epoch
                        } else if (publicImage && !privateText) text.append("\n提示：${shot.error ?: "截图失败"}。")
                    }
                }
            }
            if (snap.screen.poorTree) text.append("\n").append(formatted?.text ?: LocalOcrBoundary.message(localText))
            if (secure) clearFocusCandidate()
            ScreenSnapshot(snap.id, text.toString(), snap.appLabel, snap.packageName, secure || snap.hidden, snap.screen.poorTree, bytes, mime,
                readPackages = snap.readPackages, focus = snap.focus.takeUnless { secure },
                imageReadPackages = imageReadPackages)
        } finally { cap.recycle() }
    }

    private fun ocrAllowed(cap: Capture, snap: Snapshot, gen: Long): Boolean =
        !cancelled(gen) && availability().ok && latest === snap && visual.scope(snap.id) != null &&
            Build.VERSION.SDK_INT >= 34 && cap.windows.size == 1 && cap.visualComplete &&
            cap.keyboardShown == false && !snap.ownApp && !snap.protectedPage && !snap.hidden &&
            !cap.truncated && !cap.partial && !unavailable(cap) && secretFieldBounds(cap.windows).isEmpty() &&
            PhoneControl.peek()?.policies()?.denyPackages?.let { snap.packageName != null && snap.packageName !in it } == true

    private fun verifyOcrContext(cap: Capture, snap: Snapshot, gen: Long, deadline: Long): Boolean {
        if (!ocrAllowed(cap, snap, gen)) return false
        val left = deadline - SystemClock.uptimeMillis()
        if (left <= 0) return false
        val check = capture(minOf(CAPTURE_MS, left))
        return try { SystemClock.uptimeMillis() < deadline && ocrAllowed(check, snap, gen) &&
            observation(check).reusableCoordinates(snap.observation) }
        finally { check.recycle() }
    }

    private class FocusCandidate(
        val snapshot: Snapshot, val element: ScreenElement, val node: AccessibilityNodeInfo,
        val token: FocusObservation, val revision: Long, val generation: Long,
        val selectionStart: Int, val selectionEnd: Int, val inputType: Int,
    )

    @Suppress("DEPRECATION")
    private fun releaseFocusNode(node: AccessibilityNodeInfo) {
        if (Build.VERSION.SDK_INT < 33) node.recycle()
    }

    private fun clearFocusCandidate() {
        val old = synchronized(focusLock) {
            focusRevision++
            focusCandidate.also { focusCandidate = null }
        }
        old?.let { releaseFocusNode(it.node) }
    }

    /** The saved copy is an identity witness only: never refresh it or perform actions on it. */
    @Suppress("DEPRECATION")
    private fun replaceFocusCandidate(cap: Capture, snap: Snapshot) {
        clearFocusCandidate()
        if (snap.hidden || snap.unreadable || cap.partial || cap.truncated ||
            unavailable(cap) || !published()) return
        val revision = focusRevision
        val gen = abortGen
        val candidate = try {
            val el = snap.screen.elements.filter { it.kind == ElementKind.INPUT &&
                cap.native(it.ref)?.isFocused == true }.singleOrNull() ?: return
            val node = cap.native(el.ref) ?: return
            if (!focusNodeMatches(cap, el, node) || el.password || el.secret) return
            val start = node.textSelectionStart
            val end = node.textSelectionEnd
            if (start < 0 || end < 0 || node.inputType == android.text.InputType.TYPE_NULL) return
            FocusCandidate(snap, el, AccessibilityNodeInfo.obtain(node), FocusObservation(el.id),
                revision, gen, start, end, node.inputType)
        } catch (_: Exception) { return }
        val kept = synchronized(focusLock) {
            if (revision != focusRevision || gen != abortGen || !published()) false else {
                focusCandidate = candidate
                snap.focus = candidate.token
                true
            }
        }
        if (!kept) releaseFocusNode(candidate.node)
    }

    private fun focusNodeMatches(cap: Capture, el: ScreenElement, node: AccessibilityNodeInfo): Boolean {
        if (cap.partial || cap.truncated || unavailable(cap) || cap.windows.firstOrNull()?.id != el.windowId ||
            !node.isFocused || !node.isEditable || !node.isEnabled || !node.isVisibleToUser || node.isPassword ||
            node.windowId != el.windowId || node.packageName?.toString() != el.packageName ||
            node.viewIdResourceName == null || node.viewIdResourceName != el.viewId) return false
        val root = cap.windows.firstOrNull()?.root?.let { cap.native(it.ref) } ?: return false
        val focus = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        return try { focus == node && focus.windowId == el.windowId } finally { releaseFocusNode(focus) }
    }

    override fun prepareFocusInput(screenId: String): Either<String, FocusInput> {
        if (Looper.myLooper() == Looper.getMainLooper())
            return Either.Left(FOCUS_UNAVAILABLE)
        val candidate = synchronized(focusLock) {
            val current = focusCandidate
            if (current == null || current.snapshot.id != screenId || !current.token.committed) null
            else current.also { focusCandidate = null } // Transfer the sole saved copy to this execution.
        } ?: return Either.Left(FOCUS_UNAVAILABLE)
        var transferred = false
        try {
            synchronized(lock) {
                if (!focusCurrent(candidate) || !availability().ok) return Either.Left(FOCUS_CHANGED)
                if (Build.VERSION.SDK_INT >= 33) {
                    val capture = FutureTask { service.captureFocusInput() }
                    if (!mainHandler.post(capture)) return Either.Left(FOCUS_UNAVAILABLE)
                    val input = try { capture.get(2_000, TimeUnit.MILLISECONDS) }
                        finally { capture.cancel(false) }
                    if (input != null) {
                        // A changed captured editor does not authorize switching input paths.
                        if (!input.currentBeforeDispatch() || !verifyFocus(candidate, input))
                            return Either.Left(FOCUS_CHANGED)
                        transferred = true
                        return Either.Right(MainFocusInput(candidate, input))
                    }
                }
                // No IME commit was attempted. Never overwrite the clipboard to probe paste support.
                val cap = capture()
                try {
                    val node = freshFocusNode(cap, candidate) ?: return Either.Left(FOCUS_CHANGED)
                    if (!pasteAdvertised(node)) return Either.Left(FOCUS_UNAVAILABLE)
                } finally { cap.recycle() }
                transferred = true
                return Either.Right(MainClipboardInput(candidate))
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            return Either.Left(FOCUS_CHANGED)
        } catch (_: Exception) {
            return Either.Left(FOCUS_UNAVAILABLE)
        } finally { if (!transferred) releaseFocusNode(candidate.node) }
    }

    private fun focusCurrent(candidate: FocusCandidate): Boolean =
        published() && !cancelled(candidate.generation) && latest === candidate.snapshot &&
            focusRevision == candidate.revision

    @android.annotation.TargetApi(33)
    private fun verifyFocus(candidate: FocusCandidate, input: FocusCapturedInput33): Boolean {
        if (!focusCurrent(candidate) || !input.currentBeforeDispatch() || !availability().ok) return false
        val unlocks = lifted
        if ((candidate.element.packageName == ownPackage || candidate.snapshot.ownApp) && !unlocks.ownApp ||
            candidate.snapshot.protectedPage && !unlocks.systemPages) return false
        val witness = input.snapshot
        if (witness.editor.packageName != candidate.element.packageName ||
            witness.editor.inputType != candidate.inputType || witness.selectionStart != candidate.selectionStart ||
            witness.selectionEnd != candidate.selectionEnd || witness.editor.fieldId == 0 ||
            witness.editor.fieldId == android.view.View.NO_ID) return false
        val resourceName = try { service.packageManager.getResourcesForApplication(witness.editor.packageName!!)
            .getResourceName(witness.editor.fieldId) } catch (_: Exception) { return false }
        if (resourceName != candidate.element.viewId) return false
        val cap = capture()
        try { return freshFocusNode(cap, candidate) != null && input.currentBeforeDispatch() }
        finally { cap.recycle() }
    }

    /** Returned node is owned by this fresh capture, never the saved identity copy. */
    private fun freshFocusNode(cap: Capture, candidate: FocusCandidate,
                               sameSelection: Boolean = true): AccessibilityNodeInfo? {
        if (!focusCurrent(candidate) || !availability().ok) return null
        val titles = cap.windows.mapNotNull { it.title } +
            ProtectedPages.titleTexts(cap.windows.firstOrNull()?.root, cap.screen.height)
        if ((cap.ownAppInFront || cap.packageName == ownPackage) && !lifted.ownApp ||
            ProtectedPages.isProtected(cap.packageName, titles) && !lifted.systemPages) return null
        val matching = ScreenFormat.index(cap.windows).filter { it.kind == ElementKind.INPUT &&
            it.windowId == candidate.element.windowId && it.fingerprint == candidate.element.fingerprint }
            .singleOrNull() ?: return null
        val node = cap.native(matching.ref) ?: return null
        if (node != candidate.node || !focusNodeMatches(cap, candidate.element, node) ||
            node.inputType != candidate.inputType || sameSelection &&
            (node.textSelectionStart != candidate.selectionStart || node.textSelectionEnd != candidate.selectionEnd)) return null
        val classified = ScreenFormat.format(ScreenInput("focus-check", candidate.snapshot.appLabel,
            cap.packageName, cap.screen.width, cap.screen.height, cap.keyboardShown, cap.windows))
            .elements.singleOrNull { it.ref == matching.ref } ?: return null
        return node.takeIf { !classified.password && !classified.secret && focusCurrent(candidate) && availability().ok }
    }

    private fun pasteAdvertised(node: AccessibilityNodeInfo): Boolean =
        node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_PASTE }

    private fun focusNodeSample(node: AccessibilityNodeInfo): FocusReadback.Sample? {
        val text = if (node.isShowingHintText) "" else node.text?.toString().orEmpty()
        if (text.length > 4096) return null
        return FocusReadback.Sample(text, node.textSelectionStart, node.textSelectionEnd, 0)
    }

    private inner class MainClipboardInput(private val candidate: FocusCandidate) : FocusInput {
        private val ownership = Any()
        private var closed = false
        private var used = false
        override val method = FocusInput.Method.CLIPBOARD
        override val target: TargetInfo = info(candidate.snapshot.id, candidate.element)
        override fun close() = synchronized(ownership) {
            if (!closed) { closed = true; releaseFocusNode(candidate.node) }
        }

        override fun perform(text: String, allowed: () -> Boolean): ActionResult = synchronized(ownership) {
            if (closed || used) return ActionResult(false, FOCUS_CHANGED)
            used = true
            // 0 queued, 1 invocation claimed, 2 returned, 3 cancelled before invocation.
            // No callback takes ownership/Main locks; a running timed-out write may still finish.
            val clipboard = AtomicInteger(0)
            var pasteAttempted = false
            var write: FutureTask<Boolean>? = null
            fun uncertain(): ActionResult {
                // Seal the queued write before classifying the result: a race cannot turn
                // a reported not-started result into a later clipboard invocation.
                clipboard.compareAndSet(0, 3)
                write?.cancel(false)
                return ActionResult(false, when {
                pasteAttempted -> "已尝试一次粘贴，效果未核实；不要重复输入或改用其他方式。" // l10n:keep agent focus result
                clipboard.get() == 2 -> "系统剪贴板已被覆盖，未派发粘贴；请核对当前焦点，不要自动重试。" // l10n:keep agent focus result
                clipboard.get() == 1 -> "系统剪贴板写入已开始，结果未知，未派发粘贴；不要自动重试。" // l10n:keep agent focus result
                else -> FOCUS_CHANGED
                })
            }
            try {
                synchronized(lock) {
                    actionDeadline = SystemClock.uptimeMillis() + 30_000L
                    actionBeforeImage = null
                    if (!allowed() || !focusCurrent(candidate) || !availability().ok || !awaitInputIdle())
                        return uncertain()
                    val beforeCap = capture()
                    val before = try {
                        val node = freshFocusNode(beforeCap, candidate) ?: return uncertain()
                        if (!pasteAdvertised(node)) return uncertain()
                        focusNodeSample(node) ?: return uncertain()
                    } finally { beforeCap.recycle() }
                    if (!focusSampleMatchesSelection(before, candidate.selectionStart, candidate.selectionEnd) ||
                        !allowed() || !focusCurrent(candidate) || SystemClock.uptimeMillis() >= actionDeadline)
                        return uncertain()
                    val task = FutureTask {
                        if (!allowed() || !focusCurrent(candidate) || !availability().ok ||
                            SystemClock.uptimeMillis() >= actionDeadline || !clipboard.compareAndSet(0, 1)) false
                        else {
                            service.getSystemService(ClipboardManager::class.java)
                                .setPrimaryClip(ClipData.newPlainText("DSH", text))
                            clipboard.set(2)
                            true
                        }
                    }
                    write = task
                    if (!mainHandler.post(task)) return uncertain()
                    val remaining = minOf(3_000L, actionDeadline - SystemClock.uptimeMillis())
                    if (remaining <= 0 || !task.get(remaining, TimeUnit.MILLISECONDS)) return uncertain()
                    if (!allowed() || !focusCurrent(candidate) || SystemClock.uptimeMillis() >= actionDeadline)
                        return uncertain()
                    val pasteCap = capture()
                    val events = clock.count
                    try {
                        val node = freshFocusNode(pasteCap, candidate) ?: return uncertain()
                        if (!pasteAdvertised(node) || !allowed() || !focusCurrent(candidate) ||
                            SystemClock.uptimeMillis() >= actionDeadline) return uncertain()
                        pasteAttempted = true
                        if (!node.performAction(AccessibilityNodeInfo.ACTION_PASTE)) return uncertain()
                    } finally { pasteCap.recycle() }
                    if (!allowed() || !focusCurrent(candidate) || SystemClock.uptimeMillis() >= actionDeadline)
                        return uncertain()
                    val afterCap = capture()
                    val afterText = try { freshFocusNode(afterCap, candidate, sameSelection = false)?.let(::focusNodeSample) }
                        finally { afterCap.recycle() }
                    val result = FocusReadback.compare(before, afterText, text)
                    if (!allowed() || !focusCurrent(candidate) || SystemClock.uptimeMillis() >= actionDeadline)
                        return uncertain()
                    val message = if (result.kind == FocusReadback.Kind.LOCAL_CONSISTENT)
                        "剪贴板已覆盖并尝试一次粘贴；有限回读局部一致，不证明输入因果或业务成功。旧剪贴板未备份或恢复。" // l10n:keep agent focus result
                    else "剪贴板已覆盖并尝试一次粘贴，有限回读未确认一致；不要重发或换输入方式。旧剪贴板未备份或恢复。" // l10n:keep agent focus result
                    return after(events, candidate.snapshot, candidate.generation, message,
                        previousImage = null, ok = result.kind == FocusReadback.Kind.LOCAL_CONSISTENT)
                }
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return uncertain()
            } catch (_: Exception) {
                return uncertain()
            } finally {
                // Losing this CAS forbids a queued task from beginning. State 1 remains unknown.
                clipboard.compareAndSet(0, 3)
                write?.cancel(false)
                close()
            }
        }
    }

    @android.annotation.TargetApi(33)
    private inner class MainFocusInput(
        private val candidate: FocusCandidate, private val input: FocusCapturedInput33,
    ) : FocusInput {
        private val ownership = Any()
        private var closed = false
        private var used = false
        override val target: TargetInfo = info(candidate.snapshot.id, candidate.element)

        override fun close() = synchronized(ownership) {
            if (!closed) { closed = true; releaseFocusNode(candidate.node) }
        }

        override fun perform(text: String, allowed: () -> Boolean): ActionResult = synchronized(ownership) {
            if (closed || used) return ActionResult(false, FOCUS_CHANGED)
            used = true
            try {
                synchronized(lock) {
                    actionDeadline = SystemClock.uptimeMillis() + 30_000L
                    actionBeforeImage = null
                    if (!allowed() || !focusCurrent(candidate) || !availability().ok || !awaitInputIdle() ||
                        !allowed() || !verifyFocus(candidate, input)) return ActionResult(false, FOCUS_CHANGED)
                    val before = input.readBounded(actionDeadline)
                    if (!focusSampleMatchesSelection(before, candidate.selectionStart, candidate.selectionEnd) ||
                        !allowed() || SystemClock.uptimeMillis() >= actionDeadline || !verifyFocus(candidate, input) ||
                        !allowed() || SystemClock.uptimeMillis() >= actionDeadline ||
                        !input.currentBeforeDispatch()) return ActionResult(false, FOCUS_CHANGED)
                    val events = clock.count
                    input.commitOnce(text)
                    val afterText = if (allowed() && focusCurrent(candidate)) input.readBounded(actionDeadline) else null
                    val result = if (focusCurrent(candidate) && input.sameEditor() && allowed())
                        FocusReadback.compare(before, afterText, text) else FocusReadback.Result(FocusReadback.Kind.UNKNOWN, false)
                    // l10n:keep agent focus result
                    val message = when (result.kind) {
                        FocusReadback.Kind.LOCAL_CONSISTENT -> if (result.absoluteAlignment)
                            "已尝试一次焦点输入；有限回读的局部文字与光标位置一致，不表示业务成功，也不证明输入因果。"
                        else "已尝试一次焦点输入；按当前光标对齐的局部文字一致，原绝对位置未核实，不表示业务成功。"
                        FocusReadback.Kind.LOCAL_DIFFERENT -> "已尝试一次焦点输入；有限回读与预期局部形状不同，可能已产生效果，不要重发或切换输入方式。"
                        FocusReadback.Kind.UNKNOWN -> FOCUS_UNKNOWN
                    }
                    if (!allowed() || !focusCurrent(candidate) || SystemClock.uptimeMillis() >= actionDeadline)
                        return ActionResult(false, FOCUS_UNKNOWN)
                    return after(events, candidate.snapshot, candidate.generation, message,
                        previousImage = null, ok = result.kind == FocusReadback.Kind.LOCAL_CONSISTENT)
                }
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return ActionResult(false, if (input.attempted) FOCUS_UNKNOWN else FOCUS_CHANGED)
            } catch (_: Exception) {
                return ActionResult(false, if (input.attempted) FOCUS_UNKNOWN else FOCUS_CHANGED)
            } finally { close() }
        }
    }

    override fun prepareSkillReplayStep(step: SkillReplayStep): Either<String, SkillReplayPlan> = synchronized(lock) {
        val relation = com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute.Step(
            com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute.Op.SELECT_OPTION, "app1", PhoneScreen.MAIN,
            "navigation", "bottom-tabs", com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute.Value.OptionLiteral("more"),
            com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute.Post.OptionSelected)
        if (step.relation != relation || Looper.myLooper() == Looper.getMainLooper() || !availability().ok)
            return Either.Left("当前页面不能核实这条公共路线，未执行。") // l10n:keep
        val cap = capture(typed = true)
        try {
            val observed = MarkorNavigation.selectedObservation(service, cap, step.app)
                ?: return Either.Left("当前应用或导航页面不符合已核路线，未执行。") // l10n:keep
            val snap = publish(cap, detail = false)
            val satisfied = observed.selected == "nav_more"
            val el = if (satisfied) null else {
                if (!observed.moreCanClick) return Either.Left("当前更多选项不可直接操作，未执行。") // l10n:keep
                val hit = ScreenFormat.index(cap.windows).singleOrNull { it.ref == observed.moreRef }
                    ?: return Either.Left("当前路线目标不唯一，未执行。") // l10n:keep
                snap.screen.elements.singleOrNull { it.fingerprint == hit.fingerprint }
                    ?: return Either.Left("当前路线目标没有唯一可核对编号，未执行。") // l10n:keep
            }
            if (!typedCurrent(cap)) return Either.Left("窗口已变化，未建立路线步骤。") // l10n:keep
            Either.Right(NavigationReplayPlan(step, observed.windowId, snap, el, satisfied, abortGen))
        } finally { cap.recycle() }
    }

    private inner class NavigationReplayPlan(private val step: SkillReplayStep, private val window: Int,
        private val original: Snapshot, element: ScreenElement?, override val alreadySatisfied: Boolean,
        private val generation: Long) : SkillReplayPlan {
        private var used = false
        private var closed = false
        override val before: ScreenSnapshot = toSnapshot(original)
        override val target: TargetInfo? = element?.let { info(original.id, it) }
        @Volatile override var attempted: Boolean = false
            private set
        @Volatile override var post: SkillReplayPost = SkillReplayPost.UNKNOWN
            private set
        override fun close() = synchronized(lock) { closed = true }
        override fun perform(allowed: () -> Boolean): ActionResult = synchronized(lock) {
            if (closed || used) return ActionResult(false, "原路线步骤已使用或失效，没有再次操作。") // l10n:keep
            used = true
            actionDeadline = SystemClock.uptimeMillis() + 30_000L
            actionBeforeImage = null
            if (cancelled(generation) || !allowed() || !availability().ok || !awaitInputIdle() || !allowed())
                return ActionResult(false, "原路线步骤已停止，没有继续操作。") // l10n:keep
            val cap = capture(typed = true)
            try {
                val observed = MarkorNavigation.selectedObservation(service, cap, step.app)
                    ?.takeIf { it.windowId == window }
                    ?: return ActionResult(false, "原路线应用、页面或窗口已改变，没有操作。") // l10n:keep
                val snap = publish(cap, detail = false)
                val app = MarkorNavigation.App(step.app.uid, step.app.version, step.app.updated, step.app.signers)
                val navigation = MarkorNavigation.Before(app, observed)
                if (observed.selected == "nav_more") {
                    if (!allowed() || cancelled(generation) || !typedCurrent(cap)) return ActionResult(false, "原路线步骤已停止或窗口已变化。") // l10n:keep
                    post = SkillReplayPost.SATISFIED
                    return ActionResult(true, "更多已选中；本步没有再次点击，仅核验该公开选中状态。", // l10n:keep
                        toSnapshot(snap), navigationWitness = com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillNavigationWitness(
                            app.uid, app.version, app.updated, app.signers))
                }
                if (alreadySatisfied) return ActionResult(false, "准备后选中状态改变，没有把只读核验改成点击。") // l10n:keep
                val hit = ScreenFormat.index(cap.windows).singleOrNull { it.ref == observed.moreRef }
                    ?: return ActionResult(false, "原路线目标不唯一，没有操作。") // l10n:keep
                val el = snap.screen.elements.singleOrNull { it.fingerprint == hit.fingerprint }
                    ?: return ActionResult(false, "原路线目标不可核对，没有操作。") // l10n:keep
                val node = cap.native(hit.ref) ?: return ActionResult(false, "原路线目标不可读取，没有操作。") // l10n:keep
                refuseWrite(Resolved(snap, el, cap, node, hit))?.let { return it }
                if (!observed.moreCanClick || !node.isEnabled || !allowed() || cancelled(generation) || !typedCurrent(cap))
                    return ActionResult(false, "原路线目标或权限改变，没有操作。") // l10n:keep
                val events = clock.count
                attempted = true
                val accepted = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                // One actual NODE request only. False may be an in-flight timeout; no fallback/retry.
                after(events, snap, generation,
                    if (accepted) "已尝试选择更多；以下核对仅针对公开选中状态。" else "节点请求未确认，可能已有作用，不要重试。", // l10n:keep
                    ok = accepted, navigation = navigation, navigationPost = { post = it })
            } finally { cap.recycle() }
        }
    }

    override fun target(screenId: String, elementId: Int): TargetInfo? = synchronized(lock) {
        val snap = latest ?: return null
        if (snap.id != screenId) return null
        val el = snap.screen.element(elementId) ?: return null
        if (!availability().ok) return null
        val cap = capture()
        try { if (locate(cap, el) == null) return null } finally { cap.recycle() }
        info(screenId, el)
    }

    /** [el] as the core and the gate see it. */
    private fun info(screenId: String, el: ScreenElement) = TargetInfo(
        screenId = screenId, elementId = el.id, role = el.role, label = el.label,
        packageName = el.packageName, appLabel = label(el.packageName), isPassword = el.password,
        isSecretField = el.secret, isEditable = el.editable, viewId = el.viewId,
    )

    override fun perform(action: PhoneAction): ActionResult = perform(action) { !overlay.paused }

    override fun perform(action: PhoneAction, allowed: () -> Boolean): ActionResult = perform(action, allowed, null)

    override fun perform(action: PhoneAction, allowed: () -> Boolean,
                         coordinateAdmission: ((() -> Boolean) -> Boolean)?): ActionResult =
        perform(action, allowed, coordinateAdmission) { true }

    override fun perform(action: PhoneAction, allowed: () -> Boolean,
                         coordinateAdmission: ((() -> Boolean) -> Boolean)?,
                         actionSourcesAllowed: (Set<String>) -> Boolean): ActionResult {
        // l10n:keep agent screen result
        if (Looper.myLooper() == Looper.getMainLooper()) return ActionResult(false, "内部错误：手机动作不能在主线程执行。")
        val gen = abortGen
        synchronized(lock) {
            actionDeadline = SystemClock.uptimeMillis() + 30_000L // PhoneCore default action budget; worker interruption remains authoritative.
            availability().let { if (!it.ok) return ActionResult(false, it.reason!!) }
            // l10n:keep agent screen result
            if (!allowed()) return ActionResult(false, "用户在悬浮条上按了暂停。等用户点「继续」后再操作，不要换别的方式绕过。")
            // l10n:keep agent screen result
            if (!awaitInputIdle()) return ActionResult(false, "用户正在悬浮条上输入插话，稍等再操作。")
            if (cancelled(gen)) throw InterruptedException()
            // Editing may have held this invocation for seconds after its first admission check.
            refuseHalted(allowed)?.let { return it }
            actionBeforeImage = null
            val previous = latest
            if (action !is PhoneAction.TapXY && previous?.screen?.poorTree == true) {
                val remaining = actionDeadline - SystemClock.uptimeMillis()
                if (remaining > 0) {
                    val beforeCap = capture(minOf(CAPTURE_MS, remaining))
                    try {
                        if (ocrAllowed(beforeCap, previous, gen) && observation(beforeCap).sameContext(previous.observation)) {
                            actionBeforeImage = captureVerificationShot(beforeCap)?.observation
                        }
                    } finally { beforeCap.recycle() }
                }
            }
            // Recheck after this extra read; element handlers still resolve and gate just before input.
            if (cancelled(gen)) throw InterruptedException()
            refuseHalted(allowed)?.let { return it }
            return when (action) {
                is PhoneAction.Key -> key(action, gen)
                is PhoneAction.Tap -> tap(action, gen, allowed, actionSourcesAllowed)
                is PhoneAction.Type -> type(action, gen, allowed)
                is PhoneAction.Scroll -> scroll(action, gen, allowed, actionSourcesAllowed)
                is PhoneAction.TapXY -> tapXY(action, gen, allowed, coordinateAdmission)
            }
        }
    }

    override fun open(target: PhoneAppIdentity): ActionResult {
        val packageName = target.packageName
        // l10n:keep agent screen result
        if (Looper.myLooper() == Looper.getMainLooper()) return ActionResult(false, "内部错误：手机动作不能在主线程执行。")
        synchronized(lock) {
            availability().let { if (!it.ok) return ActionResult(false, it.reason!!) }
            // l10n:keep agent screen result
            if (packageName == ownPackage && !lifted.ownApp) return ActionResult(false, "DSH 自己不需要打开。")
            val name = label(packageName) ?: packageName
            val intent = service.packageManager.getLaunchIntentForPackage(packageName)
                // l10n:keep agent screen result
                ?: return ActionResult(false, "没找到「$name」，或它没有可以打开的界面。可以先用 apps 查一下包名。")
            val actual = try { service.packageManager.resolveActivity(intent, 0)?.activityInfo } catch (_: Exception) { null }
            if (actual == null) return ActionResult(false, Reasons.of("targetIdentityUnavailable"))
            if (actual.packageName != packageName || actual.applicationInfo.uid != target.uid)
                return ActionResult(false, Reasons.of("targetIdentityChanged"))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            val gen = abortGen
            try { service.startActivity(intent) } catch (e: Exception) {
                // l10n:keep agent screen result
                return ActionResult(false, "打开「$name」失败：${e.message ?: e.javaClass.simpleName}")
            }
            val deadline = SystemClock.uptimeMillis() + 6_000
            var front: String? = null
            while (SystemClock.uptimeMillis() < deadline && !cancelled(gen)) {
                front = foregroundPackage()
                if (front == packageName) break
                clock.pause(150) { cancelled(gen) }
            }
            if (front == packageName) clock.settle(clock.count, 800, 400, 3_000) { cancelled(gen) }
            val snap = if (front == packageName && availability().ok) {
                val cap = settledCapture(null, gen)
                try { toSnapshot(publish(cap, false)) } finally { cap.recycle() }
            } else observeQuiet()
            // l10n:keep agent screen result
            return if (front == packageName) ActionResult(true, "已打开「$name」。", snap)
            // l10n:keep agent screen result
            else ActionResult(false, "已请求打开「$name」，但 6 秒内它没有到前台（现在是「${label(front) ?: front ?: "未知"}」）。", snap)
        }
    }

    override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?): CollectResult =
        collect(screenId, listElementId, maxPages, until) { !overlay.paused }

    override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?, allowed: () -> Boolean): CollectResult =
        collect(screenId, listElementId, maxPages, until, allowed) { true }

    override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?,
                         allowed: () -> Boolean, canRead: (String?) -> Boolean): CollectResult =
        collect(screenId, listElementId, maxPages, until, allowed, canRead) { true }

    override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?,
                         allowed: () -> Boolean, canRead: (String?) -> Boolean,
                         scrollSourcesAllowed: (Set<String>) -> Boolean): CollectResult {
        // l10n:keep agent screen result
        if (Looper.myLooper() == Looper.getMainLooper()) return CollectResult(emptyList(), 0, "内部错误：不能在主线程执行", null, rejection = CollectRejection.UNAVAILABLE)
        synchronized(lock) {
            availability().let { if (!it.ok) return CollectResult(emptyList(), 0, it.reason!!, null, rejection = CollectRejection.UNAVAILABLE) }
            val snap = latest
            if (snap == null || snap.id != screenId) {
                // l10n:keep agent screen result
                return CollectResult(emptyList(), 0, "屏幕编号 $screenId 已过期，请先看新屏幕再 collect", observeQuiet(), rejection = CollectRejection.INVALID_TARGET)
            }
            // l10n:keep agent screen result
            if (snap.ownApp && !lifted.ownApp) return CollectResult(emptyList(), 0, "这是 DSH 自己的界面，不读取", null, rejection = CollectRejection.READ_REFUSED)
            var el = snap.screen.element(listElementId)
                // l10n:keep agent screen result
                ?: return CollectResult(emptyList(), 0, "屏幕 $screenId 里没有编号 $listElementId", null, rejection = CollectRejection.INVALID_TARGET)
            if (el.kind != ElementKind.LIST) {
                el = el.listId?.let { snap.screen.element(it) }
                    // l10n:keep agent screen result
                    ?: return CollectResult(emptyList(), 0, "[$listElementId] 不是列表，也不在列表里", null, rejection = CollectRejection.INVALID_TARGET)
            }
            val pages = maxPages.coerceIn(1, 30)
            val wanted = until?.trim()?.takeIf { it.isNotEmpty() }
            val gen = abortGen
            val deadline = SystemClock.uptimeMillis() + COLLECT_MS
            val items = CollectedItems()
            val readPackages = LinkedHashSet<String>()
            var sourceDenied = false
            // l10n:keep agent screen result
            var stop = "未能读取列表"
            var read = 0
            var misses = 0
            val direction = if (el.horizontal) PhoneAction.Direction.RIGHT else PhoneAction.Direction.DOWN
            var lastBounds = el.bounds
            while (true) {
                if (cancelled(gen) || !allowed()) { stop = "本任务已暂停或停止"; break } // l10n:keep agent result
                val cap = capture()
                try {
                    // Nothing readable in front: this says "cannot read" instead of blaming the list.
                    if (unavailable(cap)) {
                        // l10n:keep agent screen result
                        stop = "这一屏读不到内容（可能受敏感视图策略限制）"
                        break
                    }
                    val list = ScreenFormat.followList(ScreenFormat.index(cap.windows), el.fingerprint, lastBounds)
                    if (list == null) {
                        stop = if (cap.truncated || cap.partial) {
                            // l10n:keep agent screen result
                            "页面只读了一部分，无法确认列表是否到底"
                        } else {
                            // l10n:keep agent screen result
                            "列表不见了（界面变了）"
                        }
                        break
                    }
                    val source = cap.windows.firstOrNull { it.id == list.windowId }?.packageName
                    if (!canRead(source)) {
                        sourceDenied = true
                        stop = "本页内容不允许读取" // l10n:keep agent screen result
                        break
                    }
                    source?.let(readPackages::add)
                    val page = items.readPage(list.itemTexts, wanted, cap.truncated || cap.partial)
                    if (list.itemTexts.isNotEmpty()) read++
                    if (page.stopReason != null) { stop = page.stopReason; break }
                    if (list.itemTexts.isEmpty()) {
                        // l10n:keep agent screen result
                        stop = "列表没有可读条目，无法确认是否到底"
                        break
                    }
                    lastBounds = list.bounds
                    // l10n:keep agent screen result
                    if (page.found) { stop = "找到了「$wanted」"; break }
                    // l10n:keep agent screen result
                    if (items.chars > COLLECT_CHARS) { stop = "内容太多，先停在这里"; break }
                    // l10n:keep agent screen result
                    if (read > 1 && page.added == 0) { if (++misses >= 2) { stop = "没有读到更多条目，可能已经到底"; break } } else misses = 0
                    // l10n:keep agent screen result
                    if (read >= pages) { stop = "达到页数上限（$pages 页）"; break }
                    // l10n:keep agent screen result
                    if (cancelled(gen)) { stop = "已停止"; break }
                    // l10n:keep agent screen result
                    if (!allowed()) { stop = "本任务已暂停或停止"; break }
                    if (!canRead(source)) {
                        sourceDenied = true
                        stop = "本页内容不允许读取" // l10n:keep agent screen result
                        break
                    }
                    // l10n:keep agent screen result
                    if (SystemClock.uptimeMillis() > deadline) { stop = "超时"; break }
                    // l10n:keep agent screen result
                    val node = cap.native(list.ref) ?: run { stop = "列表不见了（界面变了）"; null } ?: break
                    // Without a node action, scrolling can use a gesture across another known window.
                    val scrollSources = cap.windows.mapNotNull { it.packageName }.toSet()
                    if (!scrollSourcesAllowed(scrollSources)) {
                        sourceDenied = true
                        stop = "当前页面来源不允许滚动" // l10n:keep agent screen result
                        break
                    }
                    val before = clock.count
                    val out = actuator.scroll(node, el.scroll, el.horizontal, list.bounds, cap.screen, direction) {
                        if (cancelled(gen) || !allowed()) false
                        else if (!canRead(source) || !scrollSourcesAllowed(scrollSources)) {
                            sourceDenied = true
                            false
                        } else true
                    }
                    // l10n:keep agent screen result
                    if (!out.accepted) { stop = "系统没有接受滚动，无法确认是否到底"; break }
                    clock.settle(before, 1_200, 350, 3_000) { cancelled(gen) }
                    if (misses > 0) clock.pause(800) { cancelled(gen) } // lists that load more on demand
                } finally { cap.recycle() }
            }
            return CollectResult(items.list(), read, stop,
                if (!sourceDenied && !cancelled(gen) && allowed()) observeQuiet() else null, readPackages.toSet())
        }
    }

    // ---- actions ----------------------------------------------------------------------------------

    private class Resolved(val snap: Snapshot, val el: ScreenElement, val cap: Capture, val node: AccessibilityNodeInfo, val found: IndexedElement)

    /** The element of the latest snapshot, re-verified against a fresh capture; or the refusal. */
    private fun resolve(screenId: String, elementId: Int, typedNavigation: Boolean = false): Any {
        val snap = latest
        if (snap == null || snap.id != screenId) {
            val now = observeQuiet()
            // l10n:keep agent screen result
            val msg = if (snap == null) "还没有读过屏幕，先用 screen 看一下。"
            // l10n:keep agent screen result
            else "屏幕编号 $screenId 过期了（最新 ${now?.id ?: snap.id}），没有执行。按新屏幕的编号来。"
            return ActionResult(false, msg, now)
        }
        val el = snap.screen.element(elementId)
            // l10n:keep agent screen result
            ?: return ActionResult(false, "屏幕 $screenId 里没有编号 $elementId（共 ${snap.screen.elements.size} 项）。")
        val cap = capture(typed = typedNavigation && el.packageName == MarkorNavigation.PACKAGE)
        val hit = locate(cap, el)
        val node = hit?.let { cap.native(it.ref) }
        if (hit == null || node == null) {
            val now = try { publish(cap, false).let { toSnapshot(it) } } finally { cap.recycle() }
            // l10n:keep agent screen result
            return ActionResult(false, "目标 [$elementId]「${short(el.label.ifEmpty { el.role })}」变了，没有执行；看新屏幕再选。", now)
        }
        return Resolved(snap, el, cap, node, hit)
    }

    private fun refuseWrite(r: Resolved): ActionResult? {
        val lifted = lifted
        return when {
            // l10n:keep agent screen result
            (r.el.packageName == ownPackage || r.snap.ownApp) && !lifted.ownApp -> ActionResult(false, "这是 DSH 自己的界面，不操作。")
            // l10n:keep agent screen result
            r.snap.protectedPage && !lifted.systemPages -> ActionResult(false, "这是系统权限 / 安全相关页面，DSH 不在这里点击或输入。需要的话请用 handoff 交给用户。")
            // l10n:keep agent screen result
            (r.el.password || r.el.secret) && !lifted.secretFields -> ActionResult(false, "这是密码 / 验证码一类的输入框，DSH 不替用户点或填。请用 handoff 让用户自己来。")
            else -> null
        }
    }

    private fun tap(a: PhoneAction.Tap, gen: Long, allowed: () -> Boolean,
                    actionSourcesAllowed: (Set<String>) -> Boolean): ActionResult {
        val res = resolve(a.screenId, a.elementId, typedNavigation = !a.long)
        val r = res as? Resolved ?: return res as ActionResult
        try {
            refuseWrite(r)?.let { return it }
            if (r.el.kind == ElementKind.LIST) {
                // l10n:keep agent screen result
                return ActionResult(false, "[${a.elementId}] 是列表本身，不能点。看更多用 scroll，整理全部条目用 collect。")
            }
            if (!r.node.isEnabled) {
                // l10n:keep agent screen result
                return ActionResult(false, "目标 [${a.elementId}] 当前不可用，没有发起点击；请重新查看屏幕。")
            }
            val sources = r.cap.windows.mapNotNull { it.packageName }.toSet()
            refuseHalted { allowed() && actionSourcesAllowed(sources) }?.let { return it }
            var navigation = if (!a.long) MarkorNavigation.before(service, r.cap, r.found.ref)
                ?.takeIf { typedCurrent(r.cap) } else null
            val before = clock.count
            val out = actuator.click(r.node, r.el.bounds, r.cap.screen, a.long) {
                val admitted = !cancelled(gen) && allowed() && actionSourcesAllowed(sources)
                if (!typedCurrent(r.cap)) navigation = null
                admitted
            }
            val what = short(r.el.label.ifEmpty { r.el.role })
            // l10n:keep agent screen result
            if (!out.accepted) return after(before, r.snap, gen,
                "系统未确认这次${if (a.long) "长按" else "点击"}「$what」完成，可能已有部分效果；请先核对新屏幕，不要直接重试。", ok = false)
            // l10n:keep agent screen result
            return after(before, r.snap, gen, "已提交${if (a.long) "长按" else "点击"}「$what」。",
                navigation = navigation.takeIf { out.via == Actuator.Via.NODE })
        } finally { r.cap.recycle() }
    }

    private fun type(a: PhoneAction.Type, gen: Long, allowed: () -> Boolean): ActionResult {
        val res = resolve(a.screenId, a.elementId)
        val r = res as? Resolved ?: return res as ActionResult
        try {
            refuseWrite(r)?.let { return it }
            if (r.el.kind != ElementKind.INPUT || !r.node.isEditable) {
                // l10n:keep agent screen result
                return ActionResult(false, "[${a.elementId}]「${short(r.el.label)}」不是输入框：先点它，等输入框出现再输入。")
            }
            // l10n:keep agent screen result
            if (r.node.isPassword && !lifted.secretFields) return ActionResult(false, "这是密码框，DSH 不代填。请用 handoff 让用户自己输入。")
            // l10n:keep agent screen result
            if (a.text.length > 2_000) return ActionResult(false, "一次最多输入 2000 字。")
            refuseHalted(allowed)?.let { return it }
            val before = clock.count
            if (!actuator.setText(r.node, a.text) { !cancelled(gen) && allowed() }) {
                // l10n:keep agent screen result
                return after(before, r.snap, gen,
                    "输入未获系统确认，输入、焦点或点击可能已产生部分效果；请先核对新屏幕，不要重复输入。", ok = false)
            }
            val got = readBack(r.node, a.text, gen)
            // l10n:keep agent screen result
            val name = short(r.el.label.ifEmpty { "输入框" })
            if (!sameText(got, a.text)) {
                return after(before, r.snap, gen, readBackMismatch(got, info(r.snap.id, r.el),
                    currentSecret = got != null && isSecretField(r.node)), ok = false)
            }
            // l10n:keep agent screen result
            var message = "已在「$name」输入，回读一致。"
            if (a.submit) {
                // The read-back can take 1.5 s: a pause in it keeps the text but sends nothing.
                if (!allowed()) return ActionResult(false, "$message 但本任务已暂停或停止，没有提交。") // l10n:keep agent result
                val submitted = if (Build.VERSION.SDK_INT < 30 || !r.node.refresh()) false else {
                    val id = AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id
                    if (r.node.actionList.none { it.id == id }) false else {
                        if (isSecretField(r.node) && !lifted.secretFields) {
                            // l10n:keep agent screen result
                            return after(before, r.snap, gen,
                                "已输入并完成回读，但输入框现在属于密码或验证码等敏感字段，未发起键盘提交。请交给用户核对；不要重复输入。", ok = false)
                        }
                        if (cancelled(gen) || !allowed()) false else r.node.performAction(id)
                    }
                }
                // l10n:keep agent screen result
                if (submitted) message += "已提交键盘上的发送 / 搜索操作。"
                // l10n:keep agent screen result
                else return after(before, r.snap, gen,
                    "$message 但键盘提交未获系统确认；不要重复输入或提交，请先核对新屏幕。", ok = false)
            }
            return after(before, r.snap, gen, message)
        } finally { r.cap.recycle() }
    }

    private fun scroll(a: PhoneAction.Scroll, gen: Long, allowed: () -> Boolean,
                       actionSourcesAllowed: (Set<String>) -> Boolean): ActionResult {
        val snap = latest
        val dirWord = when (a.direction) {
            // l10n:keep agent screen result
            PhoneAction.Direction.DOWN -> "向下"; PhoneAction.Direction.UP -> "向上"
            // l10n:keep agent screen result
            PhoneAction.Direction.LEFT -> "向左"; PhoneAction.Direction.RIGHT -> "向右"
        }
        // The element to scroll: the given one (or its list), else the biggest list on screen.
        var targetId: Int? = a.elementId
        if (targetId != null && snap != null && snap.id == a.screenId) {
            val el = snap.screen.element(targetId)
            if (el != null && el.kind != ElementKind.LIST) targetId = el.listId ?: targetId
        } else if (targetId == null && snap != null && snap.id == a.screenId) {
            targetId = snap.screen.elements.filter { it.kind == ElementKind.LIST }.maxByOrNull { it.bounds.area }?.id
        }
        if (targetId == null) {
            // l10n:keep agent screen result
            if (snap == null || snap.id != a.screenId) return ActionResult(false, "屏幕编号 ${a.screenId} 已过期，请先看新屏幕再滚动。", observeQuiet())
            val cap = capture()
            try {
                // l10n:keep agent screen result
                if (cap.ownAppInFront && !lifted.ownApp) return ActionResult(false, "这是 DSH 自己的界面，不操作。")
                // l10n:keep agent screen result
                if (unavailable(cap)) return ActionResult(false, "这一屏读不到内容（可能受敏感视图策略限制），不盲滑。请 handoff。", toSnapshot(publish(cap, false)))
                // l10n:keep agent screen result
                val current = observation(cap)
                if (!current.reusableCoordinates(snap.observation)) {
                    val reason = if (current.hasSecretFields || snap.observation.hasSecretFields)
                        "当前或上次观察含密码 / 验证码 / 支付框，不按坐标滑动。请 handoff 交给用户。" // l10n:keep agent safety result
                    else "无法确认当前界面仍与上一屏一致，没有滚动。请先看新屏幕。" // l10n:keep agent screen result
                    return ActionResult(false, reason, toSnapshot(publish(cap, false)))
                }
                val sources = cap.windows.mapNotNull { it.packageName }.toSet()
                refuseHalted { allowed() && actionSourcesAllowed(sources) }?.let { return it }
                val screen = cap.screen
                val before = clock.count
                val out = actuator.scroll(null, 0, a.direction == PhoneAction.Direction.LEFT || a.direction == PhoneAction.Direction.RIGHT,
                    Box(screen.left, screen.top + screen.height / 5, screen.right, screen.bottom - screen.height / 6), screen, a.direction) {
                    !cancelled(gen) && allowed() && actionSourcesAllowed(sources)
                }
                // l10n:keep agent screen result
                if (!out.accepted) return after(before, snap, gen,
                    "系统未确认滑动完成，可能已有部分效果；请先核对新屏幕，不要直接重试。", scrolled = true, ok = false)
                // l10n:keep agent screen result
                return after(before, snap, gen, "已提交${dirWord}滑动屏幕。", scrolled = true)
            } finally { cap.recycle() }
        }
        val res = resolve(a.screenId, targetId)
        val r = res as? Resolved ?: return res as ActionResult
        try {
            // l10n:keep agent screen result
            if ((r.el.packageName == ownPackage || r.snap.ownApp) && !lifted.ownApp) return ActionResult(false, "这是 DSH 自己的界面，不操作。")
            // Without a matching node action, scroll uses a screen gesture within these bounds.
            val sources = r.cap.windows.mapNotNull { it.packageName }.toSet()
            refuseHalted { allowed() && actionSourcesAllowed(sources) }?.let { return it }
            val before = clock.count
            val out = actuator.scroll(r.node, r.el.scroll, r.el.horizontal, r.el.bounds, r.cap.screen, a.direction) {
                !cancelled(gen) && allowed() && actionSourcesAllowed(sources)
            }
            // l10n:keep agent screen result
            if (!out.accepted) return after(before, r.snap, gen,
                "系统未确认${dirWord}滚动完成，无法确认是否到底；可能已有部分效果，不要直接重试。", scrolled = true, ok = false)
            // l10n:keep agent screen result
            return after(before, r.snap, gen, "已提交${dirWord}滚动${if (r.el.kind == ElementKind.LIST) "列表 [${r.el.id}]" else ""}。", scrolled = true)
        } finally { r.cap.recycle() }
    }

    private fun key(a: PhoneAction.Key, gen: Long): ActionResult {
        val before = clock.count
        // l10n:keep agent screen result
        if (!actuator.global(a.key)) return ActionResult(false, "系统没有执行这个按键。")
        val what = when (a.key) {
            // l10n:keep agent screen result
            PhoneAction.GlobalKey.BACK -> "已提交返回键操作。"
            // l10n:keep agent screen result
            PhoneAction.GlobalKey.HOME -> "已提交回到桌面的按键操作。"
            // l10n:keep agent screen result
            PhoneAction.GlobalKey.RECENTS -> "已提交打开最近任务的按键操作。"
            // l10n:keep agent screen result
            PhoneAction.GlobalKey.NOTIFICATIONS -> "已提交打开通知栏的按键操作。"
        }
        return after(before, latest, gen, what)
    }

    private fun tapXY(a: PhoneAction.TapXY, gen: Long, allowed: () -> Boolean,
                      coordinateAdmission: ((() -> Boolean) -> Boolean)?): ActionResult {
        val snap = latest
        if (snap == null || snap.id != a.screenId) {
            val now = observeQuiet()
            // l10n:keep agent screen result
            return ActionResult(false, "屏幕编号 ${a.screenId} 已过期，坐标对不上了。请重新 screen 加 image 再点。", now)
        }
        // l10n:keep agent screen result
        val image = snap.image?.takeIf { visual.imageAccepted(snap.id) && coordinateEpochCurrent(snap) }
            ?: return ActionResult(false, "屏幕 ${a.screenId} 没有已通过本次过滤的截图。坐标操作要先用 screen 加 image 拿一张实际保留的截图。")
        val geometry = image.geometry
        // l10n:keep agent screen result
        if (!image.isFresh(SystemClock.uptimeMillis())) return ActionResult(false, "截图已超过 30 秒，没有点击。请重新 screen 加 image 再点。", observeQuiet())
        val point = geometry.toScreen(a.x, a.y)
            // l10n:keep agent screen result
            ?: return ActionResult(false, "坐标 (${a.x}, ${a.y}) 不在这张截图里（${geometry.width}×${geometry.height}）。")
        // l10n:keep agent screen result
        if (snap.ownApp && !lifted.ownApp) return ActionResult(false, "这是 DSH 自己的界面，不操作。")
        // l10n:keep agent screen result
        if (snap.protectedPage && !lifted.systemPages) return ActionResult(false, "这是系统权限 / 安全相关页面，DSH 不在这里点击。需要的话请用 handoff 交给用户。")
        // l10n:keep agent screen result
        if (snap.hidden || snap.unreadable) return ActionResult(false, "这一屏读不到内容（可能受敏感视图策略限制），不盲点。请 handoff。", observeQuiet())
        val end = if (a.gesture == PhoneAction.CoordinateGesture.SWIPE) {
            if (a.durationMs !in 100..2_000) return ActionResult(false, "滑动时长须为 100–2000 毫秒。") // l10n:keep
            geometry.toScreen(a.x2 ?: -1, a.y2 ?: -1)
                ?: return ActionResult(false, "滑动终点不在截图内。") // l10n:keep
        } else null
        val beforeImage: ImageObservation
        val originalScope = visual.scope(snap.id)
        // Taken before verifying: a window shown after it refuses the start even when the scope is unknown.
        val transitions = visual.transitions()
        val ordinary = if (a.gesture == PhoneAction.CoordinateGesture.TAP) snap.visualEvidence?.target(point.first, point.second) else null
        val cap = capture()
        try {
            // l10n:keep agent screen result
            if (unavailable(cap)) return ActionResult(false, "这一屏读不到内容（可能受敏感视图策略限制），不盲点。请 handoff。", toSnapshot(publish(cap, false)))
            // l10n:keep agent screen result
            val current = observation(cap)
            if (!current.reusableCoordinates(snap.observation)) {
                val reason = if (current.hasSecretFields || snap.observation.hasSecretFields)
                    "当前或上次观察含密码 / 验证码 / 支付框，不执行坐标手势。请 handoff 交给用户。" // l10n:keep agent safety result
                else "无法确认当前界面仍与截图一致，没有点击。请重新看屏幕。" // l10n:keep agent screen result
                return ActionResult(false, reason, toSnapshot(publish(cap, false)))
            }
            // The same shared classifier is re-run on the full fresh tree, including ACTION_CLICK,
            // ancestry and every overlapping branch. A grant cannot preserve an obsolete classification.
            if (ordinary != null && (visual.scope(snap.id) !== originalScope ||
                    visualEvidence(cap)?.target(point.first, point.second) != ordinary)) {
                return ActionResult(false, "截图中的目标或可确认范围已变化，没有执行。请重新读屏。", toSnapshot(publish(cap, false))) // l10n:keep agent safety result
            }
            val shot = captureVerificationShot(cap)
            val currentImage = shot?.observation
            if (cancelled(gen)) throw InterruptedException()
            // l10n:keep agent screen result
            if (currentImage == null || !image.sameViewportAs(currentImage, SystemClock.uptimeMillis())) {
                val refreshed = publish(cap, false)
                return ActionResult(false,
                    "截图已过期、窗口几何已变化或无法重新截图，没有点击。请重新 screen 加 image 再点。",
                    toSnapshot(refreshed).copy(secure = refreshed.hidden || shot?.secure == true))
            }
            beforeImage = currentImage
        } finally { cap.recycle() }
        if (cancelled(gen)) throw InterruptedException()
        // A dispatched gesture consumes the coordinates even if its callback or verification fails.
        if (!coordinateEpochCurrent(snap) || !visual.consume(snap.id)) return ActionResult(false, "本次截图已失效，没有执行。请重新读屏。") // l10n:keep agent result
        snap.image = null
        val before = clock.count
        val dispatchScope = visual.scope(snap.id)
        val admission = coordinateAdmission ?: { claim: () -> Boolean -> allowed() && claim() }
        val start: (() -> Boolean) -> Boolean = { send ->
            actuator.coordinateStart({ published() && abortGen == gen && !overlay.editing && coordinateEpochCurrent(snap) && visual.isCurrent(dispatchScope, transitions) }, admission, send)
        }
        // l10n:keep agent screen result
        val accepted = when (a.gesture) {
            PhoneAction.CoordinateGesture.TAP -> actuator.tap(point.first, point.second, start = start)
            PhoneAction.CoordinateGesture.LONG -> actuator.tap(point.first, point.second, true, start)
            PhoneAction.CoordinateGesture.SWIPE -> actuator.swipe(point.first, point.second, end!!.first, end.second, a.durationMs, start)
        }
        if (!accepted) {
            val message = "系统未确认手势完成；可能已产生部分效果，请先读屏，不要直接重试。" // l10n:keep
            if (cancelled(gen)) return ActionResult(false, message)
            return after(before, snap, gen, message, previousImage = beforeImage, ok = false)
        }
        // l10n:keep agent screen result
        val verb = when (a.gesture) { PhoneAction.CoordinateGesture.TAP -> "点击"; PhoneAction.CoordinateGesture.LONG -> "长按"; PhoneAction.CoordinateGesture.SWIPE -> "滑动" }
        return after(before, snap, gen, "已提交${verb}截图上的 (${a.x}, ${a.y})。", previousImage = beforeImage)
    }

    /** Waits for the UI to settle, reads the new screen (`+` marks) and says whether anything changed. */
    private fun after(before: Long, previous: Snapshot?, gen: Long, message: String, scrolled: Boolean = false, previousImage: ImageObservation? = actionBeforeImage, ok: Boolean = true,
                      navigation: MarkorNavigation.Before? = null, navigationPost: ((SkillReplayPost) -> Unit)? = null): ActionResult {
        if (cancelled(gen)) throw InterruptedException()
        clock.settle(before, 1_500, 300, 3_000) { cancelled(gen) }
        if (cancelled(gen)) throw InterruptedException()
        val cap = try { if (previousImage == null) settledCapture(previous, gen, typed = navigation != null) else capture(typed = navigation != null) } catch (e: InterruptedException) { throw e } catch (e: Exception) {
            Log.w(TAG, "observation after an accepted action failed", e)
            // l10n:keep agent screen result
            return ActionResult(ok, "$message（没能读到新屏幕，无法追加验证；不要自动重试。）")
        }
        try {
            val snap = publish(cap, false)
            val old = previous?.observation
            val observation = snap.observation
            val comparable = old != null && observation.comparableTo(old)
            val changed = old != null && observation.changedFrom(old)
            val keyboard = old?.let { observation.keyboardChange(it) }
            // Missing content still needs an explicit warning, even when app/window/IME changed.
            val note = if (ok) ScreenVerdict.note(comparable = comparable, changed = changed, keyboard = keyboard, scrolled = scrolled)
                else unconfirmedActionNote(comparable, changed, keyboard)
            val canReuse = comparable && observation.sameContext(old) && observation.keyboardShown == old.keyboardShown
            val text = if (snap.focus != null) snap.screen.text else ScreenDigest.text(previous?.id, previous?.screen, snap.id, snap.screen, canReuse = canReuse, observationChanged = changed)
            var ocrText = if (snap.screen.poorTree) "\n" + LocalOcrBoundary.message(shooter.localTextWithoutFrame()) else ""
            var nextImage: ImageObservation? = null
            var screenshotSecure = false
            val epoch = localOcr.enabledEpoch()
            val remaining = actionDeadline - SystemClock.uptimeMillis()
            val readLocal = snap.screen.poorTree && epoch != null && ocrAllowed(cap, snap, gen)
            if (snap.screen.poorTree && epoch != null && !readLocal) {
                ocrText = "\n" + LocalOcrBoundary.message(LocalOcrResult.Unavailable(LocalOcrResult.Reason.PRIVACY_UNVERIFIED))
            }
            val compareFrame = previousImage != null && !unavailable(cap) && !snap.ownApp &&
                !snap.protectedPage && old != null && observation.sameContext(old)
            try {
                if ((compareFrame || readLocal) && remaining > 300) {
                    val capturedTransitions = visual.transitions()
                    val shot = shooter.shoot(cap.windows.singleOrNull(), cap.screen, emptyList(), emptyList(),
                        minOf(2_500, remaining - 300), image = false,
                        readLocalText = readLocal,
                        localTextPrivacyAllowed = readLocal,
                        localTextCancelled = { !ocrAllowed(cap, snap, gen) || localOcr.enabledEpoch() != epoch })
                    screenshotSecure = shot.secure
                    if (screenshotSecure) {
                        visual.observed(null, null)
                        ocrText = ""
                    }
                    if (compareFrame && !shot.secure && !cancelled(gen) && availability().ok) {
                        nextImage = shot.observation
                    }
                    val stillCurrent = !screenshotSecure && readLocal && verifyOcrContext(cap, snap, gen, actionDeadline)
                    if (stillCurrent && epoch != null && epoch == localOcr.enabledEpoch() &&
                        snap.screen.poorTree && shot.geometry != null && shot.viewport != null) {
                        val result = shot.visualText()!!
                        if (SystemClock.uptimeMillis() < actionDeadline && epoch == localOcr.enabledEpoch() &&
                            ocrAllowed(cap, snap, gen)) {
                            ocrText = "\n" + result.text
                            if (!result.sensitiveText && result.hasPoints && shot.observation != null) {
                                snap.image = shot.observation
                                snap.ocrOnlyEpoch = epoch
                                visual.candidate(snap.id, capturedTransitions)
                            }
                        }
                    }
                }
            } catch (e: InterruptedException) { throw e } catch (_: Exception) {
                // Preserve the input attempt's original result; verification cannot turn it into success.
                ocrText = if (snap.screen.poorTree) "\n" + LocalOcrBoundary.message(
                    LocalOcrResult.Failed(LocalOcrResult.Failure.ENGINE)) else ""
                nextImage = null
            }
            val visualNote = if (previousImage == null) "" else {
                val change = nextImage?.changeFrom(previousImage) ?: VisualFrame.Change.UNAVAILABLE
                when (change) {
                    // l10n:keep agent screen result
                    VisualFrame.Change.CHANGED -> "（截图中有明显画面变化；这不代表目标操作已成功。）"
                    // l10n:keep agent screen result
                    VisualFrame.Change.UNCHANGED -> "（截图未见明显画面变化，无法验证这次操作；不要自动重复操作。）"
                    // l10n:keep agent screen result
                    VisualFrame.Change.UNAVAILABLE -> "（截图无法比较，不能验证这次操作；不要自动重复操作。）"
                }
            }
            val observedNavigation = if (ok && !snap.hidden && !screenshotSecure && !cancelled(gen))
                navigation?.let { MarkorNavigation.afterObservation(service, it, cap) }?.takeIf { typedCurrent(cap) } else null
            if (observedNavigation != null) navigationPost?.invoke(
                if (observedNavigation.selected == "nav_more") SkillReplayPost.SATISFIED else SkillReplayPost.DIFFERENT)
            val witness = if (observedNavigation?.selected == "nav_more") navigation?.app?.let {
                com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillNavigationWitness(it.uid, it.version, it.updated, it.signers)
            } else null
            return ActionResult(ok, message + note + visualNote, toSnapshot(snap, text + ocrText).copy(secure = snap.hidden || screenshotSecure),
                navigationWitness = witness)
        } finally { cap.recycle() }
    }

    /** Verification frames stay local: no JPEG, no element numbering and no published observation. */
    private fun captureVerificationShot(cap: Capture): Shot? {
        val window = cap.windows.singleOrNull()
        val remaining = actionDeadline - SystemClock.uptimeMillis()
        if (remaining <= 0) return null
        val shot = shooter.shoot(window, cap.screen, emptyList(), emptyList(), minOf(2_500, remaining), image = false,
            localTextCancelled = { !published() || Thread.currentThread().isInterrupted })
        if (shot.secure) visual.observed(null, null)
        return shot
    }

    /**
     * A capture after an action. Right after a transition the new window may have no root yet
     * or an empty tree (Chrome, Settings sub-pages): retry a few times while that lasts.
     */
    private fun settledCapture(previous: Snapshot?, gen: Long, typed: Boolean = false): Capture {
        var cap = capture(typed = typed)
        var tries = 0
        while (tries++ < 4 && !cancelled(gen) && looksUnfinished(cap, previous)) {
            cap.recycle()
            clock.pause(400) { cancelled(gen) }
            cap = capture(typed = typed)
        }
        return cap
    }

    private fun looksUnfinished(cap: Capture, previous: Snapshot?): Boolean =
        cap.hiddenWindowTitle == null &&
            (cap.windows.isEmpty() || (ScreenFormat.textCount(cap.windows) < ScreenFormat.POOR_TREE && previous?.screen?.poorTree != true))

    /** Classifies metadata from the caller's successful refresh, without another platform read. */
    private fun isSecretField(node: AccessibilityNodeInfo): Boolean {
        val hint = ScreenFormat.clean(node.hintText?.toString())
            ?: if (node.isShowingHintTextCompat()) ScreenFormat.clean(node.text?.toString()) else null
        return node.isPassword || SensitiveWords.secretHit(
            hint, node.contentDescription?.toString(), node.viewIdResourceName,
        ) != null
    }

    /** Polls refreshed content; null means refresh failed. The 1.5 s limit does not bound a platform call. */
    private fun readBack(node: AccessibilityNodeInfo, expected: String, gen: Long): String? {
        val deadline = SystemClock.uptimeMillis() + 1_500
        var got: String? = null
        while (true) {
            if (!node.refresh()) return null
            got = if (node.isShowingHintTextCompat()) "" else node.text?.toString().orEmpty()
            if (sameText(got, expected) || SystemClock.uptimeMillis() > deadline || cancelled(gen)) return got
            clock.pause(100) { cancelled(gen) }
        }
    }

    private fun AccessibilityNodeInfo.isShowingHintTextCompat() = android.os.Build.VERSION.SDK_INT >= 26 && isShowingHintText

    /** Only the exact requested text counts as a matching read-back. */
    private fun sameText(got: String?, expected: String): Boolean = got == expected

    private fun awaitInputIdle(): Boolean {
        val deadline = SystemClock.uptimeMillis() + 8_000
        while (overlay.editing) {
            if (SystemClock.uptimeMillis() > deadline) return false
            clock.pause(150)
        }
        return true
    }

    // ---- snapshots --------------------------------------------------------------------------------

    /** Debug-only, read-only material; never publishes a model snapshot or performs input. */
    internal fun navigationMaterial(): NavigationMaterials.Result {
        val deadline = SystemClock.uptimeMillis() + 8_000L
        val gen = abortGen
        if (!published() || !availability().ok || cancelled(gen)) return NavigationMaterials.Unavailable("unavailable")
        val installed = MarkorNavigation.installed(service)
            ?: return NavigationMaterials.Unavailable("installation_unverified")
        if (SystemClock.uptimeMillis() >= deadline || cancelled(gen)) return NavigationMaterials.Unavailable("unavailable")
        val cap = capture(minOf(CAPTURE_MS, deadline - SystemClock.uptimeMillis()), typed = true)
        try {
            val window = cap.windows.singleOrNull() ?: return NavigationMaterials.Unavailable("incomplete")
            if (cap.packageName != MarkorNavigation.PACKAGE || window.packageName != MarkorNavigation.PACKAGE)
                return NavigationMaterials.Unavailable("app_mismatch")
            if (window.kind != WindowKind.APP || window.root == null || cap.partial || cap.truncated ||
                !cap.visualComplete || cap.keyboardShown != false || cap.hiddenWindowTitle != null ||
                cap.unreadableWindowTitle != null || cap.ownAppInFront || cap.systemInFront)
                return NavigationMaterials.Unavailable("incomplete")
            val nodes = NavigationMaterials.project(window.root, installed.second) { node ->
                cap.native(node.ref)?.actionList?.take(33)?.map { it.id }
            } ?: return NavigationMaterials.Unavailable("limit")
            if (MarkorNavigation.installed(service) != installed)
                return NavigationMaterials.Unavailable("installation_unverified")
            if (!typedCurrent(cap) || cancelled(gen) || SystemClock.uptimeMillis() >= deadline)
                return NavigationMaterials.Unavailable("changed")
            val transitions = cap.typedTransitions
            val events = cap.typedEvents
            val app = installed.first
            val fields = mapOf("packageName" to MarkorNavigation.PACKAGE,
                "installation" to mapOf("uid" to app.uid, "version" to app.version,
                    "updated" to app.updated, "signingDigest" to app.signers),
                "capture" to mapOf("partial" to cap.partial, "truncated" to cap.truncated,
                    "visualComplete" to cap.visualComplete, "keyboardShown" to cap.keyboardShown, "typedCurrent" to true),
                "window" to mapOf("id" to window.id, "kind" to "app", "bounds" to NavigationMaterials.bounds(window.bounds)),
                "nodes" to nodes)
            return NavigationMaterials.Sample(fields) {
                published() && !cancelled(gen) && SystemClock.uptimeMillis() < deadline &&
                    transitions != null && transitions == visual.transitions() && events == clock.count
            }
        } finally { cap.recycle() }
    }

    private fun typedCurrent(cap: Capture): Boolean = cap.typedTransitions?.let {
        published() && it == visual.transitions() && cap.typedEvents == clock.count
    } == true

    private fun capture(timeoutMs: Long = CAPTURE_MS, typed: Boolean = false): Capture {
        val transitions = if (typed) visual.transitions() else null
        val events = if (typed) clock.count else null
        // Cache invalidation is a qualification input, not an assertion of an atomic WMS snapshot.
        val fresh = Build.VERSION.SDK_INT in 34..37 && runCatching { service.clearCache() }.getOrDefault(false)
        try {
            return TreeCapture.capture(service, screenBox(), ownPackage, timeoutMs, transitions.takeIf { fresh }, events.takeIf { fresh }).also { cap ->
                val window = cap.windows.singleOrNull()
                val titles = cap.windows.mapNotNull { it.title } + ProtectedPages.titleTexts(window?.root, cap.screen.height)
                val known = fresh && published() && cap.visualComplete && window?.kind == WindowKind.APP &&
                    !cap.ownAppInFront && !cap.systemInFront && cap.keyboardShown == false &&
                    !unavailable(cap) && secretFieldBounds(cap.windows).isEmpty() &&
                    !ProtectedPages.isProtected(cap.packageName, titles)
                visual.observed(if (known) cap.visualWindowId else null, if (known) cap.packageName else null)
            }
        } catch (e: Throwable) { visual.observed(null, null); throw e }
    }

    private fun visualEvidence(cap: Capture): MainVisualEvidence? = cap.windows.singleOrNull()?.let {
        MainVisualEvidence(it, cap.screen, cap.visualComplete, cap.visualOcclusions)
    }

    private fun unavailable(cap: Capture) = WindowContent.unavailable(cap.hiddenWindowTitle != null, cap.unreadableWindowTitle != null, cap.windows)

    private fun observation(cap: Capture) = ScreenObservation(
        cap.packageName, cap.windows, cap.screen, cap.keyboardShown, unavailable(cap), cap.truncated || cap.partial,
        ScreenFormat.observationKeys(cap.windows),
    )

    private fun locate(cap: Capture, el: ScreenElement): IndexedElement? =
        ScreenFormat.index(cap.windows).singleOrNull { it.fingerprint == el.fingerprint }

    /** Formats [cap] as the next snapshot (`s<n>`) and makes it the latest. */
    private fun publish(cap: Capture, detail: Boolean): Snapshot {
        val id = "${PhoneScreen.MAIN.prefix}${counter.incrementAndGet()}"
        val pkg = cap.packageName
        val appLabel = label(pkg)
        val titles = cap.windows.mapNotNull { it.title } + ProtectedPages.titleTexts(cap.windows.firstOrNull()?.root, cap.screen.height)
        val protectedPage = ProtectedPages.isProtected(pkg, titles)
        // A note already shown on the previous screen of this app is not repeated: the model
        // still has it, and a warning on every screen reads as nagging.
        val seen = if (latest?.packageName == pkg) latest?.noteKeys ?: emptySet() else emptySet()
        val notes = mutableListOf<Pair<String, String>>()
        fun note(key: String, text: String) { if (key !in seen) notes += key to text }
        val lifted = lifted
        // l10n:keep agent screen result
        if (cap.ownAppInFront && !lifted.ownApp) note("ownApp", "提示：这是 DSH 自己的界面，DSH 不操作它。")
        // l10n:keep agent screen result
        if (protectedPage && !lifted.systemPages) note("protected", "提示：这是系统权限 / 安全相关页面，DSH 只看不操作；需要的话用 handoff 交给用户。")
        // l10n:keep agent screen result
        if (cap.truncated) note("truncated", "提示：页面元素太多，只读了一部分。")
        // l10n:keep agent screen result
        if (cap.partial) note("partial", "提示：部分窗口或元素读不到，当前观测不完整。")
        if (cap.hiddenWindowTitle != null) {
            val name = cap.hiddenWindowTitle.takeIf { it.isNotBlank() }?.let { "「$it」" } ?: ""
            // l10n:keep agent screen result
            note("hidden", "提示：当前无法读取前台页面${name}（可能受敏感视图策略限制）。读不到也点不了，需要就 handoff。")
        // l10n:keep agent screen result
        } else if (cap.unreadableWindowTitle != null) {
            val name = cap.unreadableWindowTitle.takeIf { it.isNotBlank() }?.let { "「$it」" } ?: ""
            // l10n:keep agent screen result
            note("unreadable", "提示：当前无法读取这一屏${name}的有效内容，可能受敏感视图策略限制（Android 14 起密码、支付、验证页会被系统过滤）。读不到也点不了；能看图的模型可以 screen 加 image，否则请 handoff。")
        // l10n:keep agent screen result
        } else if (cap.windows.isEmpty()) note("empty", "提示：读不到前台界面（可能是锁屏、安全页面或系统界面）。")
        val previous = latest?.takeIf { it.packageName == pkg }?.screen?.keys
        fun format(notes: List<Pair<String, String>>) = ScreenFormat.format(
            ScreenInput(
                screenId = id, appLabel = appLabel, packageName = pkg,
                screenWidth = cap.screen.width, screenHeight = cap.screen.height, keyboardShown = cap.keyboardShown,
                windows = cap.windows, detail = detail, previousKeys = previous, notes = notes.map { it.second },
                unreadable = cap.unreadableWindowTitle != null,
            ),
        )
        var formatted = format(notes)
        var noteKeys = notes.map { it.first }.toSet()
        // Such inputs still read 「不可代填」 (their fingerprints must not change with the setting):
        // say once, on the screens that have one, that the person allowed filling them.
        if (lifted.secretFields && "secretFields" !in seen && formatted.elements.any { it.password || it.secret }) {
            // l10n:keep agent screen result
            notes += "secretFields" to "提示：用户已允许 DSH 填写密码和验证码，标着「不可代填」的输入框也可以输入。"
            noteKeys = noteKeys + "secretFields"
            formatted = format(notes)
        }
        val snap = Snapshot(
            id, formatted, pkg, appLabel, protectedPage, cap.ownAppInFront,
            cap.hiddenWindowTitle != null, cap.unreadableWindowTitle != null, observation(cap), noteKeys,
            visualEvidence(cap), cap.windows.mapNotNull { it.packageName }.toSet(),
        )
        latest = snap
        replaceFocusCandidate(cap, snap)
        visual.publish(id)
        return snap
    }

    private fun toSnapshot(s: Snapshot, text: String = s.screen.text) =
        ScreenSnapshot(s.id, text, s.appLabel, s.packageName, secure = s.hidden, poorTree = s.screen.poorTree, readPackages = s.readPackages, focus = s.focus)

    /** A fresh text snapshot for an action result; null when the screen can't be read now. */
    private fun observeQuiet(): ScreenSnapshot? {
        if (!availability().ok) return null
        return try {
            val cap = capture()
            try { toSnapshot(publish(cap, false)) } finally { cap.recycle() }
        } catch (e: InterruptedException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "observe failed", e)
            null
        }
    }

    // l10n:keep agent screen result
    private fun blank(reason: String): ScreenSnapshot {
        clearFocusCandidate()
        visual.invalidate()
        return ScreenSnapshot("${PhoneScreen.MAIN.prefix}0", "屏幕读不到：$reason", null, null) // l10n:keep agent screen result
    }

    private fun screenBox(): Box {
        val p = Point()
        @Suppress("DEPRECATION")
        displays.getDisplay(Display.DEFAULT_DISPLAY)?.getRealSize(p)
        return Box(0, 0, p.x.coerceAtLeast(1), p.y.coerceAtLeast(1))
    }

    private fun label(pkg: String?): String? {
        if (pkg == null) return null
        labels[pkg]?.let { return it }
        val name = try {
            val pm = service.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
        } catch (_: Exception) { return null }
        labels[pkg] = name
        return name
    }

    private fun cancelled(gen: Long) = abortGen != gen || Thread.currentThread().isInterrupted

    private fun short(s: String, max: Int = 24) = ScreenFormat.clip(s, max)

    companion object {
        private const val TAG = "DshA11y"
        // l10n:keep agent focus result
        private const val FOCUS_UNAVAILABLE = "当前没有本任务已返回且可核对的焦点输入框，或系统不支持原焦点连接；请先由用户聚焦后重新读屏。"
        // l10n:keep agent focus result
        private const val FOCUS_CHANGED = "原焦点、选区或任务状态已变化，未提交输入；请重新读屏，不会自动改靶。"
        // l10n:keep agent focus result
        private const val FOCUS_UNKNOWN = "已尝试一次焦点输入，但有限回读不足以确认结果；可能已产生效果，不要重发或切换输入方式。"


        /**
         * A `type` whose read-back differs from what was typed. An ordinary input says what it
         * holds now; a password or code field ([SafetyRules.isSecretTarget], as for the log's ••••)
         * never does: the tool result goes to the model.
         */
        internal fun readBackMismatch(got: String?, target: TargetInfo, currentSecret: Boolean = false): String {
            // l10n:keep agent screen result
            if (got == null) return "已输入，但未能确认当前输入框内容。没有重试，也没有提交；请看新屏幕决定下一步。"
            // l10n:keep agent screen result
            val now = if (currentSecret || SafetyRules.isSecretTarget(target)) "这是密码 / 验证码框，框里的内容不回传"
            // l10n:keep agent screen result
            else "框里现在是" + ScreenMask.mask(got).let { if (it.isEmpty()) "空" else "「${ScreenFormat.clip(it, 40)}」" }
            // l10n:keep agent screen result
            return "已输入，但回读不一致：$now。没有重试，也没有提交；请看新屏幕决定下一步。"
        }

        /** Asked again right before each physical dispatch: a pause or stop can land while the target resolves. */
        internal fun refuseHalted(allowed: () -> Boolean): ActionResult? =
            if (allowed()) null else ActionResult(false, "本任务已暂停或停止，没有继续操作。") // l10n:keep agent result

        /** Process-wide: a reconnected service must never hand out an id the model still holds. */
        private val counter = java.util.concurrent.atomic.AtomicInteger()
        private const val OBSERVE_MS = 4_800L
        private const val CAPTURE_MS = 2_000L
        private const val COLLECT_MS = 100_000L
        private const val COLLECT_CHARS = 60_000
    }
}

/** Null belongs to a published image; OCR-only evidence must retain exactly its original ON epoch. */
internal fun mainOcrEpochCurrent(observationEpoch: Long?, enabledEpoch: Long?): Boolean =
    observationEpoch == null || observationEpoch == enabledEpoch

/** No completed-request receipt: unchanged content is not evidence that scrolling reached its end. */
internal fun unconfirmedActionNote(comparable: Boolean, changed: Boolean, keyboard: String?): String =
    keyboard ?: if (comparable && changed) "" else
        "（本次结果仍未确认，请先核对屏幕，不要自动重试。）" // l10n:keep agent result

/** Bind the bounded original-wrapper sample to the observed absolute node/F1 selection. */
internal fun focusSampleMatchesSelection(sample: FocusReadback.Sample?, start: Int, end: Int): Boolean {
    if (sample == null || sample.offset < 0 || start < 0 || end < 0 || sample.text.length > 4096 ||
        sample.selectionStart !in 0..sample.text.length || sample.selectionEnd !in 0..sample.text.length) return false
    fun boundary(at: Int): Boolean = when (at) {
        0 -> sample.text.isEmpty() || !Character.isLowSurrogate(sample.text[0])
        sample.text.length -> !Character.isHighSurrogate(sample.text[at - 1])
        else -> !(Character.isHighSurrogate(sample.text[at - 1]) && Character.isLowSurrogate(sample.text[at]))
    }
    return boundary(sample.selectionStart) && boundary(sample.selectionEnd) &&
        sample.offset.toLong() + sample.selectionStart == start.toLong() &&
        sample.offset.toLong() + sample.selectionEnd == end.toLong()
}
