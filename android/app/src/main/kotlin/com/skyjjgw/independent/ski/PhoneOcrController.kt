package com.skyjjgw.independent.ski

import android.graphics.Bitmap
import android.os.SystemClock
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CompletableFuture
import org.json.JSONObject

/** Worker-thread OCR and fresh visual dispatch; recognition never calls an external model. */
internal class PhoneOcrController(private val service:SkivuAccessibilityService) {
    private val recognizerDelegate=lazy { TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build()) }
    private val recognizer by recognizerDelegate
    @Volatile private var closed=false
    private data class Observation(val owner:String,val pkg:String,val window:Int,val rotation:Int,val width:Int,val height:Int,
        val token:String,val rows:List<Map<String,Any?>>,val patches:Map<String,String>,val imageHash:String,val region:Any?)
    private var last:Observation?=null
    private var cachedKey=""
    private var cachedRows=emptyList<Map<String,Any?>>()
    private var visualWindow:Pair<String,Int>?=null
    private val proofPrefs=service.getSharedPreferences("skivu.visual-proofs.v1",0)
    fun close(){closed=true;last=null;cachedRows=emptyList();if(recognizerDelegate.isInitialized())recognizer.close()}
    private fun checkAlive(check:()->Unit){check();kotlin.check(!closed && SkivuAccessibilityService.connected===service){"屏幕识别服务已停止。"}}
    private fun window(allowed:Set<String>)=visionUi {
        val root=service.current(allowed)
        try { root.packageName.toString() to root.windowId } finally { @Suppress("DEPRECATION") root.recycle() }
    }
    private fun native(allowed:Set<String>,args:Map<String,Any?>)=visionUi { service.observe(allowed,args) }
    @Suppress("UNCHECKED_CAST")
    private fun rows(observation:Map<String,Any?>)=observation["elements"] as List<Map<String,Any?>>
    private fun digest(bytes:ByteArray)=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString(""){"%02x".format(it)}
    private fun hash(bitmap:Bitmap):String {
        // Canonical ARGB pixels, excluding allocator-dependent row padding.
        val pixels=IntArray(bitmap.width*bitmap.height)
        bitmap.getPixels(pixels,0,bitmap.width,0,0,bitmap.width,bitmap.height)
        val bytes=java.nio.ByteBuffer.allocate(pixels.size*4);bytes.asIntBuffer().put(pixels)
        return digest(bytes.array())
    }
    private fun patch(bitmap:Bitmap,b:List<Int>):String {
        val x1=b[0].coerceIn(0,bitmap.width-1);val y1=b[1].coerceIn(0,bitmap.height-1)
        val x2=b[2].coerceIn(x1+1,bitmap.width);val y2=b[3].coerceIn(y1+1,bitmap.height)
        val values=ByteArray(24*12*3);var offset=0
        for(y in 0 until 12)for(x in 0 until 24) {
            val pixel=bitmap.getPixel(x1+(x2-x1-1)*x/23,y1+(y2-y1-1)*y/11)
            values[offset++]=((pixel shr 16 and 255)/16).toByte();values[offset++]=((pixel shr 8 and 255)/16).toByte();values[offset++]=((pixel and 255)/16).toByte()
        }
        return digest(values)
    }
    @Suppress("UNCHECKED_CAST")
    private fun box(row:Map<String,Any?>)=(row["bounds"] as List<Number>).map{it.toInt()}
    private fun recognize(frame:PhoneOcrFrame,region:Any?,check:()->Unit):List<Map<String,Any?>> {
        val r=PhoneVision.region(region)?:listOf(0.0,0.0,1.0,1.0)
        val width=frame.bitmap.width;val height=frame.bitmap.height
        val left=(width*r[0]).toInt();val top=(height*r[1]).toInt()
        val w=((width*r[2]).toInt()-left).coerceAtLeast(1);val h=((height*r[3]).toInt()-top).coerceAtLeast(1)
        val imageWidth=minOf(w,1600);val imageHeight=maxOf(1,h.toLong().times(imageWidth).div(w).toInt())
        // ML Kit owns this independent copy until its completion callback, including cancellation.
        val cropped=Bitmap.createBitmap(frame.bitmap,left,top,w,h)
        val scaled=Bitmap.createScaledBitmap(cropped,imageWidth,imageHeight,true)
        val input=scaled.copy(Bitmap.Config.ARGB_8888,false)
        if(scaled!==cropped)scaled.recycle();if(cropped!==frame.bitmap)cropped.recycle()
        val geometry=PhoneVision.Geometry(left,top,w,h,imageWidth,imageHeight)
        val future=CompletableFuture<List<Map<String,Any?>>>()
        try {
            recognizer.process(InputImage.fromBitmap(input,0)).addOnCompleteListener { task ->
                try {
                    if(!task.isSuccessful)future.completeExceptionally(task.exception?:IllegalStateException("本地文字识别失败。"))
                    else {
                        val result=task.result.textBlocks.flatMap{it.lines}.mapNotNull { line ->
                            val bounds=line.boundingBox?:return@mapNotNull null
                            if(line.text.isBlank()||bounds.width()<=0||bounds.height()<=0)return@mapNotNull null
                            val b=listOf(bounds.left.coerceAtLeast(0),bounds.top.coerceAtLeast(0),bounds.right.coerceAtMost(imageWidth),bounds.bottom.coerceAtMost(imageHeight))
                            if(b[2]<=b[0]||b[3]<=b[1])return@mapNotNull null
                            mapOf<String,Any?>("text" to line.text,"bounds" to geometry.screen(b),"source" to "ocr","class" to "ocr.TextLine","screenWidth" to width,"screenHeight" to height)
                        }
                        future.complete(result.sortedWith(compareBy<Map<String,Any?>>({box(it)[1]},{box(it)[0]})))
                    }
                }catch(e:Exception){future.completeExceptionally(e)}finally{input.recycle()}
            }
        }catch(e:Exception){input.recycle();throw e}
        return visionAwait(future){checkAlive(check)}
    }
    fun observe(allowed:Set<String>,args:Map<String,Any?>,mode:String,owner:String,check:()->Unit,
                selectors:List<Map<String,Any?>> = emptyList(),needNative:Boolean=false,allowMissingFallback:Boolean=true):Map<String,Any?> {
        checkAlive(check);PhoneVision.mode(mode)
        require(args.keys.all{it in setOf("observationId","offset","pageSize","query","recognitionMode","region")}){"屏幕观察参数含未知字段。"}
        PhoneVision.region(args["region"])
        val started=SystemClock.uptimeMillis();val current=window(allowed)
        val continuation=args["observationId"] as? String
        if(continuation?.startsWith("ocr:")==true) {
            val saved=last?:error("识别观察已变化，请重新识别。")
            require(saved.token==continuation && saved.owner==owner && current==(saved.pkg to saved.window)){"识别观察已过期。"}
            // Pagination is a read only view of the same frame; dispatch always reacquires pixels.
            return page(saved,args,mapOf("source" to "ocr","continuation" to true))
        }
        if(continuation!=null)return native(allowed,args)
        val useKnown=mode=="auto" && visualWindow==current && !needNative
        val base=if(mode=="controls" || (mode=="auto" && !useKnown))native(allowed,args+mapOf("offset" to 0,"pageSize" to 1000))else null
        val nativeRows=base?.let{rows(it)}.orEmpty()
        if(mode=="controls" || (mode=="auto" && android.os.Build.VERSION.SDK_INT<30) || (mode=="auto" && !useKnown && (!PhoneVision.needsOcr(nativeRows,args["query"] as? String,selectors) || (!allowMissingFallback && !PhoneVision.needsOcr(nativeRows,null,emptyList()))))) {
            last=null
            val offset=(args["offset"] as? Number)?.toInt()?:0;val limit=(args["pageSize"] as? Number)?.toInt()?:100
            require(offset>=0 && limit>0)
            if(offset+minOf(limit,1000)>nativeRows.size && (base!!["total"] as Number).toInt()>nativeRows.size)
                return native(allowed,args+mapOf("observationId" to base["observationId"]))+mapOf("recognition" to mapOf("mode" to mode,"source" to "accessibility"))
            val selected=nativeRows.drop(offset).take(minOf(limit,1000));val next=offset+selected.size
            return base!!+mapOf("elements" to selected,"nextOffset" to if(next<(base["total"] as Number).toInt())next else null,"complete" to (next>=(base["total"] as Number).toInt()),"recognition" to mapOf("mode" to mode,"source" to "accessibility","elapsedMs" to SystemClock.uptimeMillis()-started,"ocrAvailable" to (android.os.Build.VERSION.SDK_INT>=30)))
        }
        service.captureVision(allowed){checkAlive(check)}.use { frame ->
            val captureMs=SystemClock.uptimeMillis()-started
            require(current==(frame.pkg to frame.window)){"读取期间窗口发生变化。"}
            val imageHash=hash(frame.bitmap);val key="${frame.pkg}:${frame.window}:${frame.rotation}:${frame.bitmap.width}:${frame.bitmap.height}:$imageHash:${args["region"]}"
            val hit=key==cachedKey
            val ocrStarted=SystemClock.uptimeMillis()
            val recognized=if(hit)cachedRows else recognize(frame,args["region"]){checkAlive(check)}.also{cachedRows=it;cachedKey=key}
            val ocrMs=SystemClock.uptimeMillis()-ocrStarted
            val ocrRows=recognized.mapIndexed{i,row->row+mapOf("id" to "v_$i","parentId" to null)}
            val combined=if(mode=="auto")PhoneVision.merge(nativeRows,ocrRows)else ocrRows
            val token="ocr:"+UUID.randomUUID()
            val observed=Observation(owner,frame.pkg,frame.window,frame.rotation,frame.bitmap.width,frame.bitmap.height,token,combined,
                combined.associate{it["id"].toString() to patch(frame.bitmap,box(it))},imageHash,args["region"])
            checkAlive(check);visionUi{service.assertVisualFrame(frame,allowed)}
            last=observed;if(mode=="auto")visualWindow=frame.pkg to frame.window
            return page(observed,args,mapOf("mode" to mode,"source" to if(nativeRows.isEmpty())"ocr" else "hybrid","captureMs" to captureMs,
                "ocrMs" to ocrMs,"elapsedMs" to SystemClock.uptimeMillis()-started,"recognitionCacheHit" to hit,"modelRequests" to 0))
        }
    }
    private fun page(saved:Observation,args:Map<String,Any?>,timing:Map<String,Any?>):Map<String,Any?> {
        val query=args["query"] as? String
        val rows=if(query.isNullOrBlank())saved.rows else saved.rows.filter{listOf(it["text"],it["description"],it["viewId"]).any{v->v?.toString()?.contains(query,true)==true}}
        val offset=(args["offset"] as? Number)?.toInt()?:0;val limit=(args["pageSize"] as? Number)?.toInt()?:100
        require(offset>=0 && limit>0)
        val selected=rows.drop(offset).take(minOf(limit,1000));val next=offset+selected.size
        return mapOf("observationId" to saved.token,"package" to saved.pkg,"windowId" to saved.window,"elements" to selected,"total" to rows.size,
            "nextOffset" to if(next<rows.size)next else null,"complete" to (next>=rows.size),"screenWidth" to saved.width,"screenHeight" to saved.height,
            "rotation" to saved.rotation,"recognition" to timing,"scope" to "真实可访问控件与本地识别文字；OCR 不推断可编辑或勾选状态")
    }
    @Suppress("UNCHECKED_CAST")
    fun snapshot(allowed:Set<String>,pkg:String,mode:String,owner:String,check:()->Unit,step:Map<String,Any?>,beforeAction:Boolean=true,allowMissingFallback:Boolean=true):PhoneFlow.Snapshot {
        val selectors=mutableListOf<Map<String,Any?>>()
        if(beforeAction)step["selector"]?.let{selectors.add(PhoneFlow.map(it,"selector"))}
        fun collect(value:Any?){if(value==null)return;val c=PhoneFlow.map(value,"condition");c["selector"]?.let{selectors.add(PhoneFlow.map(it,"selector"))};(c["conditions"] as? List<*>)?.forEach{collect(it)}}
        if(beforeAction)collect(step["guard"])
        if(!beforeAction||step["action"]=="wait"||step["selector"]==null)collect(step["expect"])
        val needNative=step["action"]=="input"||step["expect"].toString().contains("checked")||step["expect"].toString().contains("selected")||selectors.any{it["viewId"]!=null||it["editable"]!=null}
        val observed=observe(allowed,mapOf("pageSize" to 1000),mode,owner,check,selectors,needNative,allowMissingFallback)
        require(observed["package"]==pkg){"当前页面不属于流程指定的软件。"}
        if(!(observed["observationId"] as String).startsWith("ocr:"))return visionUi{service.flowSnapshot(allowed,pkg,observed)}
        return PhoneFlow.Snapshot(pkg,(observed["windowId"] as Number).toInt(),rows(observed),observed)
    }
    fun perform(step:Map<String,Any?>,pkg:String,allowed:Set<String>,mode:String,owner:String,requestId:String,check:()->Unit,dispatchOnly:Boolean=false,before:()->Unit):PhoneFlow.Dispatch {
        val snapshot=snapshot(allowed,pkg,mode,owner,check,step)
        step["guard"]?.let{require(PhoneFlow.satisfied(snapshot,PhoneFlow.map(it,"guard"))){"当前画面不满足前置条件。"}}
        if(!dispatchOnly && PhoneFlow.satisfied(snapshot,PhoneFlow.map(step["expect"],"expect")))return PhoneFlow.Dispatch(true,false)
        if(!(snapshot.observation["observationId"] as String).startsWith("ocr:"))return visionUi{service.flowPerform(step,pkg,allowed,before,requestId,owner)}
        val action=step["action"] as String
        if(action=="back")return visionUi{service.flowPerform(step - "guard",pkg,allowed,before,requestId,owner)}
        val target=PhoneFlow.unique(snapshot,PhoneFlow.map(step["selector"],"selector"))
        require(action!="input" || target["source"]=="accessibility"){"文字识别不能确认输入框，请使用实际可编辑控件。"}
        if(action=="input")return visionUi{service.flowPerform(step-"guard",pkg,allowed,before,requestId,owner)}
        require(action in setOf("tap","scroll","swipe")){"此视觉动作尚不支持。"}
        val saved=last?:error("识别结果不可用。")
        service.captureVision(allowed){checkAlive(check)}.use { frame ->
            require(saved.owner==owner && saved.pkg==frame.pkg && saved.window==frame.window && saved.rotation==frame.rotation && saved.width==frame.bitmap.width && saved.height==frame.bitmap.height){"定位期间画面已变化。"}
            val proofRows=mutableListOf(target)
            fun guards(value:Any?) {
                if(value==null)return
                val c=PhoneFlow.map(value,"guard")
                if(c["kind"]=="absent")require(hash(frame.bitmap)==saved.imageHash){"否定前置条件的画面已变化，请重新识别。"}
                c["selector"]?.let{proofRows.addAll(PhoneFlow.targets(snapshot,PhoneFlow.map(it,"selector")))}
                (c["conditions"] as? List<*>)?.forEach{guards(it)}
            }
            guards(step["guard"])
            for(row in proofRows)require(saved.patches[row["id"]]==patch(frame.bitmap,box(row))){"目标或前置文字区域已移动或变化，请重新识别。"}
            val direction=if(action in setOf("scroll","swipe"))step["direction"] as String else null
            var dispatched=false
            val accepted=visionUi { checkAlive(check);service.visualGesture(frame,box(target),direction,allowed,{checkAlive(check);before();dispatched=true}) }
            last=null
            return PhoneFlow.Dispatch(accepted,dispatched)
        }
    }
    fun act(tool:String,args:Map<String,Any?>,allowed:Set<String>,owner:String,requestId:String,mode:String,check:()->Unit,before:()->Unit):Boolean {
        val fields=when(tool){"ui.input"->setOf("observationId","elementId","text");"ui.scroll","ui.swipe"->setOf("observationId","elementId","direction");else->setOf("observationId","elementId")}
        require(args.keys==fields){"视觉动作参数无效。"}
        val saved=last?:error("视觉观察已过期，请重新识别。")
        require(saved.owner==owner && saved.token==args["observationId"]){"此视觉观察不属于当前会话或已过期。"}
        val row=saved.rows.singleOrNull{it["id"]==args["elementId"]}?:error("没有这个识别目标。")
        val selector=mutableMapOf<String,Any?>("text" to row["text"],"source" to row["source"])
        require(row["text"]?.toString()?.isNotBlank()==true){"请使用有明确文字的视觉目标。"}
        // Preserve a disambiguating screen region, but reacquire the text before dispatch.
        val b=box(row);selector["region"]=listOf(b[0].toDouble()/saved.width,b[1].toDouble()/saved.height,b[2].toDouble()/saved.width,b[3].toDouble()/saved.height)
        val step=mapOf("action" to tool.removePrefix("ui."),"selector" to selector,"direction" to args["direction"],"text" to args["text"],"expect" to mapOf("kind" to "changed"))
        val key=TaskDatabase.digest("$owner:$requestId")
        val proof=JSONObject(mapOf("owner" to owner,"package" to saved.pkg,"beforeTexts" to saved.rows.mapNotNull{it["text"]?.toString()}))
        return perform(step,saved.pkg,allowed,mode,owner,requestId,check,dispatchOnly=true) {
            before()
            if(tool!="ui.input")kotlin.check(proofPrefs.edit().putString(key,proof.toString()).commit()){"视觉动作证据没有保存。"}
        }.accepted
    }
    fun hasProof(id:String,owner:String)=proofPrefs.contains(TaskDatabase.digest("$owner:$id"))
    fun verify(args:Map<String,Any?>,allowed:Set<String>,owner:String,mode:String,check:()->Unit):Map<String,Any?> {
        val id=args["requestId"] as? String?:error("缺少动作编号。")
        val proof=JSONObject(proofPrefs.getString(TaskDatabase.digest("$owner:$id"),null)?:error("没有视觉动作证据。"))
        require(proof.getString("owner")==owner)
        val expected=PhoneFlow.map(args["expect"],"expect");val text=expected["text"] as? String
        val observed=observe(allowed,mapOf("pageSize" to 1000),mode,owner,check)
        val before=proof.getJSONArray("beforeTexts");val old=(0 until before.length()).map{before.getString(it)}
        val matched=expected["kind"]=="navigation" && !text.isNullOrBlank() && PhoneVision.ocrText(text) !in old.map{PhoneVision.ocrText(it)} && observed["package"]==proof.getString("package") && rows(observed).any{PhoneVision.ocrText(it["text"])==PhoneVision.ocrText(text)}
        return observed+mapOf("matched" to matched,"verifiedRequestId" to if(matched)id else null,"verification" to "fresh_ocr_navigation")
    }
}
