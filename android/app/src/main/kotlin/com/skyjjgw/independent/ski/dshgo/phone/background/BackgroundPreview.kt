package com.skyjjgw.independent.ski.dshgo.phone.background

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Immutable publication; reading it never enters BackgroundControl's IPC-owning monitor. */
data class BackgroundPreviewTarget(
    val taskId: Long,
    val owner: String,
    val channel: PrivilegedChannel,
    val driver: BackgroundDisplay,
)

/** Local-only pixels. Main-thread consumers share one low-priority, non-cancellable IPC lane. */
class BackgroundPreview(
    context: Context,
    private val target: (Long) -> BackgroundPreviewTarget?,
    private val allowed: (Long) -> Boolean,
    private val onSettingChanged: () -> Unit,
) {
    enum class ConsumerKind { APP_DIALOG, OVERLAY }
    internal enum class DeliveryRole { SELECTED, IN_USE, OFF }
    internal class Consumer(val taskId: Long, val kind: ConsumerKind, val callback: (Map<String, Any?>) -> Unit) {
        var role: DeliveryRole? = null
    }
    private val main = Handler(Looper.getMainLooper())
    private val prefs = context.getSharedPreferences("phone-background-preview", Context.MODE_PRIVATE)
    @Volatile var enabled = prefs.getBoolean("enabled", false)
        private set
    private val consumers = LinkedHashMap<Any, Consumer>()
    private var selectedTaskId: Long? = null // Selection survives a not-yet-ready target.
    private var current: BackgroundPreviewTarget? = null
    private var unsupported: BackgroundPreviewTarget? = null
    private val delivery = BackgroundPreviewDelivery()
    @Volatile private var requestToken = Any()
    private var worker: ExecutorService? = null
    private var busy = false
    private val pendingOff = LinkedHashSet<BackgroundPreviewTarget>()
    private var cleanupBusy = false
    private var cleanupScheduled = false
    private var probed: BackgroundPreviewTarget? = null // Accessed only on the serial worker.
    private var supported = false
    private var scheduled = false
    private var lastPollAt: Long? = null
    private val tick = Runnable { scheduled = false; poll() }
    private val cleanupTick = Runnable { cleanupScheduled = false; drainOff() }

    fun setEnabled(value: Boolean): Boolean {
        checkMain()
        if (enabled != value) {
            enabled = value
            prefs.edit().putBoolean("enabled", value).apply()
            reconcile()
            onSettingChanged()
        }
        return true
    }

    fun addConsumer(owner: Any, taskId: Long, kind: ConsumerKind, onFrame: (Map<String, Any?>) -> Unit) {
        checkMain()
        val consumer = Consumer(taskId, kind, onFrame)
        consumers[owner] = consumer
        reconcile()
    }

    fun removeConsumer(owner: Any) {
        checkMain()
        consumers.remove(owner)
        reconcile()
    }

    /** Cross-thread callbacks only post to main; no privileged IPC or BackgroundControl monitor here. */
    fun refresh() {
        if (Looper.myLooper() == Looper.getMainLooper()) reconcile() else main.post { reconcile() }
    }

    private fun checkMain() = check(Looper.myLooper() == Looper.getMainLooper())

    private fun publishInitial(consumer: Consumer, force: Boolean) {
        val role = when {
            !enabled || !allowed(consumer.taskId) -> DeliveryRole.OFF
            consumer.taskId == selectedTaskId -> DeliveryRole.SELECTED
            selectedTaskId != null -> DeliveryRole.IN_USE
            else -> DeliveryRole.OFF
        }
        if (!force && consumer.role == role) return
        consumer.role = role
        val value = if (role == DeliveryRole.SELECTED) delivery.initial(consumer.taskId)
            else delivery.placeholder(consumer.taskId, role == DeliveryRole.IN_USE)
        runCatching { consumer.callback(value) }
    }

    private fun reconcile() {
        val selected = if (enabled) choosePreviewTask(consumers.values.filter { allowed(it.taskId) }, selectedTaskId) else null
        val next = selected?.let(target)
        val changed = selected != selectedTaskId || next !== current
        if (changed) {
            val old = current
            selectedTaskId = selected
            current = next
            unsupported = null
            delivery.reset(selected)
            requestToken = Any()
            main.removeCallbacks(tick)
            scheduled = false
            if (old != null) disable(old)
        }
        // A losing task can end while the selected source stays unchanged: it still needs OFF.
        consumers.values.toList().forEach { publishInitial(it, changed) }
        schedule()
        retireIdleWorker()
    }

    private fun schedule() {
        if (current == null || current === unsupported || busy || scheduled || pendingOff.isNotEmpty()) return
        scheduled = true
        val wait = lastPollAt?.let { (it + 200 - SystemClock.uptimeMillis()).coerceAtLeast(0) } ?: 0
        main.postDelayed(tick, wait)
    }

    private fun io(): ExecutorService = worker ?: Executors.newSingleThreadExecutor { job ->
        Thread(job, "dsh-preview-client").apply { isDaemon = true }
    }.also { worker = it }

    private fun disable(old: BackgroundPreviewTarget) {
        pendingOff.add(old)
        scheduleOff(0)
    }

    private fun scheduleOff(delayMs: Long = 200) {
        if (pendingOff.isEmpty() || cleanupBusy || cleanupScheduled) return
        cleanupScheduled = true
        main.postDelayed(cleanupTick, delayMs)
    }

    private fun drainOff() {
        val old = pendingOff.firstOrNull() ?: return
        cleanupBusy = true
        io().execute {
            // Busy is not an ACK. Keep this off barrier so a quick off/on cannot overtake it.
            // A sealed driver delegates physical preview cleanup to its strict release on this lane.
            val done = old.driver.previewClosed() || runCatching {
                old.driver.tryPreview(request(old, false))?.get(Proto.OK) == true
            }.getOrDefault(false)
            if (probed === old) { probed = null; supported = false }
            main.post {
                cleanupBusy = false
                if (done || old.driver.previewClosed()) pendingOff.remove(old)
                scheduleOff()
                schedule()
                retireIdleWorker()
            }
        }
    }

    private fun retireIdleWorker() {
        if (current == null && !busy && !cleanupBusy && pendingOff.isEmpty()) {
            worker?.shutdown()
            worker = null
        }
    }

    private fun request(t: BackgroundPreviewTarget, value: Boolean, after: Long = -1) = Bundle().apply {
        putString(Proto.OP, Proto.OP_PREVIEW)
        putString(Proto.OWNER, t.owner)
        putBoolean(Proto.PREVIEW_ENABLED, value)
        putLong(Proto.PREVIEW_AFTER_SEQUENCE, after)
    }

    private fun poll() {
        val selected = current ?: return
        if (busy || pendingOff.isNotEmpty()) return
        if (target(selected.taskId) !== selected || !allowed(selected.taskId)) { reconcile(); return }
        val ticket = delivery.generation
        val token = requestToken
        val after = delivery.afterSequence
        busy = true
        lastPollAt = SystemClock.uptimeMillis()
        io().execute {
            fun wanted() = requestToken === token && target(selected.taskId) === selected && allowed(selected.taskId)
            val result = runCatching {
                if (!wanted()) return@runCatching null
                if (probed !== selected) {
                    val probe = selected.driver.tryPreview(Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) })
                        ?: return@runCatching null
                    supported = probe.getBoolean(Proto.OK) && probe.getInt(Proto.PREVIEW_VERSION) == 1
                    probed = selected
                }
                if (!wanted()) return@runCatching null
                if (!supported) Bundle().apply { putBoolean(Proto.OK, false); putString(Proto.PREVIEW_REASON, "unsupported") }
                else selected.driver.tryPreview(request(selected, true, after))
            }.getOrElse { Bundle().apply { putBoolean(Proto.OK, false) } }
            main.post {
                busy = false
                if (current === selected && delivery.generation == ticket && target(selected.taskId) === selected && allowed(selected.taskId)) {
                    if (result != null) accept(selected, result)
                    schedule()
                } else reconcile()
                retireIdleWorker()
            }
        }
    }

    private fun accept(selected: BackgroundPreviewTarget, reply: Bundle) {
        val value = if (!reply.getBoolean(Proto.OK)) {
            if (reply.getString(Proto.PREVIEW_REASON) == "unsupported") unsupported = selected
            delivery.failure()
        } else delivery.accept(
            reply.getString(Proto.PREVIEW_STATE) ?: "unavailable",
            reply.getLong(Proto.PREVIEW_SEQUENCE),
            reply.getInt(Proto.PREVIEW_WIDTH), reply.getInt(Proto.PREVIEW_HEIGHT),
            reply.getByteArray(Proto.PREVIEW_BYTES),
        )
        if (value != null) consumers.values.filter { it.taskId == selected.taskId }
            .forEach { runCatching { it.callback(value) } }
    }
}

/** Actual controller selection: visibility/allowed filtering happens before this call, not readiness.
 * Same-task consumers share the selection; no JPEG or second consumer registry lives here.
 */
internal fun choosePreviewTask(consumers: List<BackgroundPreview.Consumer>, current: Long?): Long? {
    val app = consumers.filter { it.kind == BackgroundPreview.ConsumerKind.APP_DIALOG }
    val highest = app.ifEmpty { consumers }
    return highest.firstOrNull { it.taskId == current }?.taskId ?: highest.firstOrNull()?.taskId
}
