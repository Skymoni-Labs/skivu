// Portions derived from Phase (https://github.com/CikeSeven/phase), used with the author's permission. See THIRD_PARTY_NOTICES.md.
// Local changes: blocking, one owner per task (the bridge serialises calls on one worker
// thread); a UiAutomation control-tree read rendered to the screen text format, so text-only
// models can use 不打扰模式 too; IME policy HIDE; JPEG capture with bounded first-frame readiness; display
// sized to the phone's aspect (short side 720). No commands, paths or display ids are accepted
// from callers.
package com.skyjjgw.independent.ski.dshgo.phone.background

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.ActivityOptions
import android.app.KeyguardManager
import android.app.PendingIntent
import android.app.UiAutomation
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import com.skyjjgw.independent.ski.dshgo.phone.a11y.ImageGeometry
import com.skyjjgw.independent.ski.dshgo.phone.a11y.ImageObservation
import com.skyjjgw.independent.ski.dshgo.phone.a11y.VisualFrame
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.hardware.input.InputManager
import android.media.ImageReader
import android.os.Build
import android.os.IBinder
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.os.Trace
import android.os.UserHandle
import com.skyjjgw.independent.ski.dshgo.phone.PhoneAppIdentity
import android.text.InputType
import android.util.SparseArray
import android.view.Display
import android.view.InputDevice
import android.view.InputEvent
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import com.skyjjgw.independent.ski.dshgo.phone.SensitiveWords
import com.skyjjgw.independent.ski.dshgo.phone.VisualBounds
import com.skyjjgw.independent.ski.dshgo.phone.VisualNode
import com.skyjjgw.independent.ski.dshgo.phone.VisualTargets
import com.skyjjgw.independent.ski.dshgo.phone.selfcheck.TargetContract
import com.skyjjgw.independent.ski.dshgo.phone.selfcheck.TargetFramePattern
import java.io.ByteArrayOutputStream
import java.lang.reflect.InvocationTargetException
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.ExecutorService
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Runs as shell uid (inside the Shizuku UserService, or the adb-launched app_process).
 * Owns at most one trusted virtual display at a time (one per task) and all the
 * privileged primitives against it. Thread-safe via a single lock; every op has its own
 * deadline. Never throws across the call boundary: faults become a stable [Proto.ERROR] code.
 */
