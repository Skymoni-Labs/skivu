package com.skyjjgw.independent.ski

import android.app.Activity
import android.os.Bundle
import android.os.Build
import android.content.Intent
import android.widget.*
import androidx.test.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** A real target app window, separate from the controller package. Not a model
 * simulator: the accessibility service performs actual Android actions. */
class CloudFixtureActivity:Activity(){
    override fun onCreate(bundle:Bundle?){super.onCreate(bundle);screen(false)}
    private fun screen(next:Boolean){
        val column=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setPadding(24,100,24,24)}
        column.addView(TextView(this).apply{id=android.R.id.title;text=if(next)"第二页面" else "通用手机操控验收";textSize=22f})
        column.addView(EditText(this).apply{id=android.R.id.edit;hint="输入验收内容"})
        column.addView(CheckBox(this).apply{id=android.R.id.checkbox;text="启用测试选项"})
        column.addView(Button(this).apply{id=android.R.id.button1;text="切换页面";setOnClickListener{screen(!next)}})
        column.addView(TextView(this).apply{text="单选：选择正数"})
        column.addView(RadioGroup(this).apply{addView(RadioButton(this@CloudFixtureActivity).apply{text="A. −2"});addView(RadioButton(this@CloudFixtureActivity).apply{text="B. 2"})})
        column.addView(TextView(this).apply{text="多选：选择正数"})
        column.addView(CheckBox(this).apply{text="A. 2"});column.addView(CheckBox(this).apply{text="B. 3"})
        setContentView(column)
    }
}

class CloudPhoneAcceptanceTest{
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=InstrumentationRegistry.getTargetContext()
    private val testContext get()=InstrumentationRegistry.getContext()
    private fun <T> ui(block:()->T):T{val task=FutureTask(block);android.os.Handler(android.os.Looper.getMainLooper()).post(task);return task.get(10,TimeUnit.SECONDS)}
    private fun service():SkivuAccessibilityService{for(i in 0..40){SkivuAccessibilityService.connected?.let{return it};Thread.sleep(100)};error("QA accessibility service not connected")}
    @Before fun setup(){
        assertTrue(context.packageName.endsWith(".engineqa"));assertTrue(Build.HARDWARE in setOf("ranchu","goldfish"))
        val automation=instrumentation.getUiAutomation(android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        fun shell(command:String){automation.executeShellCommand(command).use{android.os.ParcelFileDescriptor.AutoCloseInputStream(it).use{stream->stream.readBytes()}}}
        shell("settings put secure enabled_accessibility_services null")
        shell("settings put secure enabled_accessibility_services ${context.packageName}/com.skyjjgw.independent.ski.SkivuAccessibilityService")
        shell("settings put secure accessibility_enabled 1")
        testContext.startActivity(Intent().setClassName(testContext.packageName,CloudFixtureActivity::class.java.name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));Thread.sleep(800);service()
    }
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
        ExecutionHub.setMode(context,"compact");ExecutionHub.update(context,state);Thread.sleep(400)
        fun capture(name:String){val image=instrumentation.getUiAutomation(android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).takeScreenshot();java.io.File(context.filesDir,"qa-overlay-$name.png").outputStream().use{image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)};image.recycle()}
        capture("compact")
        val service=service();val snapshot=ui{service.observe(allowed)};assertFalse(rows(snapshot).any{it["text"].toString().contains("正在观察")})
        val compact=ui{service.overlayReviewMetrics()};assertEquals(false,compact["expanded"]);assertEquals(false,compact["focusable"]);assertEquals(22,compact["avatarDp"]);assertTrue((compact["height"] as Number).toFloat()/context.resources.displayMetrics.density<=37)
        val now=android.os.SystemClock.uptimeMillis();val x=(compact["x"] as Number).toFloat()+20*context.resources.displayMetrics.density;val y=(compact["y"] as Number).toFloat()+18*context.resources.displayMetrics.density
        val automation=instrumentation.getUiAutomation(android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        automation.injectInputEvent(android.view.MotionEvent.obtain(now,now,android.view.MotionEvent.ACTION_DOWN,x,y,0),true);automation.injectInputEvent(android.view.MotionEvent.obtain(now,now+80,android.view.MotionEvent.ACTION_UP,x,y,0),true);Thread.sleep(400)
        assertEquals(true,ui{service.overlayReviewMetrics()}["expanded"]);capture("expanded")
        val image=service.screenshot(allowed);assertEquals(true,image["overlayExcluded"]);assertTrue(image["image"].toString().startsWith("data:image/jpeg;base64,"))
        assertTrue(automation.setRotation(android.app.UiAutomation.ROTATION_FREEZE_90));Thread.sleep(650)
        ui{service.refreshOverlay()};Thread.sleep(300)
        val rotated=ui{service.overlayReviewMetrics()};val bounds=ui{service.getSystemService(android.view.WindowManager::class.java).currentWindowMetrics.bounds}
        assertTrue((rotated["x"] as Number).toInt()>=0);assertTrue((rotated["y"] as Number).toInt()>=0)
        assertTrue((rotated["x"] as Number).toInt()+(rotated["width"] as Number).toInt()<=bounds.width())
        assertTrue((rotated["y"] as Number).toInt()+(rotated["height"] as Number).toInt()<=bounds.height());capture("rotated")
        assertTrue(automation.setRotation(android.app.UiAutomation.ROTATION_FREEZE_0));Thread.sleep(650);ui{service.refreshOverlay()}
        ExecutionHub.setMode(context,"dot");Thread.sleep(250);assertEquals("dot",ExecutionHub.mode(context));assertEquals(0,stops)
        capture("dot")
        ExecutionHub.setMode(context,"hidden");ExecutionHub.update(context,state+mapOf("sequence" to System.currentTimeMillis()+1,"phase" to "completed","verified" to true));Thread.sleep(250);assertEquals("hidden",ExecutionHub.mode(context));assertEquals(0,stops)
        ExecutionHub.update(context,state+mapOf("sequence" to System.currentTimeMillis()+2));ExecutionHub.control(id,"stop");Thread.sleep(100);assertEquals(1,stops)
        ExecutionHub.setMode(context,"hidden")
    }
}
