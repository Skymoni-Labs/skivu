package com.skyjjgw.independent.ski.dshgo.phone.background

/** Exact platform registration retained across an uncertain RPC; caller serializes access. */
internal class TreeRegistration<C : Any>(private val unregisterClient: (C) -> Unit) {
    private var client: C? = null
    private var unregisterAttempts = 0L

    fun register(value: C, registerClient: (C) -> Unit) {
        check(client == null)
        client = value // The remote side may register before its reply fails.
        registerClient(value)
    }

    fun unregister() {
        val original = client ?: return
        unregisterAttempts++
        unregisterClient(original)
        client = null // Only an actual successful call discharges this identity.
    }

    fun close(disconnect: () -> Unit): Boolean {
        val before = unregisterAttempts
        runCatching { disconnect() }
        // UiAutomation sets DISCONNECTED before the remote call. On retry it may return
        // without invoking our proxy at all. Retry the SAME client, at most once per close.
        if (client != null && unregisterAttempts == before) runCatching { unregister() }
        return client == null
    }
}
