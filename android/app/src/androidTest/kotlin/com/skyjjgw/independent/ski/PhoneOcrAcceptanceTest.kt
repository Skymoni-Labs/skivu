package com.skyjjgw.independent.ski

import android.os.Build
import androidx.test.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** Uses real bundled OCR over raster-only Chinese pages, never a mock OCR/model result. */
class PhoneOcrAcceptanceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=InstrumentationRegistry.getTargetContext()
    private val pkg get()=InstrumentationRegistry.getContext().packageName
    private val owner="qa:phone-ocr"
    private lateinit var platform:EmbeddedDevicePlatform
    private var original=mapOf<String,Any?>()
    private var originalMode="hidden"
    private fun shell(command:String)=instrumentation.getUiAutomation(android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        .executeShellCommand(command).use{android.os.ParcelFileDescriptor.AutoCloseInputStream(it).use{stream->stream.readBytes()}}
    private fun <T> ui(block:()->T):T {val task=FutureTask(block);android.os.Handler(android.os.Looper.getMainLooper()).post(task);return task.get(10,TimeUnit.SECONDS)}
    private fun fixture(op:String="read"):org.json.JSONObject {
        val result=java.util.concurrent.CompletableFuture<String>()
        val intent=android.content.Intent().setComponent(android.content.ComponentName(pkg,PhoneOcrFixtureReceiver::class.java.name)).putExtra("op",op)
        context.sendOrderedBroadcast(intent,null,object:android.content.BroadcastReceiver(){override fun onReceive(c:android.content.Context,i:android.content.Intent){result.complete(resultData?:"{}")}},android.os.Handler(android.os.Looper.getMainLooper()),0,null,null)
        return org.json.JSONObject(result.get(10,TimeUnit.SECONDS))
    }
    @Before fun setup(){
        assertTrue(context.packageName.endsWith(".phoneflowqa"))
        val physicalQa=InstrumentationRegistry.getArguments().getString("skivuPhysicalQa")=="confirmed"
        assertTrue(physicalQa || Build.HARDWARE in setOf("ranchu","goldfish"))
        val prefs=context.getSharedPreferences("skivu.device-engine.v1",0)
        original=listOf("enabled","control","allApplications","packages","recognitionMode").associateWith{prefs.all[it]}
        prefs.edit().putBoolean("enabled",true).putBoolean("control",true).putBoolean("allApplications",false).putStringSet("packages",setOf(pkg)).putString("recognitionMode","auto").commit()
        originalMode=ExecutionHub.mode(context);ExecutionHub.setMode(context,"hidden");platform=EmbeddedDevicePlatform(context)
        val component="${context.packageName}/${SkivuAccessibilityService::class.java.name}"
        val enabled=android.provider.Settings.Secure.getString(context.contentResolver,"enabled_accessibility_services").orEmpty().split(':').filter{it.isNotBlank()&&it!="null"&&it!=component}
        shell("settings put secure enabled_accessibility_services ${if(enabled.isEmpty())"null"else enabled.joinToString(":")}")
        repeat(40){if(SkivuAccessibilityService.connected!=null)Thread.sleep(25)}
        shell("settings put secure enabled_accessibility_services ${(enabled+component).joinToString(":")}");shell("settings put secure accessibility_enabled 1")
        shell("am start -W -n $pkg/${PhoneOcrFixtureActivity::class.java.name} -f 0x14010000")
        repeat(200){if(SkivuAccessibilityService.connected==null)Thread.sleep(25)}
        assertNotNull(SkivuAccessibilityService.connected);assertTrue(fixture().toString(),fixture().optBoolean("alive"));Thread.sleep(150)
        if(InstrumentationRegistry.getArguments().getString("skivuFastCapture")=="confirmed") {
            context.startActivity(android.content.Intent(context,PhoneScreenCaptureActivity::class.java).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
            val deadline=android.os.SystemClock.uptimeMillis()+600_000
            while(PhoneScreenCaptureService.active==null && android.os.SystemClock.uptimeMillis()<deadline)Thread.sleep(25)
            assertNotNull("The test needs a system-authorized projection session",PhoneScreenCaptureService.active)
            Thread.sleep(150)
        }
    }
    @After fun restore(){
        PhoneScreenCaptureService.stop(context)
        platform.close();val edit=context.getSharedPreferences("skivu.device-engine.v1",0).edit()
        for((key,value)in original)when(value){null->edit.remove(key);is Boolean->edit.putBoolean(key,value);is String->edit.putString(key,value);is Set<*>->edit.putStringSet(key,value.filterIsInstance<String>().toSet())}
        edit.commit();ExecutionHub.setMode(context,originalMode);PhoneControlArbiter.release(owner)
    }
    private fun call(tool:String,args:Map<String,Any?>,id:String="ocr_${System.nanoTime()}",asOwner:String=owner)=platform.invokeLeased(mapOf("version" to 1,"owner" to asOwner,"requestId" to id,"tool" to tool,"arguments" to args),{})
    private fun value(result:Map<String,Any?>)=PhoneFlow.map(result["value"],"value")
    private fun report(name:String,data:Map<String,Any?>){instrumentation.sendStatus(0,android.os.Bundle().apply{putString("phoneOcr_$name",org.json.JSONObject(data).toString())})}
    private fun metrics()=SkivuAccessibilityService.connected!!.visionMetrics.snapshot()
    private fun metricDelta(before:Map<String,Long>)=metrics().mapValues{(key,value)->value-(before[key]?:0L)}
    private fun condition(text:String,region:List<Double>?=null)=mapOf("kind" to "exists","selector" to (mapOf("textContains" to text)+if(region==null)emptyMap()else mapOf("region" to region)))
    private val headingRegion=listOf(0.1,0.15,0.9,0.35)
    private fun next(i:Int)=mapOf("id" to "next_$i","action" to "tap","selector" to mapOf("textContains" to "下一"),"guard" to condition(i.toString(),headingRegion),"expect" to condition((i+1).toString(),headingRegion),"timeoutMs" to 15000,"stableMs" to 100)
    private fun plan(steps:List<Map<String,Any?>>,mode:String="visual")=mapOf("package" to pkg,"recognitionMode" to mode,"steps" to steps)

    @Test fun realChineseRasterIsRecognizedOfflineAndWarmFramesReuseRecognition(){
        val native=value(call("ui.observe",mapOf("recognitionMode" to "controls","pageSize" to 1000)))
        assertFalse(native.toString().contains("下一页"));assertFalse(native.toString().contains("屏幕识别测试"))
        val first=call("ui.observe",mapOf("recognitionMode" to "visual","pageSize" to 1000));assertEquals(first.toString(),"verified",first["outcome"])
        val result=value(first)
        val recognized=(result["elements"] as List<*>).map{PhoneFlow.map(it,"row")}
        assertTrue(result.toString(),recognized.any{PhoneVision.ocrText(it["text"]).contains("下一页")})
        assertTrue(result.toString(),recognized.any{it["text"]=="确定"} && recognized.any{it["text"].toString().contains("第1页")})
        var warm=value(call("ui.observe",mapOf("recognitionMode" to "visual","pageSize" to 1000)))
        var attempts=1
        while(PhoneFlow.map(warm["recognition"],"recognition")["recognitionCacheHit"]!=true && attempts<4){warm=value(call("ui.observe",mapOf("recognitionMode" to "visual","pageSize" to 1000)));attempts++}
        report("recognition",mapOf("realOcr" to true,"nativeTextAbsent" to true,"first" to result["recognition"],"warm" to warm["recognition"],"warmAttempts" to attempts))
        assertEquals(warm.toString(),true,PhoneFlow.map(warm["recognition"],"recognition")["recognitionCacheHit"])
    }
    @Test fun localOcrFlowNavigatesFourRasterPagesWithoutModelRoundTrips(){
        val before=metrics()
        val result=call("ui.flow",plan((1..3).map{next(it)}));assertEquals(result.toString(),"verified",result["outcome"])
        assertEquals(4,fixture().getInt("page"));assertEquals(3,fixture().getInt("taps"))
        val v=value(result);assertEquals(0,v["modelRequestsDuringExecution"]);assertEquals(false,v["hasUnverifiedActions"])
        val counts=metricDelta(before)
        val observationCount=(v["observationCount"] as Number).toLong()
        val refreshCount=counts.getValue("preDispatchRefreshCount")
        report("flow",v.filterKeys{it in setOf("elapsedMs","completedSteps","observationCount","modelRequestsDuringExecution")}+
            mapOf("performance" to counts,"unchangedFrameCaptureBudget" to 10,
                "additionalResultSamples" to (observationCount-7L).coerceAtLeast(0),
                "freshDispatchChecks" to 3,"changedPreDispatchConfirmations" to refreshCount))
        assertTrue(counts.toString(),counts.getValue("reusedObservationCount")>=2L)
        assertTrue(counts.toString(),observationCount>=7L)
        assertEquals(counts.toString(),observationCount+3L+refreshCount,counts.getValue("captureCount"))
    }
    @Test fun stoppedProjectionFrameIsRejectedAndOrdinaryCaptureStillWorks(){
        if(InstrumentationRegistry.getArguments().getString("skivuFastCapture")!="confirmed")return
        val service=SkivuAccessibilityService.connected!!
        val stream=PhoneScreenCaptureService.active!!
        // Request a redraw on every check so a genuinely new raster frame is available.
        val frame=service.captureVision(setOf(pkg)) { fixture("redraw") }
        frame.use {
            assertEquals(stream.session,it.streamSession)
            assertTrue(it.capturedAt<=android.os.SystemClock.uptimeMillis())
            PhoneScreenCaptureService.stop(context)
            val failure=runCatching { visionUi{service.assertVisualFrame(it,setOf(pkg))} }.exceptionOrNull()
            assertNotNull("A stopped projection must invalidate its frame",failure)
        }
        service.captureVision(setOf(pkg)){}.use { assertNull(it.streamSession) }
        assertEquals(0,fixture().getInt("taps"))
    }
    @Test fun preparedObservationDetectsDuplicateOutsideTheOriginalTarget(){
        val service=SkivuAccessibilityService.connected!!
        val step=next(1)
        val prepared=service.vision.snapshot(setOf(pkg),pkg,"visual",owner,{},step)
        assertEquals(1,PhoneFlow.targets(prepared,PhoneFlow.map(step["selector"],"selector")).size)
        fixture("duplicateNext");Thread.sleep(100)
        val before=metrics()
        var dispatched=false
        val failure=runCatching {
            service.vision.perform(step,pkg,setOf(pkg),"visual",owner,"duplicate_${System.nanoTime()}",{},
                preparedSnapshot=prepared,before={dispatched=true})
        }.exceptionOrNull()
        val counts=metricDelta(before)
        val diagnostic=service.vision.snapshot(setOf(pkg),pkg,"visual",owner,{},step)
        val targets=PhoneFlow.targets(diagnostic,PhoneFlow.map(step["selector"],"selector"))
        report("preparedDuplicate",mapOf("newDuplicateBlocked" to (failure!=null),"originalTargetUnmoved" to true,
            "noGesture" to !dispatched,"freshTargetCount" to targets.size,
            "freshTargets" to targets.map{mapOf("text" to it["text"],"bounds" to it["bounds"])},
            "failure" to failure?.message,"performance" to counts))
        assertEquals("The independently read frame must expose both actual raster targets",2,targets.size)
        assertNotNull("A new second target must make the prepared selection ambiguous",failure)
        assertFalse(dispatched)
        assertEquals(0,fixture().getInt("taps"))
        assertEquals(counts.toString(),1L,counts.getValue("captureCount"))
        assertEquals(counts.toString(),1L,counts.getValue("ocrCount"))
    }
    @Test fun preparedObservationRelocatesMovedTargetAndConfirmsItsRecognizedFrameBeforeDispatch(){
        val service=SkivuAccessibilityService.connected!!
        val step=next(1)
        val prepared=service.vision.snapshot(setOf(pkg),pkg,"visual",owner,{},step)
        fixture("move");Thread.sleep(100)
        val before=metrics()
        var dispatched=false
        val result=service.vision.perform(step,pkg,setOf(pkg),"visual",owner,"relocated_${System.nanoTime()}",{},
            preparedSnapshot=prepared,before={dispatched=true})
        assertTrue(result.accepted);assertTrue(result.dispatched);assertTrue(dispatched)
        val touchDeadline=android.os.SystemClock.uptimeMillis()+2000
        var touched=fixture()
        while(touched.getInt("taps")==0 && android.os.SystemClock.uptimeMillis()<touchDeadline) {
            Thread.sleep(25);touched=fixture()
        }
        val counts=metricDelta(before)
        report("preparedMoved",mapOf("freshSemanticRelocation" to true,"recognizedFrameConfirmedBeforeDispatch" to true,
            "pageAdvanced" to (touched.getInt("page")==2),"actualTaps" to touched.getInt("taps"),"performance" to counts))
        assertEquals(1,touched.getInt("taps"));assertEquals(2,touched.getInt("page"))
        assertEquals(counts.toString(),2L,counts.getValue("captureCount"))
        assertEquals(counts.toString(),1L,counts.getValue("ocrCount"))
    }
    @Test fun rasterRedrawAfterRecognitionIsRejectedBeforeDispatch(){
        val service=SkivuAccessibilityService.connected!!
        val step=next(1)
        val prepared=service.vision.snapshot(setOf(pkg),pkg,"visual",owner,{},step)
        fixture("move");Thread.sleep(100)
        val before=metrics()
        val redrawn=java.util.concurrent.atomic.AtomicBoolean(false)
        var dispatched=false
        val check={
            if(android.os.Looper.myLooper()!=android.os.Looper.getMainLooper() &&
                metrics().getValue("ocrCount")>before.getValue("ocrCount") && redrawn.compareAndSet(false,true)) {
                // The fixture only invalidates its raster surface, whose accessible tree has no text nodes.
                fixture("duplicateNext");Thread.sleep(80)
            }
            Unit
        }
        val failure=runCatching {
            service.vision.perform(step,pkg,setOf(pkg),"visual",owner,"redrawn_${System.nanoTime()}",check,
                preparedSnapshot=prepared,before={dispatched=true})
        }.exceptionOrNull()
        assertTrue("The fixture must redraw after the changed-frame OCR has completed",redrawn.get())
        assertNotNull(failure)
        assertTrue(failure.toString(),failure?.message?.contains("识别期间") == true)
        assertFalse(dispatched);assertEquals(0,fixture().getInt("taps"))
        val counts=metricDelta(before)
        assertEquals(counts.toString(),2L,counts.getValue("captureCount"))
        assertEquals(counts.toString(),1L,counts.getValue("ocrCount"))
        report("redrawnDuringRecognition",mapOf("rasterChangedAfterRecognition" to true,
            "freshConfirmationRejected" to true,"noGesture" to true,"performance" to counts))
    }
    @Test fun ambiguousTextIsBlockedAndRegionSelectsTheRightActualTouchTarget(){
        val ambiguous=next(1)+mapOf("selector" to mapOf("text" to "确定"),"expect" to condition("右侧"))
        val blocked=call("ui.flow",plan(listOf(ambiguous)));assertEquals(blocked.toString(),"failed",blocked["outcome"])
        assertEquals(0,fixture().getInt("leftTaps"));assertEquals(0,fixture().getInt("rightTaps"))
        val selected=ambiguous+mapOf("selector" to mapOf("text" to "确定","region" to listOf(0.5,0.35,1.0,0.65)))
        val good=call("ui.flow",plan(listOf(selected)));assertEquals(good.toString(),"verified",good["outcome"])
        assertEquals(0,fixture().getInt("leftTaps"));assertEquals(1,fixture().getInt("rightTaps"))
        report("duplicate",mapOf("ambiguousBlocked" to true,"rightTargetOnly" to true))
    }
    @Test fun movedRasterTargetIsNotClickedAtOldCoordinates(){
        val old=value(call("ui.observe",mapOf("recognitionMode" to "visual","pageSize" to 1000)))
        val target=(old["elements"] as List<*>).map{PhoneFlow.map(it,"row")}.single{PhoneVision.ocrText(it["text"]).contains("下一")}
        fixture("move");Thread.sleep(100)
        val stale=call("ui.tap",mapOf("observationId" to old["observationId"],"elementId" to target["id"]))
        assertEquals(stale.toString(),"failed",stale["outcome"]);assertEquals(0,fixture().getInt("taps"))
        val fresh=call("ui.flow",plan(listOf(next(1))));assertEquals(fresh.toString(),"verified",fresh["outcome"])
        assertEquals(1,fixture().getInt("taps"))
        report("moved",mapOf("oldCoordinatesBlocked" to true,"freshSemanticRelocation" to true))
    }
    @Test fun cancelInterruptsVisualWaitingWithoutDispatching(){
        val id="cancel_${System.nanoTime()}"
        val task=FutureTask{call("ui.flow",plan(listOf(mapOf("id" to "wait","action" to "wait","expect" to condition("永不出现")))),id)}
        Thread(task,"ocr-cancel-acceptance").start();Thread.sleep(400)
        val start=android.os.SystemClock.uptimeMillis();platform.cancelInvocation(owner,id)
        val result=task.get(5,TimeUnit.SECONDS);assertEquals(result.toString(),"cancelled",result["outcome"])
        assertEquals(0,fixture().getInt("taps"))
        report("cancel",mapOf("stopMs" to android.os.SystemClock.uptimeMillis()-start,"noGesture" to true))
    }
    @Test fun observationCannotBeUsedByAnotherConversation(){
        val old=value(call("ui.observe",mapOf("recognitionMode" to "visual","pageSize" to 1000)))
        val target=(old["elements"] as List<*>).map{PhoneFlow.map(it,"row")}.first{PhoneVision.ocrText(it["text"]).contains("下一")}
        PhoneControlArbiter.release(owner)
        try {
            val other=call("ui.tap",mapOf("observationId" to old["observationId"],"elementId" to target["id"]),asOwner="qa:other")
            assertEquals(other.toString(),"failed",other["outcome"]);assertEquals(0,fixture().getInt("taps"))
        }finally{PhoneControlArbiter.release("qa:other")}
        report("owner",mapOf("crossConversationBlocked" to true,"noGesture" to true))
    }
    @Test fun revokingControlInterruptsRecognitionWaiting(){
        val id="revoke_${System.nanoTime()}"
        val task=FutureTask{call("ui.flow",plan(listOf(mapOf("id" to "wait","action" to "wait","expect" to condition("永不出现")))),id)}
        Thread(task,"ocr-revoke-acceptance").start();Thread.sleep(400)
        context.getSharedPreferences("skivu.device-engine.v1",0).edit().putBoolean("control",false).commit()
        val result=task.get(5,TimeUnit.SECONDS);assertEquals(result.toString(),"permission_required",result["outcome"])
        assertEquals(0,fixture().getInt("taps"));report("revoked",mapOf("permissionRequired" to true,"noGesture" to true))
    }
    @Test fun revokingControlBeforeSingleVisualTapPreventsItsGesture(){
        val old=value(call("ui.observe",mapOf("recognitionMode" to "visual","pageSize" to 1000)))
        val target=(old["elements"] as List<*>).map{PhoneFlow.map(it,"row")}.first{PhoneVision.ocrText(it["text"]).contains("下一")}
        val task=FutureTask{call("ui.tap",mapOf("observationId" to old["observationId"],"elementId" to target["id"]))}
        Thread(task,"ocr-tap-revoke").start();Thread.sleep(80)
        context.getSharedPreferences("skivu.device-engine.v1",0).edit().putBoolean("control",false).commit()
        val result=task.get(5,TimeUnit.SECONDS);assertEquals(result.toString(),"permission_required",result["outcome"])
        assertEquals(0,fixture().getInt("taps"));report("singleTapRevoked",mapOf("permissionRequired" to true,"noGesture" to true))
    }
}
