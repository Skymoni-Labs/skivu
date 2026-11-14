package com.skyjjgw.independent.ski.dshgo.phone.background

import java.net.InetAddress
import org.junit.Assert.*
import org.junit.Test

class AdbEndpointTest {
    @Test fun incompleteDiscoveryCannotBecomeAConnectTarget() {
        val address = InetAddress.getByName("127.0.0.1")
        assertNull(AdbEndpoint.discovered(null, 37123))
        for (port in listOf(-1, 0, 65536)) assertNull(AdbEndpoint.discovered(address, port))
    }

    @Test fun aCompleteResponseKeepsItsOwnAddressAndPort() {
        val address = InetAddress.getByName("192.168.1.87")
        val target = AdbEndpoint.discovered(address, 45269)!!
        assertEquals(address, target.address)
        assertEquals(45269, target.port)
        assertNotNull(AdbEndpoint.discovered(address, 1))
        assertNotNull(AdbEndpoint.discovered(address, 65535))
    }

    @Test fun replacedDiscoveryRejectsAnAlreadyResolvedOldCallback() {
        val slot = AdbDiscoverySlot()
        val address = InetAddress.getByName("127.0.0.1")
        val old = slot.begin()
        val oldResolved = { slot.publish(old, address, 37123) }
        val replacement = slot.begin()
        assertTrue(slot.publish(replacement, address, 45269))
        val current = slot.current()

        assertFalse(oldResolved())
        assertSame(current, slot.current())
        assertEquals(45269, slot.current()!!.port)
    }

    @Test fun stoppedDiscoveryCannotBeRepopulatedByItsLateCallback() {
        val slot = AdbDiscoverySlot()
        val address = InetAddress.getByName("127.0.0.1")
        val ticket = slot.begin()
        assertTrue(slot.publish(ticket, address, 37123))

        slot.retire()

        assertFalse(slot.publish(ticket, address, 45269))
        assertNull(slot.current())
    }

    @Test fun aNewDiscoveryStartsWithoutThePreviousEndpoint() {
        val slot = AdbDiscoverySlot()
        val address = InetAddress.getByName("127.0.0.1")
        val old = slot.begin()
        assertTrue(slot.publish(old, address, 37123))

        val current = slot.begin()

        assertNull(slot.current())
        assertFalse(slot.publish(old, address, 37123))
        assertTrue(slot.publish(current, address, 45269))
        assertEquals(address, slot.current()!!.address)
        assertEquals(45269, slot.current()!!.port)
    }

    @Test fun invalidCurrentResponsesDoNotReplaceACompleteEndpoint() {
        val slot = AdbDiscoverySlot()
        val address = InetAddress.getByName("127.0.0.1")
        val ticket = slot.begin()
        assertTrue(slot.publish(ticket, address, 37123))
        val current = slot.current()

        assertFalse(slot.publish(ticket, null, 45269))
        for (port in listOf(-1, 0, 65536)) assertFalse(slot.publish(ticket, address, port))

        assertSame(current, slot.current())
    }

    @Test fun aFailedOldConnectCannotDiscardANewerEndpoint() {
        val slot = AdbDiscoverySlot()
        val address = InetAddress.getByName("127.0.0.1")
        val old = slot.begin()
        assertTrue(slot.publish(old, address, 37123))
        val failed = slot.current()
        val replacement = slot.begin()
        assertTrue(slot.publish(replacement, address, 45269))
        val current = slot.current()

        slot.discard(failed)

        assertSame(current, slot.current())
        slot.discard(current)
        assertNull(slot.current())
        assertTrue(slot.publish(replacement, address, 45269))
    }

    @Test fun finishingPairingKeepsConnectDiscoveryLive() {
        val pairing = AdbDiscoverySlot()
        val connect = AdbDiscoverySlot()
        val address = InetAddress.getByName("127.0.0.1")
        val pairTicket = pairing.begin()
        val connectTicket = connect.begin()
        assertTrue(pairing.publish(pairTicket, address, 37123))
        assertTrue(connect.publish(connectTicket, address, 45269))

        pairing.retire()

        assertFalse(pairing.publish(pairTicket, address, 37123))
        assertNull(pairing.current())
        assertTrue(connect.publish(connectTicket, address, 45270))
        assertFalse(connect.publish(pairTicket, address, 37123))
        assertEquals(45270, connect.current()!!.port)
    }
}
