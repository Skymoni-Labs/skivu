package com.skyjjgw.independent.ski

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CancellationException

/** Retrieves only the archive identity pinned by this signed APK. */
internal class VerifiedRuntimeArchive(
    directory: File,
    private val connect: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection },
) {
    private val directory = directory.canonicalFile

    private fun hash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    fun obtain(
        abi: String, sha: String, size: Long, address: String,
        cancelled: () -> Boolean = { false },
        progress: (Long, Long) -> Unit = { _, _ -> },
    ): File {
        require(abi == "arm64-v8a" || abi == "x86_64")
        require(Regex("[0-9a-f]{64}").matches(sha) && size > 0)
        val expected = "https://skymoni.com/skivu-runtime/cloud/$sha/$abi/runtime.bin"
        require(address == expected) { "运行环境下载地址与签名清单不符。" }
        check(directory.mkdirs() || directory.isDirectory)
        require(!Files.isSymbolicLink(directory.toPath()))
        val archive = File(directory, "$sha.bin")
        val partial = File(directory, "$sha.part")
        for (file in listOf(archive, partial)) {
            require(!Files.isSymbolicLink(file.toPath()) && file.canonicalFile.parentFile == directory)
        }
        fun checkCancelled() {
            if (cancelled()) throw CancellationException("环境下载已停止，已下载资源保留。")
        }
        checkCancelled()
        if (archive.isFile) {
            if (archive.length() == size && hash(archive) == sha) return archive
            check(archive.delete())
        }
        if (partial.length() > size) check(partial.delete())
        var offset = if (partial.isFile) partial.length() else 0L
        if (offset < size) {
            val connection = connect(URL(address))
            try {
                connection.instanceFollowRedirects = false
                connection.connectTimeout = 20000
                connection.readTimeout = 60000
                connection.setRequestProperty("Accept-Encoding", "identity")
                if (offset > 0) connection.setRequestProperty("Range", "bytes=$offset-")
                when (val status = connection.responseCode) {
                    200 -> offset = 0
                    206 -> {
                        val range = Regex("bytes ([0-9]+)-([0-9]+)/([0-9]+)")
                            .matchEntire(connection.getHeaderField("Content-Range") ?: "")
                            ?: throw IOException("运行环境分段下载响应无效。")
                        val (first, last, total) = range.destructured
                        require(first.toLong() == offset && last.toLong() == size - 1 && total.toLong() == size)
                    }
                    else -> throw IOException("运行环境下载暂不可用（HTTP $status）。")
                }
                val length = connection.contentLengthLong
                require(length < 0 || length == size - offset) { "运行环境下载大小与签名清单不符。" }
                checkCancelled()
                connection.inputStream.use { input ->
                    FileOutputStream(partial, offset > 0).use { output ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            checkCancelled()
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (count.toLong() > size - offset) throw IOException("运行环境下载超过签名清单大小。")
                            output.write(buffer, 0, count)
                            offset += count
                            progress(offset, size)
                        }
                        output.fd.sync()
                    }
                }
            } finally { connection.disconnect() }
        }
        checkCancelled()
        if (offset != size) throw IOException("运行环境下载中断，重试时将继续下载。")
        if (hash(partial) != sha) {
            check(partial.delete())
            throw IOException("运行环境校验失败，未安装下载内容。")
        }
        check(partial.renameTo(archive))
        return archive
    }
}
