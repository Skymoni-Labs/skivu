package com.skyjjgw.independent.ski

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/** System browser authorization and user-confirmed, same-signer APK updates. */
class AppPlatform(private val activity: Activity) {
    private val worker = Executors.newSingleThreadExecutor()
    private var pluginEdgeOwner: String? = null

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "skivu/app_platform").setMethodCallHandler { call, result ->
            worker.execute {
                try {
                    when (call.method) {
                        "info" -> answer(result, info())
                        "setPluginEdgeExclusion" -> setPluginEdgeExclusion(call, result)
                        "encryptPassword" -> {
                            val pem = call.argument<String>("publicKey") ?: error("missing key")
                            val password = call.argument<String>("password") ?: error("missing password")
                            val der = android.util.Base64.decode(pem.replace("-----BEGIN PUBLIC KEY-----", "").replace("-----END PUBLIC KEY-----", "").replace(Regex("\\s"), ""), android.util.Base64.DEFAULT)
                            val key = java.security.KeyFactory.getInstance("RSA").generatePublic(java.security.spec.X509EncodedKeySpec(der))
                            val cipher = javax.crypto.Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
                            cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, key, javax.crypto.spec.OAEPParameterSpec("SHA-256", "MGF1", java.security.spec.MGF1ParameterSpec.SHA256, javax.crypto.spec.PSource.PSpecified.DEFAULT))
                            answer(result, android.util.Base64.encodeToString(cipher.doFinal(password.toByteArray(Charsets.UTF_8)), android.util.Base64.NO_WRAP))
                        }
                        "prepareUpdate" -> {
                            val directory = updateDirectory()
                            require(directory.isDirectory || directory.mkdirs())
                            val version = call.argument<Number>("versionCode")?.toLong() ?: error("missing version")
                            val hash = call.argument<String>("sha256") ?: error("missing digest")
                            answer(result, updateFile(version, hash).absolutePath)
                        }
                        "openWebsite" -> {
                            val uri = Uri.parse(call.argument<String>("url") ?: error("missing url"))
                            require(uri.scheme == "https" && uri.host == "skymoni.com" &&
                                uri.userInfo == null && uri.port in listOf(-1, 443))
                            launch(Intent(Intent.ACTION_VIEW, uri), result, "opened")
                        }
                        "installUpdate" -> install(call, result)
                        else -> activity.runOnUiThread { result.notImplemented() }
                    }
                } catch (_: Exception) {
                    activity.runOnUiThread {
                        result.error("APP_PLATFORM", "操作未完成。请检查系统设置，或重新下载更新。", null)
                    }
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun signatureFlags() = if (Build.VERSION.SDK_INT >= 28)
        PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES

    @Suppress("DEPRECATION")
    private fun packageInfo() = activity.packageManager.getPackageInfo(activity.packageName, signatureFlags())

    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val certificates = if (Build.VERSION.SDK_INT >= 28)
            info.signingInfo?.apkContentsSigners else info.signatures
        require(!certificates.isNullOrEmpty())
        return certificates.map { digest(it.toByteArray()) }.toSet()
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    private fun info(): Map<String, Any> {
        val current = packageInfo()
        val app = activity.applicationInfo
        val installedBytes = (listOf(app.sourceDir) + app.splitSourceDirs.orEmpty())
            .distinct().sumOf { File(it).length() }
        return mapOf(
            "version" to (current.versionName ?: ""),
            "versionCode" to versionCode(current),
            "installedBytes" to installedBytes,
            "packageName" to activity.packageName,
            "sdk" to Build.VERSION.SDK_INT,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "signerSha256" to signers(current).sorted().first(),
            "installMessage" to AppUpdateInstaller.message(activity)
        )
    }

    /** Reserve only the small explicit plugin-control pull zone, not a whole edge. */
    private fun setPluginEdgeExclusion(call: MethodCall, result: MethodChannel.Result) {
        activity.runOnUiThread {
            try {
                val owner = call.argument<String>("owner") ?: error("missing owner")
                require(owner.length in 1..80)
                if (Build.VERSION.SDK_INT >= 29) {
                    val root = activity.window.decorView
                    val values = call.argument<List<Number>>("rect")
                    if (values == null) {
                        if (pluginEdgeOwner == owner) {
                            root.systemGestureExclusionRects = emptyList()
                            pluginEdgeOwner = null
                        }
                    } else {
                        require(values.size == 4)
                        val density = activity.resources.displayMetrics.density
                        val left = values[0].toInt().coerceIn(0, root.width)
                        val top = values[1].toInt().coerceIn(0, root.height)
                        val right = values[2].toInt().coerceIn(left, root.width)
                        val bottom = values[3].toInt().coerceIn(top, root.height)
                        require(right > left && bottom > top)
                        val width = minOf(right - left, (32 * density).toInt())
                        val height = minOf(bottom - top, (200 * density).toInt())
                        val y = top + (bottom - top - height) / 2
                        root.systemGestureExclusionRects = listOf(android.graphics.Rect(right - width, y, right, y + height))
                        pluginEdgeOwner = owner
                    }
                }
                result.success(null)
            } catch (_: Exception) {
                result.error("APP_PLATFORM", "界面控制手势暂不可用。", null)
            }
        }
    }

    private fun updateDirectory() = File(activity.cacheDir, "updates").canonicalFile

    private fun updateFile(version: Long, hash: String): File {
        require(version > 0 && Regex("[0-9a-f]{64}").matches(hash))
        return File(updateDirectory(), "Skivu-$version-${hash.take(16)}.apk").canonicalFile
    }

    @Suppress("DEPRECATION")
    private fun install(call: MethodCall, result: MethodChannel.Result) {
        val file = File(call.argument<String>("path") ?: error("missing path")).canonicalFile
        val expectedHash = call.argument<String>("sha256") ?: error("missing digest")
        val expectedVersion = call.argument<Number>("versionCode")?.toLong() ?: error("missing version")
        require(file == updateFile(expectedVersion, expectedHash) && file.isFile)
        val actualHash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                actualHash.update(buffer, 0, count)
            }
        }
        require(hex(actualHash.digest()) == expectedHash)
        val archive = activity.packageManager.getPackageArchiveInfo(file.path, signatureFlags())
            ?: error("invalid apk")
        val current = packageInfo()
        require(archive.packageName == activity.packageName && versionCode(archive) == expectedVersion)
        require(expectedVersion > versionCode(current) && signers(archive) == signers(current))

        if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
            launch(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${activity.packageName}")), result, "permission_required")
            return
        }
        AppUpdateInstaller.submit(activity, file, expectedVersion)
        answer(result, "opened")
    }

    private fun launch(intent: Intent, result: MethodChannel.Result, status: String) {
        activity.runOnUiThread {
            try {
                activity.startActivity(intent)
                result.success(status)
            } catch (_: Exception) {
                result.error("APP_PLATFORM", "没有可处理此操作的系统应用。", null)
            }
        }
    }

    private fun answer(result: MethodChannel.Result, value: Any) =
        activity.runOnUiThread { result.success(value) }

    private fun digest(bytes: ByteArray) = hex(MessageDigest.getInstance("SHA-256").digest(bytes))
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
