package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

class OwnerScopesTest {
    private fun enter(table: OwnerScopes<Any, String>, owner: String, maintenance: Boolean = false,
                      release: Boolean = false, opening: Boolean = !release) =
        table.enter(owner, opening, maintenance, release) { Any() }
    private fun record(entry: OwnerScopes.Entry<Any, String>) =
        (entry as OwnerScopes.Entry.Acquired<Any, String>).record

    @Test fun fourthOwnerNeverConstructsAResourceAndUnknownReleaseNeverInventsReceipt() {
        val table = OwnerScopes<Any, String>()
        for (id in listOf("A", "B", "C")) table.leave(record(enter(table, id)))
        var created = false
        val fourth = table.enter("D", true, false, false) { created = true; Any() } as OwnerScopes.Entry.Refused<Any, String>
        assertEquals("scopeCapacity", fourth.code); assertTrue(fourth.unknown); assertFalse(created)
        val release = enter(table, "D", release = true) as OwnerScopes.Entry.Refused<Any, String>
        assertTrue(release.unknown); assertEquals("identityChanged", release.code)
    }

    @Test fun releaseSealsBusyOriginalBodyAndOnlyItsEventualReceiptFreesSlot() {
        val table = OwnerScopes<Any, String>(limit = 1)
        val original = record(enter(table, "A"))
        val whileBusy = enter(table, "A", release = true) as OwnerScopes.Entry.Refused<Any, String>
        assertEquals("releasePending", whileBusy.code); assertFalse(whileBusy.unknown)
        assertEquals("scopeCapacity", (enter(table, "B") as OwnerScopes.Entry.Refused<Any, String>).code)
        table.leave(original) // actual body returned, not a logical timeout
        assertEquals("releasePending", (enter(table, "A") as OwnerScopes.Entry.Refused<Any, String>).code)
        val retry = record(enter(table, "A", release = true)); assertSame(original, retry)
        table.leave(retry) // physical cleanup unknown
        assertEquals("scopeCapacity", (enter(table, "B") as OwnerScopes.Entry.Refused<Any, String>).code)
        table.leave(record(enter(table, "A", release = true)), "original completion")
        assertEquals("original completion", (enter(table, "A", release = true) as OwnerScopes.Entry.Completed<Any, String>).receipt)
        assertTrue(enter(table, "B") is OwnerScopes.Entry.Acquired)
        assertFalse((enter(table, "A") as OwnerScopes.Entry.Refused<Any, String>).unknown)
    }

    @Test fun aLongRunningConnectionKeepsAcceptingTasksAndForgetsOnlyTheOldestReceipts() {
        val table = OwnerScopes<Any, String>()
        for (i in 0 until 300) {
            table.leave(record(enter(table, "$i")))
            table.leave(record(enter(table, "$i", release = true)), "receipt-$i")
        }
        assertTrue(enter(table, "next") is OwnerScopes.Entry.Acquired) // never "history full"
        for (i in 44 until 300) {
            assertEquals("identityChanged", (enter(table, "$i") as OwnerScopes.Entry.Refused<Any, String>).code)
            assertEquals("receipt-$i", (enter(table, "$i", release = true) as OwnerScopes.Entry.Completed<Any, String>).receipt)
        }
        // A forgotten owner is unknown: its late RELEASE fails, and the App disconnects instead.
        assertTrue((enter(table, "0", release = true) as OwnerScopes.Entry.Refused<Any, String>).unknown)
    }

    @Test fun maintenanceOwnsWholeResourceLifetimeAndGlobalCannotBypassUnknownScope() {
        val table = OwnerScopes<Any, String>()
        table.leave(record(enter(table, "ordinary")))
        assertEquals("scopeBusy", (enter(table, "probe", maintenance = true) as OwnerScopes.Entry.Refused<Any, String>).code)
        assertEquals("scopeBusy", table.enterGlobal())
        table.leave(record(enter(table, "ordinary", release = true)), "done")
        table.leave(record(enter(table, "probe", maintenance = true)))
        assertEquals("scopeBusy", (enter(table, "new") as OwnerScopes.Entry.Refused<Any, String>).code)
        table.leave(record(enter(table, "probe", release = true)))
        assertEquals("scopeBusy", table.enterGlobal()) // failed cleanup still owns maintenance
        table.leave(record(enter(table, "probe", release = true)), "probe done")
        assertNull(table.enterGlobal()); table.leaveGlobal()
    }

    @Test fun publishedEarlyFailureCanReleaseItsOriginalObjectWithoutReplacingIt() {
        val table = OwnerScopes<Any, String>()
        val original = record(enter(table, "early"))
        table.leave(original) // parser/keyguard failed before platform allocation
        val release = record(enter(table, "early", release = true))
        assertSame(original.core, release.core)
        table.leave(release, "never-created fact from original Core")
        assertFalse((enter(table, "early") as OwnerScopes.Entry.Refused<Any, String>).unknown)
    }

    @Test fun legacyAndHostedModesNeverMixEvenAfterCompletion() {
        val old = OwnerScopes<Any, String>()
        assertNull(old.enterGlobal(legacyResource = true)); old.leaveGlobal()
        assertEquals("scopeModeMismatch", (enter(old, "new") as OwnerScopes.Entry.Refused<Any, String>).code)
        val modern = OwnerScopes<Any, String>()
        modern.leave(record(enter(modern, "A")))
        modern.leave(record(enter(modern, "A", release = true)), "done")
        assertEquals("scopeModeMismatch", modern.enterGlobal(legacyResource = true))
        assertNull(modern.enterGlobal()); modern.leaveGlobal()
    }
}
