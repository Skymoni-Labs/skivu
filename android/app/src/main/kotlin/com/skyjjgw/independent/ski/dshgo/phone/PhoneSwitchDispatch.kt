package com.skyjjgw.independent.ski.dshgo.phone

import java.util.concurrent.Executor
import java.util.concurrent.FutureTask

/** Disable promptly; reserve cleanup's position before later background work is submitted. */
internal fun dispatchPhoneDisable(
    controlIo: Executor,
    backgroundIo: Executor,
    disable: () -> Boolean,
    finish: () -> Boolean,
    complete: (Result<Boolean>) -> Unit,
) {
    val disabled = FutureTask { runCatching(disable) }
    controlIo.execute(disabled)
    backgroundIo.execute {
        complete(runCatching { disabled.get().getOrThrow() && finish() })
    }
}
