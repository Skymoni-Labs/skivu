package com.skyjjgw.independent.ski

import android.app.UiAutomation
import android.content.ComponentName
import android.content.Intent
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.test.InstrumentationRegistry
import com.skyjjgw.independent.ski.dshgo.phone.*
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*

/** Actual Skivu adapter -> authenticated original MCP -> original A11y driver. */
class DshGoPhoneAcceptanceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=InstrumentationRegistry.getTargetContext()
    private val fixture get()=InstrumentationRegistry.getContext().packageName
    private lateinit var host:DshGoPhoneHost
    private val control get()=PhoneControl.get(context)
    private val owner="qa:dsh-go:${System.nanoTime()}"
    private var services="null"
    private var enabled="null"
    private var serial=0
    private fun shell(command:String)=instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        .executeShellCommand(command).use{fd->ParcelFileDescriptor.AutoCloseInputStream(fd).use{String(it.readBytes()).trim()}}
    private fun put(key:String,value:String){shell(if(value=="null")"settings delete secure $key"else "settings put secure $key $value")}
    private fun waitFor(message:String,check:()->Boolean){val until=SystemClock.uptimeMillis()+15000;while(SystemClock.uptimeMillis()<until){if(check())return;Thread.sleep(100)};fail(message)}
    @Before fun setup(){
        require(context.packageName.endsWith(".dshgoqa"))
        services=shell("settings get secure enabled_accessibility_services")
        enabled=shell("settings get secure accessibility_enabled")
        val component=context.packageName+"/com.skyjjgw.independent.ski.dshgo.phone.a11y.PhoneA11yService"
        val list=services.takeUnless{it=="null"||it.isBlank()}?.split(':')?.toMutableList()?:mutableListOf()
        // Installing an updated QA APK can leave its previous binding in
        // AccessibilityManager's crashed-services set. Rebind ONLY our own
        // service, preserving every unrelated entry and the saved baseline.
        list.removeAll{it==component}
        put("enabled_accessibility_services",list.joinToString(":"))
        waitFor("previous QA accessibility binding did not detach"){PhoneRegistry.mainDriver==null}
        if(component !in list)list.add(component)
        put("enabled_accessibility_services",list.joinToString(":"));put("accessibility_enabled","1")
        control.setEnabled(true)
        assertTrue(control.setPolicies(mapOf("confirmMode" to "always")))
        host=DshGoPhoneHost(context)
        val marker="qa_${System.nanoTime()}"
        context.startActivity(Intent().setComponent(ComponentName(fixture,DshGoFixtureActivity::class.java.name)).putExtra("qaMarker",marker).putExtra("qaHostPackage",context.packageName).putExtra("qaSignalToken",owner).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        waitFor("original accessibility service did not connect"){PhoneRegistry.mainDriver!=null}
        waitFor("owned fixture did not become foreground"){
            instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).rootInActiveWindow?.let{root->try{root.packageName?.toString()==fixture && root.findAccessibilityNodeInfosByText(marker).isNotEmpty()}finally{@Suppress("DEPRECATION")root.recycle()}}==true
        }
        Thread.sleep(700)
    }
    @After fun cleanup(){
        control.stopTask("QA finished")
        control.setEnabled(false)
        if(::host.isInitialized)host.close()
        put("enabled_accessibility_services",services);put("accessibility_enabled",enabled)
        if(!services.contains(context.packageName+"/com.skyjjgw.independent.ski.dshgo.phone.a11y.PhoneA11yService"))
            waitFor("owned accessibility binding did not detach"){PhoneRegistry.mainDriver==null}
        assertEquals(services,shell("settings get secure enabled_accessibility_services"))
        assertEquals(enabled,shell("settings get secure accessibility_enabled"))
    }
    private fun call(tool:String,args:Map<String,Any?> =emptyMap(),id:String="request_${++serial}",asOwner:String=owner):Map<*,*>{
        val method=DshGoPhoneHost::class.java.getDeclaredMethod("invoke",Map::class.java).apply{isAccessible=true}
        @Suppress("UNCHECKED_CAST")
        return method.invoke(host,mapOf("version" to 1,"requestId" to id,"owner" to asOwner,"tool" to tool,"arguments" to args)) as Map<*,*>
    }
    private fun text(receipt:Map<*,*>)=((receipt["value"] as? Map<*,*>)?.get("content") as? List<*>)?.filterIsInstance<Map<*,*>>()?.filter{it["type"]=="text"}?.joinToString("\n"){it["text"].toString()}?:""
    private fun screen(receipt:Map<*,*>)=Regex("\\b[bs][0-9]+\\b").find(text(receipt))?.value?:error("native screen ID missing")
    private fun element(receipt:Map<*,*>,label:String)=text(receipt).lineSequence().firstOrNull{it.contains(label)}?.let{Regex("\\[([0-9]+)\\]").find(it)?.groupValues?.get(1)?.toInt()}?:error("owned fixture element missing: $label")
    @Test fun originalCatalogAndRealScreen(){
        // Resolve the installed manifest as well as the original protocol:
        // applicationId and the Kotlin namespace are intentionally different.
        val probe="com.skyjjgw.independent.ski.dshgo.phone.background.BackgroundProbeActivity"
        assertEquals(probe,context.packageManager.getActivityInfo(ComponentName(context.packageName,probe),0).name)
        val contract=Class.forName("com.skyjjgw.independent.ski.dshgo.phone.background.ProbeActivityContract")
        assertEquals(probe,contract.getDeclaredField("ACTIVITY").apply{isAccessible=true}.get(null))
        assertEquals(context.packageName,contract.getDeclaredField("PACKAGE").apply{isAccessible=true}.get(null))
        val catalog=PhoneToolCatalog.tools
        assertEquals(14,catalog.size)
        assertEquals(listOf("screen","id"),catalog.first{it.name=="tap"}.required)
        val read=call("phone.screen")
        assertEquals("verified",read["outcome"])
        assertTrue(text(read).contains("Skivu DSH Go fixture"))
        assertTrue(text(call("phone.apps",mapOf("query" to fixture))).contains(fixture))
    }
    @Test fun duplicateActionIsNotReplayedAndOldScreenDoesNotHitChangedTarget(){
        val before=call("phone.screen")
        val args=mapOf("screen" to screen(before),"id" to element(before,"增加计数"))
        val tapped=call("phone.tap",args,"single_tap")
        assertEquals("verified",tapped["outcome"])
        assertEquals(tapped["outcome"],call("phone.tap",args,"single_tap")["outcome"])
        assertEquals("verified",call("phone.tap",mapOf("id" to args["id"],"screen" to args["screen"]),"single_tap")["outcome"])
        val current=call("phone.screen")
        assertTrue(text(current).contains("点击计数 1"))
        assertEquals("verified",call("phone.tap",mapOf("screen" to screen(current),"id" to element(current,"下一页")))["outcome"])
        val stale=call("phone.tap",args)
        assertEquals("unknown",stale["outcome"])
        assertEquals(true,(stale["value"] as? Map<*,*>)?.get("isError"))
        assertEquals(true,(stale["value"] as? Map<*,*>)?.get("hasUnverifiedActions"))
        assertTrue(text(call("phone.screen")).contains("点击计数 1"))
    }
    @Test fun originalTypeReadsBackActualInput(){
        val before=call("phone.screen")
        val typed=call("phone.type",mapOf("screen" to screen(before),"id" to element(before,"测试内容"),"text" to "Skivu native input"))
        assertEquals("verified",typed["outcome"])
        assertTrue(text(typed).contains("Skivu native input"))
    }
    @Test fun missingPrivilegeAndDisabledMasterNeverPretendToRun(){
        val background=call("phone.open",mapOf("app" to fixture,"background" to true))
        assertEquals(true,(background["value"] as? Map<*,*>)?.get("isError"))
        control.setEnabled(false)
        assertEquals("permission_required",call("phone.screen")["outcome"])
        val reflected=DshGoPhoneHost::class.java.getDeclaredMethod("invoke",Map::class.java).apply{isAccessible=true}
        try{reflected.invoke(host,mapOf("version" to 1,"requestId" to "legacy","owner" to owner,"tool" to "ui.observe","arguments" to emptyMap<String,Any?>()));fail("legacy phone executor accepted")}
        catch(e:java.lang.reflect.InvocationTargetException){assertTrue(e.cause is IllegalArgumentException)}
    }
    @Test fun lostReplyAfterAnActualEffectIsNeverReplayed(){
        val seen=java.util.concurrent.CountDownLatch(1)
        val receiver=object:android.content.BroadcastReceiver(){override fun onReceive(c:android.content.Context,i:Intent){if(i.getStringExtra("token")==owner)seen.countDown()}}
        val filter=android.content.IntentFilter("com.skyjjgw.independent.ski.DSHGO_QA_EFFECT")
        if(android.os.Build.VERSION.SDK_INT>=33)context.registerReceiver(receiver,filter,android.content.Context.RECEIVER_EXPORTED)
        else @Suppress("DEPRECATION") context.registerReceiver(receiver,filter)
        val worker=java.util.concurrent.Executors.newSingleThreadExecutor()
        try{
            val before=call("phone.screen")
            val args=mapOf("screen" to screen(before),"id" to element(before,"计数后延迟回执"))
            val pending=worker.submit<Map<*,*>>{call("phone.tap",args,"lost_reply")}
            if(!seen.await(10,java.util.concurrent.TimeUnit.SECONDS))
                fail("owned effect did not occur: "+if(pending.isDone)text(pending.get())else "original work still pending")
            // Fault injection into this test launch only, after the actual UI effect.
            val originalBridge=PhoneControl::class.java.getDeclaredField("bridge").apply{isAccessible=true}.get(control) as PhoneBridge
            @Suppress("UNCHECKED_CAST")
            val peers=PhoneBridge::class.java.getDeclaredField("open").apply{isAccessible=true}.get(originalBridge) as MutableSet<java.io.Closeable>
            // Android close() alone need not interrupt a different thread's
            // blocked read. A peer shutdown models a real broken transport.
            synchronized(peers){peers.filterIsInstance<android.net.LocalSocket>().forEach{runCatching{it.shutdownOutput()};runCatching{it.shutdownInput()}}}
            originalBridge.stop()
            val lost=pending.get(10,java.util.concurrent.TimeUnit.SECONDS)
            assertEquals("unknown",lost["outcome"])
            Thread.sleep(2000)
            assertEquals("unknown",call("phone.tap",args,"lost_reply")["outcome"])
            val observed=call("phone.screen",asOwner="$owner:verify")
            assertEquals("screen read after reconnect: ${text(observed)}","verified",observed["outcome"])
            assertTrue("unknown action was replayed",text(observed).contains("点击计数 1"))
        }finally{context.unregisterReceiver(receiver);worker.shutdownNow()}
    }
    @Test fun cancelledOwnerCannotAdmitAnotherAction(){
        val before=call("phone.screen")
        val cancel=DshGoPhoneHost::class.java.getDeclaredMethod("cancelOwner",String::class.java).apply{isAccessible=true}
        cancel.invoke(host,owner)
        assertEquals("cancelled",call("phone.tap",mapOf("screen" to screen(before),"id" to element(before,"增加计数")))["outcome"])
        assertTrue(text(call("phone.screen",asOwner="$owner:verify")).contains("点击计数 0"))
    }
}
