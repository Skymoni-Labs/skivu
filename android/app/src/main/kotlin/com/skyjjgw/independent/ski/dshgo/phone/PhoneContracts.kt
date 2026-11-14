package com.skyjjgw.independent.ski.dshgo.phone

// The contract between the phone-control modules.
// Each module owns its side:
//
//   PhoneBridge (MCP over a unix socket) ── SafetyGate ──┬── main screen:  PhoneA11yService  (accessibility)
//                                                        └── background:   BackgroundDisplay (virtual display
//                                                                          via Shizuku or self-ADB)
//   UserGate: who asks the person (overlay on the main screen, heads-up notification otherwise).
//
// Everything here is plain Kotlin with blocking calls: the bridge runs every
// action on its own single worker thread (no coroutines in this app), and each
// call has a timeout of its own.

/** Which screen a snapshot or action belongs to; the prefix of every screen id. */
enum class PhoneScreen(val prefix: Char) {
    /** What the person sees, read and driven through the accessibility service. */
    MAIN('s'),

    /** 不打扰模式: a virtual display the person doesn't see. */
    BACKGROUND('b');

    companion object {
        /** `"s7"` → MAIN, `"b3"` → BACKGROUND, anything else → null. Never falls back across screens. */
        fun ofScreenId(id: String): PhoneScreen? = entries.firstOrNull { id.length > 1 && id[0] == it.prefix }
    }
}

/**
 * One observation of a screen, rendered for a text model: one line per element,
 * Chinese role words, element ids valid only for this snapshot's [id].
 */
data class ScreenSnapshot(
    /** e.g. `s7`: prefix + a counter that increases with every snapshot of that screen. */
    val id: String,
    /** The compact text form, header line included. Never contains password contents. */
    val text: String,
    /** Foreground app label and package, when known. */
    val appLabel: String?,
    val packageName: String?,
    /** The window refused capture (FLAG_SECURE) or the tree came back empty for a secure window. */
    val secure: Boolean = false,
    /** Fewer than five text nodes: games, canvases, some mini-programs. */
    val poorTree: Boolean = false,
    /** Optional numbered screenshot (same element ids drawn on it), PNG or JPEG bytes. */
    val image: ByteArray? = null,
    val imageMime: String? = null,
    /** Known root packages contributing to this local observation; not pixel/UID attestation. */
    internal val readPackages: Set<String> = emptySet(),
    /** Internal candidate for an INPUT retained in text; whole-screen refusals clear it. */
    internal val focus: FocusObservation? = null,
    /** Known packages in the image capture scope; independent of text and not pixel attestation. */
    internal val imageReadPackages: Set<String> = emptySet(),
)

/** What an element looks like to the safety rules, resolved from a snapshot id + element id. */
data class TargetInfo(
    val screenId: String,
    val elementId: Int,
    /** Chinese role word as rendered (按钮, 输入框, …). */
    val role: String,
    /** Visible text / content description / hint, already length-capped. */
    val label: String,
    val packageName: String?,
    val appLabel: String?,
    val isPassword: Boolean,
    /** Hint mentions 密码 / 验证码 / 支付密码 / CVV / 安全码. */
    val isSecretField: Boolean,
    val isEditable: Boolean,
    /**
     * Resource id (`com.tencent.mm:id/btn_send`), when known. Added by the core so the gate's
     * check `SensitiveWords.confirmHit(label, viewId)` is the same one the screen reader uses
     * for `⚠`: an icon-only send button whose id says "send" is marked AND confirmed.
     * When a driver leaves it null, only the label counts.
     */
    val viewId: String? = null,
)

sealed interface PhoneAction {
    val screenId: String

    data class Tap(override val screenId: String, val elementId: Int, val long: Boolean = false) : PhoneAction

    data class Type(
        override val screenId: String,
        val elementId: Int,
        val text: String,
        /** Press the IME action / Enter after typing. */
        val submit: Boolean = false,
    ) : PhoneAction

    data class Scroll(override val screenId: String, val elementId: Int?, val direction: Direction) : PhoneAction

    data class Key(override val screenId: String, val key: GlobalKey) : PhoneAction

    /** Flash only: a point on a numbered screenshot ([screenId] is the observation it came from). Unknown targets and long/swipe remain individually confirmed. */
    data class TapXY(override val screenId: String, val x: Int, val y: Int,
        val gesture: CoordinateGesture = CoordinateGesture.TAP,
        val x2: Int? = null, val y2: Int? = null, val durationMs: Long = 400) : PhoneAction

    enum class CoordinateGesture { TAP, LONG, SWIPE }

