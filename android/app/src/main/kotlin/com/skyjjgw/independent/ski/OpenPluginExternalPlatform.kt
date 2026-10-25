package com.skyjjgw.independent.ski

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Generic SDK transport; no third-party plugin IDs or app package allowlist. */
class OpenPluginExternalPlatform(private val activity: Activity) {
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "skivu/open_plugin_external").setMethodCallHandler { call, result ->
            if (call.method != "open") { result.notImplemented(); return@setMethodCallHandler }
            val raw = call.argument<String>("url")
            val uri = raw?.let { Uri.parse(it) }
            if (raw == null || raw.length > 8192 || uri == null || uri.scheme != "https" ||
                uri.host.isNullOrBlank() || uri.userInfo != null || uri.fragment != null ||
                raw.any { it <= ' ' || it == '\\' || it == '\u007f' }) {
                result.error("INVALID_ARGUMENT", "仅支持公开 HTTPS 链接。", null)
                return@setMethodCallHandler
            }
            try {
                activity.startActivity(Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE))
                result.success("accepted")
            } catch (_: ActivityNotFoundException) {
                result.success("not_available")
            } catch (_: Exception) {
                result.error("EXTERNAL_FAILED", "系统未能打开该链接。", null)
            }
        }
    }
}
