package com.skyjjgw.independent.ski.dshgo.phone.a11y

import android.content.Context
import android.graphics.Bitmap
import com.google.android.gms.tasks.OnCompleteListener
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.skyjjgw.independent.ski.dshgo.mlkit.MlKitRuntime
import java.util.concurrent.Executor

/** The OCR SDK entry; host construction and settings do not instantiate this class. */
internal class MlKitSession private constructor(private val recognizer: TextRecognizer) {
    fun start(bitmap: Bitmap, beforeProcess: () -> Boolean, accepting: () -> Boolean,
              complete: (LocalOcrResult) -> Unit): Boolean {
        val width = bitmap.width
        val height = bitmap.height
        val image = InputImage.fromBitmap(bitmap, 0)
        if (!beforeProcess()) return false
        val original = recognizer.process(image)
        original.addOnCompleteListener(DIRECT, OnCompleteListener<Text> { task ->
            var result: LocalOcrResult = LocalOcrResult.Failed(LocalOcrResult.Failure.ENGINE)
            try {
                result = when {
                    !accepting() || task.isCanceled -> LocalOcrResult.Unavailable(LocalOcrResult.Reason.CANCELLED)
                    !task.isSuccessful -> result
                    else -> adapt(task.result, width, height, accepting)
                }
            } catch (_: Exception) {
                result = LocalOcrResult.Failed(LocalOcrResult.Failure.ENGINE)
            } finally {
                // Original Task terminal, including failure/cancellation. Never a timeout wrapper.
                complete(result)
            }
        })
        return true
    }

    fun close() = recognizer.close()

    companion object {
        private val DIRECT = Executor { it.run() }

        fun create(context: Context): MlKitSession {
            MlKitRuntime.initialize(context)
            return MlKitSession(TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build()))
        }

        private fun adapt(text: Text?, width: Int, height: Int, accepting: () -> Boolean): LocalOcrResult {
            if (text == null) return LocalOcrResult.Failed(LocalOcrResult.Failure.INVALID_RESULT)
            val output = ArrayList<LocalOcrResult.Line>()
            var blocks = 0
            var lines = 0
            var bytes = 0
            for (block in text.textBlocks) {
                if (!accepting()) return LocalOcrResult.Unavailable(LocalOcrResult.Reason.CANCELLED)
                if (++blocks > 256) return LocalOcrResult.Failed(LocalOcrResult.Failure.RESULT_LIMIT)
                for (line in block.lines) {
                    if (!accepting()) return LocalOcrResult.Unavailable(LocalOcrResult.Reason.CANCELLED)
                    if (++lines > 256) return LocalOcrResult.Failed(LocalOcrResult.Failure.RESULT_LIMIT)
                    val raw = line.text
                    if (raw.length > 16 * 1024) return LocalOcrResult.Failed(LocalOcrResult.Failure.RESULT_LIMIT)
                    val size = raw.toByteArray(Charsets.UTF_8).size
                    if (size > 16 * 1024 - bytes) return LocalOcrResult.Failed(LocalOcrResult.Failure.RESULT_LIMIT)
                    bytes += size
                    val confidence = line.confidence
                    if (!confidence.isFinite() || confidence !in 0f..1f)
                        return LocalOcrResult.Failed(LocalOcrResult.Failure.INVALID_RESULT)
                    val box = line.boundingBox
                    if (raw.isBlank() && box == null) continue
                    if (box == null || box.left < 0 || box.top < 0 || box.right <= box.left ||
                        box.bottom <= box.top || box.right > width || box.bottom > height)
                        return LocalOcrResult.Failed(LocalOcrResult.Failure.INVALID_RESULT)
                    if (!raw.isBlank()) output.add(LocalOcrResult.Line(raw, box.left, box.top,
                        box.right, box.bottom, confidence))
                }
            }
            if (!accepting()) return LocalOcrResult.Unavailable(LocalOcrResult.Reason.CANCELLED)
            return LocalOcrResult.Recognized(output)
        }
    }
}
