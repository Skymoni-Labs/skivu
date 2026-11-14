package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

class PhoneStopSourceTest {
    @Test fun bothScreenReceiversKeepTheScreenSourceAndOriginalHold() {
        var time = 1_000L
        val tasks = PhoneTasks(clock = { time }, stopHoldMs = 30)
        tasks.begin()
        tasks.publish(tasks.stopActiveDeferred("screen off", PhoneTasks.StopSource.SCREEN_OFF))
        val epoch = tasks.admissionEpoch()
        time += 15
        tasks.publish(tasks.stopActiveDeferred("second receiver", PhoneTasks.StopSource.SCREEN_OFF))
        assertEquals("SCREEN_OFF", tasks.snapshot().toMap()["stopSource"])
        assertTrue(tasks.snapshot().interrupted)
        assertTrue(tasks.admissionEpoch() > epoch)
        time += 15
        assertFalse(tasks.snapshot().stopped)
        assertNull(tasks.snapshot().stopSource)
    }

    @Test fun validUserStopUpgradesAScreenHoldAndScreenCannotDowngradeIt() {
        val tasks = PhoneTasks(clock = { 1_000L })
        tasks.begin()
        tasks.publish(tasks.stopActiveDeferred("screen off", PhoneTasks.StopSource.SCREEN_OFF))
        val change = checkNotNull(tasks.stopForSnapshot(tasks.snapshot(), "user stop"))
        tasks.publish(change)
        assertEquals("USER", tasks.snapshot().toMap()["stopSource"])
        assertTrue(tasks.snapshot().interrupted)
        tasks.publish(tasks.stopActiveDeferred("screen off again", PhoneTasks.StopSource.SCREEN_OFF))
        assertEquals(PhoneTasks.StopSource.USER, tasks.snapshot().stopSource)
        tasks.publish(tasks.stopActiveDeferred("service left", PhoneTasks.StopSource.ENVIRONMENT))
        tasks.publish(tasks.stopActiveDeferred("second receiver", PhoneTasks.StopSource.SCREEN_OFF))
        assertEquals(PhoneTasks.StopSource.ENVIRONMENT, tasks.snapshot().stopSource)
    }

    @Test fun ambientRefusalDoesNotPretendTheUserCancelledUnrelatedWork() {
        val tasks = PhoneTasks(clock = { 1_000L })
        tasks.begin()
        tasks.publish(tasks.stopActiveDeferred("screen off", PhoneTasks.StopSource.SCREEN_OFF))
        val refused = tasks.begin() as PhoneTasks.Begin.Refused
        assertFalse(refused.message.contains("用户已停止"))
        assertTrue(refused.message.contains("与手机无关的工作可继续"))
    }
}
