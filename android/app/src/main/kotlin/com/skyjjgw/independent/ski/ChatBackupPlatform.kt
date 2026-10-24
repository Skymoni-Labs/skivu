package com.skyjjgw.independent.ski

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class ChatBackupPlatform(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private var archive: ByteArray? = null
    private val worker = Executors.newSingleThreadExecutor()
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "skivu/chat_backup").setMethodCallHandler { call, result ->
            if (call.method != "export") { result.notImplemented(); return@setMethodCallHandler }
            if (pending != null) { result.error("BUSY", "备份选择器已打开", null); return@setMethodCallHandler }
            val data = call.argument<ByteArray>("bytes")
            if (data == null) { result.error("INVALID", "缺少备份", null); return@setMethodCallHandler }
            pending = result; archive = data
            try {
                activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/json"
                    putExtra(Intent.EXTRA_TITLE, "skivu-chats-${System.currentTimeMillis()}.json")
                }, 6417)
            } catch (_: Exception) { pending = null; archive = null; result.error("EXPORT", "无法打开文件选择器", null) }
        }
    }
    fun close() {
        pending?.error("CANCELLED", "备份已取消", null)
        pending = null; archive = null
        worker.shutdown()
    }
    fun activityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != 6417) return false
        val result = pending ?: return true
        val bytes = archive
        pending = null; archive = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(false); return true }
        worker.execute {
            try {
                activity.contentResolver.openOutputStream(uri, "wt").use { stream ->
                    requireNotNull(stream); stream.write(requireNotNull(bytes)); stream.flush()
                }
                activity.runOnUiThread { result.success(true) }
            } catch (_: Exception) { activity.runOnUiThread { result.error("EXPORT", "备份文件写入失败", null) } }
        }
        return true
    }
}
