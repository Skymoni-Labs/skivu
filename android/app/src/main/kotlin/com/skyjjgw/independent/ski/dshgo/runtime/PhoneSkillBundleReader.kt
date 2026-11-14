package com.skyjjgw.independent.ski.dshgo.runtime

import com.skyjjgw.independent.ski.dshgo.phone.Json
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneTaskTrace
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardOpenOption.READ
import java.security.MessageDigest

/** Fixed local bundle reader for the existing rootfs worker, not an execution grant.
 * Root generation/worker admission belongs to RuntimeController. Path checks share the installer's
 * boundary: they are not a sandbox against a hostile same-UID process replacing parent paths.
 */
internal object PhoneSkillBundleReader {
    const val MAX_ROUTE_BYTES = 16 * 1024
    const val MAX_REVISION_BYTES = 4 * 1024
    enum class Reason { NAME, PATH, UNAVAILABLE, IO, SIZE, UTF8, MANIFEST, REVISION, INTEGRITY, ROUTE }
    sealed interface Read {
        /** Only immutable parsed data and public-structure digests survive; no source text/arrays. */
        data class Accepted(val route: PhoneSkillRoute.Route, val draftRevision: Long,
            val skillSha256: String, val routeSha256: String) : Read
        data class Rejected(val reason: Reason) : Read
    }
    private class CannotRead(val reason: Reason) : Exception()
    private val NAME = Regex("phone-task-[a-f0-9]{32}")
    private val REVISION = Regex("[a-f0-9]{32}")
    private val DIGEST = Regex("[a-f0-9]{64}")
    private val MANIFEST_KEYS = setOf("schema", "bundleRevision", "draftRevision", "skillSha256", "routeSha256")

    /** A null expectedRevision is discovery only; prepare/start must still bind both digests. */
    fun read(root: File, name: String, expectedRevision: String?,
        descriptors: Map<String, PhoneSkillRoute.Descriptor>): Read {
        if (!NAME.matches(name)) return Read.Rejected(Reason.NAME)
        return try {
            val rootPath = root.canonicalFile.toPath()
            val rawHome = rootPath.resolve("root/.dsh")
            val home = rawHome.toFile().canonicalFile.toPath()
            if (!home.startsWith(rootPath) || !Files.isDirectory(rawHome, NOFOLLOW_LINKS)) {
                return Read.Rejected(Reason.PATH)
            }
            val skills = home.resolve("skills")
            val directory = skills.resolve(name)
            if (!Files.isDirectory(skills, NOFOLLOW_LINKS) || !Files.isDirectory(directory, NOFOLLOW_LINKS)) {
                return Read.Rejected(Reason.PATH)
            }
            // SKILL.md is the publication point. No sidecar is consumed before this file exists.
            val markdown = readRegular(directory.resolve("SKILL.md"), PhoneTaskTrace.MAX_BYTES)
            val manifest = readRegular(directory.resolve("revision.json"), MAX_REVISION_BYTES)
            val route = readRegular(directory.resolve("route.json"), MAX_ROUTE_BYTES)
            validate(name, expectedRevision, markdown, route, manifest, descriptors)
        } catch (failure: CannotRead) { Read.Rejected(failure.reason) }
        catch (_: IOException) { Read.Rejected(Reason.IO) }
        catch (_: SecurityException) { Read.Rejected(Reason.IO) }
    }

    /** Shared with staging: the caller owns these bytes without concurrent mutation for this call.
     * This checks content, not publication. Only read() also checks the final on-disk files.
     */
    fun validate(name: String, expectedRevision: String?, markdown: ByteArray, route: ByteArray,
        manifest: ByteArray, descriptors: Map<String, PhoneSkillRoute.Descriptor>): Read {
        if (markdown.size > PhoneTaskTrace.MAX_BYTES || route.size > MAX_ROUTE_BYTES || manifest.size > MAX_REVISION_BYTES) {
            return Read.Rejected(Reason.SIZE)
        }
        val parsed = try {
            utf8(markdown) // Its exact bytes are hashed; never interpret Markdown as instructions.
            Json.parseStrict(utf8(manifest), maxDepth = 8)
        } catch (_: CharacterCodingException) { return Read.Rejected(Reason.UTF8) }
        catch (_: Json.JsonException) { return Read.Rejected(Reason.MANIFEST) }
        val values = parsed as? Map<*, *> ?: return Read.Rejected(Reason.MANIFEST)
        if (values.keys != MANIFEST_KEYS || values["schema"] != 1L) return Read.Rejected(Reason.MANIFEST)
        val revision = values["bundleRevision"] as? String ?: return Read.Rejected(Reason.MANIFEST)
        val draft = values["draftRevision"] as? Long ?: return Read.Rejected(Reason.MANIFEST)
        val skillDigest = values["skillSha256"] as? String ?: return Read.Rejected(Reason.MANIFEST)
        val routeDigest = values["routeSha256"] as? String ?: return Read.Rejected(Reason.MANIFEST)
        if (!REVISION.matches(revision) || draft < 1 || !DIGEST.matches(skillDigest) || !DIGEST.matches(routeDigest)) {
            return Read.Rejected(Reason.MANIFEST)
        }
        if (expectedRevision != null && expectedRevision != revision) return Read.Rejected(Reason.REVISION)
        if (sha256(markdown) != skillDigest || sha256(route) != routeDigest) return Read.Rejected(Reason.INTEGRITY)
        return when (val result = PhoneSkillRoute.parse(route, name, revision, descriptors)) {
            is PhoneSkillRoute.Read.Accepted -> Read.Accepted(result.route, draft, skillDigest, routeDigest)
            is PhoneSkillRoute.Read.Rejected -> Read.Rejected(Reason.ROUTE)
        }
    }

    private fun readRegular(path: Path, limit: Int): ByteArray {
        if (!Files.isRegularFile(path, NOFOLLOW_LINKS)) throw CannotRead(Reason.UNAVAILABLE)
        FileChannel.open(path, READ, NOFOLLOW_LINKS).use { channel ->
            val out = ByteArrayOutputStream(minOf(limit, 4096))
            val buffer = ByteBuffer.allocate(minOf(limit + 1, 4096))
            while (true) {
                buffer.clear()
                buffer.limit(minOf(buffer.capacity(), limit + 1 - out.size()))
                val count = channel.read(buffer)
                if (count < 0) return out.toByteArray()
                if (out.size() + count > limit) throw CannotRead(Reason.SIZE)
                out.write(buffer.array(), 0, count)
            }
        }
    }

    private fun utf8(bytes: ByteArray): String = Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes)).toString()

    private fun sha256(bytes: ByteArray): String = buildString(64) {
        for (byte in MessageDigest.getInstance("SHA-256").digest(bytes)) {
            val value = byte.toInt() and 255
            append("0123456789abcdef"[value ushr 4])
            append("0123456789abcdef"[value and 15])
        }
    }
}
