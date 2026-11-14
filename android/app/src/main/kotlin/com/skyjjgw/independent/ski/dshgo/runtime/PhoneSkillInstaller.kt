package com.skyjjgw.independent.ski.dshgo.runtime

import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillDraft
import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardOpenOption.CREATE_NEW
import java.nio.file.StandardOpenOption.WRITE

/** One explicit save of a rendered, immutable local draft. Never accepts Markdown from Flutter. */
internal class PhoneSkillWrite(val document: PhoneSkillDraft.Ready,
    val bundle: PhoneSkillBundleInstaller.Document? = null) {
    enum class Phase { STAGING, COMMITTING, FINISHED, CANCELLED }
    private var phase = Phase.STAGING
    private var outcome: PhoneSkillInstallResult? = null
    /** Small immutable receipt metadata; no Markdown or route bytes. */
    data class SaveBinding(val identity: PhoneSkillBundleInstaller.Identity,
        val origin: RuntimeController.PhoneSkillOrigin?,
        val descriptors: Map<String, com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute.Descriptor>)
    private var binding = bundle?.let { SaveBinding(it.identity, null, it.descriptors) }
    @Synchronized fun bindSaveOrigin(origin: RuntimeController.PhoneSkillOrigin): RuntimeController.PhoneSkillOrigin {
        val current = binding ?: return origin // Phase1 has no bundle query.
        current.origin?.let { return it } // Never borrow a later Runtime/root for this write.
        binding = current.copy(origin = origin)
        return origin
    }
    @Synchronized fun saveBinding(): SaveBinding? = binding

    @Synchronized fun canStage(): Boolean = phase == Phase.STAGING
    @Synchronized fun phase(): Phase = phase

    /** Short permission boundary. File IO must run after this monitor is released. */
    @Synchronized fun beginCommit(): Boolean {
        if (phase != Phase.STAGING) return false
        phase = Phase.COMMITTING
        return true
    }

    /** Once committing, closing the editor is not a promise to undo a saved file. */
    @Synchronized fun cancel(): Boolean {
        if (phase != Phase.STAGING) return false
        phase = Phase.CANCELLED
        return true
    }

    @Synchronized fun finish(result: PhoneSkillInstallResult) {
        if (outcome != null) return
        outcome = result
        phase = Phase.FINISHED
    }

    @Synchronized fun result(): PhoneSkillInstallResult? = outcome
}

internal sealed interface PhoneSkillInstallResult {
    data class Saved(val name: String) : PhoneSkillInstallResult {
        val relativePath: String get() = "skills/$name/SKILL.md"
    }
    data class BundleSaved(val identity: PhoneSkillBundleInstaller.Identity) : PhoneSkillInstallResult
    data class BundleUnverified(val identity: PhoneSkillBundleInstaller.Identity,
        val publication: PhoneSkillBundleInstaller.Publication, val code: PhoneSkillBundleInstaller.Verification) : PhoneSkillInstallResult
    enum class Refused : PhoneSkillInstallResult { STALE, NO_HOME, CONFLICT, IO }
}

/**
 * A new user skill, on RuntimeController's rootfs worker. Never updates a managed/user directory.
 * The final directory is exclusively created; a same-directory move publishes the staged SKILL.md.
 * Default move checks for an existing target; ATOMIC_MOVE would allow replacing it.
 * Root swaps share the worker; containment checks do not sandbox a hostile same-UID process
 * concurrently replacing parent directories (the same boundary as ManagedSkillInstaller).
 */
internal object PhoneSkillInstaller {
    fun install(
        root: File,
        document: PhoneSkillDraft.Ready,
        canStage: () -> Boolean,
        beginCommit: () -> Boolean,
    ): PhoneSkillInstallResult {
        var ownedDirectory: Path? = null
        var stagedFile: Path? = null
        var published = false
        try {
            if (!canStage()) return PhoneSkillInstallResult.Refused.STALE
            val rootPath = root.canonicalFile.toPath()
            val home = File(root, "root/.dsh").canonicalFile.toPath()
            if (!home.startsWith(rootPath) || !Files.isDirectory(home)) return PhoneSkillInstallResult.Refused.NO_HOME
            val skills = home.resolve("skills")
            try { Files.createDirectory(skills) } catch (_: FileAlreadyExistsException) {
                if (!Files.isDirectory(skills, NOFOLLOW_LINKS)) return PhoneSkillInstallResult.Refused.NO_HOME
            }
            val directory = skills.resolve(document.skillName)
            try { Files.createDirectory(directory) } catch (_: FileAlreadyExistsException) {
                return PhoneSkillInstallResult.Refused.CONFLICT
            }
            ownedDirectory = directory
            val stage = directory.resolve(".SKILL.tmp")
            FileChannel.open(stage, CREATE_NEW, WRITE).use { channel ->
                stagedFile = stage
                val bytes = ByteBuffer.wrap(document.markdown.toByteArray(Charsets.UTF_8))
                while (bytes.hasRemaining()) channel.write(bytes)
                channel.force(true)
            }
            // Runtime generation and the explicit draft permission are checked together here.
            if (!beginCommit()) return PhoneSkillInstallResult.Refused.STALE
            Files.move(stage, directory.resolve("SKILL.md"))
            published = true
            return PhoneSkillInstallResult.Saved(document.skillName)
        } catch (_: FileAlreadyExistsException) {
            return PhoneSkillInstallResult.Refused.CONFLICT
        } catch (_: Exception) {
            // No paths, content, tokens or filesystem exception text enter diagnostics.
            return PhoneSkillInstallResult.Refused.IO
        } finally {
            stagedFile?.let { runCatching { Files.deleteIfExists(it) } }
            // Delete only our empty directory. Never recursively remove another writer's files.
            if (!published) ownedDirectory?.let { runCatching { Files.delete(it) } }
        }
    }
}
