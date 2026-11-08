package com.skyjjgw.independent.ski

/** Host allowlist, not a model/plugin-supplied claim or a shell blacklist. */
object BackgroundExecutionPolicy {
    val allowed = setOf("device.status", "apps.list", "settings.brightness.read", "settings.brightness.write",
        "assistant.alarm.create", "assistant.alarm.list", "assistant.alarm.get", "assistant.alarm.update",
        "assistant.alarm.cancel", "assistant.timer.start")
    fun permits(tool: String) = tool in allowed
}