class PrivilegedDisplayCore internal constructor(
    private val context: Context,
    private val trees: PrivilegedTreeAccess,
    private val hosted: HostedScope? = null,
) {

    // Guarded by lock, one recent frame only; never a permission to drive coordinates.
    private var visualObservation: BackgroundVisualObservation? = null
    private var coordinateObservation: BackgroundCoordinateObservation? = null

    private val privileged: Context by lazy {
        if (Process.myUid() == Process.SHELL_UID)
            context.createPackageContext("com.android.shell", Context.CONTEXT_IGNORE_SECURITY)
        else context
    }
    private val displays by lazy { privileged.getSystemService(DisplayManager::class.java) }
    private val activities by lazy { privileged.getSystemService(ActivityManager::class.java) }
    private val keyguard by lazy { privileged.getSystemService(KeyguardManager::class.java) }
    private val taskDisplayIdField by lazy {
        runCatching { ActivityManager.RunningTaskInfo::class.java.getField("displayId") }.getOrNull()
    }

    private val lock = ReentrantLock()
    private val preview = BackgroundPreviewState()
    // Only created after an explicit preview request; never creates a display or a channel.
    private val previewWorker = BackgroundPreviewWorker()
    @Volatile private var owner: String? = hosted?.owner
    @Volatile private var display: VirtualDisplay? = null
    @Volatile private var reader: ImageReader? = null
    private var pendingReader: ImageReader? = null
    private var readerAllocationUncertain = false
    private var width = 0
    private var height = 0
    private val released = AtomicBoolean(false)
    private var strictOwner = hosted != null
    private var targetSequence: SelfCheckTargetSequence? = hosted?.target?.let { SelfCheckTargetSequence(it.owner, it.run, it.c2) }
    private var targetSnapshot: TargetSnapshot? = null
    private val targetIdentity = TargetIdentity()
    private var targetMain: SelfCheckMainSamples? = if (hosted?.target?.c2 == true) SelfCheckMainSamples(::readMainVector, ::readGlobalFocus) else null
    private var lastC2Release: SelfCheckTargetCompletion? = null
    private var selfCheckOwner = hosted?.probe == true
    private var probeConsumed = false
    private var selfCheckWindow: BackgroundInputProbe? = null
    private var releasingDisplayId: Int? = null
    private var displayCreationAttempted = false
    private var displayApiReleased = false
    private var probeDisplay = false
    private var lastReleasedOwner: String? = null
    private var lastReleaseNeverCreated = false
    private val taskManager by lazy { Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null) }
    private val rootTasksMethod by lazy {
        Class.forName("android.app.IActivityTaskManager").getMethod("getAllRootTaskInfosOnDisplay", Int::class.javaPrimitiveType)
    }
    private val rootTaskInfoType by lazy { Class.forName("android.app.ActivityTaskManager\$RootTaskInfo") }

    private fun rootTaskInfos(displayId: Int): List<Any> {
        val result = try {
            rootTasksMethod.invoke(taskManager, displayId) as? List<*> ?: throw Fault("releaseQueryFailed")
        } catch (error: InvocationTargetException) {
            // A virtual display ATMS has already forgotten is an empty task scope, not a failed
            // query. The default display must stay readable, and permission/transport failures
            // keep their stable releaseQueryFailed code.
            if (displayId != Display.DEFAULT_DISPLAY && error.cause is IllegalArgumentException) return emptyList()
            throw Fault("releaseQueryFailed")
        } catch (_: IllegalArgumentException) {
            if (displayId != Display.DEFAULT_DISPLAY) return emptyList()
            throw Fault("releaseQueryFailed")
        }
        if (result.any { !rootTaskInfoType.isInstance(it) }) throw Fault("releaseQueryFailed")
        return result.map { it as Any }
    }

    internal fun rootTasksEmpty(displayId: Int): Boolean = rootTaskInfos(displayId).isEmpty()

    /** A probe display carries only this app's own task; it must not block the owner's release. */
    private fun releaseTasksGone(displayId: Int): Boolean =
        probeDisplay || selfCheckOwner || rootTaskInfos(displayId).isEmpty()

    private class Fault(val code: String) : Exception()

    /** The single entry point for both transports. Always returns a response Bundle. */
    fun handle(request: Bundle): Bundle {
        val response = Bundle()
        val op = request.getString(Proto.OP)
        var targetReply = SelfCheckTargetRequest.Step.entries.any { it.op == op } || request.containsKey(Proto.SELF_CHECK_TARGET_C2_VERSION)
        var selfCheckReply = op == Proto.OP_SELF_CHECK_PROBE
        try {
            if (!BackgroundAfterVisual.validRequest(op, request.containsKey(Proto.AFTER_LOCAL_VISUAL),
                    request.get(Proto.AFTER_LOCAL_VISUAL))) throw Fault("invalidArguments")
            if ((request.containsKey(Proto.TARGET_IDENTITY_VERSION) || request.containsKey(Proto.TARGET_UID)) &&
                op !in setOf(Proto.OP_CREATE, Proto.OP_LAUNCH, Proto.OP_OBSERVE, Proto.OP_TAP, Proto.OP_SCROLL,
                    Proto.OP_KEY, Proto.OP_TEXT, Proto.OP_COORDINATE, Proto.OP_RELEASE, Proto.OP_REPLAY_NAVIGATION)) throw Fault("invalidArguments")
            if (op == Proto.OP_PROBE) {
                response.putBoolean(Proto.OK, true)
                response.putInt(Proto.UID, Process.myUid())
                response.putString("revision", Proto.REVISION)
                response.putInt(Proto.PREVIEW_VERSION, 1)
                response.putInt(Proto.VIEWPORT_VERSION, 1)
                response.putInt(Proto.TARGET_IDENTITY_VERSION, 1)
                response.putInt(Proto.BACKGROUND_COORDINATES, 1)
                response.putInt(Proto.AFTER_LOCAL_VISUAL, 1)
                response.putInt(Proto.REPLAY_NAVIGATION, 1)
                // Protocol facts of this APK, not device checks: a device that cannot do something
                // reports it from the real operation, with its own error code.
                response.putInt(Proto.RELEASE_RECEIPT, 1)
                response.putInt(Proto.SELF_CHECK_PROBE_VERSION, 1)
                // The fixed self-check target only: it reads these task fields on the main display.
                if (Build.VERSION.SDK_INT >= 34 && runCatching {
                    rootTaskInfoType.getField("topActivity")
                    rootTaskInfoType.getField("displayId")
                    privileged.packageManager.getActivityInfo(ComponentName(Proto.APP_PACKAGE, TargetContract.ACTIVITY_CLASS), 0)
                    rootTasksEmpty(Display.DEFAULT_DISPLAY)
                }.isSuccess) {
                    response.putInt(Proto.SELF_CHECK_TARGET_VERSION, 1)
                    response.putInt(Proto.SELF_CHECK_TARGET_C2_VERSION, 1)
                }
                return response
            }
            if (op == Proto.OP_COLLECT_SYSTEM_IME) {
                // Independent of display ownership, gates, UiAutomation and injection.
                val evidence = com.skyjjgw.independent.ski.dshgo.diagnostics.SystemImeEvidence
                val now = System.currentTimeMillis()
                // An old queued IPC must not begin a new read after its prompt expired.
                val capture = if (evidence.requestFresh(request.getLong(Proto.IME_REQUESTED_AT), now))
                    com.skyjjgw.independent.ski.dshgo.diagnostics.SystemImeLogcat.collect(request.getInt(Proto.IME_PID))
                else com.skyjjgw.independent.ski.dshgo.diagnostics.SystemImeLogcat.Capture("timeout", now)
                response.putBoolean(Proto.OK, capture.code == "ok" || capture.code == "noEvents")
                response.putString(Proto.ERROR, capture.code)
                response.putLong("capturedAt", capture.capturedAt)
                response.putLongArray("imeTimes", capture.events.map { it.timestamp }.toLongArray())
                response.putStringArray("imeEvents", capture.events.map { it.event }.toTypedArray())
                response.putIntArray("imeFromUser", capture.events.map { when (it.fromUser) { true -> 1; false -> 0; null -> -1 } }.toIntArray())
                response.putStringArray("imeReasons", capture.events.map { it.reason }.toTypedArray())
                response.putStringArray("imeOrigins", capture.events.map { it.origin }.toTypedArray())
                return response
            }
            if (op == Proto.OP_PREVIEW) {
                return previewRequest(request)
            }
            if (op == Proto.OP_DESTROY) {
                releaseAll()
                response.putBoolean(Proto.OK, true)
                return response
            }
            if (op == Proto.OP_GATE) {
                lock.withLock { gateProbe(response) }
                if (!response.containsKey(Proto.ERROR)) response.putBoolean(Proto.OK, true)
                return response
            }
            if (op == Proto.OP_GRANT_SECURE_SETTINGS) {
                lock.withLock {
                    requireTreeReady()
                    if (selfCheckOwner || targetSequence != null) throw Fault("identityChanged")
                    grantSecureSettings(request.getInt(Proto.USER))
                }
                response.putBoolean(Proto.OK, true)
                return response
            }
            lock.withLock {
                targetReply = targetReply || targetSequence != null
                selfCheckReply = selfCheckReply || selfCheckOwner
                try { dispatch(op, request, response) }
                catch (e: Throwable) {
                    coordinateObservation = null
                    visualObservation = null
                    if (request.get(Proto.OWNER) == owner &&
                        (op == Proto.OP_CREATE || op == Proto.OP_LAUNCH || e is TargetIdentity.Failure)) {
                        targetIdentity.invalidate()
                        preview.invalidate()
                    }
                    throw e
                }
            }
            if (!response.containsKey(Proto.ERROR)) response.putBoolean(Proto.OK, true)
        } catch (e: Throwable) {
            if (op == Proto.OP_REPLAY_NAVIGATION) response.getBundle(Proto.NAVIGATION)?.putString("post", "unknown")
            if (response.containsKey(Proto.COORDINATE_SCOPE_VERSION)) response.putBoolean(Proto.COORDINATE_SCOPE_KNOWN, false)
            response.putBoolean(Proto.OK, false)
            response.putString(Proto.ERROR, failureCode(e))
            val detail = if (targetReply) null else if (selfCheckReply) (e as? InputProbe.Failure)?.observation?.encode() else failureDetail(e)
            detail?.let { response.putString(Proto.ERROR_DETAIL, it) }
        }
        return response
    }

    private fun failureCode(e: Throwable): String = when (e) {
        is Fault -> e.code
        is TargetIdentity.Failure -> e.code
        is InputProbe.Failure -> e.code
        is InterruptedException -> "cancelled"
        is SecurityException -> "systemOperationDenied"
        else -> "deviceUnavailable"
    }

    private fun failureDetail(e: Throwable): String? =
        if (e is InputProbe.Failure) e.observation?.encode()
        else if (e is Fault || e is TargetIdentity.Failure || e is InterruptedException || e is SecurityException) null
        else e.javaClass.simpleName

    private fun dispatch(op: String?, request: Bundle, response: Bundle) {
        if (SelfCheckTargetRequest.Step.entries.any { it.op == op }) {
            selfCheckTarget(request, response)
            return
        }
        if (op == Proto.OP_SELF_CHECK_PROBE) {
            requireTreeReady()
            selfCheckProbe(request, response)
            return
        }
        val ownerId = request.getString(Proto.OWNER).orEmpty()
        if (op == null || ownerId.isEmpty()) throw Fault("invalidArguments")
        if (op == Proto.OP_RELEASE) {
            val c2Keys = setOf(Proto.SELF_CHECK_TARGET_C2_VERSION, Proto.SELF_CHECK_FINAL_MAIN, Proto.TARGET_RUN, Proto.RELEASE_NONCE)
            if (targetSequence?.c2 == true || lastC2Release?.request?.owner == ownerId || request.keySet().any { it in c2Keys }) {
                val release = SelfCheckTargetRelease.parse(request.keySet()) { request.get(it) } ?: throw Fault("invalidArguments")
                val completed = lastC2Release
                if (completed?.request?.owner == ownerId) {
                    if (completed.request != release) throw Fault("identityChanged")
                    writeTargetRelease(completed, response)
                    return
                }
                if (targetSequence?.bindRelease(release) != true) throw Fault("identityChanged")
                releaseStrict(ownerId, release)
                writeTargetRelease(checkNotNull(lastC2Release), response)
                return
            }
            if ((selfCheckOwner || targetSequence != null) && !request.containsKey(Proto.RELEASE_RECEIPT)) throw Fault("releaseReceiptRequired")
            if (request.containsKey(Proto.RELEASE_RECEIPT)) {
                if (request.get(Proto.RELEASE_RECEIPT) !is Int || request.getInt(Proto.RELEASE_RECEIPT) != 1) throw Fault("invalidArguments")
                val neverCreated = releaseStrict(ownerId)
                response.putInt(Proto.RELEASE_RECEIPT, 1)
                response.putString(Proto.OWNER, ownerId)
                if (neverCreated) response.putBoolean("neverCreated", true)
                else { response.putBoolean("released", true); response.putBoolean(Proto.TASK_SCOPE_EMPTY, true) }
            } else {
                if (owner == ownerId) releaseAll()
                response.putBoolean("released", true)
            }
            return
        }
        requireTreeReady()
        if (selfCheckOwner || targetSequence != null) throw Fault("identityChanged")
        if (op == Proto.OP_REPLAY_NAVIGATION && hosted == null)
            throw Fault("identityChanged")
        if (owner != null && owner != ownerId) throw Fault("identityChanged")
        if ((op == Proto.OP_CREATE || op == Proto.OP_LAUNCH) && request.containsKey(Proto.RELEASE_RECEIPT)) {
            if (request.get(Proto.RELEASE_RECEIPT) !is Int || request.getInt(Proto.RELEASE_RECEIPT) != 1) throw Fault("invalidArguments")
            if (lastReleasedOwner == ownerId) throw Fault("identityChanged")
            if (owner == null) {
                owner = ownerId
                strictOwner = true
                releasingDisplayId = null
                displayCreationAttempted = false
                displayApiReleased = false
            }
        }
        if (strictOwner && displayApiReleased) throw Fault("releasePending")
        if (strictOwner && (readerAllocationUncertain || display == null && (displayCreationAttempted || reader != null || pendingReader != null))) throw Fault("releaseUnconfirmed")
        if (keyguard?.isKeyguardLocked == true) throw Fault("locked")
        val pkg = request.getString(Proto.PKG).orEmpty()
        if (!PACKAGE.matches(pkg)) throw Fault("invalidArguments")
        if (request.containsKey(Proto.BACKGROUND_COORDINATES) && op != Proto.OP_COORDINATE &&
            (op != Proto.OP_OBSERVE || request.get(Proto.BACKGROUND_COORDINATES) !is Int ||
                request.getInt(Proto.BACKGROUND_COORDINATES) != 1 || request.get(Proto.WANT_IMAGE) != true)) throw Fault("invalidArguments")
        val opening = op == Proto.OP_CREATE || op == Proto.OP_LAUNCH
        if (!opening) requireDisplay() else owner = ownerId
        // Binding and all target changes share the resource owner lock. RELEASE never enters this gate.
        val expected = targetIdentity.request(pkg, request.containsKey(Proto.TARGET_IDENTITY_VERSION),
            request.get(Proto.TARGET_IDENTITY_VERSION), request.containsKey(Proto.TARGET_UID),
            request.get(Proto.TARGET_UID), opening)
        // Resolve the exact intent before VD/reader allocation, not again after approving its identity.
        val launch = if (opening) resolveLaunch(pkg, expected) else null

        if (op != Proto.OP_COORDINATE) coordinateObservation = null
        val localVisual = request.getBoolean(Proto.LOCAL_VISUAL) && when (op) {
            Proto.OP_CREATE, Proto.OP_LAUNCH, Proto.OP_OBSERVE, Proto.OP_TAP, Proto.OP_SCROLL -> true
            else -> false
        }
        val previousVisual = if (localVisual && (op == Proto.OP_TAP || op == Proto.OP_SCROLL)) visualObservation else null
        visualObservation = null // Consume before any dispatch, including failed or non-opt-in operations.
        if (op == Proto.OP_REPLAY_NAVIGATION) {
            navigation(request, response, expected ?: throw Fault("targetIdentityUnavailable"))
            return // navigation completes its own final actual-target gate before publishing proof.
        }
        when (op) {
            Proto.OP_CREATE, Proto.OP_LAUNCH -> {
                if (display == null) createDisplay(request)
                else requestedViewport(request)?.let {
                    if (width != it.width || height != it.height) throw Fault("viewportConflict")
                }
                response.putInt(Proto.DISPLAY_ID, displayId())
                launchPackage(pkg, checkNotNull(launch), expected)
                targetIdentity.opened(expected)
                sleepChecked(300)
                observe(pkg, request.getBoolean(Proto.WANT_IMAGE), response, localVisual = localVisual)
            }
            Proto.OP_OBSERVE -> {
                if (expected == null) requireForeground(pkg)
                observe(pkg, request.getBoolean(Proto.WANT_IMAGE), response, requireTree = true, detail = request.getBoolean(Proto.DETAIL), localVisual = localVisual, coordinates = request.containsKey(Proto.BACKGROUND_COORDINATES))
            }
            Proto.OP_COORDINATE -> coordinate(pkg, request, response)
            Proto.OP_TAP -> {
                requireForeground(pkg)
                tap(pkg, request)
                sleepChecked(250)
                observeAfterAction(pkg, request, response, localVisual = localVisual)
                if (localVisual) response.putString(Proto.VISUAL_CHANGE,
                    visualObservation?.changeFrom(previousVisual, SystemClock.uptimeMillis()) ?: "unavailable")
            }
            Proto.OP_SCROLL -> {
                requireForeground(pkg)
                scroll(pkg, request)
                sleepChecked(250)
                observeAfterAction(pkg, request, response, localVisual = localVisual)
                if (localVisual) response.putString(Proto.VISUAL_CHANGE,
                    visualObservation?.changeFrom(previousVisual, SystemClock.uptimeMillis()) ?: "unavailable")
            }
            Proto.OP_KEY -> {
                requireForeground(pkg)
                globalKey(request.getString(Proto.DIR))
                sleepChecked(250)
                observeAfterAction(pkg, request, response)
            }
            Proto.OP_TEXT -> {
                requireForeground(pkg)
                typeText(pkg, request, response)
                sleepChecked(200)
                observeAfterAction(pkg, request, response)
            }
            else -> throw Fault("invalidArguments")
        }
        if (expected == null && response.containsKey(Proto.COORDINATE_SCOPE_VERSION))
            response.putBoolean(Proto.COORDINATE_SCOPE_KNOWN, false)
        if (expected != null) {
            val actual = if (op == Proto.OP_LAUNCH) {
                val actualDisplay = display?.display ?: throw Fault("displayMissing")
                val actualId = actualDisplay.displayId
                if (actualId <= Display.DEFAULT_DISPLAY) throw Fault("displayTargetChanged")
                val target = requireActualTarget(expected, actualId)
                if (!actualDisplay.isValid || actualDisplay.displayId != actualId) throw Fault("displayTargetChanged")
                response.putInt(Proto.DISPLAY_ID, actualId)
                response.putInt(Proto.BACKGROUND_OPEN_EVIDENCE, 1)
                target
            } else requireActualTarget(expected)
            response.putInt(Proto.TARGET_IDENTITY_VERSION, 1)
            response.putInt(Proto.TARGET_UID, actual.uid)
            response.putString(Proto.PKG, actual.packageName)
        }
    }

    private data class TargetSnapshot(val run: String, val windowId: Int, val index: Int, val element: BgNode)

    private fun selfCheckTarget(request: Bundle, response: Bundle) {
        val parsed = SelfCheckTargetRequest.parse(request.keySet()) { request.get(it) }
            ?: throw Fault("invalidArguments")
        response.putString(Proto.OWNER, parsed.owner)
        response.putInt(parsed.versionKey, 1)
        response.putString(Proto.TARGET_RUN, parsed.run)
        response.putString(Proto.STEP_NONCE, parsed.nonce)
        when (parsed.step) {
            SelfCheckTargetRequest.Step.CREATE -> response.putBoolean(Proto.SELF_CHECK_DISPLAY_READY, false)
            SelfCheckTargetRequest.Step.READ -> {
                response.putBoolean(Proto.TARGET_MATCHED, false)
                response.putBoolean(Proto.TREE_COMPLETE, false)
                response.putBoolean(Proto.INITIAL_COUNTER_MATCHED, false)
            }
            SelfCheckTargetRequest.Step.TAP, SelfCheckTargetRequest.Step.TEXT_ASCII,
            SelfCheckTargetRequest.Step.TEXT_ZH -> response.putBoolean(Proto.ACTION_ATTEMPTED, false)
            SelfCheckTargetRequest.Step.CAPTURE, SelfCheckTargetRequest.Step.CONTINUITY -> {
                response.putBoolean(Proto.TARGET_MATCHED, false)
                response.putBoolean(Proto.TREE_COMPLETE, false)
                response.putBoolean(Proto.FRAME_MATCHED, false)
            }
        }
        requireTreeReady()
        var sequence = targetSequence
        if (sequence == null) {
            if (parsed.step != SelfCheckTargetRequest.Step.CREATE || owner != null || lastReleasedOwner == parsed.owner)
                throw Fault("identityChanged")
            if (display != null || reader != null || pendingReader != null || readerAllocationUncertain || selfCheckWindow != null)
                throw Fault("releaseUnconfirmed")
            // Register the owner and purpose before ANY allocation. Failed create still needs RELEASE.
            owner = parsed.owner
            strictOwner = true
            targetSnapshot = null
            sequence = SelfCheckTargetSequence(parsed.owner, parsed.run, parsed.c2)
            targetMain = if (parsed.c2) SelfCheckMainSamples(::readMainVector, ::readGlobalFocus) else null
            targetSequence = sequence
            releasingDisplayId = null
            displayCreationAttempted = false
            displayApiReleased = false
            visualObservation = null
        }
        if (owner != parsed.owner || !strictOwner || selfCheckOwner) throw Fault("identityChanged")
        sequence.enter(parsed)?.let { throw Fault(it) }
        if (Build.VERSION.SDK_INT < 34) throw Fault("targetUnavailable")
        if (keyguard?.isKeyguardLocked == true) throw Fault("locked")
        when (parsed.step) {
            SelfCheckTargetRequest.Step.CREATE -> {
                targetMain?.sample(SelfCheckMainSamples.Slot.BEFORE_CREATE)?.let { writeMainSample(it, response) }
                // Fixed ordinary-display flags, not B's Presentation path. Never launches here.
                createDisplay(Bundle().apply {
                    putInt(Proto.SHORT_SIDE, 720); putInt(Proto.ASPECT_W, 9); putInt(Proto.ASPECT_H, 20)
                })
                val actual = display?.display ?: throw Fault("displayMissing")
                if (!actual.isValid || actual.displayId <= Display.DEFAULT_DISPLAY) throw Fault("displayUnsupported")
                response.putInt(Proto.DISPLAY_ID, actual.displayId)
                response.putBoolean(Proto.SELF_CHECK_DISPLAY_READY, true)
            }
            SelfCheckTargetRequest.Step.READ -> {
                targetSnapshot = awaitTargetSnapshot(parsed.run, 0, response, initial = true)
                targetMain?.sample(SelfCheckMainSamples.Slot.AFTER_LAUNCH)?.let { writeMainSample(it, response) }
            }
            SelfCheckTargetRequest.Step.TAP -> {
                val previous = targetSnapshot ?: throw Fault("outOfOrder")
                val expected = Bundle().apply {
                    putInt(Proto.ELEMENT, previous.index)
                    putString(Proto.EXPECT_ROLE, previous.element.role)
                    putString(Proto.EXPECT_LABEL, previous.element.label)
                    putString(Proto.EXPECT_VIEW_ID, previous.element.viewId)
                }
                // resolveElement's actual fresh location read checks the SAME run and window.
                val button = resolveElement(Proto.APP_PACKAGE, expected, previous)
                requireTargetComponent()
                response.putBoolean(Proto.ACTION_ATTEMPTED, true)
                injectTap(button.bounds.centerX(), button.bounds.centerY(), false)
                awaitTargetSnapshot(parsed.run, 1, response, initial = false, windowId = previous.windowId)
            }
            SelfCheckTargetRequest.Step.TEXT_ASCII, SelfCheckTargetRequest.Step.TEXT_ZH -> {
                targetText(parsed, response)
                if (parsed.step == SelfCheckTargetRequest.Step.TEXT_ZH)
                    targetMain?.sample(SelfCheckMainSamples.Slot.AFTER_INPUTS)?.let { writeMainSample(it, response) }
            }
            SelfCheckTargetRequest.Step.CAPTURE, SelfCheckTargetRequest.Step.CONTINUITY -> targetFrame(parsed.run, sequence.framePhase, response)
        }
        sequence.complete(parsed.step)
    }

    private fun readMainVector(): List<SelfCheckMainSamples.Task>? {
        if (displays?.getDisplay(Display.DEFAULT_DISPLAY)?.isValid != true) return null
        val rows = rootTasksMethod.invoke(taskManager, Display.DEFAULT_DISPLAY) as? List<*> ?: return null
        if (rows.size > 64 || rows.any { !rootTaskInfoType.isInstance(it) }) return null
        return rows.map { row ->
            val component = rootTaskInfoType.getField("topActivity").get(row)
            if (component != null && component !is ComponentName) throw Fault("targetUnavailable")
            SelfCheckMainSamples.Task(rootTaskInfoType.getField("taskId").getInt(row),
                rootTaskInfoType.getField("userId").getInt(row), rootTaskInfoType.getField("displayId").getInt(row),
                (component as? ComponentName)?.flattenToString(), rootTaskInfoType.getField("position").getInt(row),
                rootTaskInfoType.getField("isFocused").getBoolean(row), rootTaskInfoType.getField("isVisible").getBoolean(row))
        }
    }

    private fun readGlobalFocus(): SelfCheckMainSamples.Focus? {
        val row = Class.forName("android.app.IActivityTaskManager").getMethod("getFocusedRootTaskInfo").invoke(taskManager)
            ?: return null
        if (!rootTaskInfoType.isInstance(row)) return null
        return SelfCheckMainSamples.Focus(rootTaskInfoType.getField("displayId").getInt(row),
            rootTaskInfoType.getField("taskId").getInt(row))
    }

    private fun writeMainSample(result: SelfCheckMainSamples.Result, response: Bundle) {
        response.putString(Proto.MAIN_VECTOR_RESULT, result.vector.wire)
        response.putString(Proto.GLOBAL_FOCUS_RESULT, result.focus.wire)
    }

    private fun writeTargetRelease(completed: SelfCheckTargetCompletion, response: Bundle) {
        response.putInt(Proto.RELEASE_RECEIPT, 1)
        response.putString(Proto.OWNER, completed.request.owner)
        if (completed.neverCreated) response.putBoolean("neverCreated", true)
        else { response.putBoolean("released", true); response.putBoolean(Proto.TASK_SCOPE_EMPTY, true) }
        response.putInt(Proto.SELF_CHECK_TARGET_C2_VERSION, 1)
        response.putString(Proto.TARGET_RUN, completed.request.run)
        response.putString(Proto.RELEASE_NONCE, completed.request.nonce)
        response.putString(Proto.FINAL_MAIN_VECTOR, completed.main.vector.wire)
        response.putString(Proto.FINAL_GLOBAL_FOCUS, completed.main.focus.wire)
    }

    private data class C2Read(val windowId: Int, val editorIndex: Int, val editor: BgNode,
                              val editorBounds: SelfCheckTargetEvidence.Bounds,
                              val patternBounds: SelfCheckTargetEvidence.Bounds,
                              val node: AccessibilityNodeInfo?)

    /** This actual read owns every retained node; callers recycle it before closing the connection. */
    private fun readC2Tree(automation: UiAutomation, run: String, text: String, phase: Int, targetId: Int = 0): C2Read {
        requireTargetComponent()
        val evidence = SelfCheckTargetEvidence(run, 1, true, text, phase)
        val tree = readTree(automation, displayId(), Proto.APP_PACKAGE, targetId, inspectVisual = true, targetEvidence = evidence)
        try {
            requireTargetComponent()
            val windowId = tree.targetWindowId
            val editor = tree.elements.singleOrNull { it.viewId == evidence.editorId }
            val editorBounds = evidence.editorBounds
            val patternBounds = evidence.patternBounds
            if (!tree.complete) throw Fault("targetUnavailable")
            if (windowId == null || windowId != targetSnapshot?.windowId || !evidence.targetMatched ||
                tree.hasSecrets || tree.hasSensitive || editor == null || editorBounds?.inside(width, height) != true ||
                patternBounds?.inside(width, height) != true) throw Fault("targetChanged")
            if (!evidence.counterMatched || !evidence.textMatched) throw Fault("targetReadbackMismatch")
            if (patternBounds.width < TargetFramePattern.GRID_COLUMNS * TargetFramePattern.MIN_CELL_PX ||
                patternBounds.height < TargetFramePattern.GRID_ROWS * TargetFramePattern.MIN_CELL_PX) throw Fault("targetFrameUnavailable")
            return C2Read(windowId, tree.elements.indexOf(editor) + 1, editor, editorBounds, patternBounds, tree.target)
        } catch (e: Throwable) { tree.target?.recycle(); throw e }
    }

    private fun targetText(request: SelfCheckTargetRequest, response: Bundle) {
        val before = if (request.step == SelfCheckTargetRequest.Step.TEXT_ASCII) "" else TargetContract.ASCII_TEXT
        val expected = if (request.step == SelfCheckTargetRequest.Step.TEXT_ASCII) TargetContract.ASCII_TEXT else TargetContract.ZH_TEXT
        val original = display ?: throw Fault("displayMissing")
        withTreeConnection(original.display, Proto.APP_PACKAGE, "textConnectionUnavailable") { automation ->
            val first = readC2Tree(automation, request.run, before, 0)
            val selected = readC2Tree(automation, request.run, before, 0, first.editorIndex)
            val node = selected.node ?: throw Fault("elementMissing")
            try {
                if (selected.windowId != first.windowId || selected.editorIndex != first.editorIndex ||
                    selected.editorBounds != first.editorBounds || !node.refresh() ||
                    node.windowId != selected.windowId || node.viewIdResourceName != selected.editor.viewId ||
                    node.packageName?.toString() != Proto.APP_PACKAGE || !node.isVisibleToUser || !node.isEnabled ||
                    !node.isEditable || isSecret(node) ||
                    node.actionList.none { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }) throw Fault("targetChanged")
                requireTargetComponent()
                response.putBoolean(Proto.ACTION_ATTEMPTED, true)
                val accepted = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, expected)
                })
                response.putBoolean(Proto.ACCEPTED, accepted) // Preserve this fact even if later read/close fails.
                if (!accepted) throw Fault("inputRejected")
                val deadline = SystemClock.uptimeMillis() + 1500
                while (true) {
                    runCatching { invoke(automation, "clearCache") }
                    if (!node.refresh()) throw Fault("targetChanged")
                    val actual = if (node.isShowingHintText) null else node.text
                    if (actual != null && actual.length == expected.length && actual.toString() == expected) break
                    if (SystemClock.uptimeMillis() >= deadline) throw Fault("targetReadbackMismatch")
                    sleepChecked(50)
                }
                val post = readC2Tree(automation, request.run, expected, 0)
                if (post.windowId != first.windowId || post.editorBounds != first.editorBounds ||
                    post.patternBounds != first.patternBounds || display !== original) throw Fault("targetChanged")
            } finally { node.recycle() }
        }
        // Publish post facts only after the complete node transaction AND actual unregister succeeded.
        response.putBoolean(Proto.TARGET_MATCHED, true)
        response.putBoolean(Proto.TREE_COMPLETE, true)
        response.putBoolean(Proto.TEXT_MATCHED, true)
    }

    private data class TargetFrameCheck(val run: String, val phase: Int, val bounds: SelfCheckTargetEvidence.Bounds,
                                        val width: Int, val height: Int) {
        fun matches(bitmap: Bitmap): Boolean = bitmap.width == width && bitmap.height == height && bounds.inside(width, height) &&
            TargetFramePattern.matches(run, phase, bounds.width, bounds.height) { x, y -> bitmap.getPixel(bounds.left + x, bounds.top + y) }
    }

    private fun targetFrame(run: String, phase: Int, response: Bundle) {
        val original = display ?: throw Fault("displayMissing")
        val frameWidth = width; val frameHeight = height
        fun read(): C2Read = withTreeConnection(original.display, Proto.APP_PACKAGE, "treeUnavailable") {
            readC2Tree(it, run, TargetContract.ZH_TEXT, phase)
        }
        val before = read()
        val shot = capture(targetFrame = TargetFrameCheck(run, phase, before.patternBounds, frameWidth, frameHeight))
            ?: throw Fault("targetFrameUnavailable")
        if (shot.targetMatched != true) throw Fault("targetFrameMismatch")
        val after = read()
        if (display !== original || width != frameWidth || height != frameHeight || after.windowId != before.windowId ||
            after.patternBounds != before.patternBounds || after.editorBounds != before.editorBounds) throw Fault("targetChanged")
        response.putBoolean(Proto.TARGET_MATCHED, true)
        response.putBoolean(Proto.TREE_COMPLETE, true)
        response.putBoolean(Proto.FRAME_MATCHED, true)
    }

    /** Full ATMS query, not getRunningTasks(50). No server Context UID is called the App user. */
    private fun requireTargetComponent() {
        val actual = display?.display ?: throw Fault("displayMissing")
        if (!actual.isValid || actual.displayId <= Display.DEFAULT_DISPLAY || targetSequence == null)
            throw Fault("targetChanged")
        if (keyguard?.isKeyguardLocked == true) throw Fault("locked")
        val rows = rootTasksMethod.invoke(taskManager, actual.displayId) as? List<*> ?: throw Fault("targetUnavailable")
        if (rows.any { !rootTaskInfoType.isInstance(it) }) throw Fault("targetUnavailable")
        if (rows.isEmpty()) throw Fault("targetUnavailable")
        if (rows.size != 1) throw Fault("targetChanged")
        val row = rows.single()
        val component = rootTaskInfoType.getField("topActivity").get(row) as? ComponentName
            ?: throw Fault("targetUnavailable")
        if (rootTaskInfoType.getField("displayId").getInt(row) != actual.displayId ||
            component.packageName != Proto.APP_PACKAGE || component.className != TargetContract.ACTIVITY_CLASS)
            throw Fault("targetChanged")
    }

    private fun readTargetSnapshot(run: String, counter: Int, response: Bundle? = null, initial: Boolean = false, windowId: Int? = null): TargetSnapshot {
        requireTargetComponent()
        val c2 = targetSequence?.c2 == true
        val evidence = SelfCheckTargetEvidence(run, counter, c2, if (c2) "" else null, if (c2) 0 else null)
        val tree = try { readTree(displayId(), Proto.APP_PACKAGE, inspectVisual = c2, targetEvidence = evidence) }
        catch (e: Fault) { throw Fault(when (e.code) {
            "treeUnavailable", "textConnectionUnavailable" -> "targetUnavailable"
            "displayTargetChanged" -> "targetChanged"
            else -> e.code
        }) }
        requireTargetComponent()
        val button = tree.elements.singleOrNull { it.viewId == evidence.buttonId }
        val bounds = button?.bounds
        val usable = button != null && bounds != null && !bounds.isEmpty && bounds.left >= 0 && bounds.top >= 0 &&
            bounds.right <= width && bounds.bottom <= height && button.flags and Proto.FLAG_CLICKABLE != 0
        val matched = tree.complete && tree.targetWindowId != null && (windowId == null || tree.targetWindowId == windowId) &&
            evidence.targetMatched && !tree.hasSecrets && usable && (!c2 || !tree.hasSensitive && evidence.textMatched &&
                evidence.editorBounds?.inside(width, height) == true && evidence.patternBounds?.inside(width, height) == true)
        response?.putBoolean(Proto.TARGET_MATCHED, matched)
        response?.putBoolean(Proto.TREE_COMPLETE, tree.complete)
        if (initial) response?.putBoolean(Proto.INITIAL_COUNTER_MATCHED, tree.complete && evidence.counterMatched)
        else if (tree.complete) response?.putBoolean(Proto.COUNTER_MATCHED, evidence.counterMatched)
        if (!tree.complete) throw Fault("targetUnavailable")
        if (!matched) throw Fault("targetChanged")
        if (!evidence.counterMatched) throw Fault("targetReadbackMismatch")
        return TargetSnapshot(run, checkNotNull(tree.targetWindowId), tree.elements.indexOf(button) + 1, checkNotNull(button))
    }

    /** Repeats only bounded read observations inside this consumed op, never the tap or launch. */
    private fun awaitTargetSnapshot(run: String, counter: Int, response: Bundle, initial: Boolean, windowId: Int? = null): TargetSnapshot {
        val deadline = SystemClock.uptimeMillis() + if (initial) 4000L else 1500L
        while (true) {
            // Only this latest read may supply its facts. Never carry an earlier matching
            // window across a later identity/query failure; ACTION_ATTEMPTED stays sticky.
            val counterKey = if (initial) Proto.INITIAL_COUNTER_MATCHED else Proto.COUNTER_MATCHED
            for (key in listOf(Proto.TARGET_MATCHED, Proto.TREE_COMPLETE, counterKey)) {
                if (initial) response.putBoolean(key, false) else response.remove(key)
            }
            try {
                return readTargetSnapshot(run, counter, response, initial, windowId)
            } catch (e: Fault) {
                if (e.code !in setOf("targetUnavailable", "targetReadbackMismatch") || SystemClock.uptimeMillis() >= deadline) throw e
                sleepChecked(50)
            }
        }
    }

    /** One fixed local run; its original owner must RELEASE even when setup or input fails. */
    private fun selfCheckProbe(request: Bundle, response: Bundle) {
        val ownerId = SelfCheckProbeRequest.owner(request.keySet()) { request.get(it) }
            ?: throw Fault("invalidArguments")
        response.putString(Proto.OWNER, ownerId)
        response.putInt(Proto.SELF_CHECK_PROBE_VERSION, 1)
        response.putBoolean(Proto.SELF_CHECK_DISPLAY_READY, false)
        if (owner == ownerId && selfCheckOwner && (hosted == null || probeConsumed)) throw Fault("selfCheckAlreadyStarted")
        if (owner != null && !(hosted?.probe == true && owner == ownerId) || lastReleasedOwner == ownerId) throw Fault("identityChanged")
        if (selfCheckWindow != null) throw Fault("releaseUnconfirmed")
        // The one verify attempt is consumed even if the allocated display or keyguard check fails.
        probeConsumed = true
        if (display != null || reader != null || pendingReader != null || readerAllocationUncertain)
            throw Fault("releaseUnconfirmed")
        owner = ownerId
        strictOwner = true
        selfCheckOwner = true
        releasingDisplayId = null
        displayCreationAttempted = false
        displayApiReleased = false
        visualObservation = null
        if (keyguard?.isKeyguardLocked == true) throw Fault("locked")
        createDisplay(Bundle().apply {
            putInt(Proto.SHORT_SIDE, 360)
            putInt(Proto.ASPECT_W, 9)
            putInt(Proto.ASPECT_H, 20)
        }, probe = true)
        val target = display?.display ?: throw Fault("displayMissing")
        if (target.displayId <= Display.DEFAULT_DISPLAY || !target.isValid) throw Fault("displayUnsupported")
        response.putBoolean(Proto.SELF_CHECK_DISPLAY_READY, true)
        val window = BackgroundInputProbe(privileged, target)
        selfCheckWindow = window // A failing show/verify must not lose the actual cleanup job.
        try {
            window.verify { point, time ->
                // An attempted send is not proof of delivery or proof that no input occurred.
                response.putBoolean(Proto.INJECT_OK, false)
                sendMotion(MotionEvent.ACTION_DOWN, point.x, point.y, time, waitForFinish = false)
                sendMotion(MotionEvent.ACTION_UP, point.x, point.y, time, waitForFinish = false)
            }
            response.putBoolean(Proto.INJECT_OK, true) // Only matching receiver DOWN/UP gets here.
        } catch (e: Throwable) {
            response.putString(Proto.INJECT_ERROR, failureCode(e))
            InputProbeDiagnostics.decode(window.failureDetail)?.let {
                response.putString(Proto.ERROR_DETAIL, it.encode())
            }
            throw e
        }
        // No close here: RELEASE owns the same UI job, VD, readers and ATMS confirmation.
    }

    /** Test a real input receiver, not an empty display. Never launches or touches a user app. */
    private fun gateProbe(response: Bundle) {
        requireTreeReady()
        // A settings probe must not replace or release an active task's display.
        if (owner != null || display != null) throw Fault("probeBusy")
        try {
            owner = "__gate__"
            createDisplay(Bundle().apply { putInt(Proto.SHORT_SIDE, 360); putInt(Proto.ASPECT_W, 9); putInt(Proto.ASPECT_H, 20) }, probe = true)
            response.putInt(Proto.DISPLAY_ID, displayId())
            var probeDetail: String? = null
            val injection = runCatching {
                val window = BackgroundInputProbe(privileged, checkNotNull(display).display)
                selfCheckWindow = window
                try {
                    window.verify { target, time ->
                        sendMotion(MotionEvent.ACTION_DOWN, target.x, target.y, time, waitForFinish = false)
                        sendMotion(MotionEvent.ACTION_UP, target.x, target.y, time, waitForFinish = false)
                    }
                } finally {
                    // Cleanup failure must replace a delivery failure, not be hidden by use().
                    try { window.close(); selfCheckWindow = null } finally { probeDetail = window.failureDetail }
                }
            }
            response.putBoolean(Proto.INJECT_OK, injection.isSuccess)
            injection.exceptionOrNull()?.let {
                response.putString(Proto.INJECT_ERROR, failureCode(it))
                (probeDetail ?: failureDetail(it))?.let { detail -> response.putString(Proto.ERROR_DETAIL, detail) }
            }
        } finally {
            releaseAll()
        }
    }

    // ---- display lifecycle -------------------------------------------------

    private fun displayId(): Int = display?.display?.displayId ?: throw Fault("displayMissing")
    private fun requireDisplay() { if (display == null) throw Fault("displayMissing") }

    private fun requestedViewport(request: Bundle): BackgroundPolicy.Viewport? {
        if (!request.containsKey(Proto.VIEWPORT_PRESET)) return null
        val preset = BackgroundPolicy.Viewport.parse(request.get(Proto.VIEWPORT_PRESET)) ?: throw Fault("invalidArguments")
        if (request.containsKey(Proto.ASPECT_W) || request.containsKey(Proto.ASPECT_H) ||
            request.containsKey(Proto.SHORT_SIDE) && request.get(Proto.SHORT_SIDE) != 720) throw Fault("invalidArguments")
        return preset
    }

    private fun createDisplay(request: Bundle, probe: Boolean = false) {
        val shortSide = request.getInt(Proto.SHORT_SIDE, 720).coerceIn(360, 1080)
        val aspectW = request.getInt(Proto.ASPECT_W, 9).coerceAtLeast(1)
        val aspectH = request.getInt(Proto.ASPECT_H, 20).coerceAtLeast(1)
        val preset = requestedViewport(request)
        val size = if (preset == null) BackgroundPolicy.displaySize(shortSide, aspectW, aspectH)
            else intArrayOf(preset.width, preset.height)
        val w = size[0]; val h = size[1]
        if (reader != null || pendingReader != null || readerAllocationUncertain) throw Fault("releasePending")
        readerAllocationUncertain = true
        val ir = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        pendingReader = ir
        readerAllocationUncertain = false
        try {
            // Every flag must resolve; never silently make a focus-stealing display on an old ROM.
            // SECURE is deliberately not requested, so protected content stays protected.
            val flags = try {
                FLAG_NAMES.fold(0) { bits, name ->
                    bits or DisplayManager::class.java.getDeclaredField("VIRTUAL_DISPLAY_FLAG_$name").getInt(null)
                }
            } catch (_: ReflectiveOperationException) { throw Fault("displayUnsupported") }
            // Presentation requires this flag for the gate's inert receiver. Actual tasks keep
            // their existing display flags; this tests delivery, not every target app's policy.
            displayCreationAttempted = true
            probeDisplay = probe
            val vd = displays.createVirtualDisplay("dsh-background", w, h, 320, ir.surface,
                flags or if (probe) DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION else 0)
            display = vd; reader = ir; pendingReader = null
            releasingDisplayId = vd.display.displayId
            if (vd.display.displayId <= Display.DEFAULT_DISPLAY) throw Fault("displayUnsupported")
            width = w; height = h
            // Keep the virtual display's keyboard off the main screen: IME policy HIDE.
            runCatching { setImePolicyHide(vd.display.displayId) }
        } catch (e: Throwable) {
            // Retain real handles for legacy callers too: whole-peer retirement must not
            // mistake a swallowed release failure for an empty peer.
            if (e is Fault) throw e else throw Fault("displayUnsupported")
        }
    }

    private fun resolveLaunch(pkg: String, expected: PhoneAppIdentity?): Intent {
        val pm = privileged.packageManager
        val intent = try { pm.getLaunchIntentForPackage(pkg) } catch (_: Exception) {
            throw TargetIdentity.Failure("targetIdentityUnavailable")
        } ?: throw Fault("notLaunchable")
        if (expected != null) {
            val actual = try { pm.resolveActivity(intent, 0)?.activityInfo } catch (_: Exception) { null }
                ?: throw TargetIdentity.Failure("targetIdentityUnavailable")
            if (!TargetIdentity.matches(expected, actual.packageName, actual.applicationInfo.uid))
                throw TargetIdentity.Failure("targetIdentityChanged")
        }
        return intent
    }

    private fun requirePackageIdentity(expected: PhoneAppIdentity) {
        val actual = try { privileged.packageManager.getApplicationInfo(expected.packageName, 0) }
            catch (_: Exception) { throw TargetIdentity.Failure("targetIdentityUnavailable") }
        if (!TargetIdentity.matches(expected, actual.packageName, actual.uid))
            throw TargetIdentity.Failure("targetIdentityChanged")
    }

    private fun requireActualTarget(expected: PhoneAppIdentity, onDisplayId: Int? = display?.display?.displayId): PhoneAppIdentity {
        requirePackageIdentity(expected)
        val task = foregroundTask(onDisplayId) ?: throw TargetIdentity.Failure("targetIdentityUnavailable")
        val info = try { task.javaClass.getField("topActivityInfo").get(task) as? android.content.pm.ActivityInfo }
            catch (_: Exception) { null } ?: throw TargetIdentity.Failure("targetIdentityUnavailable")
        val user = try { task.javaClass.getField("userId").getInt(task) }
            catch (_: Exception) { throw TargetIdentity.Failure("targetIdentityUnavailable") }
        val expectedUser = try {
            UserHandle::class.java.getMethod("getUserId", Int::class.javaPrimitiveType).invoke(null, expected.uid) as Int
        } catch (_: Exception) { throw TargetIdentity.Failure("targetIdentityUnavailable") }
        if (task.topActivity?.packageName != expected.packageName ||
            !TargetIdentity.matchesTask(expected, info.packageName, info.applicationInfo.uid, user, expectedUser))
            throw TargetIdentity.Failure("targetIdentityChanged")
        return PhoneAppIdentity(info.packageName, info.applicationInfo.uid)
    }

    private fun launchPackage(pkg: String, intent: Intent, expected: PhoneAppIdentity?) {
        val display = this.display ?: throw Fault("displayMissing")
        if (expected != null) requirePackageIdentity(expected)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
        val options = ActivityOptions.makeBasic().apply { launchDisplayId = display.display.displayId }
        // A shell/UserService is not an ActivityManager-attached app process: a PendingIntent
        // avoids Context.startActivity's caller check (Phase, after Aether).
        var pending: PendingIntent? = null
        try {
            pending = PendingIntent.getActivity(
                privileged.createDisplayContext(display.display), display.display.displayId, intent,
                PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE,
            )
            pending.send(privileged, 0, null, null, null, null, options.toBundle())
        } catch (_: SecurityException) { throw Fault("launchDenied") }
        catch (_: PendingIntent.CanceledException) { throw Fault("launchCancelled") }
        finally { pending?.let { runCatching { it.cancel() } } }
        // Poll for the target becoming foreground on the owned display.
        val deadline = SystemClock.uptimeMillis() + 4000
        while (true) {
            if (foregroundPackage() == pkg) {
                if (expected != null) requireActualTarget(expected)
                break
            }
            if (SystemClock.uptimeMillis() >= deadline) throw Fault("displayTargetChanged")
            sleepChecked(120)
        }
    }

    private fun requireForeground(pkg: String) {
        if (targetIdentity.verified) {
            val expected = targetIdentity.current ?: throw TargetIdentity.Failure("targetIdentityUnavailable")
            if (expected.packageName != pkg) throw TargetIdentity.Failure("targetIdentityChanged")
            requireActualTarget(expected)
        } else if (foregroundPackage() != pkg) throw Fault("displayTargetChanged")
    }

    private fun foregroundTask(onDisplayId: Int? = display?.display?.displayId): ActivityManager.RunningTaskInfo? {
        val id = onDisplayId ?: return null
        val field = taskDisplayIdField ?: return null
        @Suppress("DEPRECATION")
        return activities.getRunningTasks(50).firstOrNull { runCatching { field.getInt(it) }.getOrDefault(-1) == id }
    }

    private fun foregroundPackage(): String? = foregroundTask()?.topActivity?.packageName

    /** Legacy success shape stays unchanged; failed physical cleanup retains its original handles. */
    private fun releaseAll() = lock.withLock {
        if (strictOwner) throw Fault("releaseReceiptRequired")
        releasePhysical()
        clearResourceState()
    }

    /** At most current + pending reader are retained; failures prohibit another allocation. */
    private fun closeReaders() {
        var failed = false
        try { reader?.close(); reader = null } catch (_: Throwable) { failed = true }
        try { pendingReader?.close(); pendingReader = null } catch (_: Throwable) { failed = true }
        if (failed) throw Fault("releaseFailed")
        if (readerAllocationUncertain) throw Fault("releaseUnconfirmed")
    }

    private fun releasePhysical(): Boolean {
        coordinateObservation = null
        closeTreeConnection()
        visualObservation = null
        stopPreview()
        preview.invalidate()
        selfCheckWindow?.let { window ->
            // A probe that has not detached within its own timeout must not turn a finished
            // physical release into releasePending. Drop the handle first; the probe activity's
            // 8s self-expiry / finishAndRemoveTask still tears its own task down.
            selfCheckWindow = null
            runCatching { window.close() }
        }
        val neverCreated = !displayCreationAttempted
        if (neverCreated) {
            if (display != null || releasingDisplayId != null) throw Fault("releaseUnconfirmed")
            closeReaders()
        } else {
            val displayId = releasingDisplayId ?: throw Fault("releaseUnconfirmed")
            if (!displayApiReleased) {
                val original = display ?: throw Fault("releaseUnconfirmed")
                original.release()
                displayApiReleased = true
            }
            closeReaders()
            val deadline = SystemClock.uptimeMillis() + 1_000
            // The display itself is already released. A ROM whose task query is unreadable cannot
            // confirm the tasks left; that is not a reason to fail every release on it.
            while (!runCatching { releaseTasksGone(displayId) }.getOrDefault(true)) {
                val remaining = deadline - SystemClock.uptimeMillis()
                if (remaining <= 0) throw Fault("releasePending")
                Thread.sleep(minOf(50L, remaining))
            }
        }
        return neverCreated
    }

    private fun clearResourceState() {
        display = null; owner = null; strictOwner = false; selfCheckOwner = false
        targetIdentity.clear()
        targetSequence = null; targetSnapshot = null; targetMain = null
        releasingDisplayId = null; displayCreationAttempted = false; displayApiReleased = false; probeDisplay = false
    }

    private fun releaseStrict(ownerId: String, targetRelease: SelfCheckTargetRelease? = null): Boolean {
        if (lastReleasedOwner == ownerId) return lastReleaseNeverCreated
        if (owner != ownerId || !strictOwner) throw Fault("identityChanged")
        val neverCreated = releasePhysical()
        lastC2Release = targetRelease?.let {
            SelfCheckTargetCompletion(it, neverCreated, SelfCheckMainSamples.Result(
                SelfCheckMainSamples.Value.UNAVAILABLE, SelfCheckMainSamples.Value.UNAVAILABLE))
        }
        if (targetRelease != null) {
            val measured = targetMain?.sample(SelfCheckMainSamples.Slot.AFTER_RELEASE)
            if (measured != null) lastC2Release = checkNotNull(lastC2Release).copy(main = measured)
        }
        clearResourceState()
        lastReleasedOwner = ownerId
        lastReleaseNeverCreated = neverCreated
        return neverCreated
    }

    // ---- observation (tree + optional screenshot) --------------------------

    /** Exactly the original post-action read; a diagnostic attachment cannot rewrite the action ACK. */
    private fun observeAfterAction(pkg: String, request: Bundle, response: Bundle,
                                   localVisual: Boolean = false,
                                   coordinatePost: BackgroundCoordinateObservation? = null) {
        if (!request.containsKey(Proto.AFTER_LOCAL_VISUAL)) {
            observe(pkg, false, response, localVisual = localVisual, coordinatePost = coordinatePost)
            return
        }
        val after = Bundle()
        try {
            observe(pkg, true, after, localVisual = localVisual, coordinates = true, coordinatePost = coordinatePost)
            val expected = targetIdentity.current ?: throw Fault("targetIdentityUnavailable")
            val actual = requireActualTarget(expected)
            after.putInt(Proto.TARGET_IDENTITY_VERSION, 1)
            after.putInt(Proto.TARGET_UID, actual.uid)
            after.putString(Proto.PKG, actual.packageName)
            after.putBoolean(Proto.OK, after.containsKey(Proto.COUNT) && !after.getBoolean(Proto.FRAME_NOT_READY))
        } catch (error: Exception) {
            coordinateObservation = null
            visualObservation = null
            if (error is InterruptedException || error is Fault && error.code == "cancelled") throw error
            after.clear()
            after.putBoolean(Proto.OK, false)
            after.putString(Proto.ERROR, failureCode(error))
        }
        val legacy = Bundle(after)
        for (key in legacy.keySet().toList()) if (key !in BackgroundAfterVisual.legacyKeys) legacy.remove(key)
        response.putAll(legacy)
        response.putInt(Proto.AFTER_LOCAL_VISUAL, 1)
        response.putBundle(Proto.AFTER_VISUAL, after)
    }

    private fun observe(pkg: String, wantImage: Boolean, response: Bundle, requireTree: Boolean = false, detail: Boolean = false,
                        localVisual: Boolean = false, coordinates: Boolean = false,
                        coordinatePost: BackgroundCoordinateObservation? = null) {
        response.putInt(Proto.COORDINATE_SCOPE_VERSION, 1)
        response.putBoolean(Proto.COORDINATE_SCOPE_KNOWN, false)
        coordinateObservation = null
        if (targetIdentity.verified) requireForeground(pkg)
        visualObservation = null
        if (coordinatePost != null) response.putString(Proto.VISUAL_CHANGE, "unavailable")
        val id = displayId()
        response.putInt(Proto.DISPLAY_ID, id)
        response.putString(Proto.FG_PKG, pkg)
        response.putBoolean(Proto.PORTRAIT, height >= width)
        val captureResult = runCatching { tracePhase("dsh.bg.capture") { capture(localVisual || coordinates || coordinatePost != null) } }
        val captureFailure = captureResult.exceptionOrNull()
        if (captureFailure is InterruptedException ||
            captureFailure is Fault && captureFailure.code == "cancelled") throw captureFailure
        // Other capture faults retain the existing tree-only observation path.
        val shot = captureResult.getOrNull()
        val label = runCatching { appLabel(pkg) }.getOrNull()
        label?.let { response.putString(Proto.APP_LABEL, if (detail) BackgroundTree.cap(it) else it) }
        val treeResult = runCatching { readTree(id, pkg, scanOtherWindows = wantImage && shot != null, inspectVisual = (localVisual || coordinates || coordinatePost != null) && shot?.local != null, coordinates = coordinates) }
        val failure = treeResult.exceptionOrNull()
        if (failure is InterruptedException || failure is Fault && failure.code == "cancelled") throw failure
        // Pixels alone never identify FLAG_SECURE. Keep an explicit secure failure authoritative.
        val secure = failure is Fault && failure.code == "secureWindow"
        response.putBoolean(Proto.SECURE, secure)
        if (secure) {
            preview.protect()
            response.putBoolean(Proto.POOR, false); response.putInt(Proto.COUNT, 0); return
        }
        // Local preview never enters ScreenSnapshot / MCP. Publish only after the secure verdict.
        if (trees.ready()) {
            if (shot != null) shot.raw?.let { preview.captured(it) }
            else preview.observationUnavailable(if (captureResult.isSuccess) null else "captureFailed")
        }
        // A read must report its failure; observation after an already-dispatched write
        // must not turn that write into a failed action that a caller might replay.
        val tree = if (requireTree) treeResult.getOrThrow() else treeResult.getOrNull()
        if (captureResult.isSuccess && shot == null) {
            if (requireTree) throw Fault("frameNotReady")
            // The action already happened. Never make the caller replay it for an absent frame.
            response.putBoolean(Proto.FRAME_NOT_READY, true)
            response.putBoolean(Proto.POOR, true)
            response.putInt(Proto.COUNT, 0)
            return
        }
        // The screenshot contains the whole viewport, including nodes beyond the emitted
        // text prefix. Never attach it when secrets were found or the scan was incomplete.
        // The typing unlock changes permission to write, never permission to reveal a secret.
        if (wantImage && shot != null) {
            if (tree != null && tree.complete && !tree.hasSecrets) {
                response.putByteArray("imageBytes", shot.jpeg)
                response.putString("imageMime", "image/jpeg")
            } else {
                response.putBoolean(Proto.IMAGE_OMITTED, true)
            }
        }
        if (coordinates && wantImage && response.containsKey("imageBytes")) {
            val candidate = BackgroundCoordinateObservation.create(UUID.randomUUID().toString(), coordinateScope(),
                tree?.visualWindow, tree?.coordinateContext(), shot?.local, tree?.complete == true,
                tree?.hasSecrets != false, tree?.hasSensitive != false, SystemClock.uptimeMillis())
            if (candidate != null) {
                coordinateObservation = candidate
                coordinateReceipt(candidate, response)
            }
        }
        if (coordinatePost != null) {
            response.putString(Proto.VISUAL_CHANGE, coordinatePost.change(coordinateScope(), tree?.visualWindow,
                shot?.local, tree != null && tree.complete && !tree.hasSecrets && !tree.hasSensitive, SystemClock.uptimeMillis()))
        }
        if (localVisual && tree != null) {
            val vd = display
            val currentOwner = owner
            val scope = if (vd != null && currentOwner != null) tree.visualWindow?.let {
                BackgroundVisualObservation.Scope(vd, currentOwner, pkg, it)
            } else null
            visualObservation = BackgroundVisualObservation.create(scope, shot?.local,
                tree.complete && tree.elements.count { it.label.isNotEmpty() } >= 5,
                tree.hasSecrets, tree.hasSensitive, SystemClock.uptimeMillis())
        }
        response.putBoolean(Proto.COORDINATE_SCOPE_KNOWN, tree?.complete == true && tree.visualWindow != null)
        val elements = tree?.elements.orEmpty()
        if (detail) {
            val models = elements.mapIndexed { index, e ->
                Element(index + 1, e.role, e.label, Region.MIDDLE, indent = e.indent,
                    states = e.states, sensitive = e.flags and Proto.FLAG_SENSITIVE != 0,
                    viewId = e.viewId, bounds = ElementBounds(e.bounds.left, e.bounds.top, e.bounds.right, e.bounds.bottom))
            }
            fun payloadFor(count: Int) = Bundle().apply {
                emitElements(elements, this, count, detail = true)
                putInt(Proto.ELEMENT_OVERFLOW, elements.size - count)
                putBoolean(Proto.TREE_COMPLETE, tree?.complete == true)
            }
            var count = BackgroundTree.detailPrefixCount(models)
            var payload = payloadFor(count)
            // Measure the real Parcel, not UTF-8 estimates (Parcel strings are UTF-16).
            // Bounded binary search is only needed if platform encoding exceeds the reserve.
            if (Bundles.marshal(payload).size > BackgroundTree.DETAIL_PARCEL_BYTES) {
                var low = 0
                var high = count
                while (low < high) {
                    val mid = (low + high + 1) / 2
                    val candidate = payloadFor(mid)
                    if (Bundles.marshal(candidate).size <= BackgroundTree.DETAIL_PARCEL_BYTES) low = mid else high = mid - 1
                }
                count = low
                payload = payloadFor(count)
            }
            response.putAll(payload)
        } else emitElements(elements, response)
        // Only expose indices that survived the actual bounded output, never merely <=120.
        if (coordinateObservation != null && coordinates && tree != null) {
            val ids = tree.eligibleNodes.mapNotNull { tree.coordinateElementIds[it] }
                .filter { it <= minOf(120, response.getInt(Proto.COUNT)) }.sorted()
            response.putInt(Proto.COORDINATE_TARGETS_VERSION, 1)
            response.putIntArray(Proto.COORDINATE_TARGET_INDICES, ids.toIntArray())
            response.putIntArray(Proto.COORDINATE_TARGET_BOUNDS, ids.flatMap { id ->
                val b = elements[id - 1].bounds
                listOf(b.left, b.top, b.right, b.bottom)
            }.toIntArray())
        }
    }

    private fun emitElements(elements: List<BgNode>, response: Bundle, count: Int = 120, detail: Boolean = false) {
        val capped = elements.take(count)
        val n = capped.size
        response.putInt(Proto.COUNT, n)
        response.putBoolean(Proto.POOR, elements.count { it.label.isNotEmpty() } < 5)
        val role = arrayOfNulls<String>(n); val label = arrayOfNulls<String>(n)
        val viewIds = arrayOfNulls<String>(n)
        val states = arrayOfNulls<String>(n); val flags = IntArray(n)
        val region = IntArray(n); val indent = IntArray(n)
        val bounds = if (detail) IntArray(n * 4) else null
        for (i in 0 until n) {
            val e = capped[i]
            role[i] = e.role; label[i] = e.label; states[i] = e.states.joinToString("\u0001")
            viewIds[i] = e.viewId
            flags[i] = e.flags; region[i] = e.region; indent[i] = e.indent
            if (bounds != null) {
                bounds[i * 4] = e.bounds.left; bounds[i * 4 + 1] = e.bounds.top
                bounds[i * 4 + 2] = e.bounds.right; bounds[i * 4 + 3] = e.bounds.bottom
            }
        }
        response.putStringArray(Proto.A_ROLE, role)
        response.putStringArray(Proto.A_LABEL, label)
        response.putStringArray(Proto.A_VIEW_ID, viewIds)
        response.putStringArray(Proto.A_STATES, states)
        response.putIntArray(Proto.A_FLAGS, flags)
        response.putIntArray(Proto.A_REGION, region)
        response.putIntArray(Proto.A_INDENT, indent)
        if (bounds != null) response.putIntArray(Proto.A_BOUNDS, bounds)
    }

    private fun appLabel(pkg: String): String? {
        val pm = privileged.packageManager
        return runCatching { pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString() }.getOrNull()
    }

    private class CaptureResult(val jpeg: ByteArray, val raw: BackgroundPreviewState.RawFrame?, val local: ImageObservation?, val targetMatched: Boolean? = null)

    /** Null means only absent/black frames; other capture failures remain distinguishable. */
    private fun capture(localVisual: Boolean = false, targetFrame: TargetFrameCheck? = null): CaptureResult? {
        val ir = lock.withLock {
            if (pendingReader != null || readerAllocationUncertain) throw Fault("releasePending")
            val vd = display ?: throw Fault("displayMissing")
            readerAllocationUncertain = true
            val next = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
            pendingReader = next
            readerAllocationUncertain = false // Register before setSurface or closing the previous reader can throw.
            preview.readerChanged()
            vd.surface = next.surface
            reader?.close()
            reader = next
            pendingReader = null
            next
        }
        try {
            val deadline = SystemClock.uptimeMillis() + BackgroundFrameReadiness.CAPTURE_TIMEOUT_MS
            for (attempt in 0..1) {
                if (released.get() || Thread.currentThread().isInterrupted) throw Fault("cancelled")
                if (attempt > 0 && SystemClock.uptimeMillis() >= deadline) return null
                var image = ir.acquireLatestImage()
                while (image == null) {
                    val remaining = deadline - SystemClock.uptimeMillis()
                    if (remaining <= 0) return null
                    sleepChecked(minOf(40L, remaining))
                    image = ir.acquireLatestImage()
                }
                val capturedAt = SystemClock.uptimeMillis()
                try {
                    val plane = image.planes.singleOrNull() ?: throw Fault("screenshotFailed")
                    if (plane.pixelStride != 4 || plane.rowStride < width * 4) throw Fault("screenshotFailed")
                    val pixels = ByteBuffer.allocate(width * height * 4)
                    val src = plane.buffer.duplicate()
                    for (row in 0 until height) {
                        val start = row * plane.rowStride
                        src.limit(start + width * 4); src.position(start)
                        pixels.put(src)
                    }
                    pixels.flip()
                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    try {
                        bitmap.copyPixelsFromBuffer(pixels)
                        val remaining = deadline - SystemClock.uptimeMillis()
                        when (BackgroundFrameReadiness.next(isMostlyBlack(bitmap), attempt, remaining)) {
                            BackgroundFrameReadiness.Next.NOT_READY -> return null
                            BackgroundFrameReadiness.Next.RETRY -> Unit
                            BackgroundFrameReadiness.Next.READY -> {
                                val buffer = ByteArrayOutputStream()
                                tracePhase("dsh.bg.jpeg") {
                                    bitmap.compress(Bitmap.CompressFormat.JPEG, 80, buffer)
                                }
                                // Reuse the already-copied RGBA buffer only for an active local preview.
                                // No JPEG decode round-trip: both preview sources compare identical pixels.
                                val raw = if (preview.acceptsCandidate())
                                    BackgroundPreviewState.RawFrame(width, height, pixels.array()) else null
                                // Sampling cannot turn an existing successful capture/action into a failure.
                                val local = if (localVisual) try {
                                    val frame = VisualFrame.capture(width, height) { y, row ->
                                        bitmap.getPixels(row, 0, width, 0, y, width, 1)
                                    }
                                    ImageObservation(ImageGeometry(0, 0, 1f, 1f, width, height), capturedAt, frame)
                                } catch (_: Exception) { null } else null
                                return CaptureResult(buffer.toByteArray(), raw, local, targetFrame?.matches(bitmap))
                            }
                        }
                    } finally { bitmap.recycle() }
                } finally { image.close() }
                // Release the first Image before taking one more from this same reader/surface.
                sleepChecked(BackgroundFrameReadiness.retryWaitMs(deadline - SystemClock.uptimeMillis()))
            }
            return null
        } finally { /* reader kept for next frame; closed on release */ }
    }

    private fun isMostlyBlack(bitmap: Bitmap): Boolean {
        val stepX = (bitmap.width / 24).coerceAtLeast(1)
        val stepY = (bitmap.height / 48).coerceAtLeast(1)
        var dark = 0; var total = 0
        var y = 0
        while (y < bitmap.height) {
            var x = 0
            while (x < bitmap.width) {
                val c = bitmap.getPixel(x, y)
                val luma = ((c shr 16 and 0xff) * 30 + (c shr 8 and 0xff) * 59 + (c and 0xff) * 11) / 100
                if (luma < 12) dark++
                total++
                x += stepX
            }
            y += stepY
        }
        return total > 0 && dark * 100 / total >= 98
    }

    // ---- local, read-only preview ------------------------------------------

    private fun previewRequest(request: Bundle): Bundle {
        if (!request.containsKey(Proto.PREVIEW_ENABLED)) throw Fault("invalidArguments")
        val enabled = request.getBoolean(Proto.PREVIEW_ENABLED)
        var work: Pair<ExecutorService, BackgroundPreviewState.Ticket>? = null
        // Disabling is a cleanup operation, never a cancellable shared-stream request.
        if (enabled) {
            if (!lock.tryLock()) return previewReply(request, busy = true)
        } else lock.lock()
        val reply = try {
            if (enabled) requireTreeReady()
            if (selfCheckOwner || targetSequence != null) throw Fault("identityChanged")
            val requestedOwner = request.getString(Proto.OWNER)
            if (requestedOwner.isNullOrEmpty() || requestedOwner != owner) throw Fault("identityChanged")
            requireDisplay()
            if (!enabled) stopPreview()
            else {
                preview.configure(true)
                if (keyguard?.isKeyguardLocked == true) preview.protect()
                else preview.begin(SystemClock.uptimeMillis())?.let { ticket ->
                    val worker = previewWorker.acquire()
                    if (worker == null) {
                        preview.finish(ticket)
                        return@let
                    }
                    work = worker to ticket
                }
            }
            previewReply(request)
        } finally { lock.unlock() }
        work?.let { (worker, ticket) ->
            try { worker.execute { renderPreview(ticket) } }
            catch (_: RejectedExecutionException) { preview.finish(ticket) } // Closed after unlock.
        }
        return reply
    }

    /** The reply is a small immutable cache snapshot; no frame wait, tree read, or JPEG work. */
    private fun previewReply(request: Bundle, busy: Boolean = false): Bundle {
        val value = preview.snapshot()
        return Bundle().apply {
            putBoolean(Proto.OK, true)
            putString(Proto.PREVIEW_STATE, if (busy) "busy" else value.state)
            putLong(Proto.PREVIEW_GENERATION, value.generation)
            putLong(Proto.PREVIEW_SEQUENCE, value.sequence)
            if (!busy) {
                value.reason?.let { putString(Proto.PREVIEW_REASON, it) }
                val frame = value.frame
                if (frame != null && request.getLong(Proto.PREVIEW_AFTER_SEQUENCE, -1) != value.sequence) {
                    putInt(Proto.PREVIEW_WIDTH, frame.width)
                    putInt(Proto.PREVIEW_HEIGHT, frame.height)
                    putByteArray(Proto.PREVIEW_BYTES, frame.jpeg)
                }
            }
        }
    }

    /** Caller owns the display lock. Shutdown never waits for an encoder; its ticket is retired. */
    private fun stopPreview() {
        preview.configure(false)
        previewWorker.stop()
    }

    internal fun hasResources(): Boolean = lock.withLock { owner != null }
    internal fun knowsOwner(value: String): Boolean = lock.withLock { owner == value || lastReleasedOwner == value }

    internal fun completedRelease(): HostedRelease? = lock.withLock {
        lastReleasedOwner?.let { HostedRelease(it, lastReleaseNeverCreated, lastC2Release) }
    }

    internal fun previewDrained(): Boolean = lock.withLock { previewWorker.drained() }

    private fun renderPreview(ticket: BackgroundPreviewState.Ticket) {
        var bitmap: Bitmap? = null
        var thumbnail: Bitmap? = null
        try {
            // Agent dispatch owns this same lock for its complete capture, including the wait.
            // A preview therefore cannot consume an Image from the reader an Agent is awaiting.
            if (!lock.tryLock()) return
            try {
                if (!preview.current(ticket)) return
                if (keyguard?.isKeyguardLocked == true) { preview.protect(); return }
                val image = reader?.acquireLatestImage()
                if (image != null) try {
                    val plane = image.planes.singleOrNull() ?: throw Fault("screenshotFailed")
                    if (plane.pixelStride != 4 || plane.rowStride < width * 4) throw Fault("screenshotFailed")
                    val pixels = ByteBuffer.allocate(width * height * 4)
                    val source = plane.buffer.duplicate()
                    for (row in 0 until height) {
                        val start = row * plane.rowStride
                        source.limit(start + width * 4); source.position(start)
                        pixels.put(source)
                    }
                    pixels.flip()
                    bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    bitmap!!.copyPixelsFromBuffer(pixels)
                } finally { image.close() }
                // All Image/buffer access ends before releaseAll can close its ImageReader.
            } finally { lock.unlock() }
            if (bitmap == null) {
                val raw = ticket.candidate ?: return // A static frame keeps the same cached image.
                bitmap = Bitmap.createBitmap(raw.width, raw.height, Bitmap.Config.ARGB_8888)
                bitmap!!.copyPixelsFromBuffer(ByteBuffer.wrap(raw.pixels))
            }
            preview.consumed(ticket)
            val source = bitmap!!
            if (isMostlyBlack(source)) { preview.unavailable(ticket, "blackFrame"); return }
            val scale = minOf(1f, 360f / minOf(source.width, source.height),
                800f / maxOf(source.width, source.height))
            val w = (source.width * scale).toInt().coerceAtLeast(1)
            val h = (source.height * scale).toInt().coerceAtLeast(1)
            val small = Bitmap.createScaledBitmap(source, w, h, true).also { thumbnail = it }
            val pixels = IntArray(w * h)
            small.getPixels(pixels, 0, w, 0, 0, w, h)
            if (!preview.changed(ticket, pixels, w, h)) return
            val output = ByteArrayOutputStream()
            if (!small.compress(Bitmap.CompressFormat.JPEG, 65, output)) throw Fault("screenshotFailed")
            val bytes = output.toByteArray()
            if (bytes.size > BackgroundPreviewState.MAX_BYTES) {
                preview.unavailable(ticket, "frameTooLarge"); return
            }
            preview.publish(ticket, BackgroundPreviewState.Frame(w, h, pixels, bytes), SystemClock.uptimeMillis())
        } catch (_: Exception) {
            preview.unavailable(ticket, "captureFailed")
        } finally {
            if (thumbnail !== bitmap) thumbnail?.recycle()
            bitmap?.recycle()
            preview.finish(ticket)
        }
    }

    // ---- UiAutomation control-tree read ------------------------------------

    private class TreeRead(val targetId: Int = 0, val inspectVisual: Boolean = false,
                           val targetEvidence: SelfCheckTargetEvidence? = null, coordinates: Boolean = false) {
        val coordinateDigest: MessageDigest? = if (coordinates) MessageDigest.getInstance("SHA-256") else null
        val coordinateNodes: ArrayList<VisualNode>? = if (coordinates) ArrayList() else null
        val coordinateElementIds = HashMap<Int, Int>()
        var eligibleNodes: List<Int> = emptyList()
        fun coordinateContext(): String? {
            val digest = coordinateDigest ?: return null
            // Final classification uses the whole real tree, including output-truncated blockers.
            digest.update(ByteBuffer.allocate(4).putInt(eligibleNodes.size).array())
            eligibleNodes.forEach { digest.update(ByteBuffer.allocate(4).putInt(it).array()) }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
        var visualWindow: BackgroundVisualObservation.Window? = null
        var hasSensitive = false
        val elements = ArrayList<BgNode>()
        var visited = 0
        var complete = true
        var hasSecrets = false
        var targetWindowId: Int? = null
        var target: AccessibilityNodeInfo? = null
    }

    private fun requireTreeReady() {
        if (!trees.ready()) throw Fault("treeCleanupPending")
    }

    private fun closeTreeConnection() {
        if (!trees.closeOwned(this)) {
            coordinateObservation = null
            visualObservation = null
            stopPreview()
            preview.invalidate()
            throw Fault("treeCleanupPending")
        }
    }

    private fun <T> withTreeConnection(targetDisplay: Display, pkg: String, unavailable: String, read: (UiAutomation) -> T): T =
        try { trees.read(this, targetDisplay, pkg, unavailable, read) }
        catch (e: PrivilegedTreeAccess.Failure) {
            if (e.code == "treeCleanupPending") {
                coordinateObservation = null
                visualObservation = null
                stopPreview()
                preview.invalidate()
            }
            throw Fault(e.code)
        }

    private fun readTree(displayId: Int, pkg: String, scanOtherWindows: Boolean = false, inspectVisual: Boolean = false, targetEvidence: SelfCheckTargetEvidence? = null, coordinates: Boolean = false): TreeRead {
        val vd = display ?: throw Fault("displayMissing")
        return withTreeConnection(vd.display, pkg, "treeUnavailable") { automation ->
            tracePhase("dsh.bg.treeRead") {
                readTree(automation, displayId, pkg, scanOtherWindows = scanOtherWindows, inspectVisual = inspectVisual, targetEvidence = targetEvidence, coordinates = coordinates)
            }
        }
    }

    private fun readTree(
        automation: UiAutomation, displayId: Int, pkg: String,
        targetId: Int = 0, scanOtherWindows: Boolean = false, inspectVisual: Boolean = false,
        targetEvidence: SelfCheckTargetEvidence? = null, coordinates: Boolean = false,
        navigation: NavigationRead? = null,
    ): TreeRead {
        if (navigation != null) {
            if (Thread.currentThread().isInterrupted) throw InterruptedException()
            if (runCatching { invoke(automation, "clearCache") }.getOrNull() != true)
                throw Fault("treeUnavailable")
        } else runCatching { invoke(automation, "clearCache") }
        @Suppress("UNCHECKED_CAST")
        val all = invoke(automation, "getWindowsOnAllDisplays") as? SparseArray<List<AccessibilityWindowInfo>>
            ?: throw Fault("treeUnavailable")
        val displayWindows = all.get(displayId).orEmpty()
        val windows = displayWindows.filter {
            it.type == AccessibilityWindowInfo.TYPE_APPLICATION
        }
        if ((targetEvidence != null || navigation != null) && (displayWindows.size != 1 || windows.size != 1)) throw Fault("targetUnavailable")
        val roots = ArrayList<AccessibilityNodeInfo?>()
        try {
            for (window in windows) roots.add(window.root)
            val selected = BackgroundTree.selectApplicationWindow(roots.map { it?.packageName?.toString() }, pkg)
                ?: throw Fault(if (roots.firstOrNull() != null) "displayTargetChanged" else "treeUnavailable")
            val tree = TreeRead(targetId, inspectVisual, targetEvidence, coordinates)
            if (targetEvidence != null) tree.targetWindowId = windows[selected.index].id
            if (displayWindows.size == 1 && windows.size == 1) {
                val window = windows[selected.index]
                tree.visualWindow = try {
                    val bounds = Rect().also { window.getBoundsInScreen(it) }
                    BackgroundVisualObservation.Window(window.id, bounds.left, bounds.top, bounds.right, bounds.bottom)
                } catch (_: Exception) { null } // Extra metadata failure only disables the local summary.
            }
            if (!scanOtherWindows && roots.size > 1) tree.complete = false
            try {
                walk(roots[selected.index]!!, tree, 0, 600, navigation = navigation)
                assignRegions(tree.elements)
                if (scanOtherWindows) for (index in selected.scanOrder.drop(1)) {
                    try {
                        // Same privacy walk and total budget, but never expose secondary
                        // elements or let them take ownership of a main-window target id.
                        walk(roots[index], tree, 0, 600, emitElements = false)
                    } catch (e: Exception) {
                        if (e is InterruptedException || e is java.util.concurrent.CancellationException || e is Fault) throw e
                        // A secondary read failure prevents an image, not the already
                        // successful main-window text. Primary errors remain outside this catch.
                        tree.complete = false
                    }
                }
                tree.coordinateNodes?.let { nodes ->
                    val b = tree.visualWindow
                    if (b != null) tree.eligibleNodes = VisualTargets.eligible(nodes,
                        VisualBounds(b.left, b.top, b.right, b.bottom), tree.complete && !tree.hasSecrets && !tree.hasSensitive)
                }
                return tree
            } catch (e: Throwable) {
                tree.target?.recycle()
                throw e
            }
        } finally { roots.forEach { it?.recycle() } }
    }

    private fun walk(node: AccessibilityNodeInfo?, tree: TreeRead, indent: Int, budget: Int, emitElements: Boolean = true, parentIndex: Int = -1,
                     navigation: NavigationRead? = null, navigationParent: Int = -1) {
        if (node == null) { tree.complete = false; return }
        if (tree.visited >= budget) { tree.complete = false; return }
        tree.visited++
        if (navigation != null) {
            if (Thread.currentThread().isInterrupted) throw InterruptedException()
            val refreshed = node.refresh()
            if (Thread.currentThread().isInterrupted) throw InterruptedException()
            if (!refreshed) throw Fault("targetUnavailable")
        }
        val navigationIndex = navigation?.visit(node, navigationParent) ?: -1
        val coordinateIndex = tree.coordinateNodes?.size ?: -1
        val actionClick = if (tree.coordinateNodes != null) node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK } else false
        tree.coordinateNodes?.add(VisualNode(parentIndex, node.className?.take(4097)?.toString(),
            Rect().also { node.getBoundsInScreen(it) }.let { VisualBounds(it.left, it.top, it.right, it.bottom) },
            node.isVisibleToUser, node.isEnabled, node.isClickable, actionClick, node.childCount,
            node.isEditable, node.isCheckable, isSecret(node), node.isLongClickable, node.isScrollable,
            node.text?.take(4097)?.toString(), node.contentDescription?.take(4097)?.toString(),
            node.hintText?.take(4097)?.toString(), node.viewIdResourceName?.take(4097)))
        tree.targetEvidence?.let { evidence ->
            val id = node.viewIdResourceName
            evidence.observe(id, node.isVisibleToUser, node.text, node.contentDescription,
                node.isEnabled, node.isClickable, node.isEditable, node.isShowingHintText)
            if (evidence.needsBounds(id)) {
                val bounds = Rect().also { node.getBoundsInScreen(it) }
                evidence.observeBounds(id, bounds.left, bounds.top, bounds.right, bounds.bottom)
            }
        }
        if (node.isVisibleToUser && isSecret(node)) tree.hasSecrets = true
        val text = if (emitElements || tree.inspectVisual) bestText(node) else ""
        if (tree.inspectVisual && node.isVisibleToUser && !tree.hasSensitive) {
            tree.hasSensitive = try {
                // Check raw text too: bestText may drop an oversized blank value.
                backgroundVisualSensitive(node.text, node.contentDescription, node.hintText, node.viewIdResourceName)
            } catch (_: Exception) { true } // Incomplete additional privacy evidence cannot fail the element action.
        }
        tree.coordinateDigest?.let { digest ->
            val bounds = Rect().also { node.getBoundsInScreen(it) }
            val fields = listOf(node.text, node.contentDescription, node.hintText, node.viewIdResourceName,
                node.className, node.packageName).map { it?.toString() }
            if (fields.any { (it?.length ?: 0) > 4096 }) tree.hasSensitive = true
            else {
                // Length prefixes distinguish null/empty and field boundaries without retaining text.
                for (field in fields) {
                    val bytes = field?.toByteArray(Charsets.UTF_8)
                    digest.update(ByteBuffer.allocate(4).putInt(bytes?.size ?: -1).array())
                    if (bytes != null) digest.update(bytes)
                }
            }
            val metadata = intArrayOf(parentIndex, if (actionClick) 1 else 0, indent, node.childCount, bounds.left, bounds.top, bounds.right, bounds.bottom,
                node.inputType, if (node.isVisibleToUser) 1 else 0, if (node.isEnabled) 1 else 0,
                if (node.isClickable) 1 else 0, if (node.isLongClickable) 1 else 0, if (node.isEditable) 1 else 0,
                if (node.isScrollable) 1 else 0, if (node.isPassword) 1 else 0, if (node.isShowingHintText) 1 else 0,
                if (node.isCheckable) 1 else 0, if (node.isChecked) 1 else 0,
                if (node.isSelected) 1 else 0, if (node.isFocused) 1 else 0)
            digest.update(ByteBuffer.allocate(metadata.size * 4).apply { metadata.forEach { putInt(it) } }.array())
        }
        var childIndent = indent
        if (emitElements) {
            val actionable = node.isClickable || node.isLongClickable || node.isEditable || node.isCheckable || node.isScrollable
            val emit = actionable || (text.isNotEmpty() && node.isVisibleToUser)
            if (emit && node.isVisibleToUser) {
                val rect = Rect().also { node.getBoundsInScreen(it) }
                tree.elements.add(toElement(node, text, rect, indent))
                if (coordinateIndex >= 0) tree.coordinateElementIds[coordinateIndex] = tree.elements.size
                // Retain the exact node assigned this screen id, not whichever editor has focus.
                if (tree.elements.size == tree.targetId) tree.target = AccessibilityNodeInfo.obtain(node)
                if (node.isScrollable) childIndent = indent + 1
            }
        }
        for (i in 0 until node.childCount) {
            if (tree.visited >= budget) { tree.complete = false; break }
            val child = node.getChild(i)
            try { walk(child, tree, childIndent, budget, emitElements, coordinateIndex, navigation, navigationIndex) } finally { child?.recycle() }
        }
    }

    private fun toElement(node: AccessibilityNodeInfo, text: String, rect: Rect, indent: Int): BgNode {
        val cls = node.className?.toString().orEmpty()
        val password = node.isPassword || secretInput(node)
        val hint = node.hintText?.toString().orEmpty()
        val description = node.contentDescription?.toString().orEmpty()
        val secret = isSecret(node)
        val role = role(node, cls)
        val filled = !node.isShowingHintText && !node.text.isNullOrBlank()
        val label = BackgroundTree.label(text, description.ifBlank { hint }, filled, password, secret)
        val states = ArrayList<String>()
        // l10n:keep privileged screen protocol
        if (node.isFocused) states.add("已聚焦")
        // l10n:keep privileged screen protocol
        if (node.isSelected) states.add("已选")
        // l10n:keep privileged screen protocol
        if (node.isCheckable) states.add(if (node.isChecked) "已勾选" else "未勾选")
        // l10n:keep privileged screen protocol
        if (!node.isEnabled) states.add("不可用")
        // l10n:keep privileged screen protocol
        if (node.isScrollable) states.add("可滚动")
        // l10n:keep privileged screen protocol
        if (password) states.add("密码·不可代填")
        var flags = 0
        if (node.isPassword) flags = flags or Proto.FLAG_PASSWORD
        if (secret) flags = flags or Proto.FLAG_SECRET
        if (node.isEditable) flags = flags or Proto.FLAG_EDITABLE
        if (node.isClickable) flags = flags or Proto.FLAG_CLICKABLE
        if (node.isLongClickable) flags = flags or Proto.FLAG_LONGCLICK
        if (node.isScrollable) flags = flags or Proto.FLAG_SCROLLABLE
        if (node.isFocused) flags = flags or Proto.FLAG_FOCUSED
        val viewId = node.viewIdResourceName
        if (SensitiveWords.confirmHit(label, viewId) != null) flags = flags or Proto.FLAG_SENSITIVE
        return BgNode(role, label, states, flags, indent, rect, node.packageName?.toString(), viewId)
    }

    private fun role(node: AccessibilityNodeInfo, cls: String): String = when {
        // l10n:keep privileged screen protocol
        node.isEditable -> "输入框"
        // l10n:keep privileged screen protocol
        cls.endsWith("Switch") || cls.contains("Switch") -> "开关"
        // l10n:keep privileged screen protocol
        node.isCheckable -> "勾选框"
        // l10n:keep privileged screen protocol
        cls.contains("Button") || node.isClickable && node.text != null -> "按钮"
        // l10n:keep privileged screen protocol
        cls.contains("ImageView") && node.isClickable -> "图片"
        // l10n:keep privileged screen protocol
        cls.contains("RecyclerView") || cls.contains("ListView") -> "列表"
        // l10n:keep privileged screen protocol
        node.isClickable -> "按钮"
        // l10n:keep privileged screen protocol
        else -> "文本"
    }

    private fun isSecret(node: AccessibilityNodeInfo): Boolean = node.isPassword || secretInput(node) ||
        SensitiveWords.secretHit(
            node.hintText?.toString(), node.contentDescription?.toString(),
            // Resource ids classify inputs: a sendOtp button requests a code, not a secret value.
            // Keep hint/description masking for non-editable secret displays.
            if (node.isEditable) node.viewIdResourceName else null,
        ) != null

    private fun secretInput(node: AccessibilityNodeInfo): Boolean {
        val klass = node.inputType and InputType.TYPE_MASK_CLASS
        val variation = node.inputType and InputType.TYPE_MASK_VARIATION
        return (klass == InputType.TYPE_CLASS_TEXT && variation in setOf(
            InputType.TYPE_TEXT_VARIATION_PASSWORD, InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)) ||
            (klass == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD)
    }

    private fun bestText(node: AccessibilityNodeInfo): String {
        node.text?.toString()?.takeIf { it.isNotBlank() }?.let { return it }
        node.contentDescription?.toString()?.takeIf { it.isNotBlank() }?.let { return it }
        if (node.isEditable) node.hintText?.toString()?.takeIf { it.isNotBlank() }?.let { return it }
        return ""
    }

    private fun assignRegions(out: List<BgNode>) {
        if (out.isEmpty()) return
        val top = height / 3; val bottom = height * 2 / 3
        for (e in out) {
            val cy = (e.bounds.top + e.bounds.bottom) / 2
            e.region = when {
                cy < top -> 0
                cy < bottom -> 1
                else -> 2
            }
        }
    }

    // ---- actions -----------------------------------------------------------

    private fun resolveElement(pkg: String, request: Bundle, target: TargetSnapshot? = null): BgNode {
        val index = request.getInt(Proto.ELEMENT, -1)
        if (index < 1) throw Fault("invalidArguments")
        val e = if (target == null) {
            readTree(displayId(), pkg).elements.getOrNull(index - 1) ?: throw Fault("elementMissing")
        } else {
            val fresh = readTargetSnapshot(target.run, 0)
            if (fresh.windowId != target.windowId || fresh.index != index || fresh.element.bounds != target.element.bounds)
                throw Fault("targetChanged")
            fresh.element
        }
        val expectRole = request.getString(Proto.EXPECT_ROLE)
        val expectLabel = request.getString(Proto.EXPECT_LABEL)
        val expectViewId = request.getString(Proto.EXPECT_VIEW_ID)
        // The whole label is part of the identity: safety was checked against the observed
        // target, so "Invoice 12 view" turning into "Invoice 12 delete" must not pass.
        if (expectRole != null && expectRole != e.role ||
            expectLabel != null && expectLabel != e.label ||
            expectViewId != null && expectViewId != e.viewId) throw Fault(if (target == null) "staleSnapshot" else "targetChanged")
        return e
    }

    private fun coordinateScope(): BackgroundCoordinateObservation.Scope? {
        val vd = display ?: return null
        val ownerId = owner ?: return null
        val target = targetIdentity.current ?: return null
        return BackgroundCoordinateObservation.Scope(vd, ownerId, target)
    }

    private fun coordinateReceipt(observation: BackgroundCoordinateObservation, response: Bundle) {
        response.putInt(Proto.BACKGROUND_COORDINATES, 1)
        response.putString(Proto.COORDINATE_OBSERVATION, observation.nonce)
        response.putInt(Proto.COORDINATE_WIDTH, observation.image.geometry.width)
        response.putInt(Proto.COORDINATE_HEIGHT, observation.image.geometry.height)
        response.putInt(Proto.TARGET_IDENTITY_VERSION, 1)
        response.putString(Proto.PKG, observation.scope.target.packageName)
        response.putInt(Proto.TARGET_UID, observation.scope.target.uid)
    }

    private fun coordinate(pkg: String, request: Bundle, response: Bundle) {
        val action = BackgroundCoordinateRequest.parse(request.keySet()) { request.get(it) } ?: throw Fault("invalidArguments")
        val observed = coordinateObservation ?: throw Fault("staleSnapshot")
        if (action.nonce != observed.nonce) throw Fault("staleSnapshot")
        coordinateReceipt(observed, response)
        response.putBoolean(Proto.ACTION_ATTEMPTED, false)
        response.putString(Proto.VISUAL_CHANGE, "unavailable")
        val geometry = ImageGeometry(0, 0, 1f, 1f, width, height)
        if (!action.fits(width, height) || !observed.image.isFresh(SystemClock.uptimeMillis())) throw Fault("staleSnapshot")
        requireForeground(pkg)
        val tree = readTree(displayId(), pkg, scanOtherWindows = true, inspectVisual = true, coordinates = true)
        val scope = coordinateScope() ?: throw Fault("targetIdentityUnavailable")
        if (!tree.complete || tree.hasSecrets || tree.hasSensitive ||
            !observed.matches(scope, tree.visualWindow, tree.coordinateContext(), geometry, SystemClock.uptimeMillis()))
            throw Fault("targetChanged")
        // The complete tree transaction has already unregistered. Recheck the real target before dispatch.
        requireForeground(pkg)
        if (!observed.image.isFresh(SystemClock.uptimeMillis())) throw Fault("staleSnapshot")
        coordinateObservation = null
        response.putBoolean(Proto.ACTION_ATTEMPTED, true)
        when (action.gesture) {
            "tap" -> injectTap(action.x, action.y, false)
            "long" -> injectTap(action.x, action.y, true)
            "swipe" -> injectSwipe(action.x, action.y, checkNotNull(action.x2), checkNotNull(action.y2), action.durationMs)
        }
        sleepChecked(250)
        observeAfterAction(pkg, request, response, coordinatePost = observed)
    }

    /** Per-request original native nodes, never retained between requests. */
    private class NavigationRead : AutoCloseable {
        data class Node(val parent: Int, val viewId: String?, val desc: String?, val bounds: Rect,
            val enabled: Boolean, val password: Boolean, val editable: Boolean,
            val selected: Boolean, val clickable: Boolean, val actionClick: Boolean)
        val nodes = ArrayList<Node>()
        var more: AccessibilityNodeInfo? = null
        var observation: com.skyjjgw.independent.ski.dshgo.phone.a11y.MarkorNavigation.Observation? = null
        var label = ""
        fun visit(node: AccessibilityNodeInfo, parent: Int): Int {
            val viewId = node.viewIdResourceName
            val desc = node.contentDescription?.toString()
            if ((viewId?.length ?: 0) > 1024 || (desc?.toByteArray(Charsets.UTF_8)?.size ?: 0) > 1024)
                throw Fault("targetUnavailable")
            val index = nodes.size
            nodes += Node(parent, viewId, desc, Rect().also { node.getBoundsInScreen(it) },
                node.isEnabled && node.isVisibleToUser, node.isPassword, node.isEditable,
                node.isSelected, node.isClickable, node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK })
            if (viewId == "${BackgroundNavigationProtocol.PACKAGE}:id/nav_more" && more == null)
                more = AccessibilityNodeInfo.obtain(node)
            return index
        }
        fun window(window: BackgroundVisualObservation.Window): com.skyjjgw.independent.ski.dshgo.phone.a11y.UiWindow {
            fun convert(index: Int): com.skyjjgw.independent.ski.dshgo.phone.a11y.UiNode {
                val n = nodes[index]
                return com.skyjjgw.independent.ski.dshgo.phone.a11y.UiNode(ref = index, viewId = n.viewId,
                    desc = n.desc, bounds = com.skyjjgw.independent.ski.dshgo.phone.a11y.Box(n.bounds.left, n.bounds.top, n.bounds.right, n.bounds.bottom),
                    enabled = n.enabled, password = n.password, editable = n.editable, selected = n.selected,
                    clickable = n.clickable, actionClick = n.actionClick,
                    children = nodes.indices.filter { nodes[it].parent == index }.map(::convert))
            }
            return com.skyjjgw.independent.ski.dshgo.phone.a11y.UiWindow(window.id,
                com.skyjjgw.independent.ski.dshgo.phone.a11y.WindowKind.APP, BackgroundNavigationProtocol.PACKAGE, null,
                com.skyjjgw.independent.ski.dshgo.phone.a11y.Box(window.left, window.top, window.right, window.bottom), convert(0))
        }
        override fun close() { more?.recycle(); more = null }
    }

    private fun navigationIdentity(expected: PhoneAppIdentity, app: BackgroundNavigationProtocol.Installation): Map<String, String> {
        if (Thread.currentThread().isInterrupted) throw InterruptedException()
        if (keyguard?.isKeyguardLocked == true) throw Fault("locked")
        requireActualTarget(expected)
        val installed = com.skyjjgw.independent.ski.dshgo.phone.a11y.MarkorNavigation.installed(privileged)
            ?: throw Fault("targetIdentityUnavailable")
        val actual = installed.first
        if (expected.packageName != BackgroundNavigationProtocol.PACKAGE || actual.uid != expected.uid ||
            actual.version != app.version || actual.updated != app.updated || actual.signers != app.signers)
            throw Fault("targetIdentityChanged")
        return installed.second
    }

    private fun navigationTree(automation: UiAutomation, expected: PhoneAppIdentity,
                               app: BackgroundNavigationProtocol.Installation): NavigationRead {
        val labels = navigationIdentity(expected, app)
        val read = NavigationRead()
        try {
            val tree = readTree(automation, displayId(), expected.packageName, inspectVisual = true, navigation = read)
            if (!tree.complete || tree.hasSecrets || tree.hasSensitive || read.nodes.isEmpty()) throw Fault("targetUnavailable")
            val window = tree.visualWindow ?: throw Fault("targetUnavailable")
            read.observation = com.skyjjgw.independent.ski.dshgo.phone.a11y.MarkorNavigation.inspect(listOf(read.window(window)), labels)
                ?: throw Fault("targetUnavailable")
            read.label = labels["nav_more"]?.takeIf { it.isNotBlank() && it.toByteArray(Charsets.UTF_8).size <= 1024 }
                ?: throw Fault("targetUnavailable")
            return read
        } catch (error: Throwable) { read.close(); throw error }
    }

    /** One original resource request, at most one NODE call, no tap/coordinate fallback. */
    private fun navigation(request: Bundle, response: Bundle, expected: PhoneAppIdentity) {
        val parsed = BackgroundNavigationProtocol.request(request.keySet(), request::get) ?: throw Fault("invalidArguments")
        val result = Bundle().apply {
            putInt("version", 1); putString("mode", if (parsed.execute) "execute" else "inspect")
            putBoolean("attempted", false); putString("post", "unknown")
        }
        response.putBundle(Proto.NAVIGATION, result)
        val vd = display ?: throw Fault("displayMissing")
        withTreeConnection(vd.display, expected.packageName, "treeUnavailable") { automation ->
            navigationTree(automation, expected, parsed.app).use { before ->
                val first = checkNotNull(before.observation)
                val wanted = parsed.expected
                if (wanted != null && (first.windowId != wanted.window || before.label != wanted.label ||
                    wanted.readOnly && first.selected != "nav_more" ||
                    first.selected != "nav_more" && first.selected != wanted.selected)) throw Fault("staleSnapshot")
                fun publish(read: NavigationRead, post: String) {
                    val observed = checkNotNull(read.observation)
                    if (observed.windowId != first.windowId || read.label != before.label) throw Fault("staleSnapshot")
                    navigationIdentity(expected, parsed.app) // Final identity gate before copying successful proof.
                    result.putInt("windowId", observed.windowId); result.putString("selected", observed.selected)
                    result.putString("targetLabel", read.label); result.putBoolean("targetClickable", observed.moreCanClick)
                    result.putLong("appVersion", parsed.app.version); result.putLong("appUpdated", parsed.app.updated)
                    result.putString("appSigningDigest", parsed.app.signers); result.putString("post", post)
                    response.putInt(Proto.TARGET_IDENTITY_VERSION, 1); response.putInt(Proto.TARGET_UID, expected.uid)
                    response.putString(Proto.PKG, expected.packageName)
                }
                if (!parsed.execute) { publish(before, "unknown"); return@use }
                if (first.selected == "nav_more") { publish(before, "satisfied"); return@use }
                if (!first.moreCanClick) throw Fault("inputRejected")
                val node = before.more ?: throw Fault("targetUnavailable")
                navigationIdentity(expected, parsed.app)
                result.putBoolean("attempted", true)
                val accepted = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                // False may be an in-flight timeout. No fallback/repeat, and no successful post proof.
                navigationTree(automation, expected, parsed.app).use { after ->
                    if (!accepted) throw Fault("inputRejected")
                    publish(after, if (after.observation?.selected == "nav_more") "satisfied" else "different")
                }
            }
        }
    }

    private fun tap(pkg: String, request: Bundle) {
        val e = resolveElement(pkg, request)
        val cx = (e.bounds.left + e.bounds.right) / 2
        val cy = (e.bounds.top + e.bounds.bottom) / 2
        val long = request.getBoolean(Proto.LONG)
        if (targetIdentity.verified) requireForeground(pkg)
        injectTap(cx, cy, long)
    }

    private fun scroll(pkg: String, request: Bundle) {
        val dir = request.getString(Proto.DIR) ?: "down"
        val bounds = if (request.containsKey(Proto.ELEMENT)) {
            val target = resolveElement(pkg, request)
            if (target.flags and Proto.FLAG_SCROLLABLE == 0) throw Fault("inputRejected")
            Rect(target.bounds).also {
                if (!it.intersect(0, 0, width, height)) throw Fault("inputRejected")
            }
        } else null
        val cx = bounds?.centerX() ?: (width / 2)
        val cy = bounds?.centerY() ?: (height / 2)
        val span = if (bounds == null) (if (dir == "left" || dir == "right") width else height) / 3 else
            (if (dir == "left" || dir == "right") bounds.width() else bounds.height()) / 3
        if (bounds != null && span < 1) throw Fault("inputRejected")
        val p = when (dir) {
            "up" -> intArrayOf(cx, cy - span, cx, cy + span)
            "down" -> intArrayOf(cx, cy + span, cx, cy - span)
            "left" -> intArrayOf(cx - span, cy, cx + span, cy)
            "right" -> intArrayOf(cx + span, cy, cx - span, cy)
            else -> throw Fault("invalidArguments")
        }
        val duration = 400
        if (bounds != null) {
            val vd = display ?: throw Fault("displayMissing")
            val displayContext = context.createDisplayContext(vd.display)
            val configured = displayContext.createConfigurationContext(displayContext.resources.configuration)
            val slop = ViewConfiguration.get(configured).scaledTouchSlop
            val steps = SwipeGeometry.steps(duration)
            val lastX = SwipeGeometry.coordinate(p[0], p[2], steps - 1, steps)
            val lastY = SwipeGeometry.coordinate(p[1], p[3], steps - 1, steps)
            if (maxOf(kotlin.math.abs(lastX - p[0]), kotlin.math.abs(lastY - p[1])) <= slop)
                throw Fault("inputRejected")
        }
        if (targetIdentity.verified) requireForeground(pkg)
        injectSwipe(p[0], p[1], p[2], p[3], duration)
    }

    private fun globalKey(key: String?) {
        val code = KEYS[key] ?: throw Fault("invalidArguments")
        val now = SystemClock.uptimeMillis()
        injectKey(KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0))
        sleepChecked(4)
        injectKey(KeyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0))
    }

    private fun typeText(pkg: String, request: Bundle, response: Bundle) {
        val text = request.get(Proto.TEXT) as? String ?: throw Fault("invalidArguments")
        val index = request.getInt(Proto.ELEMENT, -1)
        if (index < 1 || text.length > 500 || '\u0000' in text) throw Fault("invalidArguments")
        val vd = display ?: throw Fault("displayMissing")
        withTreeConnection(vd.display, pkg, "textConnectionUnavailable") { automation ->
            val node = readTree(automation, vd.display.displayId, pkg, index).target ?: throw Fault("elementMissing")
            try {
                if (!node.refresh()) throw Fault("textTargetChanged")
                val current = toElement(node, bestText(node), Rect(), 0)
                val expectRole = request.getString(Proto.EXPECT_ROLE)
                val expectLabel = request.getString(Proto.EXPECT_LABEL)
                val expectViewId = request.getString(Proto.EXPECT_VIEW_ID)
                if (expectRole != null && expectRole != current.role ||
                    expectLabel != null && expectLabel != current.label ||
                    expectViewId != null && expectViewId != current.viewId) throw Fault("staleSnapshot")
                if (isSecret(node) && !request.getBoolean(Proto.ALLOW_SECRET, false)) throw Fault("textRequiresManual")
                if (!node.isEditable || node.actionList.none { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT })
                    throw Fault("textUnsupported")
                if (targetIdentity.verified) requireForeground(pkg)
                val submit = request.getBoolean(Proto.SUBMIT)
                if (submit) {
                    if (!node.isFocused && !node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)) throw Fault("textFocusMissing")
                    if (!node.refresh() || !node.isFocused) throw Fault("textTargetChanged")
                }
                if (targetIdentity.verified) requireForeground(pkg)
                // type(id, text) replaces the entire value, regardless of the old selection.
                val accepted = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                })
                response.putBoolean(Proto.ACCEPTED, accepted)
                if (!accepted) throw Fault("inputRejected")
                val deadline = SystemClock.uptimeMillis() + 1500
                while (true) {
                    runCatching { invoke(automation, "clearCache") }
                    if (!node.refresh()) throw Fault("textTargetChanged")
                    val now = if (node.isShowingHintText) "" else node.text?.toString().orEmpty()
                    if (now == text) break
                    if (SystemClock.uptimeMillis() >= deadline) throw Fault("textReadbackMismatch")
                    sleepChecked(50)
                }
                response.putString(Proto.READBACK, BackgroundTree.cap(text))
                if (submit) {
                    if (!node.isFocused) throw Fault("textTargetChanged")
                    if (targetIdentity.verified) requireForeground(pkg)
                    globalKey("enter")
                }
            } finally { node.recycle() }
        }
    }

    // ---- injection shims (hidden APIs via reflection) ----------------------

    private fun injectTap(x: Int, y: Int, long: Boolean) {
        val down = SystemClock.uptimeMillis()
        sendMotion(MotionEvent.ACTION_DOWN, x, y, down)
        sleepChecked(if (long) 650 else 60)
        sendMotion(MotionEvent.ACTION_UP, x, y, down)
    }

    private fun injectSwipe(sx: Int, sy: Int, ex: Int, ey: Int, duration: Int) {
        val down = SystemClock.uptimeMillis()
        sendMotion(MotionEvent.ACTION_DOWN, sx, sy, down)
        val steps = SwipeGeometry.steps(duration)
        for (step in 1..steps) {
            sleepChecked((duration / steps).toLong())
            val mx = SwipeGeometry.coordinate(sx, ex, step, steps)
            val my = SwipeGeometry.coordinate(sy, ey, step, steps)
            if (step < steps) sendMotion(MotionEvent.ACTION_MOVE, mx, my, down)
        }
        sendMotion(MotionEvent.ACTION_UP, ex, ey, down)
    }

    private fun sendMotion(action: Int, x: Int, y: Int, downTime: Long, waitForFinish: Boolean = true) {
        val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, x.toFloat(), y.toFloat(), 0)
        event.source = InputDevice.SOURCE_TOUCHSCREEN
        try { inject(event, waitForFinish) } finally { event.recycle() }
    }

    private fun injectKey(src: KeyEvent) {
        val event = KeyEvent(src.downTime, src.eventTime, src.action, src.keyCode, 0, src.metaState,
            KeyCharacterMap.VIRTUAL_KEYBOARD, src.scanCode, src.flags, InputDevice.SOURCE_KEYBOARD)
        inject(event)
    }

    // Runs in the shell-uid privileged process (Shizuku UserService or app_process),
    // which the app hidden-API policy that lint models doesn't apply to.
    @SuppressLint("BlockedPrivateApi")
    private fun inject(event: InputEvent, waitForFinish: Boolean = true) {
        val id = display?.display?.displayId ?: throw Fault("displayMissing")
        // WAIT_FOR_FINISH can time out after the event was delivered. A false result is
        // not proof of rejection: never replay the same event with another mode.
        val accepted = try {
            InputEvent::class.java.getDeclaredMethod("setDisplayId", Int::class.javaPrimitiveType)
                .apply { isAccessible = true }.invoke(event, id)
            // Android 17 removed InputManager.getInstance(); the Context service works on every version.
            val manager = privileged.getSystemService(InputManager::class.java)
            InputManager::class.java.getMethod("injectInputEvent", InputEvent::class.java, Int::class.javaPrimitiveType)
                .invoke(manager, event, if (waitForFinish) 2 else 0) == true
        } catch (e: InvocationTargetException) {
            throw e.targetException // the system's own answer, e.g. SecurityException
        } catch (_: ReflectiveOperationException) {
            throw Fault("inputApiUnavailable") // the hidden API is missing or blocked here
        }
        // Only the gate uses ASYNC: its window receipt, not this boolean, decides delivery.
        if (waitForFinish && !accepted) throw Fault("inputRejected")
    }

    private fun setImePolicyHide(displayId: Int) {
        val sm = Class.forName("android.os.ServiceManager")
        val binder = sm.getMethod("getService", String::class.java).invoke(null, "window") as IBinder
        val wm = Class.forName("android.view.IWindowManager\$Stub")
            .getMethod("asInterface", IBinder::class.java).invoke(null, binder)
        // DISPLAY_IME_POLICY_HIDE == 2
        wm.javaClass.getMethod("setDisplayImePolicy", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
            .invoke(wm, displayId, 2)
    }

    /**
     * `pm grant` of WRITE_SECURE_SETTINGS to this app, through the binder `pm` itself uses:
     * IPackageManager up to Android 10, IPermissionManager from 11 (Android 15 added a device id
     * before the user). Fixed permission, fixed package.
     */
    @SuppressLint("PrivateApi")
    private fun grantSecureSettings(userId: Int) {
        val (service, type) = if (Build.VERSION.SDK_INT >= 30) "permissionmgr" to "android.permission.IPermissionManager"
            else "package" to "android.content.pm.IPackageManager"
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
            .invoke(null, service) as IBinder
        val manager = Class.forName("$type\$Stub").getMethod("asInterface", IBinder::class.java).invoke(null, binder)
        val grant = manager.javaClass.methods.first { it.name == "grantRuntimePermission" }
        val permission = SecureSettingsGrant.PERMISSION
        val args = when {
            grant.parameterTypes.size == 3 -> arrayOf<Any>(Proto.APP_PACKAGE, permission, userId)
            // VirtualDeviceManager.PERSISTENT_DEVICE_ID_DEFAULT, or Context.DEVICE_ID_DEFAULT.
            grant.parameterTypes[2] == String::class.java -> arrayOf<Any>(Proto.APP_PACKAGE, permission, "default:0", userId)
            else -> arrayOf<Any>(Proto.APP_PACKAGE, permission, 0, userId)
        }
        try {
            grant.invoke(manager, *args)
        } catch (e: InvocationTargetException) {
            throw e.targetException
        }
    }

    /** Fixed phase labels only: never pass screen content, app names, or task identifiers. */
    private inline fun <T> tracePhase(name: String, block: () -> T): T {
        Trace.beginSection(name)
        try { return block() } finally { Trace.endSection() }
    }

    private fun invoke(target: Any, method: String): Any? =
        UiAutomation::class.java.getMethod(method).invoke(target)

    private fun sleepChecked(ms: Long) {
        if (ms <= 0) return
        if (released.get()) throw Fault("cancelled")
        try { Thread.sleep(ms) } catch (_: InterruptedException) { throw Fault("cancelled") }
    }

    companion object {
        private val PACKAGE = Regex("[a-zA-Z][a-zA-Z0-9_]*(\\.[a-zA-Z0-9_]+)+")
        private val FLAG_NAMES = listOf(
            "PUBLIC", "OWN_CONTENT_ONLY", "SUPPORTS_TOUCH", "DESTROY_CONTENT_ON_REMOVAL",
            "TRUSTED", "OWN_FOCUS", "STEAL_TOP_FOCUS_DISABLED")
        private val KEYS = mapOf(
            "back" to KeyEvent.KEYCODE_BACK, "home" to KeyEvent.KEYCODE_HOME,
            "enter" to KeyEvent.KEYCODE_ENTER, "delete" to KeyEvent.KEYCODE_DEL,
            "tab" to KeyEvent.KEYCODE_TAB, "escape" to KeyEvent.KEYCODE_ESCAPE,
            "up" to KeyEvent.KEYCODE_DPAD_UP, "down" to KeyEvent.KEYCODE_DPAD_DOWN,
            "left" to KeyEvent.KEYCODE_DPAD_LEFT, "right" to KeyEvent.KEYCODE_DPAD_RIGHT)
    }
}

/** Live-tree node captured during a read; carries what the driver needs to build a TargetInfo. */
class BgNode(
    val role: String,
    val label: String,
    val states: List<String>,
    val flags: Int,
    val indent: Int,
    val bounds: android.graphics.Rect,
    val packageName: String?,
    val viewId: String? = null,
) {
    var region: Int = 1
}
