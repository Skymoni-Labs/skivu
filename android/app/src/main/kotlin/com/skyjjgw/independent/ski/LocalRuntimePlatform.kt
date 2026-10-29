package com.skyjjgw.independent.ski

import android.content.*
import android.content.pm.PackageManager
import android.net.Uri
import android.os.*
import android.system.Os
import android.system.OsConstants
import android.webkit.*
import android.webkit.CookieManager
import io.flutter.plugin.common.*
import io.flutter.plugin.platform.*
import java.io.*
import java.net.*
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Generic, signed, separately installed runtime transport. No engine business code. */
class LocalRuntimePlatform(private val context: Context) {
    companion object {
        const val ACTION = "org.skivu.runtime.V1"
        const val PERMISSION = "org.skivu.permission.RUN_RUNTIME"
    }
    private val main = Handler(Looper.getMainLooper())
    private lateinit var channel: MethodChannel
    @Volatile private var active: Session? = null
    private inner class Session(val id: Int, val component: ComponentName, val uid: Int) {
        val token = UUID.randomUUID().toString()
        var worker: Messenger? = null
        var connection: ServiceConnection? = null
        var bound = false
        @Volatile var closing = false
        var approvedUrl: String? = null
        var port = 0
        var result: MethodChannel.Result? = null
        val descriptors = mutableListOf<ParcelFileDescriptor>()
        val views = mutableListOf<WebView>()
        val stopResults = mutableListOf<MethodChannel.Result>()
    }

