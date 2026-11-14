package com.skyjjgw.independent.ski.dshgo.phone.shell

/** Deliberately independent of the virtual-display protocol. */
object ShellProtocol {
    const val REVISION = "dsh.android-shell.v1"
    const val TAG = "dsh.android-shell"
    const val DEFAULT_TIMEOUT_MS = 30_000L
    const val MAX_TIMEOUT_MS = 60_000L
    const val MAX_OUTPUT_BYTES = 64 * 1024
    const val MAX_COMMAND_BYTES = 2048
    const val RPC_TIMEOUT_MS = 5_000L

    fun commandError(command: String): String? = when {
        command.isBlank() -> "invalidCommand"
        command.toByteArray(Charsets.UTF_8).size > MAX_COMMAND_BYTES -> "commandTooLong"
        command.any { c ->
            (c.code in 0..31 && c != '\n' && c != '\r' && c != '\t') ||
                c.code in 127..159 || c.code in 0x202a..0x202e || c.code in 0x2066..0x2069 ||
                c.code == 0x061c || c.code == 0x200e || c.code == 0x200f
        } -> "invalidCommand"
        else -> null
    }

    fun timeoutError(timeoutMs: Long): String? =
        if (timeoutMs !in 100..MAX_TIMEOUT_MS) "invalidTimeout" else null

    fun validUid(backend: String, uid: Int): Boolean = when (backend) {
        "adb" -> uid == 2000
        "shizuku" -> uid == 2000 || uid == 0
        else -> false
    }

    fun failure(code: String, started: Boolean = false): Map<String, Any?> = mapOf(
        "ok" to false, "started" to started, "errorCode" to code,
        "stdout" to "", "stderr" to "", "exitCode" to null,
        "timedOut" to (code == "timeout"), "cancelled" to (code == "cancelled"), "truncated" to false,
    )
}

internal data class ShellSnapshot(
    val jobId: String,
    val started: Boolean,
    val done: Boolean,
    val stdout: String,
    val stderr: String,
    val exitCode: Int?,
    val timedOut: Boolean,
    val cancelled: Boolean,
    val truncated: Boolean,
    val errorCode: String?,
) {
    fun map(): Map<String, Any?> = mapOf(
        "ok" to (errorCode == null), "jobId" to jobId, "started" to started,
        "done" to done, "stdout" to stdout, "stderr" to stderr,
        "exitCode" to exitCode, "timedOut" to timedOut,
        "cancelled" to cancelled, "truncated" to truncated, "errorCode" to errorCode,
    )
}
