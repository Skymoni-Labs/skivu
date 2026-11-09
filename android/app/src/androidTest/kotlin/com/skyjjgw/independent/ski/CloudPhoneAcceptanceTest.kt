package com.skyjjgw.independent.ski

import android.app.Activity
import android.os.Bundle
import android.os.Build
import android.content.Intent
import android.widget.*
import androidx.test.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import java.io.File
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** A real target app window, separate from the controller package. Not a model
 * simulator: the accessibility service performs actual Android actions. */
class CloudPhoneAcceptanceTest{
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=InstrumentationRegistry.getTargetContext()
    private val testContext get()=InstrumentationRegistry.getContext()
    private fun <T> ui(block:()->T):T{val task=FutureTask(block);android.os.Handler(android.os.Looper.getMainLooper()).post(task);return task.get(10,TimeUnit.SECONDS)}
    private fun service():SkivuAccessibilityService{for(i in 0..200){SkivuAccessibilityService.connected?.let{return it};Thread.sleep(100)};error("QA accessibility service not connected")}
    @Before fun setup(){
        assertTrue(context.packageName.endsWith(".engineqa"));assertTrue(Build.HARDWARE in setOf("ranchu","goldfish"))
        context.getSharedPreferences("cloud-overlay",0).edit().putFloat("y",0f).commit()
        val automation=instrumentation.getUiAutomation(android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        fun shell(command:String){automation.executeShellCommand(command).use{android.os.ParcelFileDescriptor.AutoCloseInputStream(it).use{stream->stream.readBytes()}}}
        shell("settings put secure enabled_accessibility_services null")
        for(i in 0..40){if(SkivuAccessibilityService.connected==null)break;Thread.sleep(50)}
        shell("settings put secure enabled_accessibility_services ${context.packageName}/com.skyjjgw.independent.ski.SkivuAccessibilityService")
        shell("settings put secure accessibility_enabled 1")
        shell("am start -W -n ${testContext.packageName}/${CloudFixtureActivity::class.java.name} --ez large false -f 0x14000000");Thread.sleep(800);service()
    }
    @After fun restore(){ExecutionHub.setMode(context,"hidden");instrumentation.getUiAutomation(android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).setRotation(android.app.UiAutomation.ROTATION_FREEZE_0)}
    private val allowed get()=setOf(testContext.packageName,"com.android.deskclock")
    @Suppress("UNCHECKED_CAST") private fun rows(snapshot:Map<String,Any?>)=snapshot["elements"] as List<Map<String,Any?>>
    @Test fun inputReadbackStaleNodesNavigationAndUnknownAreReal(){
        val service=service();val first=ui{service.observe(allowed)};val edit=rows(first).single{it["viewId"]=="android:id/edit"}
        // System bar updates are not a change to the observed application.
        ui{service.onAccessibilityEvent(android.view.accessibility.AccessibilityEvent.obtain(android.view.accessibility.AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED).apply{packageName="com.android.systemui"})}
        assertTrue(ui{service.act("ui.input",mapOf("observationId" to first["observationId"],"elementId" to edit["id"],"text" to "Skivu actual input"),allowed,{},"input_qa","qa")})
        Thread.sleep(350)
        val verified=ui{service.verify(mapOf("requestId" to "input_qa","expect" to mapOf("kind" to "text","text" to "Skivu actual input")),allowed,"qa")};assertEquals(true,verified["matched"])
        try{ui{service.act("ui.tap",mapOf("observationId" to first["observationId"],"elementId" to edit["id"]),allowed,{})};fail("stale node was accepted")}catch(_:Exception){}
        val current=ui{service.observe(allowed)};val check=rows(current).single{it["viewId"]=="android:id/checkbox"}
        assertTrue(ui{service.act("ui.tap",mapOf("observationId" to current["observationId"],"elementId" to check["id"]),allowed,{},"check_qa","qa")});Thread.sleep(350)
        assertEquals(true,ui{service.verify(mapOf("requestId" to "check_qa","expect" to mapOf("kind" to "checked","checked" to true)),allowed,"qa")}["matched"])
        assertEquals(false,ui{service.verify(mapOf("requestId" to "check_qa","expect" to mapOf("kind" to "checked","checked" to false)),allowed,"qa")}["matched"])
        val page=ui{service.observe(allowed)};val next=rows(page).single{it["viewId"]=="android:id/button1"}
        assertTrue(ui{service.act("ui.tap",mapOf("observationId" to page["observationId"],"elementId" to next["id"]),allowed,{},"next_qa","qa")});Thread.sleep(350)
        assertEquals(true,ui{service.verify(mapOf("requestId" to "next_qa","expect" to mapOf("kind" to "navigation","text" to "第二页面")),allowed,"qa")}["matched"])
        try{ui{service.observe(setOf("unapproved.app"))};fail("unapproved app observed")}catch(_:Exception){}
    }
    @Test fun overlayModesNeverActAndScreenshotExcludesOverlay(){
        val id="qa_overlay_task";var stops=0
        ExecutionHub.bind(id){if(it=="stop")stops++}
        val state=mapOf("taskId" to id,"source" to "native_qa","sequence" to System.currentTimeMillis(),"phase" to "observing","goal" to "观察测试页面","target" to testContext.packageName,"action" to "读取真实控件","phone" to true,"canStop" to true,"canPause" to false)
        context.getSharedPreferences("cloud-overlay",0).edit().putFloat("x",.05f).commit()
        ExecutionHub.setMode(context,"compact");ExecutionHub.update(context,state);Thread.sleep(400)
        fun capture(name:String){val image=instrumentation.getUiAutomation(android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).takeScreenshot();java.io.File(context.filesDir,"qa-overlay-$name.png").outputStream().use{image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)};image.recycle()}
        capture("compact")
        val service=service();val snapshot=ui{service.observe(allowed)};assertFalse(rows(snapshot).any{it["text"].toString().contains("正在观察")})
        val compact=ui{service.overlayReviewMetrics()};assertEquals(false,compact["expanded"]);assertEquals(false,compact["focusable"]);assertEquals(22,compact["avatarDp"]);assertTrue((compact["height"] as Number).toFloat()/context.resources.displayMetrics.density<=37)
        fun centered(label:String,metrics:Map<String,Any?> = ui{service.overlayReviewMetrics()}){
            val bounds=ui{service.getSystemService(android.view.WindowManager::class.java).currentWindowMetrics.bounds}
            val twiceCenter=2*(metrics["x"] as Number).toInt()+(metrics["width"] as Number).toInt()
            assertTrue("$label must stay centered: $metrics, bounds=$bounds",kotlin.math.abs(twiceCenter-bounds.width())<=2)
        }
        centered("compact ignores legacy horizontal preference",compact)
        if(Build.VERSION.SDK_INT>=33){
            val checkbox=rows(snapshot).single{it["viewId"]=="android:id/checkbox"};val area=checkbox["bounds"] as List<*>;val tx=((area[0] as Number).toFloat()+(area[2] as Number).toFloat())/2;val ty=((area[1] as Number).toFloat()+(area[3] as Number).toFloat())/2;val stamp=android.os.SystemClock.uptimeMillis()
            val input=instrumentation.getUiAutomation(android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            input.injectInputEvent(android.view.MotionEvent.obtain(stamp,stamp,android.view.MotionEvent.ACTION_DOWN,tx,ty,0),true);input.injectInputEvent(android.view.MotionEvent.obtain(stamp,stamp+40,android.view.MotionEvent.ACTION_UP,tx,ty,0),true);Thread.sleep(150)
            assertEquals("Transparent surface must pass touches through to the real app",true,rows(ui{service.observe(allowed)}).single{it["viewId"]=="android:id/checkbox"}["checked"])
        }
        val now=android.os.SystemClock.uptimeMillis();val x=(compact["x"] as Number).toFloat()+20*context.resources.displayMetrics.density;val y=(compact["y"] as Number).toFloat()+18*context.resources.displayMetrics.density
        val automation=instrumentation.getUiAutomation(android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        automation.injectInputEvent(android.view.MotionEvent.obtain(now,now,android.view.MotionEvent.ACTION_DOWN,x,y,0),true);automation.injectInputEvent(android.view.MotionEvent.obtain(now,now+80,android.view.MotionEvent.ACTION_UP,x,y,0),true)
        repeat(5){Thread.sleep(45);centered("expanding frame $it")};Thread.sleep(175)
        assertEquals("Expansion must retain the original window",compact["windowGeneration"],ui{service.overlayReviewMetrics()}["windowGeneration"])
        assertEquals(true,ui{service.overlayReviewMetrics()}["expanded"]);capture("expanded")
        centered("expanded")
        fun toggle(){val m=ui{service.overlayReviewMetrics()};val t=android.os.SystemClock.uptimeMillis();val tx=(m["x"] as Number).toFloat()+20*context.resources.displayMetrics.density;val ty=(m["y"] as Number).toFloat()+18*context.resources.displayMetrics.density;automation.injectInputEvent(android.view.MotionEvent.obtain(t,t,android.view.MotionEvent.ACTION_DOWN,tx,ty,0),true);automation.injectInputEvent(android.view.MotionEvent.obtain(t,t+30,android.view.MotionEvent.ACTION_UP,tx,ty,0),true)}
        toggle();Thread.sleep(65);val reversing=ui{service.overlayReviewMetrics()};centered("partially collapsed",reversing);assertTrue((reversing["transition"] as Number).toFloat() in 0f..1f)
        toggle();repeat(6){Thread.sleep(55);centered("reversed expansion $it")};Thread.sleep(100)
        assertEquals(true,ui{service.overlayReviewMetrics()}["expanded"]);assertEquals(compact["windowGeneration"],ui{service.overlayReviewMetrics()}["windowGeneration"])
        val beforeDrag=ui{service.overlayReviewMetrics()};val dragTime=android.os.SystemClock.uptimeMillis()
        val dragX=(beforeDrag["x"] as Number).toFloat()+20*context.resources.displayMetrics.density
        val dragY=(beforeDrag["y"] as Number).toFloat()+18*context.resources.displayMetrics.density
        val distance=80*context.resources.displayMetrics.density
        automation.injectInputEvent(android.view.MotionEvent.obtain(dragTime,dragTime,android.view.MotionEvent.ACTION_DOWN,dragX,dragY,0),true)
        automation.injectInputEvent(android.view.MotionEvent.obtain(dragTime,dragTime+100,android.view.MotionEvent.ACTION_MOVE,dragX+distance,dragY+distance,0),true)
        automation.injectInputEvent(android.view.MotionEvent.obtain(dragTime,dragTime+150,android.view.MotionEvent.ACTION_UP,dragX+distance,dragY+distance,0),true);Thread.sleep(150)
        val dragged=ui{service.overlayReviewMetrics()};centered("horizontal drag cannot offset capsule",dragged)
        assertEquals(true,dragged["expanded"])
        assertTrue("Vertical dragging is preserved",(dragged["y"] as Number).toFloat()>(beforeDrag["y"] as Number).toFloat()+distance/2)
        val image=service.screenshot(allowed);assertEquals(true,image["overlayExcluded"]);assertTrue(image["image"].toString().startsWith("data:image/png;base64,"))
        assertTrue(automation.setRotation(android.app.UiAutomation.ROTATION_FREEZE_90));Thread.sleep(650)
        ui{service.refreshOverlay()};Thread.sleep(300)
        val rotated=ui{service.overlayReviewMetrics()};val bounds=ui{service.getSystemService(android.view.WindowManager::class.java).currentWindowMetrics.bounds}
        centered("landscape expanded",rotated)
        assertTrue((rotated["x"] as Number).toInt()>=0);assertTrue((rotated["y"] as Number).toInt()>=0)
        assertTrue((rotated["x"] as Number).toInt()+(rotated["width"] as Number).toInt()<=bounds.width())
        assertTrue((rotated["y"] as Number).toInt()+(rotated["height"] as Number).toInt()<=bounds.height());capture("rotated")
        assertTrue(automation.setRotation(android.app.UiAutomation.ROTATION_FREEZE_0));Thread.sleep(650);ui{service.refreshOverlay()}
        ExecutionHub.setMode(context,"dot");Thread.sleep(250);assertEquals("dot",ExecutionHub.mode(context));assertEquals(0,stops)
        centered("dot")
        capture("dot")
        ExecutionHub.setMode(context,"compact");Thread.sleep(450);centered("restored compact")
        ExecutionHub.setMode(context,"hidden");ExecutionHub.update(context,state+mapOf("sequence" to System.currentTimeMillis()+1,"phase" to "completed","verified" to true));Thread.sleep(250);assertEquals("hidden",ExecutionHub.mode(context));assertEquals(0,stops)
        ExecutionHub.update(context,state+mapOf("sequence" to System.currentTimeMillis()+2));ExecutionHub.control(id,"stop");Thread.sleep(100);assertEquals(1,stops)
        ExecutionHub.setMode(context,"hidden")
    }
    @Test fun singleAndMultipleSelectionReadbackAndPageChangeUseFreshNodes(){
        val service=service();var observation=ui{service.observe(allowed)}
        fun select(text:String,request:String){
            observation=ui{service.observe(allowed)}
            val element=rows(observation).single{it["text"]==text}
            assertTrue(ui{service.act("ui.tap",mapOf("observationId" to observation["observationId"],"elementId" to element["id"]),allowed,{},request,"qa-choice")})
            Thread.sleep(150)
            assertEquals(true,ui{service.verify(mapOf("requestId" to request,"expect" to mapOf("kind" to "checked","checked" to true)),allowed,"qa-choice")}["matched"])
        }
        assertTrue(rows(observation).any{it["text"]=="单选：选择正数"})
        select("B. 2","positive-single")
        select("A. 2","positive-multiple-a");select("B. 3","positive-multiple-b")
        observation=ui{service.observe(allowed)};val old=rows(observation).single{it["text"]=="B. 2"};val next=rows(observation).single{it["viewId"]=="android:id/button1"}
        assertTrue(ui{service.act("ui.tap",mapOf("observationId" to observation["observationId"],"elementId" to next["id"]),allowed,{})});Thread.sleep(200)
        try{ui{service.act("ui.tap",mapOf("observationId" to observation["observationId"],"elementId" to old["id"]),allowed,{})};fail("previous question node was accepted")}catch(_:Exception){}
        observation=ui{service.observe(allowed)};assertTrue(rows(observation).any{it["text"]=="单选：选择负数"})
        select("A. −2","negative-new-question")
        val actual=rows(ui{service.observe(allowed)});assertEquals(false,actual.single{it["text"]=="B. 2"}["checked"])
        File(context.filesDir,"qa-choice-real-controls.json").writeText(org.json.JSONObject(mapOf("source" to "explicit QA expected answers, not model inference","singleSelectedAndReadBack" to true,"multipleSelectedAndReadBack" to true,"changedQuestionRejectedOldNode" to true,"newQuestionSelectedAndReadBack" to true)).toString())
    }
    @Test fun completeLargePageAndOriginalLosslessScreenshotCrossFormerLimits(){
        instrumentation.getUiAutomation(android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).executeShellCommand("am start -W -n ${testContext.packageName}/${CloudFixtureActivity::class.java.name} --ez large true -f 0x14000000").use{android.os.ParcelFileDescriptor.AutoCloseInputStream(it).readBytes()};Thread.sleep(1000)
        val service=service();val first=ui{service.observe(allowed,mapOf("pageSize" to 1000))}
        val all=rows(first)
        File(context.filesDir,"qa-large-observation.json").writeText(org.json.JSONObject(first).toString())
        assertTrue("Expected >160 nodes, got ${all.size}",all.size>160)
        assertTrue("Full long text absent: ${all.filter{it["text"].toString().startsWith("LONG")}}",all.any{it["text"].toString().startsWith("LONG_TEXT_")&&it["text"].toString().length>500})
        assertTrue("Deep leaf absent: ${all.filter{it["description"].toString().startsWith("DEPTH")}.map{it["description"]}}",all.any{it["text"]=="DEEPEST_REAL_NODE"})
        var page=ui{service.observe(allowed,mapOf("query" to "BOUNDARY_NODE","pageSize" to 37))};val seen=mutableSetOf<String>()
        while(true){rows(page).forEach{seen.add(it["text"].toString())};val next=page["nextOffset"] as? Number?:break;page=ui{service.observe(allowed,mapOf("observationId" to page["observationId"],"query" to "BOUNDARY_NODE","offset" to next.toInt(),"pageSize" to 37))}}
        assertEquals(250,seen.size)
        val image=service.screenshot(allowed);val text=image["image"] as String;assertTrue(text.startsWith("data:image/png;base64,"));val bytes=android.util.Base64.decode(text.substringAfter(','),android.util.Base64.DEFAULT)
        assertTrue("Original screenshot must exceed former 600k byte quota",bytes.size>600000);val decoded=android.graphics.BitmapFactory.decodeByteArray(bytes,0,bytes.size);assertEquals(context.resources.displayMetrics.widthPixels,decoded.width);assertTrue(decoded.width>720);decoded.recycle()
        File(context.filesDir,"qa-original-screenshot.png").writeBytes(bytes)
        File(context.filesDir,"qa-observation-boundaries.json").writeText(org.json.JSONObject(mapOf("visibleNodes" to all.size,"matchedNodes" to seen.size,"pngBytes" to bytes.size,"width" to image["width"],"height" to image["height"],"overlayExcluded" to image["overlayExcluded"])).toString())
    }
}
