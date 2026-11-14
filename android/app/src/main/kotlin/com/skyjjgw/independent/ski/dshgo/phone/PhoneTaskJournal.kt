package com.skyjjgw.independent.ski.dshgo.phone

import java.util.UUID

/** The logical interruption record only. No payload, replay or physical-resource receipts.
 * Its storage lock never calls Tasks, the registry, listeners or UI. status() is memory-only. */
class PhoneTaskJournal(
    private val read: () -> String?,
    private val commit: (String) -> Boolean,
    private val processInstance: String = PROCESS_INSTANCE,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    class Record internal constructor(val token: String, val process: String,
        val taskId: Long, val lifecycle: Long, val startedAt: Long)
    private val lock = Any()
    private var loaded = false
    private var attempted = false
    private var records = emptyList<Record>()
    private val failedClears = mutableSetOf<String>()
    private var batch = emptySet<String>()
    private var batchToken: String? = null
    private var error: String? = null
    @Volatile private var summary: Map<String, Any?> = mapOf(
        "version" to 1, "state" to "loading", "count" to 0, "batchToken" to null, "error" to null)

    fun status(): Map<String, Any?> = summary
    fun record(owner: PhoneTasks.Owner) = Record(UUID.randomUUID().toString(), processInstance,
        owner.taskId, owner.lifecycle, clock())

    fun load(): Boolean = synchronized(lock) { loadLocked() }
    private fun loadLocked(): Boolean {
        if (loaded) return true
        if (attempted) return false
        attempted = true
        return try {
            val raw = read()
            records = if (raw == null) emptyList() else decode(raw)
            loaded = true
            error = null
            publish()
            true
        } catch (_: Exception) { error = "loadFailed"; publish(); false }
    }

    /** Runs on the bridge call thread, before Begin/prepare and outside all task locks. */
    fun refusal(): String? = synchronized(lock) {
        if (!loadLocked() || error != null) STORAGE_MESSAGE
        else if (batch.isNotEmpty()) INTERRUPTION_MESSAGE else null
    }

    fun mark(record: Record): Boolean = synchronized(lock) {
        if (!loadLocked() || error != null || batch.isNotEmpty()) return false
        if (records.any { it.token == record.token }) return true
        if (records.size >= 256) { error = "writeFailed"; publish(); return false }
        write(records + record)
    }

    /** Caller has proved this exact scope's body and strict cleanup finished. Even an unconfirmed
     * mark is removed with a real commit: a failed prior write is not evidence of absence. */
    fun clear(record: Record): Boolean = synchronized(lock) {
        if (!loadLocked()) return false
        val ok = write(records.filterNot { it.token == record.token })
        if (ok) failedClears.remove(record.token) else failedClears.add(record.token)
        error = if (ok && failedClears.isEmpty()) null else "writeFailed"
        publish()
        ok
    }

    fun acknowledge(token: String): Boolean = synchronized(lock) {
        if (!loaded || error != null || token != batchToken || batch.isEmpty()) return false
        write(records.filterNot { it.process != processInstance && it.token in batch })
    }

    /** Retry an actual read or persist the last known snapshot after a failed transaction.
     * Failed ACK is not replayed; the original visible batch still needs its user's ACK. */
    fun retryStorage(): Boolean = synchronized(lock) {
        if (!loaded) { attempted = false; return loadLocked() }
        if (error == null) true else write(records)
    }

    private fun write(next: List<Record>): Boolean {
        val ok = try { commit(Json.write(mapOf("version" to 1, "records" to next.map { r -> mapOf(
            "token" to r.token, "processInstance" to r.process, "taskId" to r.taskId,
            "lifecycle" to r.lifecycle, "startedAt" to r.startedAt) }))) } catch (_: Exception) { false }
        if (ok) { records = next; error = if (failedClears.isEmpty()) null else "writeFailed" } else error = "writeFailed"
        publish()
        return ok
    }

    private fun publish() {
        val old = records.filter { it.process != processInstance }.map { it.token }.toSet()
        if (old != batch) { batch = old; batchToken = if (old.isEmpty()) null else UUID.randomUUID().toString() }
        summary = mapOf("version" to 1, "state" to if (error != null) "error" else if (loaded) "ready" else "loading",
            "count" to batch.size, "batchToken" to if (error == null && loaded) batchToken else null, "error" to error)
    }

    private fun decode(raw: String): List<Record> {
        val root = Json.parse(raw) as? Map<*, *> ?: error("format")
        require(root.keys == setOf("version", "records") && root["version"] == 1L)
        val list = root["records"] as? List<*> ?: error("records")
        require(list.size <= 256)
        val decoded = list.map { item ->
            val m = item as? Map<*, *> ?: error("record")
            require(m.keys == setOf("token", "processInstance", "taskId", "lifecycle", "startedAt"))
            fun uuid(key: String): String = (m[key] as? String)?.takeIf {
                runCatching { UUID.fromString(it).toString() == it }.getOrDefault(false)
            } ?: error("uuid")
            fun number(key: String): Long = (m[key] as? Long)?.takeIf { it >= 0 } ?: error("number")
            Record(uuid("token"), uuid("processInstance"), number("taskId"), number("lifecycle"), number("startedAt"))
        }
        require(decoded.map { it.token }.distinct().size == decoded.size)
        return decoded
    }

    companion object {
        private val PROCESS_INSTANCE = UUID.randomUUID().toString()
        // l10n:keep agent interruption result
        const val INTERRUPTION_MESSAGE = "上次手机任务中断或未能保存结束状态，操作结果可能已经发生。本次未执行。请先在手机操控页核对中断提示。"
        // l10n:keep agent storage result
        const val STORAGE_MESSAGE = "无法保存或读取任务状态，本次未执行。请在手机操控页重试保存或读取。"
    }
}
