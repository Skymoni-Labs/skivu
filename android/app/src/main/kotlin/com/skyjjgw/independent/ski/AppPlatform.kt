package com.skyjjgw.independent.ski

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/** System browser authorization and user-confirmed, same-signer APK updates. */
class AppPlatform(private val activity: Activity) {
    private val worker = Executors.newSingleThreadExecutor()

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "skivu/app_platform").setMethodCallHandler { call, result ->
            worker.execute {
                try {
                    when (call.method) {
                        "info" -> answer(result, info())
                        "prepareUpdate" -> {
                            val directory = updateDirectory()
                            require(directory.isDirectory || directory.mkdirs())
                            answer(result, File(directory, "Skivu-update.apk").absolutePath)
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
        return mapOf(
            "version" to (current.versionName ?: ""),
            "versionCode" to versionCode(current),
            "packageName" to activity.packageName,
            "sdk" to Build.VERSION.SDK_INT,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "signerSha256" to signers(current).sorted().first()
        )
    }

    private fun updateDirectory() = File(activity.cacheDir, "updates").canonicalFile

    @Suppress("DEPRECATION")
    private fun install(call: MethodCall, result: MethodChannel.Result) {
        val file = File(call.argument<String>("path") ?: error("missing path")).canonicalFile
        require(file.parentFile == updateDirectory() && file.name == "Skivu-update.apk" && file.isFile)
        val expectedHash = call.argument<String>("sha256") ?: error("missing digest")
        require(Regex("[0-9a-f]{64}").matches(expectedHash))
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
        val expectedVersion = call.argument<Number>("versionCode")?.toLong() ?: error("missing version")
        require(archive.packageName == activity.packageName && versionCode(archive) == expectedVersion)
        require(expectedVersion > versionCode(current) && signers(archive) == signers(current))

        if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
            launch(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${activity.packageName}")), result, "permission_required")
            return
        }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        launch(intent, result, "opened")
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
