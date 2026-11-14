package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** JPEG work never runs on the UI thread; only an attached view receives the accepted Bitmap. */
internal class OverlayPreviewDecoder(private val present: (Bitmap?) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val queue = OverlayPreviewQueue()
    private var worker: ExecutorService? = null

    fun offer(bytes: ByteArray) {
        queue.offer(bytes)
        start()
    }

    fun clear() {
        queue.clear()
        worker?.shutdown() // Let an already-started decoder release its output normally.
        worker = null
    }

    private fun start() {
        val ticket = queue.start() ?: return
        val executor = worker ?: Executors.newSingleThreadExecutor { job ->
            Thread(job, "dsh-overlay-preview").apply { isDaemon = true }
        }.also { worker = it }
        executor.execute {
            val bitmap = runCatching { BitmapFactory.decodeByteArray(ticket.bytes, 0, ticket.bytes.size) }.getOrNull()
            main.post {
                if (queue.finish(ticket)) present(bitmap) else bitmap?.recycle()
                start()
            }
        }
    }
}
