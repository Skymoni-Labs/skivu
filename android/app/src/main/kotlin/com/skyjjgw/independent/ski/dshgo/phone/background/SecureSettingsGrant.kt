package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.R

/**
 * WRITE_SECURE_SETTINGS for 自动恢复无障碍 ([com.skyjjgw.independent.ski.dshgo.phone.a11y.A11yKeeper]):
 * which one-tap way to it the shell-uid engine offers right now, and the command for granting it
 * by hand (its `pm grant` part also runs as is in a root shell).
 */
object SecureSettingsGrant {
    const val PERMISSION = "android.permission.WRITE_SECURE_SETTINGS"

    // `a11yKeeper.path` in the `dsh/phone` status.
    const val GRANTED = "granted"

    /** Shizuku runs and has let us in: the tap grants. */
    const val SHIZUKU = "shizuku"

    /** Self-ADB is paired, and wireless debugging isn't known to be off: the tap connects and grants. */
    const val ADB = "adb"

    /** Shizuku runs but hasn't let us in: the tap asks it first, then grants. */
    const val SHIZUKU_PERMISSION = "shizukuPermission"

    // Names exposed only by background.privileged v1; legacy a11yKeeper.path stays unchanged.
    const val SUI = "sui"
    const val SUI_PERMISSION = "suiPermission"
    const val ROOT = "root"

    /** Neither is set up (不打扰模式's page sets up both). */
    const val SETUP = "setup"

    fun path(granted: Boolean, shizuku: ShizukuStatus, adb: AdbStatus): String = when {
        granted -> GRANTED
        shizuku.running && shizuku.granted -> SHIZUKU
        adb.paired && adb.wirelessDebugging != false -> ADB
        shizuku.running -> SHIZUKU_PERMISSION
        else -> SETUP
    }

    fun command(packageName: String): String = "adb shell pm grant $packageName $PERMISSION"

    /** One grant attempt, retained before a temporary channel is normally closed. */
    enum class Attempt { UNAVAILABLE, DENIED, EXECUTED, FAILED, CANCELLED }

    /** RPC acknowledgement is not a permission receipt; the caller must read permission back. */
    fun attempt(ok: Boolean, error: String?): Attempt = when {
        ok -> Attempt.EXECUTED
        error == "systemOperationDenied" -> Attempt.DENIED
        error == "deviceUnavailable" -> Attempt.UNAVAILABLE
        else -> Attempt.FAILED
    }

    /** A true permission readback wins even when this attempt failed or was cancelled. */
    fun failureReason(granted: Boolean, attempt: Attempt): Int? = if (granted) null else when (attempt) {
        Attempt.UNAVAILABLE -> R.string.a11y_keeper_grant_unavailable
        Attempt.DENIED -> R.string.a11y_keeper_grant_denied
        Attempt.EXECUTED -> R.string.a11y_keeper_grant_not_acquired
        Attempt.FAILED -> R.string.a11y_keeper_grant_failed
        Attempt.CANCELLED -> R.string.background_selection_cancelled
    }

    /** `background.privileged.grantPath`: a chosen root never falls back to another provider. */
    fun privilegedPath(granted: Boolean, shizuku: ShizukuStatus, adb: AdbStatus, rootSelected: Boolean, rootConnected: Boolean): String {
        val legacy = path(granted, shizuku, adb)
        return when {
            granted -> GRANTED
            rootSelected -> if (rootConnected) ROOT else SETUP
            shizuku.provider != ShizukuStatus.SUI -> legacy
            legacy == SHIZUKU -> SUI
            legacy == SHIZUKU_PERMISSION -> SUI_PERMISSION
            else -> legacy
        }
    }
}
