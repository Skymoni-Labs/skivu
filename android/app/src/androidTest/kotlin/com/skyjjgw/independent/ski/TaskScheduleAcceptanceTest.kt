package com.skyjjgw.independent.ski

import android.content.ContentValues
import android.content.ContentUris
import android.os.Build
import android.provider.CalendarContract
import androidx.test.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import java.time.*

/** Isolated QA package only. No model HTTP requests, system alarms or production app data. */
class TaskScheduleAcceptanceTest {
    private lateinit var context: android.content.Context
    private lateinit var db: TaskDatabase
    private lateinit var schedules: TaskScheduleStore
    private fun document()=JSONObject().put("version",2).put("tasks",org.json.JSONArray().put(JSONObject().put("id","task").put("title","QA task").put("body","").put("date","2025-01-01").put("time","09:00").put("category","生活").put("done",false).put("archived",false).put("created",1).put("updated",1))).put("memories",org.json.JSONArray()).put("receipts",org.json.JSONArray())
    @Before fun setup() {
        context=InstrumentationRegistry.getTargetContext()
        assertTrue(context.packageName.endsWith(".engineqa"));assertTrue(Build.HARDWARE in setOf("ranchu","goldfish"))
        db=TaskDatabase.get(context)
        db.transaction {sql-> for(table in listOf("effects","runs","plans","resources","operations","budgets","documents","migration_backup"))sql.delete(table,null,null)}
        db.initialize(document().toString());schedules=TaskScheduleStore(context)
    }
    private fun plan(kind: String="once",calls: Int=3): JSONObject = schedules.create(JSONObject().put("taskId","task").put("goal","Read tasks and summarize").put("modelIdentity","a".repeat(64)).put("modelName","QA").put("rule",if(kind=="once") JSONObject().put("kind","once").put("at",System.currentTimeMillis()+60_000) else JSONObject().put("kind","interval").put("intervalMinutes",15)).put("maxRequestsPerRun",calls).put("maxDailyRequests",calls),"create")
    @After fun cleanup(){ if(::db.isInitialized) db.transaction {sql->for(table in listOf("effects","runs","plans","resources","operations","budgets","documents","migration_backup"))sql.delete(table,null,null)} }
    private fun due(p: JSONObject,offset: Long=1000): Long {
        val due=System.currentTimeMillis()-offset;p.put("nextAt",due)
        if(p.getJSONObject("rule").getString("kind")=="once") p.getJSONObject("rule").put("at",due)
        db.transaction {db.writePlan(it,p)};return due
    }
    private fun lease(claim: JSONObject)=claim.getJSONObject("run").let {JSONObject().put("id",it.getString("id")).put("token",it.getString("token"))}
    @Test fun migrationAndCASNeverAutoEnableLegacyDates() {
        assertTrue(schedules.list().isEmpty())
        val old=db.document();assertEquals(document().toString(),old["value"])
        val changed=document().put("version",2)
        assertTrue(db.compareAndSet(old["version"] as Int,changed.toString(),null))
        assertFalse(db.compareAndSet(old["version"] as Int,document().toString(),null))
        db.readableDatabase.rawQuery("SELECT value FROM migration_backup",null).use {assertTrue(it.moveToFirst());assertEquals(document().toString(),it.getString(0))}
    }
    @Test fun oneOccurrenceClaimsOnceAndNeverReplaysAfterSuccess() {
        val p=plan();val at=due(p);val claim=schedules.claim(p.getString("id"),1,at)!!
        assertNull(schedules.claim(p.getString("id"),1,at))
        schedules.finish(lease(claim),"verified","done","result")
        assertEquals("ended",schedules.get(p.getString("id")).getString("state"))
        assertNull(schedules.claim(p.getString("id"),1,at))
    }
    @Test fun endedPlanCannotBeRecreatedAfterRecentReceiptsArePruned() {
        val args=JSONObject().put("taskId","task").put("goal","Original plan").put("modelIdentity","a".repeat(64)).put("rule",JSONObject().put("kind","once").put("at",System.currentTimeMillis()+60_000))
        val original=schedules.create(args,"original")
        schedules.mutate("cancel",JSONObject().put("id",original.getString("id")).put("expectedRevision",1),"end")
        db.writableDatabase.delete("operations",null,null)
        val replay=schedules.create(args,"original")
        assertEquals(original.getString("id"),replay.getString("id"));assertEquals("ended",replay.getString("state"));assertEquals(1,schedules.list().size)
    }
    @Test fun repeatedPlanKeepsNextOccurrenceAndAllowsTomorrowAfterToday() {
        val p=plan("interval");val at=due(p);val first=schedules.claim(p.getString("id"),1,at)!!
        schedules.finish(lease(first),"verified","done","today")
        val next=schedules.get(p.getString("id"));assertEquals("enabled",next.getString("state"));assertTrue(next.getLong("nextAt")>at)
        val later=due(next,200);val second=schedules.claim(next.getString("id"),1,later)!!
        assertNotEquals(first.getJSONObject("run").getString("id"),second.getJSONObject("run").getString("id"))
    }
    @Test fun pauseInvalidatesTheLeaseAndStaleWritesCannotCommit() {
        val p=plan();val at=due(p);val running=schedules.claim(p.getString("id"),1,at)!!
        schedules.mutate("pause",JSONObject().put("id",p.getString("id")).put("expectedRevision",1),"pause")
        try {db.compareAndSet(db.document()["version"] as Int,document().toString(),lease(running));fail("cancelled lease accepted")}catch(_: IllegalArgumentException){}
        assertEquals("paused",schedules.get(p.getString("id")).getString("state"))
    }
    @Test fun deadProcessIsUnknownWithoutReplayingAnUncertainOccurrence() {
        val p=plan();val at=due(p);val c=schedules.claim(p.getString("id"),1,at)!!
        val r=c.getJSONObject("run").put("processId",-1);db.transaction {db.writeRun(it,r)}
        schedules.recover()
        assertEquals("unknown",db.run(r.getString("id"))!!.getString("state"))
        assertNull(schedules.claim(p.getString("id"),1,at))
    }
    @Test fun modelBudgetIsReservedBeforeARequestAndRejectsTheNextCall() {
        val p=plan(calls=2);val at=due(p);val l=lease(schedules.claim(p.getString("id"),1,at)!!)
        assertTrue(schedules.reserveModel(l).getBoolean("reserved"));schedules.reserveModel(l)
        try {schedules.reserveModel(l);fail("model budget exceeded")}catch(_: IllegalArgumentException){}
        assertEquals(2,db.run(l.getString("id"))!!.getInt("requests"))
    }
    @Test fun archivingTaskStopsItsPlansInTheSameDocumentTransaction() {
        val p=plan();val at=due(p);val l=lease(schedules.claim(p.getString("id"),1,at)!!)
        val value=document();value.getJSONArray("tasks").getJSONObject(0).put("archived",true)
        assertTrue(db.compareAndSet(db.document()["version"] as Int,value.toString(),null))
        assertEquals("paused",schedules.get(p.getString("id")).getString("state"))
        try{schedules.check(l);fail("archived plan still active")}catch(_: IllegalArgumentException){}
    }
    @Test fun missedWorkSkipsWithoutCreatingABacklog() {
        val p=plan();p.put("maxDelayMinutes",1);val at=due(p,120_000)
        assertNull(schedules.claim(p.getString("id"),1,at))
        val result=schedules.get(p.getString("id"));assertEquals("ended",result.getString("state"));assertEquals("missed",result.getJSONObject("lastRun").getString("state"))
    }
    @Test fun dailyRulesRespectDSTAndDoNotRepeatTheFallBackHour() {
        val zone=ZoneId.of("America/New_York")
        val spring=JSONObject().put("kind","daily").put("time","02:30").put("timeZone",zone.id)
        val after=ZonedDateTime.of(2026,3,8,0,0,0,0,zone).toInstant().toEpochMilli()
        assertEquals(3,Instant.ofEpochMilli(schedules.next(spring,after)!!).atZone(zone).hour)
        val fall=JSONObject().put("kind","daily").put("time","01:30").put("timeZone",zone.id)
        val first=ZonedDateTime.of(2026,11,1,1,30,0,0,zone).toInstant().toEpochMilli()
        assertEquals(2,Instant.ofEpochMilli(schedules.next(fall,first)!!).atZone(zone).dayOfMonth)
    }
    @Test fun headlessHostRefusesUIActionsWithoutLaunchingAnActivity() {
        val p=plan();val at=due(p);val l=lease(schedules.claim(p.getString("id"),1,at)!!)
        val receipt=TaskBackgroundTools(context).invoke(JSONObject().put("tool","apps.launch").put("requestId","qa").put("arguments",JSONObject().put("package","com.android.settings")),l)
        assertEquals("permission_required",receipt["outcome"])
        val original=JSONObject().put("days",org.json.JSONArray(listOf(2,3,4,5,6)))
        assertEquals(setOf(2,3,4,5,6),TaskClockVerification.expectedDays(original,null))
        assertEquals(emptySet<Int>(),TaskClockVerification.expectedDays(original,JSONObject().put("repeat","none")))
        assertEquals(setOf(1,7),TaskClockVerification.expectedDays(original,JSONObject().put("repeat","weekly").put("weekdays",org.json.JSONArray(listOf(6,7)))))
        assertNull(TaskClockVerification.expectedDays(original,JSONObject().put("weekdays",org.json.JSONArray(listOf(1)))))
    }
    @Test fun realCalendarReminderUsesActualIdAndUpdatesAndCancelsWithoutDuplicates() {
        for(permission in listOf("android.permission.READ_CALENDAR","android.permission.WRITE_CALENDAR")) android.os.ParcelFileDescriptor.AutoCloseInputStream(InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("pm grant ${context.packageName} $permission")).use {it.readBytes()}
        val account="Skivu-QA-${System.currentTimeMillis()}"
        val uri=CalendarContract.Calendars.CONTENT_URI.buildUpon().appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER,"true").appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME,account).appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE,CalendarContract.ACCOUNT_TYPE_LOCAL).build()
        val calendar=context.contentResolver.insert(uri,ContentValues().apply {
            put(CalendarContract.Calendars.ACCOUNT_NAME,account);put(CalendarContract.Calendars.ACCOUNT_TYPE,CalendarContract.ACCOUNT_TYPE_LOCAL);put(CalendarContract.Calendars.NAME,account);put(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,account);put(CalendarContract.Calendars.OWNER_ACCOUNT,account);put(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,CalendarContract.Calendars.CAL_ACCESS_OWNER);put(CalendarContract.Calendars.VISIBLE,1);put(CalendarContract.Calendars.SYNC_EVENTS,1);put(CalendarContract.Calendars.CALENDAR_COLOR,0xff0088aa.toInt());put(CalendarContract.Calendars.ALLOWED_REMINDERS,"0,1");put(CalendarContract.Calendars.MAX_REMINDERS,5)
        })!!
        try {
            val resources=TaskResourceStore(context)
            val args=JSONObject().put("taskId","task").put("calendarId",ContentUris.parseId(calendar)).put("at",System.currentTimeMillis()+86_400_000).put("repeat","daily").put("reminderMinutes",30)
            val first=resources.create(args,"remind");assertEquals("verified",first.getString("state"));assertTrue(first.getLong("externalId")>0)
            val again=resources.create(args,"remind");assertEquals(first.getLong("externalId"),again.getLong("externalId"))
            context.contentResolver.insert(CalendarContract.Reminders.CONTENT_URI,ContentValues().apply {put(CalendarContract.Reminders.EVENT_ID,first.getLong("externalId"));put(CalendarContract.Reminders.MINUTES,120);put(CalendarContract.Reminders.METHOD,CalendarContract.Reminders.METHOD_ALERT)})
            val edit=JSONObject().put("id",first.getString("id")).put("expectedRevision",first.getInt("version")).put("expectedTag",again.getJSONObject("actual").getString("tag")).put("title","Renamed QA")
            try {resources.mutate("update",edit,"stale");fail("stale external tag was accepted")}catch(_: IllegalArgumentException){}
            edit.put("expectedTag",resources.verify(first.getString("id")).getJSONObject("actual").getString("tag"))
            val changed=resources.mutate("update",edit,"edit");assertEquals(first.getLong("externalId"),changed.getLong("externalId"));assertEquals("FREQ=DAILY",changed.getJSONObject("actual").getString("rrule"));assertEquals("Renamed QA",changed.getJSONObject("actual").getString("title"))
            assertEquals(2,changed.getJSONObject("actual").getJSONArray("reminders").length())
            assertEquals(changed.getInt("version"),resources.mutate("update",edit,"edit").getInt("version"))
            val cancel=JSONObject().put("id",changed.getString("id")).put("expectedRevision",changed.getInt("version")).put("expectedTag",changed.getJSONObject("actual").getString("tag"))
            assertEquals("cancelled",resources.mutate("cancel",cancel,"cancel").getString("state"))
            assertEquals("cancelled",resources.mutate("cancel",cancel,"cancel").getString("state"))
            db.writableDatabase.delete("operations",null,null)
            assertEquals("cancelled",resources.create(args,"remind").getString("state"))
        } finally {context.contentResolver.delete(calendar,null,null)}
    }
}
