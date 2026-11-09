package com.skyjjgw.independent.ski

import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import android.os.Handler
import android.os.Looper
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature

/** Existing hardware-bound credentials can sign in a headless run; no new pairing is created. */
object TaskBetaKeys {
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger,"skivu/beta_keystore").setMethodCallHandler { call,result ->
            TaskPlatform.worker.execute {
                try {
                    val alias=call.argument<String>("alias") ?: error("缺少设备密钥。")
                    require(Regex("skivu_beta_[0-9a-f-]{36}").matches(alias))
                    val keys=KeyStore.getInstance("AndroidKeyStore").apply {load(null)}
                    val answer: Any=when(call.method) {
                        "exists"->keys.containsAlias(alias)
                        "sign"->{
                            val method=call.argument<String>("method") ?: error("缺少方法")
                            val path=call.argument<String>("path") ?: error("缺少路径")
                            val time=call.argument<Number>("time")?.toLong() ?: error("缺少时间")
                            val nonce=call.argument<String>("nonce") ?: error("缺少随机数")
                            val body=call.argument<String>("bodyHash") ?: error("缺少摘要")
                            val token=call.argument<String>("tokenHash") ?: error("缺少摘要")
                            require(method in listOf("GET","POST") && path.substringBefore('?') in listOf("/api/app-beta/device","/api/app-beta/chat/completions","/api/app-beta/responses") && !path.contains('\n') && !path.contains('\r'))
                            require(Regex("[A-Za-z0-9_-]{32}").matches(nonce) && Regex("[0-9a-f]{64}").matches(body) && Regex("[0-9a-f]{64}").matches(token))
                            val payload="skymoni-app-beta-v1\n$method\n$path\n$time\n$nonce\n$body\n$token"
                            val signer=Signature.getInstance("SHA256withECDSA");signer.initSign(keys.getKey(alias,null) as PrivateKey);signer.update(payload.toByteArray(Charsets.UTF_8));Base64.encodeToString(signer.sign(),Base64.NO_WRAP)
                        }
                        else->error("后台不会创建或删除设备配对。请在应用中配置。")
                    }
                    Handler(Looper.getMainLooper()).post {result.success(answer)}
                } catch(e: Exception) {Handler(Looper.getMainLooper()).post {result.error("BETA_KEYSTORE",e.message,null)}}
            }
        }
    }
}
