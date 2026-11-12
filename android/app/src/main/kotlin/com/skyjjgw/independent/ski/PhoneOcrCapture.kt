package com.skyjjgw.independent.ski

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

internal data class PhoneOcrFrame(val bitmap: Bitmap, val pkg: String, val window: Int,
    val rotation: Int, val epoch: Long, val capturedAt: Long, val forbidden: Boolean) : AutoCloseable {
    override fun close() { if (!bitmap.isRecycled) bitmap.recycle() }
}

internal fun <T> visionUi(block: () -> T): T {
    if (Looper.myLooper() == Looper.getMainLooper()) return block()
    val task = java.util.concurrent.FutureTask(block)
    Handler(Looper.getMainLooper()).post(task)
    return try { task.get() } catch(e:java.util.concurrent.ExecutionException){throw(e.cause as? Exception?:e)}
}

/** Poll cancellation without blocking the Android main looper or retaining late bitmaps. */
internal fun <T> visionAwait(future: CompletableFuture<T>, check: () -> Unit): T {
    require(Looper.myLooper() != Looper.getMainLooper()) { "屏幕识别必须在工作线程执行。" }
    val deadline = SystemClock.uptimeMillis() + 15000
    try {
        while (true) {
            check()
            require(SystemClock.uptimeMillis() < deadline) { "本地屏幕识别等待超时。" }
            try { return future.get(50, TimeUnit.MILLISECONDS) }
            catch (_: TimeoutException) { }
            catch(e:java.util.concurrent.ExecutionException){throw(e.cause as? Exception?:e)}
        }
    } catch (e: Exception) { future.cancel(false); throw e }
}
