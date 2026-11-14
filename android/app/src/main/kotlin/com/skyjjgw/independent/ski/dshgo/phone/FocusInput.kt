package com.skyjjgw.independent.ski.dshgo.phone

import java.util.concurrent.atomic.AtomicReference

/** Identity of one INPUT that actually appears in this observation's final text.
 * No node or text is retained here. The originating driver owns the native witness.
 */
class FocusObservation internal constructor(val elementId: Int) {
    private val reply = AtomicReference<PhoneReplyCommit?>(null)

    /** A filtered output may associate this candidate with its original call exactly once. */
    internal fun bind(commit: PhoneReplyCommit): Boolean = reply.compareAndSet(null, commit)

    /** Necessary, never sufficient: the original owner, driver, node and selection still matter. */
    internal val committed: Boolean get() = reply.get()?.committed == true
}

/** One captured original editor. No operation may refocus, replace the connection, or retry input.
 * The caller closes this plan on every exit, including denied confirmation and retirement.
 */
interface FocusInput : AutoCloseable {
    enum class Method { INPUT_METHOD, CLIPBOARD }
    val method: Method get() = Method.INPUT_METHOD
    val target: TargetInfo

    /** Inserts once at the captured selection; [allowed] is checked again before physical input. */
    fun perform(text: String, allowed: () -> Boolean): ActionResult

    override fun close()
}
