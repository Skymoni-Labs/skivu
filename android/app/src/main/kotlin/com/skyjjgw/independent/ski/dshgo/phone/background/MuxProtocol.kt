package com.skyjjgw.independent.ski.dshgo.phone.background

import android.os.Bundle
import java.io.IOException
import java.util.UUID

/** The actual three channels and both entries share the transport envelope, not resource receipts. */
internal object MuxProtocol {
    private val header = setOf(Proto.REQUEST_MUX_VERSION, Proto.PEER_INSTANCE, Proto.REQUEST_ID)
    private val reserved = header + Proto.MAX_IN_FLIGHT
    private val optInKeys = setOf(Proto.OP, Proto.REQUEST_MUX_VERSION, Proto.MAX_IN_FLIGHT, Proto.PEER_INSTANCE)
    fun global(request: Bundle): Boolean = request.get(Proto.OP) in setOf(Proto.OP_DESTROY, Proto.OP_GRANT_SECURE_SETTINGS)
    fun destroyed(request: Bundle, response: Bundle): Boolean = request.get(Proto.OP) == Proto.OP_DESTROY && response.get(Proto.OK) == true
    fun hasHeader(value: Bundle): Boolean = reserved.any(value::containsKey)

    fun capability(response: Bundle, peer: String): Bundle = response.apply {
        if (get(Proto.OK) == true) {
            putInt(Proto.REQUEST_MUX_VERSION, 1); putInt(Proto.MAX_IN_FLIGHT, 3); putString(Proto.PEER_INSTANCE, peer)
        }
    }
    fun peer(cap: Bundle): String? {
        if (!hasHeader(cap)) return null
        return capabilityPeer(cap.get(Proto.REQUEST_MUX_VERSION), cap.get(Proto.MAX_IN_FLIGHT), cap.get(Proto.PEER_INSTANCE))
    }
    fun capabilityPeer(version: Any?, limit: Any?, peer: Any?): String {
        if (version !is Int || version != 1 || limit !is Int || limit != 3 || peer !is String ||
            runCatching { UUID.fromString(peer).toString() == peer }.getOrDefault(false).not())
            throw IOException("identityChanged")
        return peer
    }
    fun optIn(peer: String) = Bundle().apply {
        putString(Proto.OP, Proto.OP_PROBE); putInt(Proto.REQUEST_MUX_VERSION, 1)
        putInt(Proto.MAX_IN_FLIGHT, 3); putString(Proto.PEER_INSTANCE, peer)
    }
    fun isOptIn(value: Bundle, expected: String): Boolean = value.keySet() == optInKeys &&
        value.get(Proto.OP) == Proto.OP_PROBE && peer(value) == expected
    fun acknowledge(value: Bundle, expected: String) {
        if (value.get(Proto.OK) != true || peer(value) != expected) throw IOException("identityChanged")
    }
    fun request(value: Bundle, peer: String, id: Long): Bundle {
        check(value.keySet().none { it in reserved }) { "reserved transport field" }
        return wrap(value, peer, id)
    }
    fun wrap(value: Bundle, peer: String, id: Long): Bundle = Bundle(value).apply {
        putInt(Proto.REQUEST_MUX_VERSION, 1); putString(Proto.PEER_INSTANCE, peer); putLong(Proto.REQUEST_ID, id)
    }
    fun unwrap(value: Bundle, peer: String): FramedMuxSession.Reply<Bundle> {
        if (value.containsKey(Proto.MAX_IN_FLIGHT)) throw IOException("identityChanged")
        val id = responseId(value.get(Proto.REQUEST_MUX_VERSION), value.get(Proto.PEER_INSTANCE), value.get(Proto.REQUEST_ID), peer)
        return FramedMuxSession.Reply(id, Bundle(value).apply { header.forEach(::remove) })
    }
    fun responseId(version: Any?, peer: Any?, id: Any?, expectedPeer: String): Long {
        if (version !is Int || version != 1 || peer != expectedPeer || id !is Long || id <= 0)
            throw IOException("identityChanged")
        return id
    }
}
