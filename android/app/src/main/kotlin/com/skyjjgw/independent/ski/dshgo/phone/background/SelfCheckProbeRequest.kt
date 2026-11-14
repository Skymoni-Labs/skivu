package com.skyjjgw.independent.ski.dshgo.phone.background

/** Fixed local probe request only. The real Core calls this before registering or allocating. */
internal object SelfCheckProbeRequest {
    private val fields = setOf(Proto.OP, Proto.OWNER, Proto.RELEASE_RECEIPT, Proto.SELF_CHECK_PROBE_VERSION)
    private val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    fun owner(keys: Set<String>, value: (String) -> Any?): String? {
        if (keys != fields) return null
        val op = value(Proto.OP)
        if (op !is String || op != Proto.OP_SELF_CHECK_PROBE) return null
        val release = value(Proto.RELEASE_RECEIPT)
        val version = value(Proto.SELF_CHECK_PROBE_VERSION)
        if (release !is Int || release != 1 || version !is Int || version != 1) return null
        val owner = value(Proto.OWNER) as? String ?: return null
        return owner.takeIf { uuid.matches(it) }
    }
}
