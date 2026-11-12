package com.skyjjgw.independent.ski

import android.graphics.Bitmap
import android.os.SystemClock
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import java.util.UUID
import java.util.concurrent.CompletableFuture
import org.json.JSONObject

/** Worker-thread OCR and fresh visual dispatch; recognition never calls an external model. */
internal class PhoneOcrController(private val service:SkivuAccessibilityService) {
    private val recognizerDelegate=lazy { TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build()) }
    private val recognizer by recognizerDelegate
    @Volatile private var closed=false
    private data class Observation(val owner:String,val pkg:String,val window:Int,val rotation:Int,val width:Int,val height:Int,
        val token:String,val rows:List<Map<String,Any?>>,val imageHash:String,val region:Any?,val mode:String,
        val epoch:Long,val capturedAt:Long)
    private var last:Observation?=null
    internal fun hasVisualObservation()=last!=null
    private var cachedKey=""
    private var cachedRows=emptyList<Map<String,Any?>>()
    private var visualWindow:Pair<String,Int>?=null
    private val pixelHash=PhonePixelHash()
    private val resultExecutor=java.util.concurrent.Executor { task -> java.util.concurrent.ForkJoinPool.commonPool().execute(task) }
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
    private fun hash(bitmap:Bitmap):String {
        return pixelHash.hash(bitmap.width,bitmap.height) { pixels,top,count ->
            bitmap.getPixels(pixels,0,bitmap.width,0,top,bitmap.width,count)
        }
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
        val input=Bitmap.createBitmap(imageWidth,imageHeight,Bitmap.Config.ARGB_8888)
        android.graphics.Canvas(input).drawBitmap(frame.bitmap,android.graphics.Rect(left,top,left+w,top+h),
            android.graphics.Rect(0,0,imageWidth,imageHeight),android.graphics.Paint(android.graphics.Paint.FILTER_BITMAP_FLAG))
        val geometry=PhoneVision.Geometry(left,top,w,h,imageWidth,imageHeight)
        val future=CompletableFuture<List<Map<String,Any?>>>()
        try {
            recognizer.process(InputImage.fromBitmap(input,0)).addOnCompleteListener(resultExecutor) { task ->
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
                selectors:List<Map<String,Any?>> = emptyList(),needNative:Boolean=false,allowMissingFallback:Boolean=true,
                preferVisible:Boolean=true,requireVisualState:Boolean=false,stateStep:Map<String,Any?>?=null):Map<String,Any?> {
        checkAlive(check);PhoneVision.mode(mode)
        require(args.keys.all{it in setOf("observationId","offset","pageSize","query","recognitionMode","region")}){"屏幕观察参数含未知字段。"}
        PhoneVision.region(args["region"])
        val started=SystemClock.uptimeMillis();val current=window(allowed)
        val continuation=args["observationId"] as? String
        if(continuation?.startsWith("ocr:")==true) {
            val saved=last?:error("识别观察已变化，请重新识别。")
            require(saved.token==continuation && saved.owner==owner && current==(saved.pkg to saved.window)){"识别观察已过期。"}
            // Pagination is a read only view of the same frame; dispatch always reacquires pixels.
            return page(saved,args,mapOf("source" to "ocr","continuation" to true),preferVisible)
        }
        if(continuation!=null)return native(allowed,args)
        val useKnown=mode=="auto" && visualWindow==current && !needNative
        // Routing needs the full hierarchy, including WebView ancestors hidden by a text query.
        val base=if(mode=="controls" || (mode=="auto" && (!useKnown || needNative)))native(allowed,(args-"query")+mapOf("offset" to 0,"pageSize" to 1000))else null
        val nativeRows=base?.let{rows(it)}.orEmpty()
        val nativeState=requireVisualState && stateStep!=null && base!=null && nativeStateSuffices(stateStep,
            PhoneFlow.Snapshot(current.first,current.second,nativeRows,base))
        val forceVisualState=requireVisualState && !nativeState
        if(mode=="controls" || nativeState || (mode=="auto" && android.os.Build.VERSION.SDK_INT<30) || (mode=="auto" && !forceVisualState && !useKnown && (!PhoneVision.needsOcr(nativeRows,args["query"] as? String,selectors) || (!allowMissingFallback && !PhoneVision.needsOcr(nativeRows,null,emptyList()))))) {
            last=null
            val offset=(args["offset"] as? Number)?.toInt()?:0;val limit=(args["pageSize"] as? Number)?.toInt()?:100
            require(offset>=0 && limit>0)
            val query=args["query"] as? String
            val filtered=if(query.isNullOrBlank())nativeRows else nativeRows.filter{row->listOf(row["text"],row["description"],row["viewId"]).any{it?.toString()?.contains(query,true)==true}}
            if((base!!["total"] as Number).toInt()>nativeRows.size && (!query.isNullOrBlank() || offset+minOf(limit,1000)>nativeRows.size))
                return native(allowed,args+mapOf("observationId" to base["observationId"]))+mapOf("recognition" to mapOf("mode" to mode,"source" to "accessibility"))
            val selected=filtered.drop(offset).take(minOf(limit,1000));val next=offset+selected.size
            val total=if(query.isNullOrBlank())(base["total"] as Number).toInt()else filtered.size
            return base+mapOf("elements" to selected,"total" to total,"nextOffset" to if(next<total)next else null,"complete" to (next>=total),"recognition" to mapOf("mode" to mode,"source" to "accessibility","elapsedMs" to SystemClock.uptimeMillis()-started,"ocrAvailable" to (android.os.Build.VERSION.SDK_INT>=30)))
        }
        service.captureVision(allowed){checkAlive(check)}.use { frame ->
            require(current==(frame.pkg to frame.window)){"读取期间窗口发生变化。"}
            return observeFrame(frame,allowed,args,mode,owner,check,nativeRows,started,preferVisible=preferVisible,
                requiredOcrSelectors=selectors.filter{it["source"]=="ocr"})
        }
    }

    /** All text and coordinates belong to this frame, including a changed pre-dispatch frame. */
    private fun observeFrame(frame:PhoneOcrFrame,allowed:Set<String>,args:Map<String,Any?>,mode:String,owner:String,
                             check:()->Unit,nativeRows:List<Map<String,Any?>>,started:Long,imageHash:String=hash(frame.bitmap),
                             preferVisible:Boolean=true,requiredOcrSelectors:List<Map<String,Any?>> = emptyList()):Map<String,Any?> {
        val captureMs=SystemClock.uptimeMillis()-started
        val key="${frame.pkg}:${frame.window}:${frame.rotation}:${frame.bitmap.width}:${frame.bitmap.height}:$imageHash:${args["region"]}"
        val hit=key==cachedKey
        val ocrStarted=SystemClock.uptimeMillis()
        val recognized=try {
            if(hit)cachedRows else recognize(frame,args["region"]){checkAlive(check)}.also{cachedRows=it;cachedKey=key}
        } finally { service.visionMetrics.recordOcr(SystemClock.uptimeMillis()-ocrStarted,hit) }
        val ocrMs=SystemClock.uptimeMillis()-ocrStarted
        val token="ocr:"+UUID.randomUUID()
        val stateStarted=SystemClock.uptimeMillis()
        val ocrRows=visualStates(frame,recognized.mapIndexed{i,row->row+mapOf("id" to "v_$i","parentId" to null)},token,imageHash)
        val visualStateMs=SystemClock.uptimeMillis()-stateStarted
        service.visionMetrics.recordVisualState(visualStateMs)
        val stateFields=setOf("visualChecked","visualStateKind","visualStateConfidence","visualMarkBounds",
            "visualStateObservationId","visualStateCapturedAtMs","visualStateImageHash")
        val nativeWithState=nativeRows.map { node ->
            val candidates=ocrRows.filter { visual ->
                val a=box(node);val b=box(visual)
                visual.containsKey("visualChecked") && PhoneVision.text(node["text"]).isNotEmpty() &&
                    PhoneVision.text(node["text"])==PhoneVision.text(visual["text"]) &&
                    (b[0]+b[2])/2 in a[0]..a[2] && (b[1]+b[3])/2 in a[1]..a[3]
            }
            candidates.singleOrNull()?.let{node+it.filterKeys{key->key in stateFields}}?:node
        }
        val combined=if(mode=="auto")PhoneVision.merge(nativeWithState,ocrRows,requiredOcrSelectors)else ocrRows
        val observed=Observation(owner,frame.pkg,frame.window,frame.rotation,frame.bitmap.width,frame.bitmap.height,
            token,combined,imageHash,args["region"],mode,frame.epoch,frame.capturedAt)
        checkAlive(check);visionUi{service.assertVisualFrame(frame,allowed)}
        last=observed;if(mode=="auto")visualWindow=frame.pkg to frame.window
        return page(observed,args,mapOf("mode" to mode,"source" to if(nativeRows.isEmpty())"ocr" else "hybrid","captureMs" to captureMs,
            "ocrMs" to ocrMs,"visualStateMs" to visualStateMs,"elapsedMs" to SystemClock.uptimeMillis()-started,"recognitionCacheHit" to hit,"modelRequests" to 0),preferVisible)
    }
    private fun page(saved:Observation,args:Map<String,Any?>,timing:Map<String,Any?>,preferVisible:Boolean=true):Map<String,Any?> {
        val query=args["query"] as? String
        val visible=if(preferVisible && saved.mode=="auto")PhoneVision.visibleProjection(saved.rows)else saved.rows
        val rows=if(query.isNullOrBlank())visible else visible.filter{listOf(it["text"],it["description"],it["viewId"]).any{v->v?.toString()?.contains(query,true)==true}}
        val offset=(args["offset"] as? Number)?.toInt()?:0;val limit=(args["pageSize"] as? Number)?.toInt()?:100
        require(offset>=0 && limit>0)
        val selected=rows.drop(offset).take(minOf(limit,1000));val next=offset+selected.size
        return mapOf("observationId" to saved.token,"package" to saved.pkg,"windowId" to saved.window,"elements" to selected,"total" to rows.size,
            "nextOffset" to if(next<rows.size)next else null,"complete" to (next>=rows.size),"screenWidth" to saved.width,"screenHeight" to saved.height,
            "rotation" to saved.rotation,"capturedAtMs" to saved.capturedAt,"imageHash" to saved.imageHash,"recognition" to timing,
            "scope" to "OCR 表示屏幕可见文字；accessibilityText 为系统无障碍别名，不能替代屏幕选项字母。visualChecked 只表示同帧支持样式的圈选或勾选图形，未识别样式不提供此字段。")
    }

    /** State belongs to the same pixels as the text, with no retained screenshot or model call. */
    private fun visualStates(frame:PhoneOcrFrame,rows:List<Map<String,Any?>>,token:String,imageHash:String):List<Map<String,Any?>> {
        val width=frame.bitmap.width;val height=frame.bitmap.height
        fun marker(row:Map<String,Any?>):String? {
            val text=row["text"].toString().trim()
            if(Regex("^[A-H]$").matches(text))return text
            return Regex("^([A-H])(?:\\s+|[.、]\\s*)").find(text)?.groupValues?.get(1)
        }
        val letters=rows.filter{marker(it)!=null}
        val letterGroup=letters.mapNotNull{marker(it)}.distinct().size>=2
        return rows.map { row ->
            val b=box(row);val textHeight=b[3]-b[1]
            if(textHeight !in 8..120)return@map row
            val left=(b[0]-5*textHeight).coerceAtLeast(0)
            val right=(b[0]+3*textHeight).coerceAtMost(width)
            val top=(b[1]-textHeight*3/2).coerceAtLeast(0)
            val bottom=(b[3]+textHeight*3/2).coerceAtMost(height)
            if(right<=left || bottom<=top)return@map row
            val pixels=IntArray((right-left)*(bottom-top))
            frame.bitmap.getPixels(pixels,0,right-left,left,top,right-left,bottom-top)
            val glyphs=if(letterGroup)letters.map { glyph ->
                val g=box(glyph);val end=if(Regex("^[A-H]$").matches(glyph["text"].toString().trim()))g[2]
                    else minOf(g[2],g[0]+((g[3]-g[1])*0.85).toInt())
                PhoneVisualState.Box(g[0]-left,g[1]-top,end-left,g[3]-top)
            }else emptyList()
            val marks=PhoneVisualState.detect(PhoneVisualState.Raster(right-left,bottom-top,pixels),glyphs).filter { mark ->
                val m=mark.bounds
                val cy=(m.top+m.bottom)/2.0+top
                val aligned=kotlin.math.abs(cy-(b[1]+b[3])/2.0)<=textHeight*0.45
                val preceding=m.right+left<=b[0]+textHeight*0.35 && b[0]-(m.right+left)<=textHeight*3
                val isLetter=Regex("^[A-Z]$").matches(row["text"].toString()) &&
                    m.contains((b[0]+b[2])/2.0-left,(b[1]+b[3])/2.0-top)
                val leadingLetter=marker(row)!=null && m.contains(b[0]+minOf(15.0,textHeight*0.25)-left,(b[1]+b[3])/2.0-top)
                aligned && (preceding || isLetter || leadingLetter) && m.height>=textHeight*0.75
            }
            val mark=marks.singleOrNull()?:return@map row
            row+mapOf("visualChecked" to mark.checked,"visualStateKind" to mark.kind,"visualStateConfidence" to mark.confidence,
                "visualMarkBounds" to mark.bounds.let{listOf(it.left+left,it.top+top,it.right+left,it.bottom+top)},
                "visualStateObservationId" to token,"visualStateCapturedAtMs" to frame.capturedAt,"visualStateImageHash" to imageHash)
        }
    }

    private fun usesVisualState(step:Map<String,Any?>):Boolean {
        fun condition(value:Any?):Boolean {
            if(value==null)return false
            val c=PhoneFlow.map(value,"condition")
            return c["kind"] in setOf("checked","visual_checked") || (c["conditions"] as? List<*>)?.any{condition(it)}==true
        }
        return step["action"]=="set_checked" || listOf("guard","expect","when").any{condition(step[it])}
    }

    private fun nativeStateSuffices(step:Map<String,Any?>,snapshot:PhoneFlow.Snapshot):Boolean {
        fun supported(selector:Map<String,Any?>):Boolean {
            val target=PhoneFlow.targets(snapshot,selector).singleOrNull()?:return false
            return target["source"]!="ocr" && target["checkable"]==true && target["checked"] is Boolean
        }
        fun condition(value:Any?):Boolean {
            if(value==null)return true
            val c=PhoneFlow.map(value,"condition")
            if(c["kind"]=="visual_checked")return false
            if((c["selector"] as? Map<*,*>)?.get("source")=="ocr")return false
            if(c["kind"]=="checked")return supported(PhoneFlow.map(c["selector"],"selector"))
            return (c["conditions"] as? List<*>)?.all{condition(it)}?:true
        }
        return (step["action"]!="set_checked" || supported(PhoneFlow.map(step["selector"],"selector"))) &&
            listOf("guard","expect","when").all{condition(step[it])}
    }
    private fun selectorsForStep(step:Map<String,Any?>,beforeAction:Boolean):List<Map<String,Any?>> {
        val selectors=mutableListOf<Map<String,Any?>>()
        if(beforeAction)step["selector"]?.let{selectors.add(PhoneFlow.map(it,"selector"))}
        fun collect(value:Any?){if(value==null)return;val c=PhoneFlow.map(value,"condition");c["selector"]?.let{selectors.add(PhoneFlow.map(it,"selector"))};(c["conditions"] as? List<*>)?.forEach{collect(it)}}
        if(beforeAction)collect(step["guard"])
        if(!beforeAction||step["action"]=="wait"||step["selector"]==null)collect(step["expect"])
        return selectors
    }
    @Suppress("UNCHECKED_CAST")
    fun snapshot(allowed:Set<String>,pkg:String,mode:String,owner:String,check:()->Unit,step:Map<String,Any?>,beforeAction:Boolean=true,allowMissingFallback:Boolean=true):PhoneFlow.Snapshot {
        val selectors=selectorsForStep(step,beforeAction)
        val visualState=usesVisualState(step)
        val needNative=requiresNative(step)
        val observed=observe(allowed,mapOf("pageSize" to 1000),mode,owner,check,selectors,needNative,allowMissingFallback,preferVisible=!needNative||visualState,requireVisualState=visualState,stateStep=step)
        require(observed["package"]==pkg){"当前页面不属于流程指定的软件。"}
        if(!(observed["observationId"] as String).startsWith("ocr:"))return visionUi{service.flowSnapshot(allowed,pkg,observed)}
        return PhoneFlow.Snapshot(pkg,(observed["windowId"] as Number).toInt(),rows(observed),observed)
    }
    private fun requiresNative(step:Map<String,Any?>):Boolean {
        if(step["action"]=="input")return true
        fun condition(value:Any?):Boolean {
            if(value==null)return false
            val c=PhoneFlow.map(value,"condition")
            val selector=c["selector"]?.let{PhoneFlow.map(it,"selector")}
            if(c["kind"] in setOf("selected","changed") || (c["kind"]=="checked" && selector?.get("source")!="ocr"))return true
            if(selector!=null && nativeSelector(selector))return true
            return (c["conditions"] as? List<*>)?.any{condition(it)}==true
        }
        return step["selector"]?.let{nativeSelector(PhoneFlow.map(it,"selector"))}==true ||
            listOf("guard","expect","when").any{condition(step[it])}
    }
    private fun nativeSelector(selector:Map<String,Any?>):Boolean =
        selector["source"]=="accessibility" || selector.keys.any{it in setOf("viewId","className","description","descriptionContains","clickable","editable","scrollable","checked","selected","enabled","within")}

    private fun prepared(snapshot:PhoneFlow.Snapshot?,pkg:String,mode:String,owner:String,step:Map<String,Any?>,
                         allowed:Set<String>,check:()->Unit):PhoneFlow.Snapshot? {
        checkAlive(check)
        val saved=last?:return null
        if(snapshot==null || snapshot.observation["observationId"]!=saved.token || saved.owner!=owner ||
            saved.pkg!=pkg || saved.mode!=mode || saved.region!=null || snapshot.observation["complete"]!=true ||
            requiresNative(step) ||
            step["action"] !in setOf("tap","set_checked","scroll","swipe") ||
            SystemClock.uptimeMillis()-saved.capturedAt !in 0L..1000L)return null
        return visionUi {
            val size=service.visualMetrics()
            if(window(allowed)!=(saved.pkg to saved.window) || size!=Triple(saved.width,saved.height,saved.rotation) ||
                service.visualScrollEpoch!=saved.epoch)null else {
                // The previous step may have required raw native labels for state verification.
                // A new visual-text action always prepares its own visible projection.
                val visible=if(mode=="auto")PhoneVision.visibleProjection(saved.rows)else saved.rows
                PhoneFlow.Snapshot(saved.pkg,saved.window,visible,snapshot.observation+mapOf("elements" to visible))
            }
        }
    }

    /** Only an immediately preceding, complete visual result can prepare another action. */
    fun reuseSnapshot(snapshot:PhoneFlow.Snapshot,pkg:String,mode:String,owner:String,step:Map<String,Any?>,
                      allowed:Set<String>,check:()->Unit):PhoneFlow.Snapshot? {
        if(step["when"]!=null)return null
        val candidate=try { prepared(snapshot,pkg,mode,owner,step,allowed,check) }
            catch (_:PhoneFlow.ObservationUnavailable) { null } ?:return null
        // Fresh reading is needed for decisions that would skip or reject the next action.
        if(step["guard"]?.let{!PhoneFlow.satisfied(candidate,PhoneFlow.map(it,"guard"))}==true ||
            PhoneFlow.shouldSkip(candidate,step) ||
            PhoneFlow.targets(candidate,PhoneFlow.map(step["selector"],"selector")).size!=1)return null
        service.visionMetrics.recordReuse()
        return candidate
    }

    fun perform(step:Map<String,Any?>,pkg:String,allowed:Set<String>,mode:String,owner:String,requestId:String,check:()->Unit,
                dispatchOnly:Boolean=false,preparedSnapshot:PhoneFlow.Snapshot?=null,before:()->Unit):PhoneFlow.Dispatch {
        var snapshot=prepared(preparedSnapshot,pkg,mode,owner,step,allowed,check)
            ?:snapshot(allowed,pkg,mode,owner,check,step)
        if(!(snapshot.observation["observationId"] as String).startsWith("ocr:"))return visionUi{service.flowPerform(step,pkg,allowed,before,requestId,owner)}
        val action=step["action"] as String
        if(action in setOf("back","input")) {
            step["guard"]?.let{require(PhoneFlow.satisfied(snapshot,PhoneFlow.map(it,"guard"))){"当前画面不满足前置条件。"}}
            if(!dispatchOnly && PhoneFlow.shouldSkip(snapshot,step))return PhoneFlow.Dispatch(true,false)
            if(action=="input")require(PhoneFlow.unique(snapshot,PhoneFlow.map(step["selector"],"selector"))["source"]=="accessibility"){"文字识别不能确认输入框，请使用实际可编辑控件。"}
            return visionUi{service.flowPerform(step-"guard",pkg,allowed,before,requestId,owner)}
        }
        require(action in setOf("tap","set_checked","scroll","swipe")){"此视觉动作尚不支持。"}
        val saved=last?:error("识别结果不可用。")
        val started=SystemClock.uptimeMillis()
        service.captureVision(allowed){checkAlive(check)}.use { frame ->
            require(saved.owner==owner && saved.pkg==frame.pkg && saved.window==frame.window && saved.rotation==frame.rotation && saved.width==frame.bitmap.width && saved.height==frame.bitmap.height){"定位期间画面已变化。"}
            val imageHash=hash(frame.bitmap)
            if(imageHash!=saved.imageHash) {
                service.visionMetrics.recordRefresh()
                val nativeRows=if(mode=="auto" && saved.rows.any{it["source"]!="ocr"})
                    rows(native(allowed,mapOf("pageSize" to 1000)))else emptyList()
                val observed=observeFrame(frame,allowed,mapOf("pageSize" to 1000),mode,owner,check,nativeRows,started,imageHash,
                    preferVisible=!requiresNative(step)||usesVisualState(step),requiredOcrSelectors=selectorsForStep(step,true).filter{it["source"]=="ocr"})
                snapshot=PhoneFlow.Snapshot(pkg,frame.window,rows(observed),observed)
            }
            step["when"]?.let{require(PhoneFlow.satisfied(snapshot,PhoneFlow.map(it,"when"))){"当前画面不满足分支条件。"}}
            step["guard"]?.let{require(PhoneFlow.satisfied(snapshot,PhoneFlow.map(it,"guard"))){"当前画面不满足前置条件。"}}
            if(!dispatchOnly && PhoneFlow.shouldSkip(snapshot,step))return PhoneFlow.Dispatch(true,false)
            val target=PhoneFlow.unique(snapshot,PhoneFlow.map(step["selector"],"selector"))
            if(action=="set_checked")require(PhoneFlow.checkedState(snapshot,target)!=null){"无法确认目标当前圈选或勾选状态，未派发动作。"}
            val direction=if(action in setOf("scroll","swipe"))step["direction"] as String else null
            fun dispatch(currentFrame:PhoneOcrFrame):PhoneFlow.Dispatch {
                var dispatched=false
                last=null
                val accepted=visionUi { checkAlive(check);service.visualGesture(currentFrame,box(target),direction,allowed,{checkAlive(check);before();dispatched=true}) }
                return PhoneFlow.Dispatch(accepted,dispatched)
            }
            if(imageHash==saved.imageHash)return dispatch(frame)
            // Canvas changes may emit no accessibility events while OCR is running.
            // Reuse its recognized text only after a new frame confirms the exact pixels.
            service.captureVision(allowed){checkAlive(check)}.use { confirmed ->
                require(confirmed.pkg==frame.pkg && confirmed.window==frame.window && confirmed.rotation==frame.rotation &&
                    confirmed.epoch==frame.epoch && confirmed.bitmap.width==frame.bitmap.width && confirmed.bitmap.height==frame.bitmap.height &&
                    hash(confirmed.bitmap)==imageHash){"页面在识别期间继续变化，请重新观察。"}
                return dispatch(confirmed)
            }
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