    enum class Direction { UP, DOWN, LEFT, RIGHT }

    enum class GlobalKey { BACK, HOME, RECENTS, NOTIFICATIONS }
}

data class ActionResult(
    val ok: Boolean,
    /** One short Chinese sentence for the model: what happened, or why not. */
    val message: String,
    /** The screen after the action settled (new lines marked `+`), when it could be read. */
    val screen: ScreenSnapshot? = null,
    /** Explicit fingerprint rejection before input. Refresh once; never replay the action. */
    val staleSnapshot: Boolean = false,
    /** Internal, this BG open only: the original peer confirmed its valid VD and full target identity. */
    val backgroundOpenConfirmed: Boolean = false,
    /** Same-call native navigation facts; never supplied by a tool argument or serialized. */
    internal val navigationWitness: com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillNavigationWitness? = null,
)

/** A definite refusal before collection starts; normal empty and partial results have none. */
enum class CollectRejection { UNAVAILABLE, INVALID_TARGET, READ_REFUSED }

data class CollectResult(
    /** De-duplicated items, one per line, in on-screen order. */
    val items: List<String>,
    val pages: Int,
    /** Stopped because: end of list / `until` matched / page limit / list lost. */
    val stopReason: String,
    val screen: ScreenSnapshot?,
    /** Union of known packages whose pages contributed items, independent of the last screen. */
    internal val readPackages: Set<String> = emptySet(),
    internal val rejection: CollectRejection? = null,
)

/** Whether a driver can work right now, and if not, a sentence the model can relay. */
data class Availability(val ok: Boolean, val reason: String? = null, val userReason: String? = null)

/**
 * A screen the agent can read and drive. Implemented by the accessibility service
 * (MAIN) and by the virtual-display module (BACKGROUND). All calls block and must
 * return within their own timeout (observe ≤ 5 s, actions ≤ 15 s incl. settling).
 */
interface PhoneDriver {
    val screen: PhoneScreen

    fun availability(): Availability

    fun observe(detail: Boolean, image: Boolean): ScreenSnapshot

    /** An omitted image argument may return an image only for this observation's poor tree.
     * Old drivers and explicit two-argument callers keep their original image behavior. */
    fun observe(detail: Boolean, image: Boolean, automaticImage: Boolean): ScreenSnapshot = observe(detail, image)

    /** Accepts only a driver-recorded candidate after the task's final screen filter, including
     * text-only visual observations. A missing candidate is a no-op; not model-delivery evidence. */
    fun acceptVisualObservation(screenId: String) {}

    fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?): CollectResult

    /** Multi-page implementations recheck this invocation's gate before each physical scroll. */
    fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?, allowed: () -> Boolean): CollectResult =
        if (allowed()) collect(screenId, listElementId, maxPages, until)
        else CollectResult(emptyList(), 0, PhoneTasks.STOPPED_MESSAGE, null)

    /** Local source gate. Legacy drivers retain their existing behavior without guessing a package. */
    fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?,
                allowed: () -> Boolean, canRead: (String?) -> Boolean): CollectResult =
        collect(screenId, listElementId, maxPages, until, allowed)

    /** Same-capture sources for a physical collect scroll, separate from the page's read source. */
    fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?,
                allowed: () -> Boolean, canRead: (String?) -> Boolean,
                scrollSourcesAllowed: (Set<String>) -> Boolean): CollectResult =
        collect(screenId, listElementId, maxPages, until, allowed, canRead)

    /**
     * Resolves an element of a recent snapshot for the safety rules. Null when the
     * snapshot is stale or the element no longer matches its fingerprint
     * (window, bounds, text); the bridge then refuses and re-observes.
     */
    fun target(screenId: String, elementId: Int): TargetInfo?

    /** Captures only the original committed observation's editor. */
    fun prepareFocusInput(screenId: String): Either<String, FocusInput> =
        Either.Left("当前屏幕不能核实原焦点输入连接；请 handoff，不要改用全文替换或重复输入。") // l10n:keep agent focus result
    /** Native reviewed-route operation; default drivers cannot execute it. */
    fun prepareSkillReplayStep(step: SkillReplayStep): Either<String, SkillReplayPlan> =
        Either.Left("当前屏幕不支持已核手机路线，未执行。") // l10n:keep agent replay result

    /** Pure memory, tied to this exact published observation; independent of image acceptance. */
    fun visualScope(screenId: String): VisualScope? = null

    /** Only native evidence from this observation may offer a reusable ordinary coordinate tap. */
    fun coordinateTarget(action: PhoneAction.TapXY): VisualTarget? = null

    fun perform(action: PhoneAction): ActionResult

    /** Invocation-owned pause/current check, separate from whichever task the overlay displays. */
    fun perform(action: PhoneAction, allowed: () -> Boolean): ActionResult =
        if (allowed()) perform(action) else ActionResult(false, PhoneTasks.STOPPED_MESSAGE)

    /** The claim is pure memory under the original task lock; dispatch happens after it returns. */
    fun perform(action: PhoneAction, allowed: () -> Boolean,
                coordinateAdmission: ((() -> Boolean) -> Boolean)?): ActionResult = perform(action, allowed)

    /** Actual action sources from the same capture; legacy drivers retain their old behavior. */
    fun perform(action: PhoneAction, allowed: () -> Boolean,
                coordinateAdmission: ((() -> Boolean) -> Boolean)?,
                actionSourcesAllowed: (Set<String>) -> Boolean): ActionResult =
        perform(action, allowed, coordinateAdmission)

    /** Launches the native-resolved [target] on this screen (BACKGROUND moves the task to the virtual display). */
    fun open(target: PhoneAppIdentity): ActionResult

    /** Original-call admission; asynchronous drivers recheck at their physical launch gate. */
    fun open(target: PhoneAppIdentity, allowed: () -> Boolean): ActionResult =
        if (allowed()) open(target) else ActionResult(false, PhoneTasks.STOPPED_MESSAGE)

    /** Package of the app in front on this screen, if known (for per-app approval and deny lists). */
    fun foregroundPackage(): String?
}

