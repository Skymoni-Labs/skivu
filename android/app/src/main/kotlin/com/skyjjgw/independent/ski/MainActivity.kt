package com.skyjjgw.independent.ski

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val chatBackup by lazy { ChatBackupPlatform(this) }
    private val appPlatform by lazy { AppPlatform(this) }
    private val chatAttachment by lazy { ChatAttachmentPlatform(this) }
    private val voice by lazy { VoiceCallPlatform(this) }
    private val pluginFiles by lazy { OpenPluginFilesPlatform(this) }
    private val pluginExternal by lazy { OpenPluginExternalPlatform(this) }
    private val pluginRuntime by lazy { OpenPluginRuntimePlatform(this) }
    private val keyWorker = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        appPlatform.register(flutterEngine.dartExecutor.binaryMessenger)
        chatAttachment.register(flutterEngine.dartExecutor.binaryMessenger)
        voice.register(flutterEngine.dartExecutor.binaryMessenger)
        chatBackup.register(flutterEngine.dartExecutor.binaryMessenger)
        pluginFiles.register(flutterEngine.dartExecutor.binaryMessenger)
        pluginExternal.register(flutterEngine.dartExecutor.binaryMessenger)
        pluginRuntime.register(flutterEngine.dartExecutor.binaryMessenger)
        flutterEngine.platformViewsController.registry.registerViewFactory("skivu/open-plugin", OpenPluginViewFactory(flutterEngine.dartExecutor.binaryMessenger))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "skivu/beta_keystore")
            .setMethodCallHandler { call, result ->
                keyWorker.execute {
                    try {
                        val answer = betaOperation(call)
                        runOnUiThread { result.success(answer) }
                    } catch (_: Exception) {
                        runOnUiThread { result.error("BETA_KEYSTORE", "硬件密钥操作未完成。请确认设备支持硬件证明，且系统时间正确。", null) }
                    }
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        chatBackup.activityResult(requestCode, resultCode, data)
        chatAttachment.onResult(requestCode, resultCode, data)
        pluginFiles.onResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        voice.permissionResult(requestCode, grantResults)
    }
    override fun onStop() { pluginRuntime.close(); voice.pause(); super.onStop() }
    override fun onDestroy() { pluginRuntime.close(); pluginFiles.close(); chatBackup.close(); chatAttachment.close(); appPlatform.close(); voice.close(); super.onDestroy() }

    private fun alias(call: MethodCall): String {
        val value = call.argument<String>("alias") ?: error("missing alias")
        require(Regex("skivu_beta_[0-9a-f-]{36}").matches(value))
        return value
    }

    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun betaOperation(call: MethodCall): Any? = when (call.method) {
        "exists" -> keyStore().containsAlias(alias(call))
        "delete" -> { keyStore().deleteEntry(alias(call)); null }
        "attest" -> {
            val challenge = Base64.decode(call.argument<String>("challenge") ?: error("missing challenge"), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
            require(challenge.size == 32)
            val generatedAlias = "skivu_beta_${UUID.randomUUID()}"
            try {
                val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
                generator.initialize(KeyGenParameterSpec.Builder(generatedAlias, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .setAttestationChallenge(challenge)
                    .build())
                val pair = generator.generateKeyPair()
                val info = KeyFactory.getInstance(pair.private.algorithm, "AndroidKeyStore")
                    .getKeySpec(pair.private, KeyInfo::class.java)
                val hardware = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    info.securityLevel == KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT ||
                        info.securityLevel == KeyProperties.SECURITY_LEVEL_STRONGBOX
                } else {
                    @Suppress("DEPRECATION")
                    info.isInsideSecureHardware
                }
                require(hardware)
                val chain = keyStore().getCertificateChain(generatedAlias)
                require(chain != null && chain.size >= 2)
                mapOf("alias" to generatedAlias, "chain" to chain.map { Base64.encodeToString(it.encoded, Base64.NO_WRAP) }, "label" to "${Build.MANUFACTURER} ${Build.MODEL}".take(64))
            } catch (e: Exception) {
                keyStore().deleteEntry(generatedAlias)
                throw e
            }
        }
        "sign" -> {
            val method = call.argument<String>("method") ?: error("missing method")
            val path = call.argument<String>("path") ?: error("missing path")
            val time = call.argument<Number>("time")?.toLong() ?: error("missing time")
            val nonce = call.argument<String>("nonce") ?: error("missing nonce")
            val bodyHash = call.argument<String>("bodyHash") ?: error("missing hash")
            val tokenHash = call.argument<String>("tokenHash") ?: error("missing token hash")
            require(method in listOf("GET", "POST"))
            require(path.substringBefore('?') in listOf("/api/app-beta/device", "/api/app-beta/chat/completions", "/api/app-beta/responses") && !path.contains('\n') && !path.contains('\r'))
            require(Regex("[A-Za-z0-9_-]{32}").matches(nonce))
            require(Regex("[0-9a-f]{64}").matches(bodyHash) && Regex("[0-9a-f]{64}").matches(tokenHash))
            val payload = "skymoni-app-beta-v1\n$method\n$path\n$time\n$nonce\n$bodyHash\n$tokenHash"
            val privateKey = keyStore().getKey(alias(call), null) as PrivateKey
            val signer = Signature.getInstance("SHA256withECDSA")
            signer.initSign(privateKey)
            signer.update(payload.toByteArray(Charsets.UTF_8))
            Base64.encodeToString(signer.sign(), Base64.NO_WRAP)
        }
        else -> error("unsupported method")
    }
}
