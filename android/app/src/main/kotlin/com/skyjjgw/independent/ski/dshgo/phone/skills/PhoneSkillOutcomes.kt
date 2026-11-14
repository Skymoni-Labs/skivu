package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.phone.Json

/** WIP leaf accounting, not a replay executor. Call outside registry/task/driver locks.
 * One App-private preference value owns counts and in-flight receipts together. Neither
 * callbacks nor records contain actions, parameters, screen text or guest paths.
 * begin is only for a freshly claimed native invocation; this is not an invocation registry. */
internal class PhoneSkillOutcomes(
    private val read: () -> String?,
    private val commit: (String) -> Boolean,
    private val process: String,
) {
    data class Key(val name: String, val revision: String, val digest: String)
    enum class Outcome { SUCCESS, FAILURE, UNKNOWN, CANCEL, NOT_STARTED }
    enum class Result { SAVED, UNCHANGED, BLOCKED, INVALID, FULL }
    data class Counts(val successes: Long = 0, val failures: Long = 0, val streak: Long = 0,
        val last: Outcome? = null) {
        val suggestDisable: Boolean get() = streak >= 3
    }
    private data class Active(val invocation: String, val process: String, val key: Key, val dispatched: Boolean)
    private data class State(val counts: Map<Key, Counts>, val active: Map<String, Active>)
    private data class Pending(val state: State, val bytes: String)
    private val lock = Any()
    private var state = State(emptyMap(), emptyMap())
    private var loaded = false
    private var readFailed = false
    private var pending: Pending? = null

    init { require(id(process)) }

    /** Unknown/corrupt storage is never replaced with an empty successful state. */
    fun load(): Boolean = synchronized(lock) { loadLocked() }

    private fun loadLocked(): Boolean {
        if (loaded) return pending == null
        if (readFailed) return false
        val decoded = try { read()?.let(::decode) ?: State(emptyMap(), emptyMap()) }
            catch (_: Exception) { readFailed = true; return false }
        state = decoded
        loaded = true
        val old = decoded.active.values.filter { it.process != process }
        if (old.isEmpty()) return true
        val counts = LinkedHashMap(decoded.counts)
        val active = LinkedHashMap(decoded.active)
        for (entry in old) {
            // A durable dispatch marker is uncertainty, never a resume instruction.
            counts[entry.key] = counts.getValue(entry.key).copy(
                last = if (entry.dispatched) Outcome.UNKNOWN else Outcome.NOT_STARTED)
            active.remove(entry.invocation)
        }
        return write(State(counts, active)) == Result.SAVED
    }

    /** Includes records not yet durably settled; only immutable count values are exposed. */
    fun counts(key: Key): Counts? = synchronized(lock) {
        if (!loaded || readFailed || pending != null) null else state.counts[key]
    }

    fun begin(invocation: String, key: Key): Result = synchronized(lock) {
        if (!id(invocation) || !valid(key)) return Result.INVALID
        if (!loadLocked() || pending != null) return Result.BLOCKED
        state.active[invocation]?.let {
            return if (it.process == process && it.key == key) Result.UNCHANGED else Result.INVALID
        }
        if (state.active.size >= MAX_ACTIVE || key !in state.counts && state.counts.size >= MAX_SKILLS) return Result.FULL
        val counts = LinkedHashMap(state.counts)
        counts.putIfAbsent(key, Counts())
        write(State(counts, state.active + (invocation to Active(invocation, process, key, false))))
    }

    /** Caller must see SAVED/UNCHANGED before crossing the first actual dispatch boundary. */
    fun markDispatch(invocation: String): Result = synchronized(lock) {
        if (!loadLocked() || pending != null) return Result.BLOCKED
        val entry = state.active[invocation]?.takeIf { it.process == process } ?: return Result.INVALID
        if (entry.dispatched) return Result.UNCHANGED
        write(state.copy(active = state.active + (invocation to entry.copy(dispatched = true))))
    }

    /** The executor has frozen a typed terminal result. ToolOutput/LLM prose never enters here.
     * BLOCKED means the caller MUST retain that invocation's frozen accountingPending result.
     * It must retry after retryStorage, without re-evaluating or dispatching the route again. */
    fun settle(invocation: String, outcome: Outcome): Result = synchronized(lock) {
        if (!loadLocked() || pending != null) return Result.BLOCKED
        val entry = state.active[invocation] ?: return Result.UNCHANGED
        if (entry.process != process) return Result.INVALID
        val old = state.counts.getValue(entry.key)
        if (outcome == Outcome.SUCCESS && old.successes == Long.MAX_VALUE ||
            outcome == Outcome.FAILURE && (old.failures == Long.MAX_VALUE || old.streak == Long.MAX_VALUE)) return Result.FULL
        val next = when (outcome) {
            Outcome.SUCCESS -> old.copy(successes = old.successes + 1, streak = 0, last = outcome)
            Outcome.FAILURE -> old.copy(failures = old.failures + 1, streak = old.streak + 1, last = outcome)
            else -> old.copy(last = outcome)
        }
        write(State(state.counts + (entry.key to next), state.active - invocation))
    }

    /** Recommit EXACT next bytes, never recompute +1 or write the previously published state.
     * No callback to an invocation registry under this leaf lock. The caller drains its own
     * retained terminal results after this returns true and releases the storage lock. */
    fun retryStorage(): Boolean = synchronized(lock) {
        val next = pending
        if (next != null) return publish(next)
        if (readFailed) { readFailed = false; loaded = false }
        loadLocked()
    }

    private fun write(next: State): Result {
        val value = Pending(next, encode(next))
        pending = value // Even a false/throwing commit may have changed durable storage.
        return if (publish(value)) Result.SAVED else Result.BLOCKED
    }

    private fun publish(next: Pending): Boolean {
        val saved = try { commit(next.bytes) } catch (_: Exception) { false }
        if (!saved) return false
        state = next.state
        pending = null
        return true
    }

    private fun keyMap(key: Key) = mapOf("name" to key.name, "revision" to key.revision, "digest" to key.digest)
    private fun encode(value: State): String = Json.write(mapOf(
        "version" to 1,
        "skills" to value.counts.map { (key, count) -> keyMap(key) + mapOf(
            "successes" to count.successes, "failures" to count.failures, "streak" to count.streak,
            "last" to count.last?.name) },
        "active" to value.active.values.map { keyMap(it.key) + mapOf(
            "invocation" to it.invocation, "process" to it.process, "dispatched" to it.dispatched) },
    ))

    private fun decode(raw: String): State {
        require(raw.toByteArray(Charsets.UTF_8).size <= MAX_BYTES)
        val root = Json.parse(raw) as? Map<*, *> ?: error("invalid")
        require(root.keys == setOf("version", "skills", "active") && whole(root["version"]) == 1L)
        val skills = root["skills"] as? List<*> ?: error("invalid")
        val runs = root["active"] as? List<*> ?: error("invalid")
        require(skills.size <= MAX_SKILLS && runs.size <= MAX_ACTIVE)
        val counts = LinkedHashMap<Key, Counts>()
        for (rawSkill in skills) {
            val item = rawSkill as? Map<*, *> ?: error("invalid")
            require(item.keys == setOf("name", "revision", "digest", "successes", "failures", "streak", "last"))
            val key = readKey(item)
            require(key !in counts)
            val last = item["last"]?.let { value -> Outcome.entries.firstOrNull { it.name == value } ?: error("invalid") }
            val count = Counts(whole(item["successes"]), whole(item["failures"]), whole(item["streak"]), last)
            require(count.streak <= count.failures)
            counts[key] = count
        }
        val active = LinkedHashMap<String, Active>()
        for (rawRun in runs) {
            val item = rawRun as? Map<*, *> ?: error("invalid")
            require(item.keys == setOf("name", "revision", "digest", "invocation", "process", "dispatched"))
            val key = readKey(item)
            val invocation = item["invocation"] as? String ?: error("invalid")
            val owner = item["process"] as? String ?: error("invalid")
            val dispatched = item["dispatched"] as? Boolean ?: error("invalid")
            require(id(invocation) && id(owner) && key in counts && invocation !in active)
            active[invocation] = Active(invocation, owner, key, dispatched)
        }
        return State(counts, active)
    }

    private fun readKey(item: Map<*, *>): Key = Key(item["name"] as? String ?: error("invalid"),
        item["revision"] as? String ?: error("invalid"), item["digest"] as? String ?: error("invalid")).also { require(valid(it)) }

    companion object {
        private const val MAX_SKILLS = 256
        private const val MAX_ACTIVE = 256
        private const val MAX_BYTES = 256 * 1024
        private val HEX = Regex("[a-f0-9]{32}")
        private val DIGEST = Regex("[a-f0-9]{64}")
        private val NAME = Regex("phone-task-[a-f0-9]{32}")
        private fun id(value: String) = HEX.matches(value)
        private fun valid(key: Key) = NAME.matches(key.name) && id(key.revision) && DIGEST.matches(key.digest)
        private fun whole(value: Any?): Long = when (value) {
            is Long -> value
            is Int -> value.toLong()
            else -> error("invalid")
        }.also { require(it >= 0) }
    }
}
