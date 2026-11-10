package com.skyjjgw.independent.ski

import androidx.test.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CancellationException

class VerifiedRuntimeArchiveTest {
    private val bytes = ByteArray(180000) { (it % 251).toByte() }
    private val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private val address get() = "https://skymoni.com/skivu-runtime/cloud/$sha/x86_64/runtime.bin"
    private fun directory(): File = File(InstrumentationRegistry.getTargetContext().cacheDir, "qa-runtime-" + UUID.randomUUID()).apply { check(mkdir()) }
    private class Response(url: URL, val bytes: ByteArray, private val code: Int = 200, private val range: String? = null) : HttpURLConnection(url) {
        override fun connect() {}
        override fun disconnect() {}
        override fun usingProxy() = false
        override fun getResponseCode() = code
        override fun getContentLengthLong() = bytes.size.toLong()
        override fun getHeaderField(name: String?) = if (name == "Content-Range") range else null
        override fun getInputStream() = ByteArrayInputStream(bytes)
    }
    @Test fun fullDownloadIsPinnedAndReusedWithoutAnotherConnection() {
        val dir=directory();var calls=0
        try {
            val source=VerifiedRuntimeArchive(dir) { calls++;Response(it,bytes) }
            val file=source.obtain("x86_64",sha,bytes.size.toLong(),address)
            assertArrayEquals(bytes,file.readBytes())
            assertEquals(file,source.obtain("x86_64",sha,bytes.size.toLong(),address))
            assertEquals(1,calls)
        } finally { dir.deleteRecursively() }
    }
    @Test fun interruptedArchiveResumesOnlyAtItsVerifiedRange() {
        val dir=directory();val retained=70000
        try {
            File(dir,"$sha.part").writeBytes(bytes.copyOfRange(0,retained))
            lateinit var response:Response
            val source=VerifiedRuntimeArchive(dir) { response=Response(it,bytes.copyOfRange(retained,bytes.size),206,"bytes $retained-${bytes.size-1}/${bytes.size}");response }
            val file=source.obtain("x86_64",sha,bytes.size.toLong(),address)
            assertEquals("bytes=$retained-",response.getRequestProperty("Range"))
            assertArrayEquals(bytes,file.readBytes())
        } finally { dir.deleteRecursively() }
    }
    @Test fun ignoredRangeRestartsInsteadOfAppendingDuplicateData() {
        val dir=directory()
        try {
            File(dir,"$sha.part").writeBytes(bytes.copyOfRange(0,100))
            val file=VerifiedRuntimeArchive(dir) { Response(it,bytes) }.obtain("x86_64",sha,bytes.size.toLong(),address)
            assertArrayEquals(bytes,file.readBytes())
        } finally { dir.deleteRecursively() }
    }
    @Test fun cancellationRetainsPartialButNeverPublishesAnArchive() {
        val dir=directory();var stop=false
        try {
            try {
                VerifiedRuntimeArchive(dir) { Response(it,bytes) }.obtain("x86_64",sha,bytes.size.toLong(),address,{stop}) { _,_->stop=true }
                fail("cancelled download succeeded")
            } catch (_:CancellationException) {}
            assertTrue(File(dir,"$sha.part").length() in 1 until bytes.size.toLong())
            assertFalse(File(dir,"$sha.bin").exists())
        } finally { dir.deleteRecursively() }
    }
    @Test fun mismatchedHashAndOriginCannotPublish() {
        val dir=directory();var calls=0
        try {
            val source=VerifiedRuntimeArchive(dir) { calls++;Response(it,ByteArray(bytes.size)) }
            try { source.obtain("x86_64",sha,bytes.size.toLong(),address);fail("bad hash accepted") } catch (_:IOException) {}
            assertFalse(File(dir,"$sha.bin").exists())
            assertFalse(File(dir,"$sha.part").exists())
            try { source.obtain("x86_64",sha,bytes.size.toLong(),"https://example.com/runtime.bin");fail("untrusted origin accepted") } catch (_:IllegalArgumentException) {}
            assertEquals(1,calls)
        } finally { dir.deleteRecursively() }
    }
    @Test fun mismatchedResumeRangePreservesOldPartial() {
        val dir=directory();val prefix=bytes.copyOfRange(0,100)
        try {
            File(dir,"$sha.part").writeBytes(prefix)
            try {
                VerifiedRuntimeArchive(dir) { Response(it,bytes.copyOfRange(100,bytes.size),206,"bytes 99-${bytes.size-1}/${bytes.size}") }.obtain("x86_64",sha,bytes.size.toLong(),address)
                fail("mismatched range accepted")
            } catch (_:IllegalArgumentException) {}
            assertArrayEquals(prefix,File(dir,"$sha.part").readBytes())
        } finally { dir.deleteRecursively() }
    }
}
