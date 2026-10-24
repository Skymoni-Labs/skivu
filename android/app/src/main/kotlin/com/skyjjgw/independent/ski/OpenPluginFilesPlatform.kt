// SPDX-License-Identifier: GPL-3.0-only
package com.skyjjgw.independent.ski

import android.app.Activity
import android.content.Intent
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Explicit system file selection only; never returns a filesystem path. */
class OpenPluginFilesPlatform(private val activity: Activity) {
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var bytes: ByteArray? = null
    private var channel: MethodChannel? = null
    private var closed = false
    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "skivu/open_plugin_files").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method !in listOf("pick", "save")) { result.notImplemented(); return@setMethodCallHandler }
                if (pending != null || closed) { result.error("BUSY", "文件选择器正在使用。", null); return@setMethodCallHandler }
                try {
                    val saving = call.method == "save"
                    val data = if (saving) requireNotNull(call.argument<ByteArray>("bytes")) else null
                    require(data == null || data.size <= 8 * 1024 * 1024)
                    val mime = call.argument<String>("mime") ?: "application/octet-stream"
                    require(Regex("[A-Za-z0-9.+-]+/[A-Za-z0-9.+*-]+").matches(mime))
                    val name = (call.argument<String>("name") ?: "plugin-export.bin").replace(Regex("[\\\\/\\p{Cc}<>:\"|?*]"), "_").take(160)
                    pending = result; bytes = data
                    activity.startActivityForResult(Intent(if(saving) Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = if(saving) mime else "*/*"
                        if(saving) putExtra(Intent.EXTRA_TITLE, name)
                    }, if(saving) 6453 else 6452)
                } catch (_: Exception) { pending = null; bytes = null; result.error("FILE_FAILED", "文件选择未完成。", null) }
            }
        }
    }
    fun onResult(requestCode: Int, resultCode: Int, intent: Intent?): Boolean {
        if(requestCode !in listOf(6452,6453)) return false
        val result = pending ?: return true
        pending = null
        val data = bytes; bytes = null
        val uri = intent?.data
        if(resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return true }
        if(uri.scheme != "content") { result.error("FILE_FAILED", "请选择系统文档。", null); return true }
        worker.execute {
            try {
                val answer: Any = if(requestCode == 6453) {
                    activity.contentResolver.openOutputStream(uri, "wt").use { output -> requireNotNull(output).write(requireNotNull(data)); output.flush() }; true
                } else {
                    var name = "plugin-import.bin"
                    activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE),null,null,null)?.use { cursor ->
                        if(cursor.moveToFirst()) {
                            name = cursor.getString(0).take(160)
                            if(!cursor.isNull(1)) require(cursor.getLong(1) <= 8*1024*1024)
                        }
                    }
                    val raw = activity.contentResolver.openInputStream(uri).use { input ->
                        val stream = requireNotNull(input); val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(65536)
                        while(true) { val count=stream.read(buffer); if(count<0)break; require(out.size()+count<=8*1024*1024); out.write(buffer,0,count) };out.toByteArray()
                    }
                    mapOf("name" to name, "mime" to (activity.contentResolver.getType(uri) ?: "application/octet-stream"), "bytes" to raw)
                }
                activity.runOnUiThread { if(!closed)result.success(answer) }
            } catch (_: Exception) { activity.runOnUiThread { if(!closed)result.error("FILE_FAILED", "文件读写失败或超过 8 MiB。", null) } }
        }
        return true
    }
    fun close(){ closed=true;pending?.error("CLOSED","插件文件操作已结束。",null);pending=null;bytes=null;channel?.setMethodCallHandler(null);worker.shutdownNow() }
}
