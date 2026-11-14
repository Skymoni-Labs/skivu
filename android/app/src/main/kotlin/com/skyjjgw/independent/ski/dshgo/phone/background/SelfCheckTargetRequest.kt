package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.selfcheck.TargetContract

/** Fixed C1/C2 operations only; no text, coordinates, display, or caller-selected phase. */
internal data class SelfCheckTargetRequest(val step: Step, val owner: String, val run: String, val nonce: String, val c2: Boolean = false) {
    enum class Step(val op: String) {
        CREATE(Proto.OP_SELF_CHECK_TARGET_CREATE), READ(Proto.OP_SELF_CHECK_TARGET_READ), TAP(Proto.OP_SELF_CHECK_TARGET_TAP),
        TEXT_ASCII(Proto.OP_SELF_CHECK_TARGET_TEXT_ASCII), TEXT_ZH(Proto.OP_SELF_CHECK_TARGET_TEXT_ZH),
        CAPTURE(Proto.OP_SELF_CHECK_TARGET_CAPTURE), CONTINUITY(Proto.OP_SELF_CHECK_TARGET_CONTINUITY),
    }
    val versionKey: String get() = if (c2) Proto.SELF_CHECK_TARGET_C2_VERSION else Proto.SELF_CHECK_TARGET_VERSION

    companion object {
        fun parse(keys: Set<String>, value: (String) -> Any?): SelfCheckTargetRequest? {
            val step = Step.entries.firstOrNull { it.op == value(Proto.OP) } ?: return null
            val c2 = Proto.SELF_CHECK_TARGET_C2_VERSION in keys
            if (!c2 && step.ordinal > Step.TAP.ordinal) return null
            val version = if (c2) Proto.SELF_CHECK_TARGET_C2_VERSION else Proto.SELF_CHECK_TARGET_VERSION
            val expected = setOf(Proto.OP, Proto.OWNER, version, Proto.TARGET_RUN, Proto.STEP_NONCE) +
                if (step == Step.CREATE) setOf(Proto.RELEASE_RECEIPT) else emptySet()
            if (keys != expected || value(version) !is Int || value(version) != 1) return null
            if (step == Step.CREATE && (value(Proto.RELEASE_RECEIPT) !is Int || value(Proto.RELEASE_RECEIPT) != 1)) return null
            val owner = value(Proto.OWNER) as? String ?: return null
            val run = value(Proto.TARGET_RUN) as? String ?: return null
            val nonce = value(Proto.STEP_NONCE) as? String ?: return null
            if (!TargetContract.validRun(owner) || !TargetContract.validRun(run) || !TargetContract.validRun(nonce)) return null
            return SelfCheckTargetRequest(step, owner, run, nonce, c2)
        }
    }
}

/** The Core lock serializes these bounded slots. A consumed but failed slot cannot be replayed. */
internal class SelfCheckTargetSequence(val owner: String, val run: String, val c2: Boolean = false) {
    private val steps = if (c2) listOf(SelfCheckTargetRequest.Step.CREATE, SelfCheckTargetRequest.Step.READ,
        SelfCheckTargetRequest.Step.TAP, SelfCheckTargetRequest.Step.TEXT_ASCII, SelfCheckTargetRequest.Step.TEXT_ZH,
        SelfCheckTargetRequest.Step.CAPTURE, SelfCheckTargetRequest.Step.CONTINUITY,
        SelfCheckTargetRequest.Step.CONTINUITY, SelfCheckTargetRequest.Step.CONTINUITY)
        else SelfCheckTargetRequest.Step.entries.take(3)
    private val nonces = ArrayList<String>(steps.size)
    private var completed = 0
    private var releaseNonce: String? = null
    val framePhase: Int get() { check(c2 && completed in 5..8); return completed - 4 }

    fun enter(request: SelfCheckTargetRequest): String? {
        if (request.owner != owner || request.run != run || request.c2 != c2) return "identityChanged"
        if (releaseNonce != null) return "releasePending"
        if (request.nonce in nonces) return "alreadyAttempted"
        if (completed != nonces.size) return if (steps[completed] == request.step) "alreadyAttempted" else "outOfOrder"
        if (completed >= steps.size || steps[completed] != request.step)
            return if (request.step in steps.take(completed)) "alreadyAttempted" else "outOfOrder"
        nonces.add(request.nonce)
        return null
    }

    fun complete(step: SelfCheckTargetRequest.Step) {
        check(completed < steps.size && steps[completed] == step && nonces.size == completed + 1)
        completed++
    }

    fun bindRelease(request: SelfCheckTargetRelease): Boolean {
        if (!c2 || request.owner != owner || request.run != run) return false
        if (releaseNonce != null && releaseNonce != request.nonce) return false
        releaseNonce = request.nonce
        return true
    }
}

internal data class SelfCheckTargetRelease(val owner: String, val run: String, val nonce: String) {
    companion object {
        fun parse(keys: Set<String>, value: (String) -> Any?): SelfCheckTargetRelease? {
            if (keys != setOf(Proto.OP, Proto.OWNER, Proto.RELEASE_RECEIPT, Proto.SELF_CHECK_TARGET_C2_VERSION,
                    Proto.SELF_CHECK_FINAL_MAIN, Proto.TARGET_RUN, Proto.RELEASE_NONCE) || value(Proto.OP) != Proto.OP_RELEASE) return null
            for (key in listOf(Proto.RELEASE_RECEIPT, Proto.SELF_CHECK_TARGET_C2_VERSION, Proto.SELF_CHECK_FINAL_MAIN))
                if (value(key) !is Int || value(key) != 1) return null
            val owner = value(Proto.OWNER) as? String ?: return null
            val run = value(Proto.TARGET_RUN) as? String ?: return null
            val nonce = value(Proto.RELEASE_NONCE) as? String ?: return null
            if (!TargetContract.validRun(owner) || !TargetContract.validRun(run) || !TargetContract.validRun(nonce)) return null
            return SelfCheckTargetRelease(owner, run, nonce)
        }
    }
}
