package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundReplayResourceTest {
    @Test fun onlyPinnedUnsealedResourceCanPublishLocalQualification() {
        val io = BackgroundDisplayIo<Any>()
        val peer = Any()
        var checked = 0
        try {
            assertFalse(io.existingResource { checked++; true })
            assertEquals(0, checked)
            io.call {
                io.startResource(peer, { beforeSend -> beforeSend(); true }, { it })
            }
            assertTrue(io.existingResource { it === peer })
            assertFalse(io.existingResource { false })
            io.seal()
            assertFalse(io.existingResource { checked++; true })
            assertEquals(0, checked)
        } finally { assertTrue(io.release { it === peer }) }
    }
}
