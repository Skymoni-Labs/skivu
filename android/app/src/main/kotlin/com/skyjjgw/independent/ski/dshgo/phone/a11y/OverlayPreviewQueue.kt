package com.skyjjgw.independent.ski.dshgo.phone.a11y

/** Main-thread decode ownership: one running image and only the newest waiting image. */
internal class OverlayPreviewQueue {
    class Ticket internal constructor(val epoch: Long, val bytes: ByteArray)
    private var epoch = 0L
    private var latest: ByteArray? = null
    private var running: Ticket? = null

    fun offer(bytes: ByteArray) { latest = bytes }

    fun start(): Ticket? {
        if (running != null) return null
        val bytes = latest ?: return null
        latest = null
        return Ticket(epoch, bytes).also { running = it }
    }

    fun clear() {
        epoch++
        latest = null
        // An old physical decode retains its slot until it actually completes.
    }

    fun finish(ticket: Ticket): Boolean {
        if (running !== ticket) return false
        running = null
        return ticket.epoch == epoch
    }
}
