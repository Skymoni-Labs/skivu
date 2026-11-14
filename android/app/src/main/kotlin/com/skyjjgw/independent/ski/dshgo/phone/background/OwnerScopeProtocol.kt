package com.skyjjgw.independent.ski.dshgo.phone.background

import android.os.Bundle

/** The three real resource callers share the envelope, not their action/release decoders. */
internal object OwnerScopeProtocol {
    fun request(source: Bundle): Bundle = Bundle(source).apply { putInt(Proto.OWNER_SCOPE_VERSION, 1) }

    fun response(owner: String, source: Bundle): Bundle {
        check(matches(owner, source)) { Reasons.of("scopeIdentityUnavailable") }
        return Bundle(source).apply { remove(Proto.OWNER_SCOPE_VERSION); remove(Proto.SCOPE_ACCEPTED) }
    }

    fun first(io: BackgroundDisplayIo<PrivilegedChannel>, peer: PrivilegedChannel, request: Bundle,
              admit: ((() -> Unit) -> Boolean) = { action -> action(); true }): Bundle {
        fun accepted(reply: Bundle): Boolean? = OwnerScopeReply.first(io.owner,
            reply.get(Proto.OWNER_SCOPE_VERSION), reply.get(Proto.OWNER), reply.get(Proto.SCOPE_ACCEPTED), reply.get(Proto.OK))
        val raw = io.startResource(peer, { beforeSend ->
            peer.execute(OwnerScopeProtocol.request(request)) { check(admit(beforeSend)) { Reasons.of("deviceUnavailable") } }
        }, ::accepted)
        check(accepted(raw) != null) { Reasons.of("scopeIdentityUnavailable") }
        return response(io.owner, raw)
    }

    fun execute(peer: PrivilegedChannel, owner: String, source: Bundle, beforeSend: () -> Unit = {}): Bundle =
        response(owner, peer.execute(request(source), beforeSend))

    /** RELEASE of one owner's screen; true only when the service confirmed it. */
    fun release(peer: PrivilegedChannel, owner: String): Boolean = execute(peer, owner, Bundle().apply {
        putString(Proto.OP, Proto.OP_RELEASE); putString(Proto.OWNER, owner); putInt(Proto.RELEASE_RECEIPT, 1)
    }).get(Proto.OK) == true

    private fun matches(owner: String, source: Bundle): Boolean = OwnerScopeReply.matches(owner, source.get(Proto.OWNER_SCOPE_VERSION), source.get(Proto.OWNER))
}