    fun register(messenger: BinaryMessenger, registry: PlatformViewRegistry) {
        WebView.setWebContentsDebuggingEnabled((context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0)
        channel = MethodChannel(messenger, "skivu/local_runtime")
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "providers" -> result.success(providers())
                    "start" -> start(call, result)
                    "stop" -> {
                        val s = active
                        if (s == null || s.id != call.argument<Int>("sessionId")) result.success(null)
                        else stop(s, result)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("RUNTIME_UNAVAILABLE", "本地运行组件不可用，请检查安装、来源和签名。", null) }
        }
        registry.registerViewFactory("skivu/local-runtime", object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
            override fun create(viewContext: Context, id: Int, args: Any?): PlatformView {
                val s = active ?: error("runtime closed")
                require(!s.closing && (args as? Map<*, *>)?.get("sessionId") == s.id)
                val url = s.approvedUrl ?: error("runtime not ready")
                val view = WebView(viewContext).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.allowFileAccess = false
                    settings.allowContentAccess = false
                    settings.setGeolocationEnabled(false)
                    settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                    CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
                    webChromeClient = object : WebChromeClient() {
                        override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
                    }
                    setDownloadListener { _, _, _, _, _ -> }
                    webViewClient = object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(v: WebView, r: WebResourceRequest) = !local(s, r.url)
                        override fun shouldInterceptRequest(v: WebView, r: WebResourceRequest): WebResourceResponse? = proxy(s, r)
                    }
                    loadUrl(url)
                }
                s.views.add(view)
                return object : PlatformView {
                    override fun getView() = view
                    override fun dispose() { s.views.remove(view); view.stopLoading(); view.destroy() }
                }
            }
        })
    }

    @Suppress("DEPRECATION") private fun signing(packageName: String): String {
        val info = context.packageManager.getPackageInfo(packageName,
            if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        require(signatures?.size == 1)
        return MessageDigest.getInstance("SHA-256").digest(signatures!![0].toByteArray()).joinToString("") { "%02x".format(it) }
    }
    private fun service(component: ComponentName) = context.packageManager.getServiceInfo(component, PackageManager.GET_META_DATA).also {
        require(it.exported && it.enabled && it.permission == PERMISSION && it.applicationInfo.uid != context.applicationInfo.uid)
        require(it.metaData?.getInt("org.skivu.runtime.protocol") == 1)
        require(context.packageManager.checkPermission(android.Manifest.permission.INTERNET, component.packageName) == PackageManager.PERMISSION_DENIED)
    }
    @Suppress("DEPRECATION") private fun providers(): List<Map<String, Any>> =
        context.packageManager.queryIntentServices(Intent(ACTION), PackageManager.GET_META_DATA).take(32).mapNotNull { resolved ->
            runCatching {
                val component = ComponentName(resolved.serviceInfo.packageName, resolved.serviceInfo.name)
                service(component)
                mapOf("component" to component.flattenToString(), "name" to resolved.loadLabel(context.packageManager).toString().take(120),
                    "signerSha256" to signing(component.packageName), "protocol" to 1)
            }.getOrNull()
        }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        check(active == null)
        val component = ComponentName.unflattenFromString(call.argument<String>("component") ?: "") ?: error("component")
        val expected = call.argument<String>("signerSha256") ?: error("signer")
        require(Regex("[0-9a-f]{64}").matches(expected) && signing(component.packageName) == expected)
        val info = service(component)
        val id = call.argument<Int>("sessionId") ?: error("session")
        require(id > 0)
        val s = Session(id, component, info.applicationInfo.uid).also { it.result = result; active = it }
        s.connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                if (active !== s || s.closing) return
                try {
                    // Recheck after binding; installation can change while awaiting the service.
                    require(signing(component.packageName) == expected && service(component).applicationInfo.uid == s.uid)
                    s.worker = Messenger(binder)
                    val socket = Os.socket(OsConstants.AF_INET, OsConstants.SOCK_STREAM, 0)
                    val listener: ParcelFileDescriptor
                    try {
                        Os.bind(socket, InetAddress.getByName("127.0.0.1"), 0); Os.listen(socket, 8)
                        s.port = (Os.getsockname(socket) as InetSocketAddress).port
                        listener = ParcelFileDescriptor.dup(socket)
                    } finally { Os.close(socket) }
                    val model = ParcelFileDescriptor.createSocketPair()
                    val device = ParcelFileDescriptor.createSocketPair()
                    s.descriptors.addAll(listOf(listener, model[0], model[1], device[0], device[1]))
                    val receiver = Messenger(Handler(Looper.getMainLooper()) { message ->
                        if (active !== s || s.closing || message.sendingUid != s.uid) return@Handler true
                        val url = message.data.getString("url")
                        if (message.data.getString("token") != s.token) return@Handler true
                        if (url != null && local(s, Uri.parse(url)) && url.length <= 4096) {
                            s.approvedUrl = url; s.result?.success(null); s.result = null
                        } else if (message.what == 3) {
                            s.result?.error("RUNTIME_FAILED", "运行组件启动失败，请检查可用空间或重新安装组件。", null); s.result = null
                            stop(s, null)
                        }
                        true
                    })
                    s.worker!!.send(Message.obtain(null, 1).apply { replyTo = receiver; data = Bundle().apply {
                        putString("token", s.token); putParcelable("listener", listener); putInt("port", s.port)
                        putParcelable("model", model[1]); putParcelable("device", device[1])
                    } })
                    listener.close(); model[1].close(); device[1].close()
                    broker(s, model[0], "model", 256 * 1024)
                    broker(s, device[0], "device", 64 * 1024)
                } catch (_: Exception) {
                    s.result?.error("RUNTIME_FAILED", "运行组件连接失败。", null); s.result = null; stop(s, null)
                }
            }
            override fun onServiceDisconnected(name: ComponentName?) { disconnected(s) }
            override fun onBindingDied(name: ComponentName?) { disconnected(s) }
            override fun onNullBinding(name: ComponentName?) { disconnected(s) }
        }
        s.bound = context.bindService(Intent().setComponent(component), s.connection!!, Context.BIND_AUTO_CREATE)
        if (!s.bound) { active = null; s.result = null; result.error("NOT_INSTALLED", "请先安装并启用本地运行组件。", null); return }
        main.postDelayed({ if (active === s && s.result != null) {
            s.result?.error("RUNTIME_TIMEOUT", "运行组件准备超时，请检查可用空间后重试。", null); s.result = null; stop(s, null)
        } }, 240000)
    }

    private fun broker(s: Session, fd: ParcelFileDescriptor, kind: String, limit: Int) {
        Thread {
            try {
                val input = FileInputStream(fd.fileDescriptor)
                val output = FileOutputStream(fd.fileDescriptor)
                while (active === s && !s.closing) {
                    val frame = ByteArrayOutputStream()
                    while (true) {
                        val byte = input.read()
                        if (byte < 0) throw EOFException()
                        if (byte == 10) break
                        if (frame.size() >= limit) throw IOException("frame limit")
                        frame.write(byte)
                    }
                    val latch = CountDownLatch(1)
                    val answer = AtomicReference<String?>()
                    main.post { if (active === s && !s.closing) {
                        channel.invokeMethod(kind, mapOf("sessionId" to s.id, "frame" to frame.toString("UTF-8")), object : MethodChannel.Result {
                            override fun success(value: Any?) { answer.set(value as? String); latch.countDown() }
                            override fun error(code: String, message: String?, details: Any?) { latch.countDown() }
                            override fun notImplemented() { latch.countDown() }
                        })
                    } else latch.countDown() }
                    if (!latch.await(180, TimeUnit.SECONDS)) throw IOException("broker timeout")
                    val response = answer.get() ?: throw IOException("broker closed")
                    val bytes = response.toByteArray(Charsets.UTF_8)
                    if (bytes.size > limit || active !== s || s.closing) throw IOException("response limit")
                    output.write(bytes); output.write(10); output.flush()
                }
            } catch (_: Exception) { main.post { disconnected(s) } }
        }.apply { name = "Skivu runtime $kind"; isDaemon = true; start() }
    }
    private fun disconnected(s: Session) {
        if (active !== s || s.closing) return
        channel.invokeMethod("closed", mapOf("sessionId" to s.id))
        s.result?.error("RUNTIME_DISCONNECTED", "本地运行组件已断开。", null); s.result = null
        stop(s, null)
    }
    private fun local(s: Session, uri: Uri) = uri.scheme == "http" && uri.host == "127.0.0.1" && uri.port == s.port && uri.userInfo == null
    private fun blocked() = WebResourceResponse("text/plain", "utf-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))
    private fun proxy(s: Session, request: WebResourceRequest): WebResourceResponse? {
        if (active !== s || s.closing || !local(s, request.url)) return blocked()
        if (request.method != "GET") return null
        return try {
            var url = request.url.toString()
            var response: HttpURLConnection? = null
            for (attempt in 0 until 4) {
                val c = URL(url).openConnection() as HttpURLConnection
                c.instanceFollowRedirects = false; c.connectTimeout = 10000; c.readTimeout = 30000
                request.requestHeaders.forEach { (name, value) -> if (name.lowercase() !in setOf("host", "cookie", "authorization", "accept-encoding")) c.setRequestProperty(name, value) }
                CookieManager.getInstance().getCookie(url)?.let { c.setRequestProperty("Cookie", it) }
                val code = c.responseCode
                c.headerFields.filterKeys { it?.equals("Set-Cookie", true) == true }.values.flatten().forEach {
                    CookieManager.getInstance().setCookie(url, it)
                }
                if (code in 300..399) {
                    val target = URL(URL(url), c.getHeaderField("Location") ?: error("redirect")).toString()
                    require(local(s, Uri.parse(target))); c.disconnect(); url = target
                } else { response = c; break }
            }
            val c = response ?: return blocked()
            val headers = c.headerFields.filterKeys { it != null }.mapKeys { it.key!! }.mapValues { it.value.joinToString(", ") }.toMutableMap()
            val origin = "http://127.0.0.1:${s.port}"
            headers["Content-Security-Policy"] = "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src $origin ws://127.0.0.1:${s.port}; worker-src blob:; frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'none'"
            headers["Referrer-Policy"] = "no-referrer"
            headers["Cache-Control"] = "no-store"
            var stream: InputStream? = if (c.responseCode >= 400) c.errorStream else c.inputStream
            if (c.contentType?.substringBefore(';')?.lowercase() == "text/html") {
                // CSP alone does not govern WebRTC data channels. Install this
                // before any engine/plugin script, including parser execution.
                val body = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val n = stream?.read(buffer) ?: -1
                    if (n < 0) break
                    require(body.size() + n <= 8 * 1024 * 1024)
                    body.write(buffer, 0, n)
                }
                stream?.close()
                val guard = "<!doctype html><script>for(const n of ['RTCPeerConnection','webkitRTCPeerConnection','WebTransport']){Object.defineProperty(window,n,{value:undefined,writable:false,configurable:false});}</script>"
                stream = ByteArrayInputStream(guard.toByteArray(Charsets.UTF_8) + body.toByteArray())
                headers.keys.filter { it.equals("Content-Length", true) || it.equals("Content-Encoding", true) }.toList().forEach { headers.remove(it) }
            }
            val owned = object : FilterInputStream(stream ?: ByteArrayInputStream(ByteArray(0))) {
                override fun close() { try { super.close() } finally { c.disconnect() } }
            }
            WebResourceResponse(c.contentType?.substringBefore(';') ?: "application/octet-stream", "utf-8", c.responseCode,
                c.responseMessage?.takeIf { it.isNotBlank() } ?: "Response", headers, owned)
        } catch (_: Exception) { blocked() }
    }

    private fun stop(s: Session, result: MethodChannel.Result?) {
        if (active !== s) { result?.success(null); return }
        if (result != null) s.stopResults.add(result)
        if (s.closing) return
        s.closing = true
        s.descriptors.forEach { runCatching { it.close() } }; s.descriptors.clear()
        s.views.forEach { it.stopLoading(); it.loadUrl("about:blank") }
        s.result?.error("CANCELLED", "运行环境已关闭。", null); s.result = null
        var finished = false
        fun finish(ok: Boolean) {
            if (finished) return
            finished = true
            if (s.bound) s.connection?.let { runCatching { context.unbindService(it) } }
            if (active === s) active = null
            s.stopResults.forEach {
                if (ok) it.success(null) else it.error("STOP_UNCONFIRMED", "运行组件未确认停止，请通过系统设置停止该组件并核对文件。", null)
            }
            s.stopResults.clear()
        }
        val target = s.worker
        if (target == null) { finish(true); return }
        try {
            target.send(Message.obtain(null, 4).apply { data = Bundle().apply { putString("token", s.token) }
                replyTo = Messenger(Handler(Looper.getMainLooper()) { message ->
                    if (message.sendingUid == s.uid && message.data.getString("token") == s.token) finish(message.data.getBoolean("stopped"))
                    true
                })
            })
        } catch (_: Exception) { finish(false) }
        main.postDelayed({ finish(false) }, 30000)
    }
    fun close() { active?.let { stop(it, null) } }
}
