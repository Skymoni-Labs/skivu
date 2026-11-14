package com.skyjjgw.independent.ski.dshgo.phone.background

import java.net.InetAddress

/** Keep the address and port from one complete discovery response together. */
internal data class AdbEndpoint(val address: InetAddress, val port: Int) {
    companion object {
        fun discovered(address: InetAddress?, port: Int): AdbEndpoint? =
            if (address != null && port in 1..65535) AdbEndpoint(address, port) else null
    }
}

/** A discovery callback may already be running when its mDNS instance is stopped. */
internal class AdbDiscoverySlot {
    private var owner: Any? = null
    private var endpoint: AdbEndpoint? = null

    @Synchronized fun begin(): Any = Any().also {
        owner = it
        endpoint = null
    }

    @Synchronized fun retire() {
        owner = null
        endpoint = null
    }

    // The owner check and publication share the same lock as begin/retire.
    @Synchronized fun publish(ticket: Any, address: InetAddress?, port: Int): Boolean {
        if (owner !== ticket) return false
        val value = AdbEndpoint.discovered(address, port) ?: return false
        endpoint = value
        return true
    }

    @Synchronized fun current(): AdbEndpoint? = endpoint

    @Synchronized fun discard(expected: AdbEndpoint?) {
        if (endpoint === expected) endpoint = null
    }
}
