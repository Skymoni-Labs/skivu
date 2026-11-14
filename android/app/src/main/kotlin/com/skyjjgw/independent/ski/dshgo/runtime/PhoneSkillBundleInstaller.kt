package com.skyjjgw.independent.ski.dshgo.runtime

import com.skyjjgw.independent.ski.dshgo.phone.Json
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneTaskTrace
import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardOpenOption.CREATE_NEW
import java.nio.file.StandardOpenOption.WRITE
import java.security.MessageDigest

/** New-only bundle publication on the existing rootfs worker. No runtime or execution grant.
 * The caller binds the original root/epoch and checks it with the write's beginCommit permit.
 * Parent-path checks are not a sandbox against a hostile same-UID directory replacement. */
internal object PhoneSkillBundleInstaller {
    data class Identity(val name: String, val revision: String, val draftRevision: Long,
        val skillSha256: String, val routeSha256: String)
    class Document internal constructor(val identity: Identity, markdown: ByteArray, route: ByteArray,
        manifest: ByteArray, descriptors: Map<String, PhoneSkillRoute.Descriptor>) {
        internal val descriptors: Map<String, PhoneSkillRoute.Descriptor> =
            java.util.Collections.unmodifiableMap(LinkedHashMap(descriptors))
        private val markdown = markdown.copyOf()
        private val route = route.copyOf()
        private val manifest = manifest.copyOf()
        // Return owned copies, never expose the frozen storage to a writer/caller.
        internal fun bytes(): List<ByteArray> = listOf(markdown.copyOf(), route.copyOf(), manifest.copyOf())
    }
    sealed interface Frozen {
        data class Ready(val document: Document) : Frozen
        data class Refused(val reason: PhoneSkillBundleReader.Reason) : Frozen
    }
    enum class Publication { PUBLISHED, UNKNOWN }
    enum class Verification { VERIFICATION_UNAVAILABLE, BUNDLE_INVALID, ORIGIN_UNAVAILABLE }
    sealed interface Result {
        data class Saved(val identity: Identity) : Result
        data class Unverified(val identity: Identity, val publication: Publication, val code: Verification) : Result
        enum class Refused : Result { STALE, NO_HOME, CONFLICT, IO, INVALID }
    }
    private val NAME = Regex("phone-task-[a-f0-9]{32}")
    private val REVISION = Regex("[a-f0-9]{32}")

    /** Native frozen data only, never Flutter-supplied paths, Markdown or descriptor permissions. */
    fun freeze(name: String, revision: String, draftRevision: Long, markdown: ByteArray, route: ByteArray,
        descriptors: Map<String, PhoneSkillRoute.Descriptor>): Frozen {
        if (!NAME.matches(name)) return Frozen.Refused(PhoneSkillBundleReader.Reason.NAME)
        if (!REVISION.matches(revision) || draftRevision < 1) return Frozen.Refused(PhoneSkillBundleReader.Reason.MANIFEST)
        if (markdown.size > PhoneTaskTrace.MAX_BYTES || route.size > PhoneSkillBundleReader.MAX_ROUTE_BYTES) {
            return Frozen.Refused(PhoneSkillBundleReader.Reason.SIZE)
        }
        val skillBytes = markdown.copyOf()
        val routeBytes = route.copyOf()
        val identity = Identity(name, revision, draftRevision, digest(skillBytes), digest(routeBytes))
        val manifest = Json.write(mapOf("schema" to 1, "bundleRevision" to revision,
            "draftRevision" to draftRevision, "skillSha256" to identity.skillSha256,
            "routeSha256" to identity.routeSha256)).toByteArray(Charsets.UTF_8)
        val trusted = java.util.Collections.unmodifiableMap(LinkedHashMap(descriptors))
        return when (val read = PhoneSkillBundleReader.validate(name, revision, skillBytes, routeBytes, manifest, trusted)) {
            is PhoneSkillBundleReader.Read.Accepted -> Frozen.Ready(Document(identity, skillBytes, routeBytes, manifest, trusted))
            is PhoneSkillBundleReader.Read.Rejected -> Frozen.Refused(read.reason)
        }
    }

