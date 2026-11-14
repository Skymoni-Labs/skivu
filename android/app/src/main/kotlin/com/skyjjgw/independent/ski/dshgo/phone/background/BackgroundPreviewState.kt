package com.skyjjgw.independent.ski.dshgo.phone.background

/** In-memory preview ownership. No Android objects or agent observation identifiers live here. */
internal class BackgroundPreviewState {
    data class RawFrame(val width: Int, val height: Int, val pixels: ByteArray)
    data class Frame(val width: Int, val height: Int, val pixels: IntArray, val jpeg: ByteArray)
    data class Snapshot(val generation: Long, val sequence: Long, val state: String,
        val reason: String? = null, val frame: Frame? = null)
    class Ticket internal constructor(val readerEpoch: Long, val candidate: RawFrame?)

    private var enabled = false
    private var blocked = false
    private var readerEpoch = 0L
    private var generation = 0L
    private var sequence = 0L
    private var snapshot = Snapshot(0, 0, "off")
    private var pending: Ticket? = null
    private var candidate: RawFrame? = null
    private var lastStarted: Long? = null
    private var lastPublished: Long? = null

    @Synchronized fun snapshot(): Snapshot = snapshot
    @Synchronized fun acceptsCandidate(): Boolean = enabled && !blocked

    @Synchronized fun configure(value: Boolean) {
        if (enabled == value) return
        enabled = value
        invalidate()
    }

    /** New display/task, off/on, or release: retire both work and visible content. */
    @Synchronized fun invalidate() {
        readerEpoch++
        generation++
        candidate = null
        blocked = false
        update(if (enabled) "waiting" else "off")
        // Keep the physical in-flight slot until its worker exits, even after cancellation.
    }

    /** Same display, new reader: retire work, retaining the visible frame and deduplication baseline. */
    @Synchronized fun readerChanged() {
        readerEpoch++
        candidate = null
        blocked = false
    }

    /** An Agent capture found no usable frame; an earlier picture must not mask that outcome. */
    @Synchronized fun observationUnavailable(reason: String?) {
        if (!enabled) return
        readerEpoch++ // Capture can fail before readerChanged; a late encoder must not restore its old frame.
        candidate = null
        update(if (reason == null) "waiting" else "unavailable", reason)
    }

    /** The caller has already checked the observation's explicit secure-window result. */
    @Synchronized fun captured(raw: RawFrame) {
        if (enabled && !blocked) candidate = raw
    }

    @Synchronized fun protect() {
        if (!enabled || blocked) return
        readerEpoch++
        generation++
        candidate = null
        blocked = true
        update("protected")
    }

    @Synchronized fun begin(now: Long): Ticket? {
        if (!enabled || blocked || pending != null || lastStarted?.let { now - it < INTERVAL_MS } == true ||
            lastPublished?.let { now - it < INTERVAL_MS } == true) return null
        lastStarted = now
        return Ticket(readerEpoch, candidate).also { pending = it }
    }

    @Synchronized fun current(ticket: Ticket): Boolean = enabled && !blocked &&
        pending === ticket && ticket.readerEpoch == readerEpoch

    @Synchronized fun consumed(ticket: Ticket) {
        if (current(ticket)) candidate = null
    }

    @Synchronized fun changed(ticket: Ticket, pixels: IntArray, width: Int, height: Int): Boolean {
        if (!current(ticket)) return false
        val old = snapshot.frame
        return old == null || old.width != width || old.height != height || !old.pixels.contentEquals(pixels)
    }

    @Synchronized fun publish(ticket: Ticket, frame: Frame, now: Long) {
        if (current(ticket)) {
            lastPublished = now
            update("frame", frame = frame)
        }
    }

    @Synchronized fun unavailable(ticket: Ticket, reason: String) {
        if (current(ticket)) update("unavailable", reason)
    }

    @Synchronized fun finish(ticket: Ticket) {
        if (pending === ticket) pending = null
    }

    private fun update(state: String, reason: String? = null, frame: Frame? = null) {
        if (snapshot.generation == generation && snapshot.state == state &&
            snapshot.reason == reason && snapshot.frame === frame) return
        sequence++
        snapshot = Snapshot(generation, sequence, state, reason, frame)
    }

    companion object {
        const val INTERVAL_MS = 200L
        const val MAX_BYTES = 128 * 1024
    }
}
