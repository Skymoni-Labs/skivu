package com.skyjjgw.independent.ski.dshgo.phone.background

import android.content.Context
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date
import javax.security.auth.x500.X500Principal
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder

/**
 * The adb RSA identity for self-ADB, persisted in the app's private files (0600). libadb-android
 * needs a real [PrivateKey] + self-signed [Certificate]; BouncyCastle builds the certificate.
 * Generated once, then reused so a paired device stays paired.
 */
class AdbKeyStore(context: Context) {
    private companion object {
        // Display and Android Shell use independent managers but the same private identity.
        val identityLock = Any()
    }

    private val dir = File(context.filesDir, "phone-adb").apply { mkdirs() }
    private val keyFile = File(dir, "adbkey.pk8")
    private val certFile = File(dir, "adbkey.crt")

    @Volatile private var cached: Pair<PrivateKey, Certificate>? = null

    @Synchronized
    fun privateKey(): PrivateKey = load().first

    @Synchronized
    fun certificate(): Certificate = load().second

    private fun load(): Pair<PrivateKey, Certificate> = synchronized(identityLock) {
        cached?.let { return@synchronized it }
        val pair = if (keyFile.isFile && certFile.isFile) read() else generate()
        cached = pair
        pair
    }

    private fun read(): Pair<PrivateKey, Certificate> {
        val key = KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(keyFile.readBytes()))
        val cert = certFile.inputStream().use { CertificateFactory.getInstance("X.509").generateCertificate(it) }
        return key to cert
    }

    private fun generate(): Pair<PrivateKey, Certificate> {
        val generator = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }
        val keyPair = generator.generateKeyPair()
        val now = System.currentTimeMillis()
        val subject = X500Principal("CN=dsh-app")
        val builder = JcaX509v3CertificateBuilder(
            subject,
            BigInteger.valueOf(now),
            Date(now - 60_000L),
            Date(now + 30L * 365 * 24 * 3600 * 1000),
            subject,
            keyPair.public,
        )
        val signer = JcaContentSignerBuilder("SHA256withRSA").build(keyPair.private)
        val cert = JcaX509CertificateConverter().getCertificate(builder.build(signer))
        val keyBytes = PKCS8EncodedKeySpec(keyPair.private.encoded).encoded
        val certBytes = cert.encoded
        var createdKey = false
        var createdCert = false
        try {
            // A failed write can leave two regular files, which load() would
            // thereafter treat as a complete identity. Roll back only names
            // created by this attempt; existing files retain the old policy.
            createdKey = keyFile.createNewFile()
            keyFile.writeBytes(keyBytes)
            createdCert = certFile.createNewFile()
            certFile.writeBytes(certBytes)
        } catch (e: Exception) {
            if (createdKey) runCatching { keyFile.delete() }
            if (createdCert) runCatching { certFile.delete() }
            throw e
        }
        runCatching {
            android.system.Os.chmod(keyFile.path, "600".toInt(8))
            android.system.Os.chmod(certFile.path, "600".toInt(8))
        }
        return keyPair.private to cert
    }
}
