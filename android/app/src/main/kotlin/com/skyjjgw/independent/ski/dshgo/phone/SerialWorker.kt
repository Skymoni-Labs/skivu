package com.skyjjgw.independent.ski.dshgo.phone

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Callable
import java.util.concurrent.CancellationException
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicLong

/**
 * Every phone action runs here, one at a time, in a single serial queue. Each call has its own
 * time budget that excludes the time spent waiting for the person ([Scope.userWait]: confirmations,
 * pause, handoff), plus an overall cap below DSH's 660 s MCP timeout. A call that overruns is
 * interrupted; if its thread doesn't come back, the worker thread is abandoned and replaced so the
 * queue never wedges behind a stuck driver.
 */
class SerialWorker internal constructor(
    private val name: String,
    private val clock: () -> Long,
    private val awaitFinished: (CountDownLatch) -> Boolean,
) {
    constructor(name: String) : this(name, ::now, { it.await(1000, TimeUnit.MILLISECONDS) })

    class Scope internal constructor(private val clock: () -> Long = ::now) {
        internal val waited = AtomicLong()
        @Volatile internal var waitingSince = 0L

        /** Runs [block] (which waits for the person) without charging it to the call's own budget. */
        fun <T> userWait(block: () -> T): T {
            val start = clock()
            waitingSince = start
            try {
                return block()
            } finally {
                waited.addAndGet(clock() - start)
                waitingSince = 0L
            }
        }

        internal fun charged(startedAt: Long, at: Long): Long {
            val since = waitingSince
            return at - startedAt - waited.get() - (if (since > 0) at - since else 0)
        }
    }

    sealed interface Outcome<out T> {
        class Done<T>(val value: T) : Outcome<T>
        class Failed(val error: Throwable) : Outcome<Nothing>
        /** Ran past its budget, or left a retired queue ([queued]: never got to start). */
        class TimedOut(val queued: Boolean) : Outcome<Nothing>
        /** Interrupted by [interruptCurrent] (stop). */
        object Interrupted : Outcome<Nothing>
    }

    private enum class AdmissionState { QUEUED, RUNNING, CANCELLED }

    private val generation = AtomicLong()
    @Volatile private var executor: ExecutorService = newExecutor()
    private val current = java.util.concurrent.atomic.AtomicReference<Thread?>(null)
    private val retirementLock = Any()
    private var currentOwner: Any? = null
    private val ownerBodies = java.util.IdentityHashMap<Any, Int>()
    private val drainWaiters = java.util.IdentityHashMap<Any, MutableList<() -> Unit>>()
    private var retirementEpoch = 0L

    private fun newExecutor(): ExecutorService {
        val gen = generation.incrementAndGet()
        return Executors.newSingleThreadExecutor { r -> Thread(r, "$name-$gen").apply { isDaemon = true } }
    }

    /** Runs [job] on the worker; blocks the caller until it finishes or overruns. */
    fun <T> run(budgetMs: Long, maxTotalMs: Long, owner: Any? = null, job: (Scope) -> T): Outcome<T> {
        val admittedEpoch = synchronized(retirementLock) { retirementEpoch }
        val scope = Scope(clock)
        val submitted = clock()
        var admission = AdmissionState.QUEUED // Protected by retirementLock, including the body claim.
        var startedAt = 0L // Zero is a valid clock value; admission is the execution state.
        val finished = CountDownLatch(1)
        val exec = executor
        val future: Future<T> = try {
            exec.submit(Callable {
                val startTime = clock() // May block in a test/clock provider; never inside the admission lock.
                val self = Thread.currentThread()
                var registered = false
                try {
                    synchronized(retirementLock) {
                        if (admission != AdmissionState.QUEUED || admittedEpoch != retirementEpoch || self.isInterrupted) {
                            admission = AdmissionState.CANCELLED
                            throw InterruptedException()
                        }
                        admission = AdmissionState.RUNNING
                        startedAt = startTime
                        current.set(self)
                        currentOwner = owner
                        if (owner != null) { ownerBodies[owner] = (ownerBodies[owner] ?: 0) + 1; registered = true }
                    }
                    job(scope)
                } finally {
                    val drained = synchronized(retirementLock) {
                        if (current.compareAndSet(self, null)) currentOwner = null
                        Thread.interrupted() // don't leak an interrupt into the next job
                        finished.countDown()
                        if (registered && owner != null) {
                            val remaining = checkNotNull(ownerBodies[owner]) - 1
                            if (remaining == 0) { ownerBodies.remove(owner); drainWaiters.remove(owner)?.toList().orEmpty() }
                            else { ownerBodies[owner] = remaining; emptyList() }
                        } else emptyList()
                    }
                    // Lifecycle observers may release device resources; never call them under the worker lock.
                    drained.forEach { runCatching(it) }
                }
            })
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            return Outcome.Failed(e)
        }
        while (true) {
            try {
                val value = future.get(POLL_MS, TimeUnit.MILLISECONDS)
                // Device code may consume interruption. Retirement and delivery share this
                // commit point; a drained old body must not publish a successful old value.
                return synchronized(retirementLock) {
                    if (admittedEpoch != retirementEpoch) Outcome.Interrupted else Outcome.Done(value)
                }
            } catch (_: TimeoutException) {
                val t = clock()
                val state = synchronized(retirementLock) { admission to startedAt }
                if (state.first != AdmissionState.RUNNING) {
                    if (t - submitted > maxTotalMs) {
                        val cancelledBeforeStart = synchronized(retirementLock) {
                            if (admission != AdmissionState.QUEUED) false
                            else { admission = AdmissionState.CANCELLED; true }
                        }
                        if (cancelledBeforeStart) {
                            future.cancel(false)
                            return Outcome.TimedOut(queued = true)
                        }
                    }
                    continue
                }
                if (scope.charged(state.second, t) > budgetMs || t - submitted > maxTotalMs) {
                    future.cancel(true)
                    abandonIfStuck(exec, finished)
                    return if (Thread.currentThread().isInterrupted) Outcome.Interrupted else Outcome.TimedOut(queued = false)
                }
            } catch (e: ExecutionException) {
                val cause = e.cause ?: e
                return if (cause is InterruptedException) Outcome.Interrupted else Outcome.Failed(cause)
            } catch (_: CancellationException) {
                // A retired executor removes queued Futures without running their Callables.
                // This is an unexecuted call, not a user stop of a running operation.
                return if (synchronized(retirementLock) { admission != AdmissionState.RUNNING }) Outcome.TimedOut(queued = true) else Outcome.Interrupted
            } catch (e: InterruptedException) {
                future.cancel(true)
                Thread.currentThread().interrupt()
                return Outcome.Interrupted
            }
        }
    }

    /** Retires already-admitted calls for this engine; later calls can use the same worker. */
    fun retire() = synchronized(retirementLock) {
        retirementEpoch++
        interruptCurrent()
    }

    /** Interrupts the job that is running now, if any (the stop button). Gates treat it as STOP. */
    fun interruptCurrent(owner: Any? = null) = synchronized(retirementLock) {
        if (owner == null || currentOwner === owner) current.get()?.interrupt()
    }

    /** A cancelled Future may be done while its body still owns device work. */
    fun afterDrained(owner: Any, action: () -> Unit) {
        val ready = synchronized(retirementLock) {
            if ((ownerBodies[owner] ?: 0) == 0) true
            else { drainWaiters.getOrPut(owner) { mutableListOf() }.add(action); false }
        }
        if (ready) action()
    }

    fun shutdown() {
        shutdown(executor)
    }

    private fun shutdown(exec: ExecutorService) {
        // run() submits Futures. Complete only those shutdownNow actually removed;
        // a running job still follows the existing interruption and budget rules.
        for (task in exec.shutdownNow()) {
            (task as Future<*>).cancel(false)
        }
    }

    /** Cancellation completes the Future before its body exits; wait for this job's own finally. */
    private fun abandonIfStuck(exec: ExecutorService, finished: CountDownLatch) {
        if (finished.count == 0L) return
        try {
            if (awaitFinished(finished)) return
        } catch (_: InterruptedException) {
            // Cancellation of the caller must not skip this job's retirement check.
            Thread.currentThread().interrupt()
        }
        synchronized(retirementLock) {
            // The job can finish as its grace period expires. Its successor may reuse the same
            // thread, so only this completion signal can authorize retiring the executor.
            if (finished.count != 0L && executor === exec) {
                current.set(null)
                currentOwner = null
                executor = newExecutor()
                shutdown(exec)
            }
        }
    }

    companion object {
        private const val POLL_MS = 50L
        internal fun now(): Long = System.nanoTime() / 1_000_000
    }
}
