package com.skyjjgw.independent.ski

import android.app.ActivityManager
import android.app.UiAutomation
import android.content.Intent
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.test.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

/** Test-only restoration of an existing task, without launching a second app entry activity. */
internal object PhoneQaTaskRestore {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    fun studyTask():Int {
        val automation=instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        val dump=automation.executeShellCommand("dumpsys activity activities").use {
            ParcelFileDescriptor.AutoCloseInputStream(it).use { stream->stream.readBytes().toString(Charsets.UTF_8) }
        }
        return Regex("topResumedActivity=.*com\\.chaoxing\\.mobile/[^\\n]* t(\\d+)").find(dump)
            ?.groupValues?.get(1)?.toInt()?:error("请先将学习通题目页面置于前台。")
    }
    fun restoreStudy(task:Int) {
        val automation=instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        automation.adoptShellPermissionIdentity("android.permission.REORDER_TASKS")
        try { InstrumentationRegistry.getTargetContext().getSystemService(ActivityManager::class.java).moveTaskToFront(task,0) }
        finally { automation.dropShellPermissionIdentity() }
        val deadline=SystemClock.uptimeMillis()+5000
        var pkg:String?=null
        while(SystemClock.uptimeMillis()<deadline) {
            pkg=visionUi {
                val root=SkivuAccessibilityService.connected?.rootInActiveWindow
                try{root?.packageName?.toString()}finally{@Suppress("DEPRECATION") root?.recycle()}
            }
            if(pkg=="com.chaoxing.mobile")return
            Thread.sleep(25)
        }
        error("学习通现有任务尚未恢复，当前软件：$pkg")
    }
}

class PhoneTaskRestoreAcceptanceTest {
    @Test fun restoresExistingStudyTaskWithoutReopeningItsLauncher() {
        assertEquals("confirmed",InstrumentationRegistry.getArguments().getString("skivuPhysicalQa"))
        val context=InstrumentationRegistry.getTargetContext()
        assertTrue(context.packageName.endsWith(".phoneflowqa"))
        val study=PhoneStudyNavigationTest()
        try {
            study.setup()
            val task=PhoneQaTaskRestore.studyTask()
            context.startActivity(Intent().setClassName(context.packageName+".test",PhoneOcrFixtureActivity::class.java.name)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION))
            Thread.sleep(500)
            PhoneQaTaskRestore.restoreStudy(task)
        } finally { study.restore() }
    }
}
