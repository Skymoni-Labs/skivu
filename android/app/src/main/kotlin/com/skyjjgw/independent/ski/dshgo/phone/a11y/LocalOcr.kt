package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.graphics.Bitmap

/** Borrows the existing screenshot synchronously. Never retain/recycle it or publish a late callback.
 * An asynchronous adapter will need its own bounded ownership contract before it can be installed. */
internal interface LocalOcr {
    val unavailableReason: LocalOcrResult.Reason?
    fun recognize(bitmap: Bitmap, deadlineUptimeMs: Long, cancelled: () -> Boolean): LocalOcrResult
}

/** Explicit absent-backend fallback. This is not a successful empty recognition. */
internal object NoLocalOcr : LocalOcr {
    override val unavailableReason = LocalOcrResult.Reason.NOT_INSTALLED
    override fun recognize(bitmap: Bitmap, deadlineUptimeMs: Long, cancelled: () -> Boolean) =
        LocalOcrResult.Unavailable(unavailableReason)
}
