package com.skyjjgw.independent.ski

import android.content.Context
import android.system.Os
import org.json.JSONObject
import java.io.*
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.GZIPInputStream

/** Installs the APK's hash-pinned archive. Never extracts across symlink boundaries. */
class CloudRuntimeInstaller(private val context: Context) {
    private val abi = android.os.Build.SUPPORTED_ABIS.first { it == "arm64-v8a" || it == "x86_64" }
    private fun text(bytes: ByteArray): String = Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT).decode(java.nio.ByteBuffer.wrap(bytes)).toString()
    private fun field(block: ByteArray, offset: Int, length: Int): String =
        text(block.copyOfRange(offset, offset + length).takeWhile { it != 0.toByte() }.toByteArray())
    private fun octal(value: String): Long {
        val cleaned = value.trim(' ', '\u0000')
        require(cleaned.isEmpty() || Regex("[0-7]+").matches(cleaned))
        return if (cleaned.isEmpty()) 0 else cleaned.toLong(8)
    }
    private fun path(name: String): String {
        val value = name.removePrefix("./").removeSuffix("/")
        require(value.isNotEmpty() && value.length <= 2000 && !value.startsWith('/') && !value.contains('\\'))
        require(value.none { it.code < 32 || it.code == 127 })
        require(value.split('/').none { it.isEmpty() || it == "." || it == ".." })
        return value
    }
    private fun inside(root: File, file: File) {
        require(file.canonicalPath == root.canonicalPath || file.canonicalPath.startsWith(root.canonicalPath + File.separator))
    }
    private fun exact(input: InputStream, count: Int): ByteArray {
        val data = ByteArray(count); var position = 0
        while (position < count) { val n = input.read(data, position, count-position); if (n < 0) throw EOFException(); position += n }
        return data
    }
    private fun skip(input: InputStream, count: Long) {
        var left = count
        while (left > 0) { val n = input.skip(left); if (n > 0) left -= n else { if (input.read() < 0) throw EOFException(); left-- } }
    }
    private fun pax(bytes: ByteArray): Map<String, String> {
        val out = mutableMapOf<String, String>(); var start = 0
        while (start < bytes.size) {
            var space = start
            while (space < bytes.size && bytes[space] != 32.toByte()) space++
            require(space < bytes.size && space-start in 1..8)
            val length = text(bytes.copyOfRange(start, space)).toInt()
            require(length > space-start+2 && start+length <= bytes.size && bytes[start+length-1] == 10.toByte())
            val record = text(bytes.copyOfRange(space+1, start+length-1))
            val equal = record.indexOf('='); require(equal > 0)
            val key = record.substring(0,equal)
            if (key == "path" || key == "linkpath") { require(!out.containsKey(key)); out[key] = record.substring(equal+1) }
            start += length
        }
        return out
    }

    private fun removeStaging(staging:File) {
        java.nio.file.Files.walkFileTree(staging.toPath(), object : java.nio.file.SimpleFileVisitor<java.nio.file.Path>() {
            override fun visitFile(file:java.nio.file.Path, attrs:java.nio.file.attribute.BasicFileAttributes):java.nio.file.FileVisitResult {
                java.nio.file.Files.delete(file);return java.nio.file.FileVisitResult.CONTINUE
            }
            override fun postVisitDirectory(dir:java.nio.file.Path,error:IOException?):java.nio.file.FileVisitResult {
                if(error!=null)throw error
                java.nio.file.Files.delete(dir);return java.nio.file.FileVisitResult.CONTINUE
            }
        })
    }
    @Synchronized fun install(progress:(Int)->Unit={}): File {
        android.util.Log.i("SkivuRuntime","archive metadata")
        val metadata = JSONObject(context.assets.open("cloud-runtime/$abi/runtime.json").bufferedReader().use { it.readText() })
        val sha = metadata.getString("sha256"); require(Regex("[0-9a-f]{64}").matches(sha))
        val base = File(context.filesDir,"runtimes").apply { mkdirs() }
        require(!java.nio.file.Files.isSymbolicLink(base.toPath()) && base.canonicalFile==File(context.filesDir.canonicalFile,"runtimes"))
        // Abandoned installer-owned staging only; published roots, projects and
        // home are preserved. walkFileTree never follows symlinks.
        base.listFiles()?.filter { Regex("stage-[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}").matches(it.name) }?.forEach { removeStaging(it) }
        val target = File(base, sha)
        val marker = File(target,".installed")
        if (marker.isFile && marker.readText() == sha) return target
        require(!target.exists())
        android.util.Log.i("SkivuRuntime","archive verify")
        val digest = MessageDigest.getInstance("SHA-256")
        context.assets.open("cloud-runtime/$abi/runtime.bin").use { input ->
            val buffer=ByteArray(65536); while (true) { val n=input.read(buffer); if(n<0) break; digest.update(buffer,0,n) }
        }
        require(digest.digest().joinToString("") { "%02x".format(it) } == sha)
        android.util.Log.i("SkivuRuntime","archive extracting")
        val staging=File(base,"stage-"+UUID.randomUUID()).apply { check(mkdir()) }
        try {
            val names=HashSet<String>(); var total=0L; var extended=emptyMap<String,String>()
            GZIPInputStream(context.assets.open("cloud-runtime/$abi/runtime.bin"),65536).use { input ->
                while (true) {
                    val header=exact(input,512)
                    if(header.all { it==0.toByte() }) break
                    val checksum=octal(field(header,148,8))
                    val actual=header.indices.sumOf { if(it in 148..155) 32L else (header[it].toInt() and 255).toLong() }
                    require(checksum==actual)
                    val size=octal(field(header,124,12)); require(size in 0..(300L*1024*1024))
                    val type=header[156].toInt().toChar()
                    if(type=='x') {
                        require(size<=65536 && extended.isEmpty()); extended=pax(exact(input,size.toInt()))
                        skip(input,(512-size%512)%512); continue
                    }
                    var name=field(header,0,100)
                    val prefix=field(header,345,155); if(prefix.isNotEmpty()) name="$prefix/$name"
                    name=extended["path"] ?: name
                    val link=extended["linkpath"] ?: field(header,157,100)
                    extended=emptyMap()
                    if(name=="./" || name==".") { require(type=='5' && size==0L); continue }
                    val normalized=path(name); require(names.add(normalized) && names.size<=100000)
                    if(names.size%2000==0) progress(names.size)
                    val dest=File(staging,normalized)
                    dest.parentFile!!.mkdirs(); inside(staging,dest.parentFile!!)
                    when(type) {
                        '0','\u0000' -> {
                            require(!dest.exists()); total+=size; require(total<=2L*1024*1024*1024)
                            FileOutputStream(dest).use { output ->
                                val buffer=ByteArray(65536); var left=size
                                while(left>0) { val n=input.read(buffer,0,minOf(left,buffer.size.toLong()).toInt()); if(n<0) throw EOFException(); output.write(buffer,0,n); left-=n }
                            }
                            Os.chmod(dest.absolutePath, (octal(field(header,100,8)).toInt() and 511) or 384)
                        }
                        '5' -> { require(size==0L); require(dest.mkdirs() || dest.isDirectory); inside(staging,dest) }
                        '2' -> {
                            require(size==0L && link.isNotEmpty() && !link.startsWith('/') && !link.contains('\\') && link.none { it.code<32 })
                            inside(staging,File(dest.parentFile,link)); require(!dest.exists())
                            Os.symlink(link,dest.absolutePath)
                        }
                        else -> error("unsupported archive entry")
                    }
                    skip(input,(512-size%512)%512)
                }
            }
            File(staging,".installed").writeText(sha)
            check(staging.renameTo(target))
            android.util.Log.i("SkivuRuntime","archive ready")
            return target
        } catch (error: Throwable) {
            // Unique staging path was created here and all links were confined.
            removeStaging(staging)
            throw error
        }
    }
}
