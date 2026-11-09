package com.skyjjgw.independent.ski

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.AlarmClock
import org.json.JSONObject
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** Conservative current-window proof; never opens a clock or replays an action. */
object TaskClockVerification {
    fun read(context: Context,resource: JSONObject): JSONObject? {
        val service=SkivuAccessibilityService.connected ?: return null
        val prefs=context.getSharedPreferences("skivu.device-engine.v1",0)
        if(!prefs.getBoolean("enabled",false)) return null
        val allowed=prefs.getStringSet("packages",emptySet()).orEmpty()
        val clockPackages=context.packageManager.queryIntentActivities(Intent(AlarmClock.ACTION_SET_ALARM),0).map {it.activityInfo.packageName}.toSet()
        val probe=FutureTask { service.observe(allowed) }
        Handler(Looper.getMainLooper()).post(probe)
        val observation=try {probe.get(5,TimeUnit.SECONDS)} catch(_: Exception){return null}
        if(observation["package"] !in clockPackages) return null
        @Suppress("UNCHECKED_CAST") val rows=(observation["elements"] as? List<Map<String,Any?>>) ?: return null
        val all=rows.joinToString(" "){"${it["text"]} ${it["description"]}"}
        if(resource.optString("pendingAction")=="cancel") {
            if(listOf("暂无闹钟","没有闹钟","无闹钟","No alarms","No alarm").none {all.contains(it,true)})return null
            if(rows.any {it["checkable"]==true})return null
            return JSONObject().put("state","cancelled").put("summary","已从手机时钟的空闹钟列表核对，原提醒已不在列表中。")
        }
        val locator=resource.getJSONObject("locator")
        val change=resource.optJSONObject("desiredChange")
        var hour=locator.getInt("hour");var minute=locator.getInt("minute")
        if(change?.has("at")==true) {val time=java.time.Instant.ofEpochMilli(change.getLong("at")).atZone(java.time.ZoneId.systemDefault());hour=time.hour;minute=time.minute}
        val label=change?.optString("title",locator.optString("label")) ?: locator.optString("label")
        if(label.isBlank())return null // A time alone is not enough to identify an existing alarm.
        val pattern=Regex("(^|\\D)0?$hour[:：]${minute.toString().padStart(2,'0')}(\\D|$)")
        val byId=rows.associateBy {it["id"]}
        fun below(node: Map<String,Any?>,parent: Any?): Boolean {
            var id: Any?=node["id"]
            repeat(25){if(id==parent)return true;id=byId[id]?.get("parentId") ?: return false};return false
        }
        val matches=mutableSetOf<Any?>()
        for(time in rows.filter {pattern.containsMatchIn("${it["text"]} ${it["description"]}")}) {
            var ancestor: Any?=time["parentId"]
            repeat(6) {
                val children=rows.filter {below(it,ancestor)}
                val text=children.joinToString(" "){"${it["text"]} ${it["description"]}"}
                val switches=children.filter {it["checkable"]==true}
                if(switches.size==1 && switches.single()["checked"]==true && text.contains(label)) {
                    val expected=(locator.optJSONArray("days")?.let {a->(0 until a.length()).map {a.getInt(it)}.toSet()} ?: emptySet())
                    val actual=when {
                        text.contains("每天")||text.contains("Every day",true)->(1..7).toSet()
                        text.contains("工作日")||text.contains("Weekdays",true)->(2..6).toSet()
                        else->emptySet()
                    }
                    val single=listOf("明天","今天","一次","Tomorrow","Today","Not repeating").any {text.contains(it,true)}
                    if(expected.isNotEmpty() && actual!=expected) return@repeat
                    if(expected.isEmpty() && (!single || actual.isNotEmpty() || Regex("周[一二三四五六日天]|星期[一二三四五六日天]|\\b(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\\b",RegexOption.IGNORE_CASE).containsMatchIn(text))) return@repeat
                    if(change?.has("at")==true) {
                        val date=java.time.Instant.ofEpochMilli(change.getLong("at")).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
                        val today=java.time.LocalDate.now()
                        val dateProved= date==today && listOf("今天","Today").any{text.contains(it,true)} || date==today.plusDays(1) && listOf("明天","Tomorrow").any{text.contains(it,true)} || text.contains(date.toString()) || text.contains("${date.year}年${date.monthValue}月${date.dayOfMonth}日")
                        if(!dateProved)return@repeat
                    }
                    matches.add(switches.single()["id"])
                }
                ancestor=byId[ancestor]?.get("parentId")
            }
        }
        if(matches.size!=1)return null
        return JSONObject().put("state","verified").put("summary","已从手机时钟当前界面核对匹配项的时间、标签、启用及重复状态；系统对象编号仍不可读。").put("observedAt",System.currentTimeMillis()).put("observedPackage",observation["package"])
    }
}
