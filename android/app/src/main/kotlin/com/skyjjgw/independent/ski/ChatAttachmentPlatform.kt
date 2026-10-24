package com.skyjjgw.independent.ski

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class ChatAttachmentFileProvider : FileProvider()

/** Bounded local chat attachments; no network or broad external storage access. */
class ChatAttachmentPlatform(private val activity: Activity) {
    companion object { const val SAVE_REQUEST = 6421 }
    private data class Attachment(val bytes: ByteArray, val mime: String, val name: String)
    private data class Save(val result: MethodChannel.Result, val attachment: Attachment)
    private val worker = Executors.newSingleThreadExecutor()
    private val results = mutableSetOf<MethodChannel.Result>()
    private var pending: Save? = null
    private var channel: MethodChannel? = null
    @Volatile private var closed = false
    private val extensions = mapOf(
        "image/png" to "png", "image/jpeg" to "jpg", "image/webp" to "webp",
        "video/mp4" to "mp4", "video/webm" to "webm", "audio/webm" to "webm",
        "audio/ogg" to "ogg", "audio/mp4" to "m4a", "audio/mpeg" to "mp3", "audio/wav" to "wav",
        "application/pdf" to "pdf", "application/octet-stream" to "bin", "text/plain" to "txt", "application/zip" to "zip"
    )

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "skivu/chat_attachment").also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                if (call.method !in listOf("open", "save")) { result.notImplemented(); return@setMethodCallHandler }
                if (closed) { result.error("CLOSED", "附件操作已结束。", null); return@setMethodCallHandler }
                val attachment = try { parse(call) } catch (_: Exception) {
                    result.error("INVALID_ATTACHMENT", "附件格式不正确或超过 2MB。", null); return@setMethodCallHandler
                }
                if (call.method == "save" && pending != null) {
                    result.error("BUSY", "附件保存选择器已打开。", null); return@setMethodCallHandler
                }
                results.add(result)
                if (call.method == "open") open(attachment, result) else save(attachment, result)
            }
        }
    }

    private fun parse(call: MethodCall): Attachment {
        val bytes = requireNotNull(call.argument<ByteArray>("bytes"))
        require(bytes.isNotEmpty() && bytes.size <= 2 * 1024 * 1024)
        val mime = requireNotNull(call.argument<String>("mime"))
        val extension = requireNotNull(extensions[mime])
        val rawName = requireNotNull(call.argument<String>("name"))
        require(rawName.isNotBlank() && rawName.length <= 160)
        val sanitized = rawName.replace(Regex("[\\\\/\\p{Cc}<>:\"|?*\\u202a-\\u202e\\u2066-\\u2069]"), "_")
            .trim().trim('.')
        var stem = sanitized.substringBeforeLast('.', sanitized).trim().trim('.')
        if (stem.isBlank()) stem = "chat-attachment"
        if (Regex("^(con|prn|aux|nul|com[1-9]|lpt[1-9])$", RegexOption.IGNORE_CASE).matches(stem)) stem = "chat-$stem"
        return Attachment(bytes, mime, "${stem.take(90)}.$extension")
    }

    private fun answer(result: MethodChannel.Result, value: Boolean) {
        if (results.remove(result)) result.success(value)
    }
    private fun fail(result: MethodChannel.Result, code: String, message: String) {
        if (results.remove(result)) result.error(code, message, null)
    }

    private fun open(attachment: Attachment, result: MethodChannel.Result) {
        worker.execute {
            try {
                val directory = File(activity.cacheDir, "chat-attachments").apply { mkdirs() }
                val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000
                directory.listFiles()?.filter { it.isDirectory }?.sortedByDescending { it.lastModified() }?.forEachIndexed { index, file ->
                    if (index >= 20 || file.lastModified() < cutoff) file.deleteRecursively()
                }
                val session = File(directory, UUID.randomUUID().toString()).apply { check(mkdir()) }
                val file = File(session, attachment.name)
                check(file.canonicalFile.parentFile == session.canonicalFile)
                file.writeBytes(attachment.bytes)
                val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.chat_attachments", file)
                activity.runOnUiThread {
                    if (closed) return@runOnUiThread
                    try {
                        val view = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, attachment.mime)
                            clipData = ClipData.newRawUri(attachment.name, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        // Let Android's chooser resolve handlers without a
                        // package-visibility-dependent preflight query.
                        activity.startActivity(Intent.createChooser(view, "打开聊天附件").apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        })
                        answer(result, true)
                    } catch (_: ActivityNotFoundException) {
                        fail(result, "NO_VIEWER", "未找到可打开此附件的应用。")
                    } catch (_: Exception) { fail(result, "OPEN_FAILED", "附件未能打开。") }
                }
            } catch (_: Exception) {
                activity.runOnUiThread { fail(result, "OPEN_FAILED", "附件未能打开。") }
            }
        }
    }

    private fun save(attachment: Attachment, result: MethodChannel.Result) {
        pending = Save(result, attachment)
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = attachment.mime
                putExtra(Intent.EXTRA_TITLE, attachment.name)
            }, SAVE_REQUEST)
        } catch (_: Exception) { pending = null; fail(result, "SAVE_FAILED", "无法打开附件保存选择器。") }
    }

    fun onResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != SAVE_REQUEST) return false
        val save = pending ?: return true
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { answer(save.result, false); return true }
        if (uri.scheme != "content") { fail(save.result, "SAVE_FAILED", "请选择有效的文档保存位置。"); return true }
        worker.execute {
            try {
                activity.contentResolver.openOutputStream(uri, "wt").use { output ->
                    requireNotNull(output).write(save.attachment.bytes)
                    output.flush()
                }
                activity.runOnUiThread { answer(save.result, true) }
            } catch (_: Exception) {
                activity.runOnUiThread { fail(save.result, "SAVE_FAILED", "附件未能写入所选位置。") }
            }
        }
        return true
    }

    fun close() {
        closed = true
        channel?.setMethodCallHandler(null)
        pending = null
        results.toList().forEach { fail(it, "CLOSED", "附件操作已结束。") }
        // Already-authorized writes may finish; external viewers retain their
        // read grant. Cache entries expire on a later open, not on Activity stop.
        worker.shutdown()
    }
}
