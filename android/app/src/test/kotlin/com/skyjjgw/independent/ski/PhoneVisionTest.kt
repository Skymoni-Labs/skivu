package com.skyjjgw.independent.ski

import org.junit.Assert.*
import org.junit.Test

class PhoneVisionTest {
    private fun row(id:String,text:String,bounds:List<Int>,source:String="ocr")=mapOf<String,Any?>("id" to id,"text" to text,"bounds" to bounds,"source" to source,"screenWidth" to 1080,"screenHeight" to 2400)
    private fun rejects(block:()->Unit){try{block();fail("Expected invalid input to be rejected")}catch(_:IllegalArgumentException){}}
    @Test fun cropAndScaleMapBackToPhysicalPixels(){
        val g=PhoneVision.Geometry(100,400,800,1200,400,600)
        assertEquals(listOf(120,440,300,600),g.screen(listOf(10,20,100,100)))
    }
    @Test fun mappingRoundsOuterEdgeOutward(){assertEquals(listOf(0,0,4,7),PhoneVision.Geometry(0,0,10,20,3,3).screen(listOf(0,0,1,1)))}
    @Test fun invalidAndOutOfImageBoundsAreRejected(){
        rejects{PhoneVision.Geometry(0,0,0,20,3,3)}
        rejects{PhoneVision.Geometry(0,0,10,20,3,3).screen(listOf(0,0,4,3))}
    }
    @Test fun regionsRejectReversalNaNAndWrongLength(){
        rejects{PhoneVision.region(listOf(0.8,0.0,0.2,1.0))}
        rejects{PhoneVision.region(listOf(0.0,Double.NaN,1.0,1.0))}
        rejects{PhoneVision.region(listOf(0.0,0.0,1.0))}
    }
    @Test fun regionIsIndependentOfDeviceResolution(){
        val a=row("a","确认",listOf(800,1800,1000,2000));val b=a+mapOf("bounds" to listOf(400,900,500,1000),"screenWidth" to 540,"screenHeight" to 1200)
        val selector=mapOf("text" to "确认","region" to listOf(0.5,0.5,1.0,1.0))
        assertTrue(PhoneFlow.matches(a,selector,listOf(a)));assertTrue(PhoneFlow.matches(b,selector,listOf(b)))
    }
    @Test fun sameTextElsewhereIsNotSilentlyDeduplicated(){
        val native=row("n","下一题",listOf(0,0,200,100),"accessibility")
        val overlap=row("v1","下 一 题",listOf(10,10,190,90));val other=row("v2","下一题",listOf(700,1800,1000,1900))
        assertEquals(listOf(native,other),PhoneVision.merge(listOf(native),listOf(overlap,other)))
    }
    @Test fun unknownCheckboxStateCannotBeVerifiedFromOcrText(){
        val r=row("v","A. 正确",listOf(20,300,900,360));val snap=PhoneFlow.Snapshot("example.app",1,listOf(r),emptyMap())
        for(value in listOf(true,false))assertFalse(PhoneFlow.satisfied(snap,mapOf("kind" to "checked","selector" to mapOf("text" to "A. 正确"),"checked" to value)))
    }
    @Test fun duplicateTargetRequiresRegion(){
        val rows=listOf(row("a","确定",listOf(0,0,200,100)),row("b","确定",listOf(800,1800,1000,1900)))
        val snap=PhoneFlow.Snapshot("example.app",1,rows,emptyMap())
        rejects{PhoneFlow.unique(snap,mapOf("text" to "确定"))}
        assertEquals("b",PhoneFlow.unique(snap,mapOf("text" to "确定","region" to listOf(0.5,0.5,1.0,1.0)))["id"])
    }
    @Test fun controlsWithTargetAvoidOcrAndMissingTextRequestsIt(){
        val rows=listOf(row("n","设置",listOf(0,0,200,100),"accessibility"))
        assertFalse(PhoneVision.needsOcr(rows,null,listOf(mapOf("text" to "设置"))))
        assertTrue(PhoneVision.needsOcr(rows,null,listOf(mapOf("text" to "下一题"))))
        assertTrue(PhoneVision.needsOcr(rows,"下一题",emptyList()))
    }
    @Test fun passwordTextCannotSuppressVisualFallbackOrMatch(){
        val password=row("p","秘密",listOf(0,0,200,100),"accessibility")+mapOf("password" to true)
        assertFalse(PhoneFlow.matches(password,mapOf("text" to "秘密"),listOf(password)))
        assertTrue(PhoneVision.needsOcr(listOf(password),null,emptyList()))
    }
    @Test fun sourceFilterAndModeValidationAreExplicit(){
        val r=row("v","确定",listOf(0,0,200,100))
        assertFalse(PhoneFlow.matches(r,mapOf("text" to "确定","source" to "accessibility"),listOf(r)))
        assertEquals("auto",PhoneVision.mode(null));assertEquals("visual",PhoneVision.mode("visual"))
        rejects{PhoneVision.mode("cloud")};rejects{PhoneFlow.validateSelector(mapOf("source" to "invented"))}
    }
    @Test fun onlyDocumentedOcrStrokeAndCjkSpacingVariantsAreNormalized(){
        val a=row("v","下ー页",listOf(0,0,200,100))
        assertTrue(PhoneFlow.matches(a,mapOf("text" to "下一页"),listOf(a)))
        assertEquals("下一页",PhoneVision.ocrText("下 一 页"))
        assertEquals("カレー",PhoneVision.ocrText("カレー"))
        assertNotEquals(PhoneVision.ocrText("屏幕"),PhoneVision.ocrText("屏暮"))
        assertFalse(PhoneFlow.matches(a+mapOf("source" to "accessibility"),mapOf("text" to "下一页"),listOf(a)))
    }
    @Test fun coordinatesAloneNeverVerifyContentChange(){
        val r=row("a","第1页",listOf(0,0,200,100),"accessibility");val condition=mapOf("kind" to "changed")
        val a=PhoneFlow.Snapshot("example.app",1,listOf(r),emptyMap())
        val b=a.copy(rows=listOf(r+mapOf("id" to "b","bounds" to listOf(20,20,220,120))))
        assertFalse(PhoneFlow.satisfied(b,condition,PhoneFlow.evidence(a,condition)))
        assertTrue(PhoneFlow.satisfied(b.copy(rows=listOf(r+mapOf("text" to "第2页"))),condition,PhoneFlow.evidence(a,condition)))
    }
    @Test fun ocrNoiseCannotBeUsedAsGenericBusinessChangeProof(){
        val r=row("a","屏暮",listOf(0,0,200,100));val condition=mapOf("kind" to "changed")
        val a=PhoneFlow.Snapshot("example.app",1,listOf(r),emptyMap())
        val b=a.copy(rows=listOf(r+mapOf("text" to "屏幕")))
        rejects{PhoneFlow.satisfied(b,condition,PhoneFlow.evidence(a,condition))}
    }
}
