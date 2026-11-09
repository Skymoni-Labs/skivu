package com.skyjjgw.independent.ski

import android.os.Build
import android.os.Bundle
import androidx.test.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

/** Read-only verification after a real emulator reboot and headless callback. */
class TaskRecoveryReadbackTest {
    @Test fun persistedPlanRanAfterRebootWithoutAnActivity() {
        val context=InstrumentationRegistry.getTargetContext()
        assertTrue(context.packageName.endsWith(".engineqa"));assertTrue(Build.HARDWARE in setOf("ranchu","goldfish"))
        val id=InstrumentationRegistry.getArguments().getString("recoveryPlanId")!!
        assertTrue(Regex("plan_[a-zA-Z0-9_]+").matches(id))
        val database=TaskDatabase.get(context)
        val p=database.plan(id)!!
        assertEquals("ended",p.getString("state"))
        val result=p.getJSONObject("lastRun")
        assertEquals("verified",result.getString("state"));assertEquals(2,result.getInt("requests"));assertTrue(result.getString("result").isNotEmpty())
        assertEquals(1,database.queryJson(database.readableDatabase,"SELECT data FROM runs WHERE plan_id=?",arrayOf(id)).size)
        assertNotNull(database.task("legacy_migrate"))
        InstrumentationRegistry.getInstrumentation().sendStatus(0,Bundle().apply {putString("SkivuRecovery","$id verified exactly once after reboot; 2 local model requests")})
    }
}
