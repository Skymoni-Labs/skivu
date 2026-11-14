package com.skyjjgw.independent.ski.dshgo.runtime

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.io.File
import java.util.concurrent.Executors
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute

/** Skivu's native-phone host lifecycle, NOT a second DSH/model/chat runtime.
 * Skill publication/readback below is the original dsh-go implementation.
 * The source root and generation are owned by the native bridge launch.
 */
class RuntimeController private constructor(context: Context) {
    private enum class Phase { RUNNING, STOPPED }
    private val main=Handler(Looper.getMainLooper())
    private val worker=Executors.newSingleThreadExecutor { r -> Thread(r,"skivu-phone-skills").apply { isDaemon=true } }
    private val installer=object { val rootfs=File(context.filesDir,"dsh-go-phone-host").apply { File(this,"root/.dsh/skills").mkdirs() } }
    @Volatile private var phase=Phase.STOPPED
    @Volatile private var runGen=0
    @Volatile private var stopGen=-1
    @Volatile private var phoneSkillStoppedGeneration=-1
    private val runSafe=false
    private val resetting=false
    @Synchronized fun activate() { runGen++;phase=Phase.RUNNING }
    @Synchronized fun retire() { stopGen=runGen; phase=Phase.STOPPED }
    /** Original Runtime/root captured at the trusted local button request, never after queueing.
     * This is a read origin, not an invocation or permission to execute a phone action. */
    internal class PhoneSkillOrigin internal constructor(
        internal val runtime: RuntimeController,
        internal val generation: Int,
        internal val root: File,
    )

    @Synchronized internal fun capturePhoneSkillOrigin(): PhoneSkillOrigin? =
        if (phase == Phase.RUNNING && !runSafe && !resetting && stopGen < runGen &&
            phoneSkillStoppedGeneration < runGen) PhoneSkillOrigin(this, runGen, installer.rootfs) else null

    // Read-only generation fence for physical action gates; never acquires the Runtime monitor.
    // The final generation read rejects mixed fields across an unexpected-exit/restart.
    internal fun phoneSkillOriginCurrent(origin: PhoneSkillOrigin): Boolean =
        origin.runtime === this && phase == Phase.RUNNING && !runSafe && !resetting &&
            runGen == origin.generation && stopGen < origin.generation &&
            phoneSkillStoppedGeneration < origin.generation && runGen == origin.generation

    /** Uses the existing rootfs worker. The only descriptor input is the native reviewed table;
     * private UI/JSON never supplies it. An empty table has no executable App registration.
     * Caller keeps this same origin for pending/claim checks, outside registry/Tasks locks. */
    internal fun readPhoneSkillBundle(origin: PhoneSkillOrigin, name: String, revision: String?,
        descriptors: Map<String, PhoneSkillRoute.Descriptor>,
        onDone: (PhoneSkillBundleReader.Read) -> Unit) {
        val reviewed = java.util.Collections.unmodifiableMap(LinkedHashMap(descriptors))
        worker.execute {
            val result = if (!phoneSkillOriginCurrent(origin)) {
                PhoneSkillBundleReader.Read.Rejected(PhoneSkillBundleReader.Reason.UNAVAILABLE)
            } else PhoneSkillBundleReader.read(origin.root, name, revision, reviewed)
            main.post {
                onDone(if (phoneSkillOriginCurrent(origin)) result
                    else PhoneSkillBundleReader.Read.Rejected(PhoneSkillBundleReader.Reason.UNAVAILABLE))
            }
        }
    }

