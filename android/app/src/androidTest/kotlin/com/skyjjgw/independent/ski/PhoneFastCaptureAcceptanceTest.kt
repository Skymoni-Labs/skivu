package com.skyjjgw.independent.ski

import android.app.UiAutomation
import android.os.Bundle
import android.os.ParcelFileDescriptor
import androidx.test.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** One consent session exercises the same real raster assertions as ordinary capture. */
class PhoneFastCaptureAcceptanceTest {
    @Test fun oneAuthorizedSessionChecksNavigationRedrawAmbiguityAndStop() {
        assertEquals("confirmed", InstrumentationRegistry.getArguments().getString("skivuFastCapture"))
        val suite = PhoneOcrAcceptanceTest()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val passed = mutableListOf<String>()
        val failures = linkedMapOf<String,String>()
        val studyTask=if(InstrumentationRegistry.getArguments().getString("skivuFastStudy")=="confirmed")PhoneQaTaskRestore.studyTask()else null
        fun reset() {
            val pkg = InstrumentationRegistry.getTargetContext().packageName + ".test"
            instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
                .executeShellCommand("am start -W -n $pkg/${PhoneOcrFixtureActivity::class.java.name} -f 0x14010000").use {
                    ParcelFileDescriptor.AutoCloseInputStream(it).use { stream -> stream.readBytes() }
                }
            Thread.sleep(500)
        }
        try {
            suite.setup()
            reset()
            val context=InstrumentationRegistry.getTargetContext()
            val service=SkivuAccessibilityService.connected!!
            var previous:IntArray?=null
            val frames=mutableListOf<Map<String,Any?>>()
            repeat(6) { index ->
                service.captureVision(setOf(context.packageName+".test")){}.use { frame ->
                    val pixels=IntArray(frame.bitmap.width*frame.bitmap.height)
                    frame.bitmap.getPixels(pixels,0,frame.bitmap.width,0,0,frame.bitmap.width,frame.bitmap.height)
                    val older=previous
                    var count=0;var left=frame.bitmap.width;var right=0;var top=frame.bitmap.height;var bottom=0
                    if(older!=null)for(i in pixels.indices)if(pixels[i]!=older[i]) {
                        count++;left=minOf(left,i%frame.bitmap.width);right=maxOf(right,i%frame.bitmap.width)
                        top=minOf(top,i/frame.bitmap.width);bottom=maxOf(bottom,i/frame.bitmap.width)
                    }
                    frames.add(mapOf("index" to index,"stream" to (frame.streamSession!=null),"changedPixels" to count,
                        "changedBounds" to listOf(left,top,right,bottom),"capturedAt" to frame.capturedAt))
                    previous=pixels
                }
                Thread.sleep(80)
            }
            instrumentation.sendStatus(0,Bundle().apply{putString("phoneOcr_fastPixelStability",JSONObject(mapOf("frames" to frames)).toString())})
            val cases = listOf<Pair<String, () -> Unit>>(
                "realChineseRecognition" to suite::realChineseRasterIsRecognizedOfflineAndWarmFramesReuseRecognition,
                "threePageFlips" to suite::localOcrFlowNavigatesFourRasterPagesWithoutModelRoundTrips,
                "duplicateBlocked" to suite::preparedObservationDetectsDuplicateOutsideTheOriginalTarget,
                "movedTargetRelocated" to suite::preparedObservationRelocatesMovedTargetAndConfirmsItsRecognizedFrameBeforeDispatch,
                "redrawDuringOcrBlocked" to suite::rasterRedrawAfterRecognitionIsRejectedBeforeDispatch,
                "ambiguousTargetRegion" to suite::ambiguousTextIsBlockedAndRegionSelectsTheRightActualTouchTarget,
                "staleCoordinatesBlocked" to suite::movedRasterTargetIsNotClickedAtOldCoordinates,
            )
            for ((name, test) in cases) {
                reset()
                try { test(); passed.add(name) }
                catch(error:Throwable) { failures[name]=error.toString() }
            }
            if(InstrumentationRegistry.getArguments().getString("skivuFastStudy")=="confirmed") {
                PhoneControlArbiter.release("qa:phone-ocr")
                val study=PhoneStudyNavigationTest()
                try { PhoneQaTaskRestore.restoreStudy(studyTask!!);study.setup();study.navigateNextQuestionAndReturnToPreparedQuestion();passed.add("studyNextAndReturn") }
                catch(error:Throwable) { failures["studyNextAndReturn"]=error.toString() }
                finally { study.restore() }
            }
            reset()
            try { suite.stoppedProjectionFrameIsRejectedAndOrdinaryCaptureStillWorks();passed.add("stopInvalidatesFrameAndFallsBack") }
            catch(error:Throwable) { failures["stopInvalidatesFrameAndFallsBack"]=error.toString() }
            assertTrue(failures.toString(),failures.isEmpty())
        } finally {
            suite.restore()
            instrumentation.sendStatus(0, Bundle().apply {
                putString("phoneOcr_fastSession", JSONObject(mapOf("passedCases" to passed,"failures" to failures,"systemConsentSessions" to 1)).toString())
            })
        }
    }
}
