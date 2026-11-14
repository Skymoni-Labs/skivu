package com.skyjjgw.independent.ski.dshgo.phone

/** The native backend is selected only by App settings, never by model arguments. */
fun interface PhoneShellExecutor {
    fun execute(ownerId: Long, command: String, timeoutMs: Long, stillWanted: () -> Boolean,
                confirm: (String, Int) -> Decision): Map<String, Any?>
}

/** A separate one-command grant: UI app/task waivers deliberately have no effect here. */
object PhoneAndroidShell {
    const val MAX_COMMAND_BYTES = 2048
    const val DEFAULT_TIMEOUT_MS = 30_000L
    const val MAX_TIMEOUT_MS = 60_000L
    data class Request(val command: String, val timeoutMs: Long)

    fun parse(args: Args): Request? {
        if (!args.onlyKeys("command", "timeout_ms")) return null
        val command = args.strictText("command") ?: return null
        if (!validCommand(command)) return null
        val timeout = if (args.provided("timeout_ms")) args.strictInt("timeout_ms")?.toLong() ?: return null
            else DEFAULT_TIMEOUT_MS
        if (timeout !in 100L..MAX_TIMEOUT_MS) return null
        return Request(command, timeout)
    }

    fun validCommand(command: String): Boolean = command.isNotBlank() &&
        command.toByteArray(Charsets.UTF_8).size <= MAX_COMMAND_BYTES && command.none {
            (it.code < 32 && it !in "\n\r\t") || it.code in 0x7f..0x9f ||
                it.code == 0x061c || it.code in 0x200e..0x200f || it.code in 0x202a..0x202e || it.code in 0x2066..0x2069
        }

    fun failure(code: String): Map<String, Any?> = linkedMapOf(
        "started" to false, "backend" to null, "uid" to null, "exitCode" to null,
        "stdout" to "", "stderr" to "", "timedOut" to false, "cancelled" to (code == "cancelled"),
        "truncated" to false, "errorCode" to code,
    )

    /** Shell grants are one command only; unavailable UI is not a user denial. */
    fun confirmationError(decision: Decision): String? = when (decision) {
        Decision.ALLOW_ONCE -> null
        Decision.UNAVAILABLE -> "confirmationUnavailable"
        Decision.STOP -> "cancelled"
        else -> "confirmationDenied"
    }

    fun run(request: Request, owner: PhoneTasks.Owner, tasks: PhoneTasks, scope: SerialWorker.Scope,
            executor: PhoneShellExecutor?, enabled: () -> Boolean, locked: () -> Boolean,
            gate: () -> UserGate?, ui: PhoneUiText): Map<String, Any?> {
        fun live() = tasks.isCurrent(owner) && !tasks.isPaused && enabled() && !locked() &&
            !Thread.currentThread().isInterrupted
        if (locked()) return failure("locked")
        if (!live()) return failure("cancelled")
        if (executor == null) return failure("unsupported")
        return executor.execute(owner.taskId, request.command, request.timeoutMs, ::live) { backend, uid ->
            if (!live()) Decision.STOP
            else if (!(backend == "adb" && uid == 2000 || backend == "shizuku" && uid in setOf(0, 2000))) Decision.DENY
            else {
                val prompt = ConfirmRequest(
                    ui.get("phone_shell_confirm",
                        "执行 Android 系统命令（%1\$s，UID %2\$s）。这可能修改系统或应用数据；屏幕操作的免确认不适用。仅允许本条命令：\n\n%3\$s",
                        backend, uid.toString(), request.command), // l10n:keep test default
                    appLabel = null, packageName = null, firstInApp = false,
                    offerTaskWaiver = false, owner = owner,
                )
                val decision = scope.userWait { if (live()) gate()?.confirm(prompt) ?: Decision.UNAVAILABLE else Decision.STOP }
                if (decision == Decision.STOP) tasks.stopIfCurrent(owner, "Android Shell 已停止") // l10n:keep agent stop reason
                if (live()) decision else Decision.STOP
            }
        }
    }
}
