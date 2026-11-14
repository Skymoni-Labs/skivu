package com.skyjjgw.independent.ski.dshgo.phone.background

import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

/** Pure field decoders used by the real Bundle codec; no mocked Android Parcel. */
class MuxProtocolTest {
    private val peer = "00000000-0000-4000-8000-000000000001"
    private fun rejected(call: () -> Unit) { try { call(); fail("accepted malformed tuple") } catch (_: IOException) {} }
    @Test fun capabilityRequiresCompleteTypedCanonicalTuple() {
        assertEquals(peer, MuxProtocol.capabilityPeer(1, 3, peer))
        for (value in listOf(null, 1L, 0, 2, "1")) rejected { MuxProtocol.capabilityPeer(value, 3, peer) }
        for (value in listOf(null, 3L, 1, 4, "3")) rejected { MuxProtocol.capabilityPeer(1, value, peer) }
        for (value in listOf(null, "1-1-1-1-1", "00000000-0000-4000-8000-00000000000A", 1))
            rejected { MuxProtocol.capabilityPeer(1, 3, value) }
    }
    @Test fun replyUsesExactPeerAndPositiveLongWithoutArrivalOrderAssumptions() {
        assertEquals(8L, MuxProtocol.responseId(1, peer, 8L, peer))
        assertEquals(2L, MuxProtocol.responseId(1, peer, 2L, peer))
        for (value in listOf(null, 1, 0L, -1L, "1")) rejected { MuxProtocol.responseId(1, peer, value, peer) }
        rejected { MuxProtocol.responseId(1L, peer, 1L, peer) }
        rejected { MuxProtocol.responseId(1, "00000000-0000-4000-8000-000000000002", 1L, peer) }
    }
}
