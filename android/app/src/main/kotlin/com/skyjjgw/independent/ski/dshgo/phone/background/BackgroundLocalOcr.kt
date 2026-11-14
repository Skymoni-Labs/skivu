package com.skyjjgw.independent.ski.dshgo.phone.background

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.SystemClock
import com.skyjjgw.independent.ski.dshgo.phone.a11y.LocalOcr
import com.skyjjgw.independent.ski.dshgo.phone.a11y.LocalOcrBoundary
import com.skyjjgw.independent.ski.dshgo.phone.a11y.LocalOcrResult

/** Decodes only the JPEG of this strict observation receipt, never a preview or another capture. */
internal object BackgroundLocalOcr {
    // Existing fixed presets plus the legacy 1080 x 3240 bound; not the SDK's clone budget.
    private const val MAX_PIXELS = 1080L * 3240
    private const val MAX_BYTES = MAX_PIXELS * 4

    internal fun acceptsDimensions(width: Int, height: Int): Boolean = width > 0 && height > 0 &&
        minOf(width, height) <= 1080 && maxOf(width, height).toLong() <= minOf(width, height).toLong() * 3 &&
        width.toLong() * height.toLong() <= MAX_PIXELS

    fun read(jpeg: ByteArray, receipt: BackgroundCoordinateImage.Receipt, localOcr: LocalOcr,
             deadline: Long, cancelled: () -> Boolean): LocalOcrResult {
        localOcr.unavailableReason?.let { return LocalOcrResult.Unavailable(it) }
        if (cancelled()) return LocalOcrResult.Unavailable(LocalOcrResult.Reason.CANCELLED)
        if (SystemClock.uptimeMillis() >= deadline) return LocalOcrResult.Unavailable(LocalOcrResult.Reason.DEADLINE)
        if (!acceptsDimensions(receipt.width, receipt.height))
            return LocalOcrResult.Failed(LocalOcrResult.Failure.RESULT_LIMIT)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, bounds)
        if (bounds.outMimeType != "image/jpeg" || bounds.outWidth != receipt.width || bounds.outHeight != receipt.height)
            return LocalOcrResult.Failed(LocalOcrResult.Failure.INVALID_RESULT)
        if (cancelled()) return LocalOcrResult.Unavailable(LocalOcrResult.Reason.CANCELLED)
        if (SystemClock.uptimeMillis() >= deadline) return LocalOcrResult.Unavailable(LocalOcrResult.Reason.DEADLINE)
        val options = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inScaled = false
            inSampleSize = 1
        }
        val bitmap = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options)
            ?: return LocalOcrResult.Failed(LocalOcrResult.Failure.INVALID_RESULT)
        try {
            if (bitmap.width != receipt.width || bitmap.height != receipt.height)
                return LocalOcrResult.Failed(LocalOcrResult.Failure.INVALID_RESULT)
            if (bitmap.allocationByteCount.toLong() > MAX_BYTES)
                return LocalOcrResult.Failed(LocalOcrResult.Failure.RESULT_LIMIT)
            return LocalOcrBoundary.read(true, true, bitmap.width, bitmap.height, deadline,
                SystemClock::uptimeMillis, cancelled) { localOcr.recognize(bitmap, deadline, cancelled) }
        } finally {
            // The synchronous LocalOcr contract borrows this frame; ML Kit owns a separate clone.
            bitmap.recycle()
        }
    }
}