    /** User-selected phone draft only. Lock order: Controller -> write; no IO under either. */
    internal fun savePhoneSkill(write: PhoneSkillWrite, onDone: (PhoneSkillInstallResult) -> Unit) {
        val origin = capturePhoneSkillOrigin()?.let(write::bindSaveOrigin)
        if (origin == null) {
            val result = PhoneSkillInstallResult.Refused.STALE
            write.finish(result)
            main.post { onDone(result) }
            return
        }
        try { worker.execute {
            fun current(): Boolean = phoneSkillOriginCurrent(origin)
            var result: PhoneSkillInstallResult? = null
            try {
                val bundle = write.bundle
                result = if (bundle == null) PhoneSkillInstaller.install(origin.root, write.document,
                    canStage = { synchronized(this) { current() && write.canStage() } },
                    beginCommit = { synchronized(this) { current() && write.beginCommit() } },
                ) else when (val saved = PhoneSkillBundleInstaller.install(origin.root, bundle,
                    canStage = { synchronized(this) { current() && write.canStage() } },
                    beginCommit = { synchronized(this) { current() && write.beginCommit() } },
                )) {
                    is PhoneSkillBundleInstaller.Result.Saved -> PhoneSkillInstallResult.BundleSaved(saved.identity)
                    is PhoneSkillBundleInstaller.Result.Unverified -> PhoneSkillInstallResult.BundleUnverified(
                        saved.identity, saved.publication, saved.code)
                    PhoneSkillBundleInstaller.Result.Refused.STALE -> PhoneSkillInstallResult.Refused.STALE
                    PhoneSkillBundleInstaller.Result.Refused.NO_HOME -> PhoneSkillInstallResult.Refused.NO_HOME
                    PhoneSkillBundleInstaller.Result.Refused.CONFLICT -> PhoneSkillInstallResult.Refused.CONFLICT
                    PhoneSkillBundleInstaller.Result.Refused.IO, PhoneSkillBundleInstaller.Result.Refused.INVALID -> PhoneSkillInstallResult.Refused.IO
                }
            } finally {
                // Physical completion precedes any UI callback. A permit already consumed is
                // not proof of zero publication when the operation fails without a result.
                val finished = result ?: write.bundle?.takeIf { write.phase() == PhoneSkillWrite.Phase.COMMITTING }?.let {
                    PhoneSkillInstallResult.BundleUnverified(it.identity, PhoneSkillBundleInstaller.Publication.UNKNOWN,
                        PhoneSkillBundleInstaller.Verification.VERIFICATION_UNAVAILABLE)
                } ?: PhoneSkillInstallResult.Refused.IO
                write.finish(finished)
                main.post { onDone(finished) }
            }
        } } catch (_: java.util.concurrent.RejectedExecutionException) {
            // Submission failed: this job cannot enter the reader/installer.
            val result = PhoneSkillInstallResult.Refused.IO
            write.finish(result)
            main.post { onDone(result) }
        }
    }

    /** Original worker/root only. Completion runs in the physical job's finally, NOT on main.
     * The caller clears its Receipt pin there before separately delivering UI callbacks. */
    internal fun checkPhoneSkillSave(binding: PhoneSkillWrite.SaveBinding,
        publication: PhoneSkillBundleInstaller.Publication, onDone: (PhoneSkillInstallResult) -> Unit) {
        fun unverified(code: PhoneSkillBundleInstaller.Verification) =
            PhoneSkillInstallResult.BundleUnverified(binding.identity, publication, code)
        try { worker.execute {
            var result: PhoneSkillInstallResult = unverified(PhoneSkillBundleInstaller.Verification.VERIFICATION_UNAVAILABLE)
            try {
                val origin = binding.origin
                result = if (origin == null || !phoneSkillOriginCurrent(origin)) {
                    unverified(PhoneSkillBundleInstaller.Verification.ORIGIN_UNAVAILABLE)
                } else {
                    val identity = binding.identity
                    val read = PhoneSkillBundleReader.read(origin.root, identity.name, identity.revision, binding.descriptors)
                    when {
                        !phoneSkillOriginCurrent(origin) -> unverified(PhoneSkillBundleInstaller.Verification.ORIGIN_UNAVAILABLE)
                        read is PhoneSkillBundleReader.Read.Accepted && PhoneSkillBundleInstaller.matches(identity, read) ->
                            PhoneSkillInstallResult.BundleSaved(identity)
                        read is PhoneSkillBundleReader.Read.Rejected && read.reason == PhoneSkillBundleReader.Reason.IO ->
                            unverified(PhoneSkillBundleInstaller.Verification.VERIFICATION_UNAVAILABLE)
                        else -> unverified(PhoneSkillBundleInstaller.Verification.BUNDLE_INVALID)
                    }
                }
            } finally { onDone(result) }
        } } catch (_: java.util.concurrent.RejectedExecutionException) {
            onDone(unverified(PhoneSkillBundleInstaller.Verification.ORIGIN_UNAVAILABLE))
        }
    }

    companion object {
        @Volatile private var instance:RuntimeController?=null
        fun get(context:Context):RuntimeController=instance?:synchronized(this){instance?:RuntimeController(context.applicationContext).also{instance=it}}
    }
}
