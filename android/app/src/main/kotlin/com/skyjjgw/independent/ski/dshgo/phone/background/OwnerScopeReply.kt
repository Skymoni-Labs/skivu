package com.skyjjgw.independent.ski.dshgo.phone.background

/** Shared exact envelope predicates; an absent/contradictory first ACK never discharges a pin. */
internal object OwnerScopeReply {
    fun matches(expected: String, version: Any?, owner: Any?): Boolean = version is Int && version == 1 && owner == expected
    fun first(expected: String, version: Any?, owner: Any?, accepted: Any?, ok: Any?): Boolean? {
        if (!matches(expected, version, owner) || accepted !is Boolean || ok !is Boolean) return null
        if (!accepted && ok) return null
        return accepted
    }
}
