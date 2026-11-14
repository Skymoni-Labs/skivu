package com.skyjjgw.independent.ski.dshgo.phone

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.skyjjgw.independent.ski.MainActivity

/** One asynchronous UI coordinator for native SafetyGate and structured engine requests. */
class PhonePrompts(
    private val app: Context,
    private val tasks: PhoneTasks,
    private val enabled: () -> Boolean,
    private val locked: () -> Boolean,
    private val notifications: NotificationGate,
    private val reopen: (String?, String?) -> Boolean,
    private val displaySelection: PhoneDisplaySelection,
    private val resolveTask: (Long, String?) -> PhoneTasks? = { id, _ -> tasks.takeIf { it.snapshot().id == id } },
) : UserGate {
    private val main = Handler(Looper.getMainLooper())
    private val arbiter = PromptArbiter(SystemClock::elapsedRealtime)
    private var activityOwner: Any? = null
    private var activity: Activity? = null
    private var display: Pair<PromptTicket, () -> Unit>? = null

    fun attachActivity(owner: Any, next: Activity?) {
        if (next == null && activityOwner !== owner) return
        if (activity !== next && arbiter.current()?.let { it.presentationSurfaceIsApp() } == true) {
            arbiter.current()?.stop("stale")
        }
        activityOwner = if (next == null) null else owner
        activity = next
    }

    fun appResumed(): Boolean = activity?.let { !it.isFinishing && !it.isDestroyed && AppVisibility.isResumed(it) } == true

    fun present(request: EnginePhonePrompt, owner: Any, sourceCurrent: () -> Boolean = { true },
                reply: (Map<String, Any?>) -> Unit) {
        if (!enabled()) { reply(unavailable("disabled")); return }
        val bound = request.taskId?.let { resolveTask(it, request.sessionId) } ?: if (request.taskId == null) tasks else null
        if (bound == null) { reply(unavailable("stale")); return }
        val taskOwner = if (request.taskId == null) bound.beforeTaskOwner() else bound.activeOwner(request.taskId)
        if (taskOwner == null || locked()) { reply(unavailable("stale")); return }
        val ticket = arbiter.begin(request.requestId, owner,
            PromptContent(request.kind, request.text, sessionId = request.sessionId, host = request.host), 30_000,
            { sourceCurrent() && enabled() && !locked() && bound.isCurrent(taskOwner) })
        if (ticket == null) { reply(unavailable("busy")); return }
        ticket.onFinished {
            onMain {
                val result = ticket.finalResult()
                // OPEN is a choice plus a navigation attempt, not proof of OS visibility.
                // Dispatch the exact route before replying: Dart may immediately cancel
                // its completed request in finally, and that must not erase a valid OPEN.
                if (result.outcome == PromptOutcome.OPEN) reopen(request.sessionId, request.host)
                reply(result.toMap())
            }
        }
        schedule(ticket)
    }

    fun cancel(requestId: String) = arbiter.cancel(requestId)
    fun detachOwner(owner: Any) { arbiter.cancelOwner(owner); attachActivity(owner, null) }
    fun stopAll() = arbiter.stopAll()
    fun check() = arbiter.check()

    override fun confirm(request: ConfirmRequest): Decision = confirmFor(tasks, null, request)

    private fun confirmFor(task: PhoneTasks, sessionId: String?, request: ConfirmRequest): Decision {
        if (Looper.myLooper() == Looper.getMainLooper()) return Decision.UNAVAILABLE
        val taskOwner = request.owner ?: task.activeOwner() ?: return Decision.STOP
        if (!task.isCurrent(taskOwner)) return Decision.STOP
        val shown = if (sessionId == null) request else request.copy(sentence = "[$sessionId]\n${request.sentence}")
        val ticket = arbiter.begin(null, task,
            PromptContent(PromptKind.NATIVE_CONFIRM, shown.sentence.take(4096), shown, sessionId = sessionId), request.timeoutMs.coerceIn(1, 30_000),
            { enabled() && !locked() && task.isCurrent(taskOwner) }) ?: return Decision.UNAVAILABLE
        schedule(ticket)
        val result = ticket.await()
        // Revocation/lock is not a user STOP. Reuse the worker interruption path.
        if (result.outcome == PromptOutcome.STOPPED && result.reason != null) throw InterruptedException()
        return when (result.outcome) {
            PromptOutcome.ALLOW_ONCE -> Decision.ALLOW_ONCE
            PromptOutcome.ALLOW_APP -> Decision.ALLOW_APP_FOR_TASK
            PromptOutcome.ALLOW_TASK -> Decision.ALLOW_ALL_FOR_TASK
            PromptOutcome.ALLOW_VISUAL -> Decision.ALLOW_VISUAL_FOR_TASK
            PromptOutcome.STOPPED -> Decision.STOP
            PromptOutcome.UNAVAILABLE -> Decision.UNAVAILABLE
            else -> Decision.DENY
        }
    }

    override fun handoff(reason: String, timeoutMs: Long): HandoffResult = handoff(reason, timeoutMs, null)

    override fun handoff(reason: String, timeoutMs: Long, cause: HandoffCause?): HandoffResult =
        handoffFor(tasks, null, reason, timeoutMs, cause, tasks.activeOwner())

    override fun handoff(reason: String, timeoutMs: Long, cause: HandoffCause?, owner: PhoneTasks.Owner): HandoffResult =
        handoffFor(tasks, null, reason, timeoutMs, cause, owner)

    private fun handoffFor(task: PhoneTasks, sessionId: String?, reason: String, timeoutMs: Long, cause: HandoffCause?, owner: PhoneTasks.Owner?): HandoffResult {
        if (Looper.myLooper() == Looper.getMainLooper()) return HandoffResult.STOP
        val taskOwner = owner ?: return HandoffResult.STOP
        if (!task.isCurrent(taskOwner)) return HandoffResult.STOP
        val ticket = arbiter.begin(null, task, PromptContent(PromptKind.HANDOFF, (if (sessionId == null) reason else "[$sessionId]\n$reason").take(4096), cause = cause, sessionId = sessionId),
            timeoutMs.coerceIn(1, 600_000), { enabled() && !locked() && task.isCurrent(taskOwner) }) ?: return HandoffResult.STOP
        schedule(ticket)
        val result = ticket.await()
        // Revocation/lock is not a user STOP. Reuse the worker interruption path.
        if (result.outcome == PromptOutcome.STOPPED && result.reason != null) throw InterruptedException()
        return when (result.outcome) {
            PromptOutcome.CONTINUE -> HandoffResult.CONTINUE
            PromptOutcome.TIMEOUT -> HandoffResult.TIMEOUT
            else -> HandoffResult.STOP
        }
    }

    /** One UI arbiter, but every native ticket retains its own task and conversation. */
    fun scoped(task: PhoneTasks, sessionId: String?): UserGate = object : UserGate {
        override fun confirm(request: ConfirmRequest): Decision = confirmFor(task, sessionId, request)
        override fun handoff(reason: String, timeoutMs: Long): HandoffResult =
            handoffFor(task, sessionId, reason, timeoutMs, null, task.activeOwner())
        override fun handoff(reason: String, timeoutMs: Long, cause: HandoffCause?, owner: PhoneTasks.Owner): HandoffResult =
            handoffFor(task, sessionId, reason, timeoutMs, cause, owner)
        override fun status(text: String?) = status(text, displaySelection.currentGuard(task))
        override fun status(text: String?, ifCurrent: (() -> Unit) -> Boolean) =
            publishStatus(text, displaySelection.scoped(task, ifCurrent))
        override fun close(ifCurrent: (() -> Unit) -> Unit) = closeTask(task, ifCurrent)
    }

    fun stopTask(task: PhoneTasks) = arbiter.cancelOwner(task)

    override fun status(text: String?) = status(text, displaySelection.currentGuard(tasks))

    override fun status(text: String?, ifCurrent: (() -> Unit) -> Boolean) =
        publishStatus(text, displaySelection.scoped(tasks, ifCurrent))

    private fun publishStatus(text: String?, ifCurrent: (() -> Unit) -> Boolean) {
        notifications.status(text, ifCurrent)
        PhoneRegistry.overlayGate?.status(text, ifCurrent)
    }

    override fun close(ifCurrent: (() -> Unit) -> Unit) = closeTask(tasks, ifCurrent)

    private fun closeTask(task: PhoneTasks, ifCurrent: (() -> Unit) -> Unit) {
        val captured = arbiter.current()?.takeIf { it.owner === task }
        onMain {
            var accepted = false
            ifCurrent { accepted = true }
            // A ticket, not a reusable task reference; callbacks/UI run outside the task lock.
            if (accepted) captured?.stop()
        }
    }

    private fun schedule(ticket: PromptTicket) {
        val tick = object : Runnable {
            override fun run() {
                if (!ticket.live) return
                main.postDelayed(this, minOf(250, ticket.remainingMs).coerceAtLeast(1))
            }
        }
        ticket.onFinished {
            onMain {
                main.removeCallbacks(tick)
                if (display?.first === ticket) clearDisplay()
            }
        }
        onMain {
            if (!ticket.live) return@onMain
            tick.run()
            val overlay = PhoneRegistry.overlayGate as? PhonePromptPresenter
            if (overlay != null && show(ticket, PromptSurface.OVERLAY, overlay::showPrompt)) return@onMain
            if (show(ticket, PromptSurface.NOTIFICATION, notifications::showPrompt)) return@onMain
            showApp(ticket)
        }
    }

    private fun show(ticket: PromptTicket, surface: PromptSurface, presenter: (PromptPresentation) -> (() -> Unit)?): Boolean {
        if (!ticket.live) return false
        clearDisplay()
        val p = ticket.attempt(surface) ?: return false
        val handle = runCatching { presenter(p) }.getOrNull()
        if (handle == null) { p.retire(); return false }
        if (!p.live) { handle(); return false }
        display = ticket to handle
        notifications.showWaiting(p)
        return true
    }

    private fun showApp(ticket: PromptTicket, alreadyLaunching: Boolean = false) {
        if (!ticket.live) return
        val host = activity
        if (host != null && appResumed()) {
            if (!show(ticket, PromptSurface.APP) { PhonePromptUi.showDialog(host, it) }) ticket.unavailable()
            return
        }
        if (!alreadyLaunching && !reopen(ticket.content.sessionId, ticket.content.host)) {
            ticket.unavailable(); return
        }
        val deadline = minOf(ticket.deadline, SystemClock.elapsedRealtime() + 3_000)
        val wait = object : Runnable {
            override fun run() {
                if (!ticket.live) return
                val next = activity
                if (next != null && appResumed()) {
                    if (!show(ticket, PromptSurface.APP) { PhonePromptUi.showDialog(next, it) }) ticket.unavailable()
                } else if (SystemClock.elapsedRealtime() >= deadline) ticket.unavailable()
                else main.postDelayed(this, 100)
            }
        }
        ticket.onFinished { main.removeCallbacks(wait) }
        main.postDelayed(wait, 100)
    }

    /** Activity PendingIntent, not a receiver/service launching an Activity on a notification tap. */
    fun handleOpenIntent(intent: Intent): Boolean {
        if (intent.action != ACTION_OPEN) return false
        val nonce = intent.getStringExtra(EXTRA_NONCE) ?: return true
        val ticket = arbiter.current() ?: return true
        val p = ticket.presentation(nonce) ?: return true
        if (!p.live || !p.shown) return true
        if (ticket.content.kind == PromptKind.REVIEW) p.choose(PromptChoice.OPEN)
        else {
            p.retire()
            clearDisplay()
            showApp(ticket, alreadyLaunching = true)
        }
        return true
    }

    private fun clearDisplay() {
        val old = display
        display = null
        old?.second?.let { runCatching { it() } }
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    private fun PromptTicket.presentationSurfaceIsApp(): Boolean = display?.let { (t, _) ->
        t === this && finalPresentationSurface() == PromptSurface.APP
    } == true

    companion object {
        private const val ACTION_OPEN = "com.skyjjgw.independent.ski.dshgo.phone.OPEN_PROMPT"
        private const val EXTRA_NONCE = "phone_prompt_nonce"
        fun unavailable(reason: String) = PromptResult(PromptOutcome.UNAVAILABLE, PromptSurface.NONE, reason).toMap()
        fun openIntent(app: Context, p: PromptPresentation): Intent = Intent(app, MainActivity::class.java)
            .setAction(ACTION_OPEN).setData(Uri.parse("dsh-phone-prompt://request/${p.nonce}"))
            .putExtra(EXTRA_NONCE, p.nonce)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    }
}