    fun install(root: File, document: Document, canStage: () -> Boolean, beginCommit: () -> Boolean): Result {
        val identity = document.identity
        // Reuse the reader validator even for an internally constructed Document.
        if (!NAME.matches(identity.name)) return Result.Refused.INVALID
        val bytes = document.bytes()
        val validated = PhoneSkillBundleReader.validate(identity.name, identity.revision,
            bytes[0], bytes[1], bytes[2], document.descriptors)
        if (validated !is PhoneSkillBundleReader.Read.Accepted || !matches(identity, validated)) return Result.Refused.INVALID
        var ownedDirectory: Path? = null
        val stages = ArrayList<Path>(3)
        var attemptedPublication = false
        var published = false
        try {
            if (!canStage()) return Result.Refused.STALE
            val rootPath = root.canonicalFile.toPath()
            val rawHome = rootPath.resolve("root/.dsh")
            val home = rawHome.toFile().canonicalFile.toPath()
            if (!home.startsWith(rootPath) || !Files.isDirectory(rawHome, NOFOLLOW_LINKS)) return Result.Refused.NO_HOME
            val skills = home.resolve("skills")
            try { Files.createDirectory(skills) } catch (_: FileAlreadyExistsException) {
                if (!Files.isDirectory(skills, NOFOLLOW_LINKS)) return Result.Refused.NO_HOME
            }
            val directory = skills.resolve(identity.name)
            try { Files.createDirectory(directory) } catch (_: FileAlreadyExistsException) { return Result.Refused.CONFLICT }
            ownedDirectory = directory
            for ((index, name) in listOf(".SKILL.tmp", ".route.tmp", ".revision.tmp").withIndex()) {
                val stage = directory.resolve(name)
                FileChannel.open(stage, CREATE_NEW, WRITE).use { channel ->
                    stages.add(stage) // Only after we actually created this file.
                    val buffer = ByteBuffer.wrap(bytes[index])
                    while (buffer.hasRemaining()) channel.write(buffer)
                    channel.force(true)
                }
            }
            Files.move(stages[1], directory.resolve("route.json"))
            Files.move(stages[2], directory.resolve("revision.json"))
            // Sidecars alone are not published. Cancellation may still win this short permit.
            if (!beginCommit()) return Result.Refused.STALE
            attemptedPublication = true
            Files.move(stages[0], directory.resolve("SKILL.md"))
            published = true
            return when (val read = PhoneSkillBundleReader.read(root, identity.name, identity.revision, document.descriptors)) {
                is PhoneSkillBundleReader.Read.Accepted -> if (matches(identity, read)) Result.Saved(identity)
                    else Result.Unverified(identity, Publication.PUBLISHED, Verification.BUNDLE_INVALID)
                is PhoneSkillBundleReader.Read.Rejected -> Result.Unverified(identity, Publication.PUBLISHED,
                    if (read.reason == PhoneSkillBundleReader.Reason.IO) Verification.VERIFICATION_UNAVAILABLE
                    else Verification.BUNDLE_INVALID)
            }
        } catch (_: FileAlreadyExistsException) {
            // A target found before a default move is a conflict, not permission to replace it.
            if (!published) return Result.Refused.CONFLICT
            return Result.Unverified(identity, Publication.PUBLISHED, Verification.VERIFICATION_UNAVAILABLE)
        } catch (_: Exception) {
            if (published) return Result.Unverified(identity, Publication.PUBLISHED, Verification.VERIFICATION_UNAVAILABLE)
            if (attemptedPublication) return Result.Unverified(identity, Publication.UNKNOWN, Verification.VERIFICATION_UNAVAILABLE)
            return Result.Refused.IO
        } finally {
            for (stage in stages) runCatching { Files.deleteIfExists(stage) }
            // Never recursively delete sidecars or another writer's content; only our empty dir.
            if (!attemptedPublication) ownedDirectory?.let { runCatching { Files.delete(it) } }
        }
    }

    internal fun matches(identity: Identity, read: PhoneSkillBundleReader.Read.Accepted): Boolean =
        read.route.skillName == identity.name && read.route.revision == identity.revision &&
            read.draftRevision == identity.draftRevision &&
            read.skillSha256 == identity.skillSha256 && read.routeSha256 == identity.routeSha256

    private fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(java.util.Locale.ROOT, it.toInt() and 255) }
}
