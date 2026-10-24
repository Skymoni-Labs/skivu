// SPDX-License-Identifier: GPL-3.0-only
package com.skyjjgw.independent.ski

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.View
import android.webkit.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import java.io.ByteArrayInputStream

/** Each view serves only its own package at a virtual, never-network origin. */
class OpenPluginViewFactory(private val messenger: BinaryMessenger) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView = OpenPluginView(context, viewId, args as Map<*, *>, messenger)
}

private class OpenPluginView(context: Context, id: Int, args: Map<*, *>, messenger: BinaryMessenger) : PlatformView {
    private val browser = WebView(context)
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "skivu/open_plugin/$id")
    private val origin = "https://p${args["digest"]}.plugins.skivu.invalid"
    private val entry = args["entry"] as String
    private val resources = (args["files"] as Map<*, *>).map { (key, value) ->
        val resource = value as Map<*, *>
        key as String to Pair(resource["mime"] as String, Base64.decode(resource["base64"] as String, Base64.DEFAULT))
    }.toMap()
    private val sdk = context.assets.open("flutter_assets/assets/plugin_sdk/skivu-sdk.js").use { it.readBytes() }
    private var closed = false
    private var inFlight = 0
    private val csp = "default-src 'none'; script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' blob:; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; worker-src 'self' blob:; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

    init {
        with(browser.settings) {
            javaScriptEnabled = true
            domStorageEnabled = false
            allowFileAccess = false
            allowContentAccess = false
            @Suppress("DEPRECATION")
            allowFileAccessFromFileURLs = false
            @Suppress("DEPRECATION")
            allowUniversalAccessFromFileURLs = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            setGeolocationEnabled(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = WebSettings.LOAD_NO_CACHE
            blockNetworkLoads = true
            mediaPlaybackRequiresUserGesture = true
        }
        browser.isSaveEnabled = false
        browser.addJavascriptInterface(object {
            @JavascriptInterface fun postMessage(raw: String) {
                if (raw.length > 18 * 1024 * 1024) return
                main.post {
                    if (closed || inFlight >= 8) return@post
                    val request = try { JSONObject(raw) } catch (_: Exception) { return@post }
                    val ticket = request.optString("id")
                    if (!Regex("[0-9]{1,16}").matches(ticket)) return@post
                    inFlight++
                    channel.invokeMethod("request", raw, object : MethodChannel.Result {
                        override fun success(value: Any?) { inFlight--; if (!closed) resolve(ticket, JSONObject(value as? Map<*, *> ?: mapOf("ok" to false, "error" to mapOf("code" to "FAILED", "message" to "宿主调用未完成。")))) }
                        override fun error(code: String, message: String?, details: Any?) { inFlight--; if (!closed) resolve(ticket, JSONObject(mapOf("ok" to false, "error" to mapOf("code" to "FAILED", "message" to "宿主调用未完成。")))) }
                        override fun notImplemented() { error("UNSUPPORTED", null, null) }
                    })
                }
            }
        }, "SkivuNative")
        browser.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = !localDocument(request.url)
            @Suppress("DEPRECATION")
            override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean = !localDocument(Uri.parse(url))
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                val uri = request.url
                if (closed || request.method != "GET" || "${uri.scheme}://${uri.authority}" != origin || uri.fragment != null) return blocked()
                val path = uri.path?.removePrefix("/") ?: return blocked()
                if (path.split('/').any { it == "." || it == ".." || it.isEmpty() } || path.contains('\\')) return blocked()
                val data = if (path == "skivu-sdk.js") Pair("application/javascript", sdk) else resources[path] ?: return blocked()
                var bytes = data.second
                if (data.first == "text/html") {
                    // First policy cannot be relaxed by a later plugin meta tag.
                    val prefix = "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"$csp\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\"><script src=\"/skivu-sdk.js\"></script>"
                    bytes = prefix.toByteArray(Charsets.UTF_8) + bytes
                }
                return WebResourceResponse(data.first, "UTF-8", 200, "OK", mapOf("Content-Security-Policy" to csp, "X-Content-Type-Options" to "nosniff", "Cache-Control" to "no-store", "Referrer-Policy" to "no-referrer", "Permissions-Policy" to "camera=(), microphone=(), geolocation=(), payment=(), usb=()"), ByteArrayInputStream(bytes))
            }
            override fun onPageStarted(view: WebView, url: String, icon: Bitmap?) {
                if (!localDocument(Uri.parse(url))) view.stopLoading()
            }
            override fun onReceivedHttpAuthRequest(view: WebView, handler: HttpAuthHandler, host: String, realm: String) { handler.cancel() }
        }
        browser.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
            override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                if (!closed) channel.invokeMethod("console", mapOf("level" to message.messageLevel().name, "message" to message.message().take(1000), "line" to message.lineNumber()))
                return true
            }
            override fun onShowFileChooser(webView: WebView, filePathCallback: android.webkit.ValueCallback<Array<Uri>>, fileChooserParams: FileChooserParams): Boolean { filePathCallback.onReceiveValue(null); return true }
        }
        channel.setMethodCallHandler { call, result ->
            when(call.method) {
                "event" -> {
                    val name = call.argument<String>("name") ?: ""
                    val detail = JSONObject.wrap(call.argument<Any?>("detail"))
                    if (!closed) browser.evaluateJavascript("window.__skivuEvent&&window.__skivuEvent(${JSONObject.quote(name)},$detail)", null)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        browser.loadUrl("$origin/$entry")
    }
    private fun blocked() = WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden", mapOf("Cache-Control" to "no-store"), ByteArrayInputStream(ByteArray(0)))
    private fun localDocument(uri: Uri): Boolean {
        if("${uri.scheme}://${uri.authority}" != origin) return false
        val path=uri.path?.removePrefix("/") ?: return false
        return resources[path]?.first == "text/html"
    }
    private fun resolve(ticket: String, value: JSONObject) { browser.evaluateJavascript("window.__skivuResolve&&window.__skivuResolve(${JSONObject.quote(ticket)},$value)", null) }
    override fun getView(): View = browser
    override fun dispose() {
        if (closed) return
        closed = true
        channel.setMethodCallHandler(null)
        browser.stopLoading()
        browser.removeJavascriptInterface("SkivuNative")
        browser.webChromeClient = WebChromeClient()
        browser.webViewClient = WebViewClient()
        browser.destroy()
    }
}