data class ConfirmRequest(
    /** The full plain sentence shown to the person, e.g. 在「微信」给 张三 发送："晚上见". */
    val sentence: String,
    val appLabel: String?,
    val packageName: String?,
    /** First action in this app during this task: approval covers the rest of the task. */
    val firstInApp: Boolean,
    val timeoutMs: Long = 30_000,
    /**
     * 本任务免确认: offer [Decision.ALLOW_ALL_FOR_TASK] as the main choice (see ConfirmMode); a
     * gate that ignores it still answers correctly, just asks more.
     */
    val offerTaskWaiver: Boolean = false,
    /** Exact native task lifetime; never inferred from the visible conversation. */
    val owner: PhoneTasks.Owner? = null,
    val visualScope: VisualScope? = null,
)

/** Ordinary task waivers do not authorize independent visual scopes or bypass hard rules. */
enum class Decision { ALLOW_ONCE, ALLOW_APP_FOR_TASK, ALLOW_ALL_FOR_TASK, ALLOW_VISUAL_FOR_TASK, DENY, STOP, UNAVAILABLE }

enum class HandoffResult { CONTINUE, STOP, TIMEOUT }

/**
 * Why a `handoff` came: the hard rule that refused the task's last write, when there was one.
 * The card names it in its title (「密码需要你来输入」) so the person knows it is a rule, not a
 * fault; the model's own sentence stays the body. Null: the model handed off on its own.
 */
enum class HandoffCause(val rule: String) {
    /** A password, verification-code or payment-code input. */
    SECRET("secret-field"),

    /** System settings, permissions, installers, security centres, SystemUI. */
    SYSTEM("system-page"),

    /** An app on the person's 不碰 list. */
    DENY_LIST("deny-list");

    companion object {
        /** From an action-log decision (`refused:<rule>`); null for anything else. */
        fun ofDecision(decision: String?): HandoffCause? {
            if (decision == null || !decision.startsWith("refused:")) return null
            val rule = decision.removePrefix("refused:")
            return entries.firstOrNull { it.rule == rule }
        }
    }
}

/**
 * Asks the person. The main-screen implementation is the accessibility overlay
 * (ControlOverlay); without it, a heads-up notification. Confirm buttons must not be
 * reachable by injected input.
 */
interface UserGate {
    fun confirm(request: ConfirmRequest): Decision

    /** Blocks until the person taps 继续 / 停止, up to [timeoutMs] (≤ 10 min). */
    fun handoff(reason: String, timeoutMs: Long): HandoffResult

    /** [handoff] with the rule behind it, for the card's title; gates that can't show it ignore it. */
    fun handoff(reason: String, timeoutMs: Long, cause: HandoffCause?): HandoffResult = handoff(reason, timeoutMs)

    fun handoff(reason: String, timeoutMs: Long, cause: HandoffCause?, owner: PhoneTasks.Owner): HandoffResult =
        handoff(reason, timeoutMs, cause)

    /** The one-line "DSH 正在操作 · 点「路线」" status; null clears it. */
    fun status(text: String?)

