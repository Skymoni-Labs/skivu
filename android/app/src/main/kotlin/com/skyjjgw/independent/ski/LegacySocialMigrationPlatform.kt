package com.skyjjgw.independent.ski

import android.app.Activity
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.AtomicFile
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.json.JSONTokener
import java.io.ByteArrayInputStream
import java.io.File
import java.util.concurrent.Executors

/** One-time, read-only localStorage extraction. Never installs a platform view. */
class LegacySocialMigrationPlatform(private val activity: Activity) {
    companion object {
        const val SOURCE = "file:///android_asset/flutter_assets/assets/social_ui/index.html"
        const val SCHEMA = "skivu-legacy-social-v1"
        private const val MAX_BYTES = 24 * 1024 * 1024
        private val KEYS = listOf("skivu.host.social.v1", "skivu.social-demo.v2", "skivu.chat-modes.html.v1")
    }
    private val handler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val archive = AtomicFile(File(activity.filesDir, "legacy-social/local-storage-v1.json"))
    private var pending: MethodChannel.Result? = null
    private var view: WebView? = null
    private var serial = 0
    private var closed = false
    private var timeout: Runnable? = null

    fun accepts(call: MethodCall) = call.method == "legacySocialRead" || call.method == "legacySocialBackup"

    /** Wire before AppPlatform's worker dispatch on the skivu/app_platform channel. */
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (!accepts(call)) { result.notImplemented(); return }
        activity.runOnUiThread {
            if (closed) { result.error("CANCELLED", "旧社交数据读取已关闭。", null); return@runOnUiThread }
            if (pending != null) { result.error("BUSY", "旧社交数据正在读取。", null); return@runOnUiThread }
            pending = result
            val ticket = ++serial
            timeout = Runnable { finish(ticket, null, "旧社交数据读取超时，原数据已保留，可重试。") }
            handler.postDelayed(timeout!!, 15000)
            worker.execute {
                try {
                    val saved = if (archive.baseFile.exists() || File(archive.baseFile.path + ".bak").exists()) {
                        val bytes = archive.readFully()
                        require(bytes.size <= MAX_BYTES)
                        bytes.toString(Charsets.UTF_8).also { validate(it) }
                    } else null
                    activity.runOnUiThread {
                        if (ticket != serial || pending == null) return@runOnUiThread
                        if (saved != null || call.method == "legacySocialBackup") finish(ticket, saved)
                        else capture(ticket)
                    }
                } catch (_: Exception) {
                    activity.runOnUiThread { finish(ticket, null, "旧社交备份读取失败，原文件已保留。") }
                }
            }
        }
    }

    @Suppress("DEPRECATION", "SetJavaScriptEnabled")
    private fun capture(ticket: Int) {
        try {
            // Use the default WebView profile and the exact old file base URL.
            // loadDataWithBaseURL(file:...) has an opaque origin on Android.
            // A new, static empty asset at the exact historical path preserves
            // the old storage origin. No historical HTML/scripts are bundled.
            // Asset loads can bypass shouldInterceptRequest, so that asset has
            // a deny-all CSP and contains no scripts or resource references.
            val browser = WebView(activity)
            view = browser
            browser.settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                allowFileAccess = true
                allowContentAccess = false
                allowFileAccessFromFileURLs = false
                allowUniversalAccessFromFileURLs = false
                javaScriptCanOpenWindowsAutomatically = false
                setSupportMultipleWindows(false)
                blockNetworkLoads = true
                blockNetworkImage = true
            }
            browser.setNetworkAvailable(false)
            var evaluated = false
            browser.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean = true
                override fun shouldOverrideUrlLoading(v: WebView, url: String): Boolean = true
                override fun shouldInterceptRequest(v: WebView, request: WebResourceRequest): WebResourceResponse {
                    if (request.isForMainFrame && request.url.toString() == SOURCE) {
                        return WebResourceResponse("text/html", "UTF-8",
                            activity.assets.open("flutter_assets/assets/social_ui/index.html"))
                    }
                    return WebResourceResponse("text/html", "UTF-8", 403,
                        "Blocked", mapOf("Cache-Control" to "no-store"),
                        ByteArrayInputStream(ByteArray(0)))
                }
                override fun onPageStarted(v: WebView, url: String, icon: Bitmap?) {
                    if (url != SOURCE) finish(ticket, null, "旧社交数据来源不正确，已停止读取。")
                }
                override fun onReceivedError(v: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if (request.isForMainFrame) finish(ticket, null, "旧社交数据读取失败，原数据已保留。")
                }
                override fun onPageFinished(v: WebView, url: String) {
                    if (ticket != serial || pending == null || evaluated || url != SOURCE) return
                    evaluated = true
                    val keys = org.json.JSONArray(KEYS).toString()
                    v.evaluateJavascript("""(function(){try{var d={};$keys.forEach(function(k){d[k]=localStorage.getItem(k)});return JSON.stringify({schema:'$SCHEMA',source:'$SOURCE',platform:'android',capturedAt:new Date().toISOString(),storage:d})}catch(e){return null}})()""") { raw ->
                        if (ticket != serial || pending == null) return@evaluateJavascript
                        try {
                            val text = JSONTokener(raw).nextValue() as? String ?: error("unreadable")
                            require(text.toByteArray(Charsets.UTF_8).size <= MAX_BYTES)
                            validate(text)
                            destroyView()
                            worker.execute {
                                try {
                                    require(archive.baseFile.parentFile!!.isDirectory || archive.baseFile.parentFile!!.mkdirs())
                                    val bytes = text.toByteArray(Charsets.UTF_8)
                                    val stream = archive.startWrite()
                                    try { stream.write(bytes); archive.finishWrite(stream) }
                                    catch (e: Exception) { archive.failWrite(stream); throw e }
                                    require(archive.readFully().contentEquals(bytes))
                                    activity.runOnUiThread { finish(ticket, text) }
                                } catch (_: Exception) {
                                    activity.runOnUiThread { finish(ticket, null, "旧社交备份未能保存，原数据已保留，可重试。") }
                                }
                            }
                        } catch (_: Exception) {
                            finish(ticket, null, "旧社交数据读取失败，原数据已保留，可重试。")
                        }
                    }
                }
            }
            browser.loadUrl(SOURCE)
        } catch (_: Exception) { finish(ticket, null, "此设备暂时无法读取旧社交数据，原数据已保留。") }
    }

    private fun validate(text: String) {
        val value = JSONObject(text)
        require(value.getString("schema") == SCHEMA && value.getString("source") == SOURCE)
        val storage = value.getJSONObject("storage")
        require(storage.keys().asSequence().toSet() == KEYS.toSet())
        KEYS.forEach { require(storage.isNull(it) || storage.get(it) is String) }
    }
    private fun destroyView() {
        try { view?.apply { stopLoading(); webViewClient = WebViewClient(); destroy() } }
        catch (_: Exception) { /* Never clear the default WebView data profile. */ }
        view = null
    }
    private fun finish(ticket: Int, value: String?, error: String? = null) {
        if (ticket != serial) return
        val result = pending ?: return
        if (error != null) android.util.Log.w("SkivuLegacyImport", error)
        pending = null
        serial++
        timeout?.let { handler.removeCallbacks(it) }; timeout = null
        destroyView()
        if (error == null) result.success(value) else result.error("LEGACY_SOCIAL", error, null)
    }
    fun close() {
        activity.runOnUiThread {
            closed = true
            finish(serial, null, "旧社交数据读取已取消，原数据已保留。")
            destroyView()
            worker.shutdown()
        }
    }
}