    /** Owner gate: only short memory writes belong inside [ifCurrent], never platform IO.
     * Asynchronous presenters must recheck at their final UI runnable, before applying it. */
    fun status(text: String?, ifCurrent: (() -> Unit) -> Boolean) {
        if (ifCurrent {}) status(text)
    }
    /** Retire only the task status, preserving independently owned prompt tickets. */
    fun clearStatus(ifCurrent: (() -> Unit) -> Unit) = ifCurrent { status(null) }

    /** Run [ifCurrent] at cleanup time; a newer task must keep its windows and pending questions. */
    fun close(ifCurrent: (() -> Unit) -> Unit = { it() }) = ifCurrent { status(null) }
}

/**
 * The status bar's 暂停 / 停止 / 插话 for the one task whose status they are shown with. Each acts
 * on that task's owner only: once it stopped, ended or was replaced, an action does nothing, and
 * it never reaches a task selected later. Main thread; must return quickly.
 */
interface TaskControls {
    val taskId: Long
    val lifecycle: Long

    /** Keeps an already displayed status through consecutive executions of this owner.
     * Never admits a new status; callers without native selection retain their execution guard. */
    fun isCurrentDisplay(): Boolean = false

    fun isPaused(): Boolean

    /** 暂停 (true) / 继续 (false). While paused, MAIN actions are refused by the driver as well. */
    fun setPaused(paused: Boolean): Boolean

    /** [reason] is Chinese (for the agent). */
    fun stop(reason: String): Boolean

    /** Text the person typed into 插话 and sent; meant for the agent as a user message. */
    fun interject(text: String): Boolean
}

/**
 * The overlay's way to its task's controls, and the stops the accessibility service itself
 * sees. Implemented by the core (task owner), set in [PhoneRegistry.controlListener].
 * Called on the main thread; must return quickly.
 */
interface ControlListener {
    /** Called only inside a displayed status's own guard: the controls of the task it belongs to. */
    fun shownControls(): TaskControls? = null

    /** Device-wide boundary: screen off, lock, or loss of the accessibility service. [reason] is Chinese. */
    fun onStopAllRequested(reason: String, source: PhoneTasks.StopSource = PhoneTasks.StopSource.ENVIRONMENT) {}

    /** The accessibility service connected or went away (for the `status` event). */
    fun onAccessibilityChanged(connected: Boolean) {}
}

/**
 * Where the modules meet at run time. Services register themselves when they
 * connect and clear on disconnect; the bridge reads these on every call.
 */
object PhoneRegistry {
    @Volatile var mainDriver: PhoneDriver? = null

    /** Overlay gate when the accessibility service runs, else the notification gate. */
    @Volatile var overlayGate: UserGate? = null
    @Volatile var notificationGate: UserGate? = null

    /** Process-wide arbiter for native and engine questions; presenters do not call one another. */
    @Volatile var promptGate: UserGate? = null

    /** Set by the core; see [ControlListener]. */
    @Volatile var controlListener: ControlListener? = null

    /**
     * The hard rules the person lifted (解除限制), for the drivers' own second line of refusals and
     * the overlay's 「已解除限制」 tag. Nothing lifted until the core says otherwise.
     */
    @Volatile var unlocks: () -> PhoneUnlocks = { PhoneUnlocks() }

    fun gate(): UserGate? = overlayGate ?: notificationGate
}

/** Optional native UI copy for pure phone-control code. */
fun interface PhoneUiText {
    fun resolve(key: String, args: List<Any>): String?

    fun get(key: String, fallback: String, vararg args: Any): String =
        resolve(key, args.toList()) ?: String.format(java.util.Locale.ROOT, fallback, *args)

    fun role(value: String): String = when (value) {
        "按钮" -> get("phone_role_button", value) // l10n:keep model role key
        "输入框" -> get("phone_role_input", value) // l10n:keep model role key
        "列表" -> get("phone_role_list", value) // l10n:keep model role key
        "开关" -> get("phone_role_switch", value) // l10n:keep model role key
        "勾选框" -> get("phone_role_checkbox", value) // l10n:keep model role key
        "单选" -> get("phone_role_radio", value) // l10n:keep model role key
        "滑块" -> get("phone_role_slider", value) // l10n:keep model role key
        "下拉框" -> get("phone_role_dropdown", value) // l10n:keep model role key
        "链接" -> get("phone_role_link", value) // l10n:keep model role key
        "标签" -> get("phone_role_tab", value) // l10n:keep model role key
        "图片" -> get("phone_role_image", value) // l10n:keep model role key
        "文本" -> get("phone_role_text", value) // l10n:keep model role key
        else -> value
    }

    companion object {
        val DEFAULT = PhoneUiText { _, _ -> null }
    }
}
