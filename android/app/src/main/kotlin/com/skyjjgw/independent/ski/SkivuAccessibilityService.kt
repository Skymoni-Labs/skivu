package com.skyjjgw.independent.ski

import android.accessibilityservice.AccessibilityService
import android.graphics.Rect
import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Handler
import android.os.Looper
import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.util.UUID

/** Built-in observation/input backend. Never exposes the controller's own UI. */
class SkivuAccessibilityService : AccessibilityService() {
    companion object { @Volatile var connected: SkivuAccessibilityService? = null }
    private val nodes = mutableMapOf<String, AccessibilityNodeInfo>()
    private var snapshotRows=emptyList<Map<String,Any?>>()
    private var observation = ""
    private var observedPackage = ""
    private var observedWindow = -1
    private var observedAt = 0L
    @Volatile internal var visualScrollEpoch = 0L
        private set
    internal val vision by lazy { PhoneOcrController(this) }
    internal val visionMetrics = PhoneVisionMetrics()
    private val visionCaptureSlot = java.util.concurrent.Semaphore(1, true)
    private val visionCaptureTiming = PhoneCaptureTiming()
    private val flowChanges = Object()
    fun awaitFlowChange(milliseconds: Long) { synchronized(flowChanges) { flowChanges.wait(milliseconds.coerceAtLeast(1)) } }
    private data class Proof(val tool:String,val owner:String,val pkg:String,val viewId:String,val text:String,val checked:Boolean,val selected:Boolean,val checkable:Boolean,val originalNodes:Set<String>)
    private val proofs=linkedMapOf<String,Proof>()
    private var overlay:CloudOverlay?=null
    fun refreshOverlay(){if(overlay==null)overlay=CloudOverlay(this);overlay?.refresh()}
    internal fun overlayReviewMetrics()=overlay?.reviewMetrics()?:mapOf("visible" to false)

    override fun onServiceConnected() { connected = this;refreshOverlay() }
    override fun onInterrupt() { clearObservation() }
    override fun onDestroy() {
        if (connected === this) connected = null
        overlay?.close();overlay=null
        clearObservation()
        vision.close()
        super.onDestroy()
    }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if(windows.any{it.id==event?.windowId&&it.type==android.view.accessibility.AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY})return
        if(event==null)return
        if (event.eventType == AccessibilityEvent.TYPE_VIEW_SCROLLED) visualScrollEpoch++
        synchronized(flowChanges) { flowChanges.notifyAll() }
        if(event.eventType in setOf(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,AccessibilityEvent.TYPE_VIEW_SCROLLED,AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED)){
            if(event.packageName?.toString()==observedPackage&&(event.windowId==observedWindow||event.windowId<0))clearObservation()
        }else if(event.eventType in setOf(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,AccessibilityEvent.TYPE_WINDOWS_CHANGED)){
            val root=rootInActiveWindow
            if(root==null||root.packageName?.toString()!=observedPackage||root.windowId!=observedWindow)clearObservation()
            @Suppress("DEPRECATION") root?.recycle()
        }
        overlay?.refresh()
    }

    private fun clearObservation() {
        nodes.values.forEach { @Suppress("DEPRECATION") it.recycle() }
        nodes.clear();snapshotRows=emptyList()
        observation = ""
    }

    internal fun current(allowed: Set<String>): AccessibilityNodeInfo {
        require(!getSystemService(android.app.KeyguardManager::class.java).isDeviceLocked&&getSystemService(android.os.PowerManager::class.java).isInteractive){"手机已锁屏或屏幕不可操作，请解锁后核对；没有重放动作。"}
        val root = rootInActiveWindow ?: throw PhoneFlow.ObservationUnavailable("当前没有可观察的界面。")
        val target = root.packageName?.toString().orEmpty()
        require(target in allowed) { "当前软件不在授权范围内。" }
        return root
    }

    fun observe(allowed:Set<String>,args:Map<String,Any?> = emptyMap()):Map<String,Any?>{
        val continuation=args["observationId"] as? String
        if(continuation!=null){require(continuation==observation&&observation.isNotBlank()){"观察已变化，请重新观察。"};val root=current(allowed);require(root.windowId==observedWindow&&root.packageName?.toString()==observedPackage);@Suppress("DEPRECATION") root.recycle()}
        else{
            clearObservation();val root=current(allowed);observedPackage=root.packageName.toString();observedWindow=root.windowId;observedAt=SystemClock.uptimeMillis();observation=UUID.randomUUID().toString()
            val rows=mutableListOf<Map<String,Any?>>()
            val stack=java.util.ArrayDeque<Pair<AccessibilityNodeInfo,String?>>();stack.add(root to null)
            while(stack.isNotEmpty()){
                val (node,parent)=stack.removeLast();var id=parent
                if(node.isVisibleToUser){id="n_${rows.size}";val bounds=Rect().also{node.getBoundsInScreen(it)};val secret=node.isPassword
                    @Suppress("DEPRECATION") val copy=AccessibilityNodeInfo.obtain(node);nodes[id]=copy
                    rows+=mapOf("id" to id,"parentId" to parent,"text" to if(secret)""else node.text?.toString().orEmpty(),"description" to if(secret)""else node.contentDescription?.toString().orEmpty(),"viewId" to node.viewIdResourceName.orEmpty(),"class" to node.className?.toString().orEmpty(),"password" to secret,"editable" to node.isEditable,"enabled" to node.isEnabled,"checkable" to node.isCheckable,"checked" to node.isChecked,"selected" to node.isSelected,"clickable" to node.isClickable,"scrollable" to node.isScrollable,"bounds" to listOf(bounds.left,bounds.top,bounds.right,bounds.bottom))
                }
                for(i in node.childCount-1 downTo 0)node.getChild(i)?.let{stack.add(it to id)}
                @Suppress("DEPRECATION") node.recycle()
            };val metrics=visualMetrics();snapshotRows=rows.map { it + mapOf("source" to "accessibility", "screenWidth" to metrics.first, "screenHeight" to metrics.second) }
        }
        val query=args["query"] as? String;val rows=if(query.isNullOrBlank())snapshotRows else snapshotRows.filter{listOf(it["text"],it["description"],it["viewId"]).any{v->v.toString().contains(query,true)}}
        val offset=(args["offset"] as? Number)?.toInt()?:0;val limit=(args["pageSize"] as? Number)?.toInt()?:100;require(offset>=0&&limit>0)
        val page=rows.drop(offset).take(minOf(limit,1000));val next=offset+page.size
        return mapOf("observationId" to observation,"package" to observedPackage,"windowId" to observedWindow,"elements" to page,"total" to rows.size,"nextOffset" to if(next<rows.size)next else null,"complete" to (next>=rows.size),"scope" to "当前系统可访问的可见节点；未找到时继续分页、检索或滚动观察")
    }

    fun act(tool: String, args: Map<String, Any?>, allowed: Set<String>, beforeDispatch: () -> Unit, requestId:String="",owner:String="", semanticFallback:Boolean=false): Boolean {
        val root = current(allowed)
        val matches = root.packageName?.toString() == observedPackage && root.windowId == observedWindow
        @Suppress("DEPRECATION") root.recycle()
        if (tool == "ui.back" || tool == "ui.home") {
            require(args.isEmpty()) { "界面动作参数无效。" }
            val original=nodes.values.map{it.text?.toString().orEmpty()}.filter{it.isNotBlank()}.toSet()
            if(requestId.isNotEmpty()){val proof=Proof(tool,owner,observedPackage,"","",false,false,false,original);proofs[requestId]=proof;saveProof(requestId,proof)}
            clearObservation()
            beforeDispatch()
            return performGlobalAction(if (tool == "ui.back") GLOBAL_ACTION_BACK else GLOBAL_ACTION_HOME)
        }
        require(observation.isNotEmpty() && args["observationId"] == observation && matches) { "界面观察已过期，请重新观察。" }
        val node = nodes[args["elementId"]] ?: error("当前观察中没有这个控件。")
        require(node.refresh() && node.isVisibleToUser && !node.isPassword) { "控件已变化或是密码字段，请重新观察。" }
        val keys = when (tool) {
            "ui.input" -> setOf("observationId", "elementId", "text")
            "ui.scroll" -> setOf("observationId", "elementId", "direction")
            "ui.swipe" -> setOf("observationId", "elementId", "direction")
            else -> setOf("observationId", "elementId")
        }
        require(args.keys == keys) { "界面动作参数无效。" }
        // Android permission management is always a host/user authorization flow.
        require(observedPackage !in setOf("com.android.permissioncontroller", "com.google.android.permissioncontroller")&&nodes.values.none{it.viewIdResourceName?.contains("accessibility_service_detail")==true||it.viewIdResourceName?.contains("permission_allow_button")==true}) {
            "系统权限管理页面由用户操作；请使用明确的系统接口修改设置。"
        }
        val texts=nodes.values.flatMap{listOf(it.text?.toString().orEmpty(),"node:${it.viewIdResourceName.orEmpty()}:${it.text?.toString().orEmpty()}:${it.contentDescription?.toString().orEmpty()}")}.filter{it.isNotBlank()}.toSet()
        val proof=Proof(tool,owner,observedPackage,node.viewIdResourceName.orEmpty(),if(tool=="ui.input")args["text"].toString() else node.text?.toString().orEmpty(),node.isChecked,node.isSelected,node.isCheckable,texts)
        fun dispatch(){beforeDispatch();if(requestId.isNotEmpty()){proofs[requestId]=proof;saveProof(requestId,proof)}}
        val result = when (tool) {
            "ui.tap" -> {
                if (semanticFallback && !node.isClickable) {
                    val bounds=Rect().also{node.getBoundsInScreen(it)}
                    require(bounds.width()>0&&bounds.height()>0){"控件没有可点击的可见范围。"}
                    dispatch();dispatchGesture(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(Path().apply{moveTo(bounds.exactCenterX(),bounds.exactCenterY())},0,50)).build(),null,null)
                } else { dispatch(); node.performAction(AccessibilityNodeInfo.ACTION_CLICK) }
            }
            "ui.longPress" -> {dispatch();node.performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK)}
            "ui.swipe" -> {
                require(args["direction"] in listOf("up","down","left","right"))
                val b=Rect().also{node.getBoundsInScreen(it)};require(b.width()>20&&b.height()>20)
                var x1=b.centerX().toFloat();var y1=b.centerY().toFloat();var x2=x1;var y2=y1
                when(args["direction"]){"up"->{y1=b.top+b.height()*.8f;y2=b.top+b.height()*.2f};"down"->{y1=b.top+b.height()*.2f;y2=b.top+b.height()*.8f};"left"->{x1=b.left+b.width()*.8f;x2=b.left+b.width()*.2f};else->{x1=b.left+b.width()*.2f;x2=b.left+b.width()*.8f}}
                dispatch();dispatchGesture(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(Path().apply{moveTo(x1,y1);lineTo(x2,y2)},0,350)).build(),null,null)
            }
            "ui.input" -> {
                val text = args["text"] as? String ?: error("缺少输入文字。")
                require(!text.contains('\u0000') && node.isEditable)
                dispatch()
                node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                })
            }
            "ui.scroll" -> {
                require(args["direction"] in listOf("forward", "backward"))
                dispatch()
                node.performAction(if (args["direction"] == "forward") AccessibilityNodeInfo.ACTION_SCROLL_FORWARD else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
            }
            else -> error("不支持的界面操作。")
        }
        if(result&&requestId.isNotEmpty()){proofs[requestId]=proof;saveProof(requestId,proof)}
        clearObservation()
        return result
    }

    internal fun flowSnapshot(allowed:Set<String>, pkg:String, prior:Map<String,Any?>?=null):PhoneFlow.Snapshot {
        val args=if(prior?.get("observationId")==observation && observation.isNotBlank())mapOf("observationId" to observation)else emptyMap()
        val observation=observe(allowed.intersect(setOf(pkg)),args)
        require(observation["package"]==pkg){"当前页面不属于流程指定的软件，未派发动作。"}
        return PhoneFlow.Snapshot(pkg,observedWindow,snapshotRows.map{it.toMap()},observation)
    }

    internal fun flowPerform(step:Map<String,Any?>,pkg:String,allowed:Set<String>,beforeDispatch:()->Unit,requestId:String,owner:String):PhoneFlow.Dispatch {
        // Fresh lookup and dispatch run in the same main-thread turn. No model-held IDs survive here.
        val snapshot=flowSnapshot(allowed,pkg)
        step["when"]?.let{require(PhoneFlow.satisfied(snapshot,PhoneFlow.map(it,"when"))){"页面分支条件已变化，未派发动作。"}}
        step["guard"]?.let{require(PhoneFlow.satisfied(snapshot,PhoneFlow.map(it,"guard"))){"页面前置条件已变化，未派发动作。"}}
        if(PhoneFlow.satisfied(snapshot,PhoneFlow.map(step["expect"],"expect")))return PhoneFlow.Dispatch(true,false)
        val action=step["action"] as String
        val arguments=mutableMapOf<String,Any?>()
        if(action!="back") {
            val target=PhoneFlow.unique(snapshot,PhoneFlow.map(step["selector"],"selector"))
            require(target["enabled"]!=false){"目标控件当前不可操作，未派发动作。"}
            arguments["observationId"]=snapshot.observation["observationId"];arguments["elementId"]=target["id"]
            if(action=="input")arguments["text"]=step["text"]
            if(action in setOf("scroll","swipe"))arguments["direction"]=step["direction"]
        }
        var dispatched=false
        val accepted=act("ui.$action",arguments,allowed,{beforeDispatch();dispatched=true},requestId,owner,true)
        return PhoneFlow.Dispatch(accepted,dispatched)
    }

    private fun proofFile(id:String,owner:String)=java.io.File(filesDir,"cloud-ui-proofs/${TaskDatabase.digest("$owner:$id")}.json").also{it.parentFile!!.mkdirs()}
    private fun saveProof(id:String,p:Proof){val file=proofFile(id,p.owner);val tmp=java.io.File(file.path+".tmp");tmp.writeText(org.json.JSONObject(mapOf("tool" to p.tool,"owner" to p.owner,"pkg" to p.pkg,"viewId" to p.viewId,"text" to p.text,"checked" to p.checked,"selected" to p.selected,"checkable" to p.checkable,"originalNodes" to p.originalNodes.toList())).toString());check(tmp.renameTo(file))}
    private fun loadProof(id:String,owner:String):Proof?{val file=proofFile(id,owner);if(!file.isFile)return null;val p=org.json.JSONObject(file.readText());require(p.getString("owner")==owner);val originals=p.getJSONArray("originalNodes");return Proof(p.getString("tool"),owner,p.getString("pkg"),p.getString("viewId"),p.getString("text"),p.getBoolean("checked"),p.getBoolean("selected"),p.getBoolean("checkable"),(0 until originals.length()).map{originals.getString(it)}.toSet())}

    fun verify(args:Map<String,Any?>,allowed:Set<String>,owner:String):Map<String,Any?>{
        val id=args["requestId"] as? String?:error("缺少原动作编号。")
        val proof=proofs[id]?:loadProof(id,owner)?:error("原动作证据暂不可读，结果仍待核对，不能重放。")
        require(proof.owner==owner){"不能核对其他会话的动作。"}
        @Suppress("UNCHECKED_CAST") val expect=args["expect"] as? Map<String,Any?>?:error("缺少明确核对条件。")
        val snapshot=observe(allowed)
        @Suppress("UNCHECKED_CAST") val rows=snapshotRows
        val target=expect["package"] as? String?:proof.pkg
        val viewId=expect["viewId"] as? String?:proof.viewId
        if(expect["kind"] in setOf("text","checked","selected")&&proof.viewId.isNotBlank())require(viewId==proof.viewId){"必须核对原控件，不能用其他控件替代。"}
        val candidates=rows.filter{viewId.isNotBlank()&&it["viewId"]==viewId||viewId.isBlank()&&it["text"]==proof.text}
        val matched=if(snapshot["package"]!=target)false else when(expect["kind"]){
            "text"->proof.tool=="ui.input"&&expect["text"]==proof.text&&candidates.size==1&&candidates.single()["text"]==proof.text
            "checked"->proof.checkable&&expect["checked"] is Boolean&&expect["checked"]!=proof.checked&&candidates.size==1&&candidates.single()["checked"]==expect["checked"]
            "selected"->expect["selected"] is Boolean&&expect["selected"]!=proof.selected&&candidates.size==1&&candidates.single()["selected"]==expect["selected"]
            "navigation"->{val wanted=expect["text"] as? String;val description=expect["description"] as? String;val matches=rows.filter{(expect["viewId"]==null||it["viewId"]==expect["viewId"])&&(wanted==null||it["text"]==wanted)&&(description==null||it["description"]==description)};val changed=matches.any{"node:${it["viewId"]}:${it["text"]}:${it["description"]}" !in proof.originalNodes};(wanted?.isNotBlank()==true||description?.isNotBlank()==true)&&matches.isNotEmpty()&&changed&&(expect["viewId"]!=null||wanted !in proof.originalNodes)}
            else->false
        }
        return mapOf("matched" to matched,"verifiedRequestId" to if(matched)id else null,"package" to snapshot["package"],"observationId" to snapshot["observationId"],"verification" to "fresh_ui_predicate","elements" to snapshot["elements"],"total" to rows.size,"nextOffset" to snapshot["nextOffset"])
    }

    @Suppress("DEPRECATION")
    internal fun visualMetrics(): Triple<Int, Int, Int> {
        val display=getSystemService(android.hardware.display.DisplayManager::class.java).getDisplay(android.view.Display.DEFAULT_DISPLAY)
        val metrics=android.util.DisplayMetrics();display.getRealMetrics(metrics)
        return Triple(metrics.widthPixels,metrics.heightPixels,display.rotation)
    }

    internal fun assertVisualFrame(frame:PhoneOcrFrame,allowed:Set<String>) {
        val root=current(allowed)
        try {
            require(root.packageName?.toString()==frame.pkg && root.windowId==frame.window) { "识别后软件或窗口已变化，请重新观察。" }
            val size=visualMetrics()
            require(size.first==frame.bitmap.width && size.second==frame.bitmap.height && size.third==frame.rotation && visualScrollEpoch==frame.epoch) { "屏幕尺寸、方向或滚动位置已变化，请重新识别。" }
            require(!frame.forbidden && frame.pkg !in setOf(packageName,"com.android.permissioncontroller","com.google.android.permissioncontroller")) { "此页面不能通过视觉坐标操作。" }
        } finally { @Suppress("DEPRECATION") root.recycle() }
    }

    private fun visualPrivacy(allowed:Set<String>):Pair<List<Rect>,Boolean> {
        val masks=mutableListOf<Rect>();var forbidden=false
        val root=current(allowed);val windowId=root.windowId
        val visible=Rect().also{root.getBoundsInScreen(it)};val metrics=visualMetrics()
        masks.add(Rect(0,0,metrics.first,visible.top.coerceAtLeast(0)))
        masks.add(Rect(0,visible.bottom.coerceAtMost(metrics.second),metrics.first,metrics.second))
        masks.add(Rect(0,0,visible.left.coerceAtLeast(0),metrics.second))
        masks.add(Rect(visible.right.coerceAtMost(metrics.first),0,metrics.first,metrics.second))
        val active=windows.firstOrNull{it.id==windowId}
        if(active!=null)windows.filter{it.id!=windowId && it.layer>active.layer}.forEach{w->masks.add(Rect().also{w.getBoundsInScreen(it)})}
        val stack=java.util.ArrayDeque<AccessibilityNodeInfo>();stack.add(root)
        try {
            while(stack.isNotEmpty()) {
                val node=stack.removeLast()
                try {
                    val viewId=node.viewIdResourceName.orEmpty()
                    if(viewId.contains("accessibility_service_detail")||viewId.contains("permission_allow_button"))forbidden=true
                    if(node.isPassword)masks.add(Rect().also{node.getBoundsInScreen(it)})
                    for(i in 0 until node.childCount)node.getChild(i)?.let{stack.add(it)}
                } finally { @Suppress("DEPRECATION") node.recycle() }
            }
        } finally { stack.forEach { @Suppress("DEPRECATION") it.recycle() } }
        return masks to forbidden
    }

    /** Raw in-memory pixels for local OCR. No compression, base64, files or model upload. */
    internal fun captureVision(allowed:Set<String>,check:()->Unit):PhoneOcrFrame {
        require(android.os.Build.VERSION.SDK_INT>=30) { "本地屏幕识别需要 Android 11 或以上。" }
        require(Looper.myLooper()!=Looper.getMainLooper()) { "屏幕识别必须在工作线程执行。" }
        val queuedAt=SystemClock.uptimeMillis()
        val deadline=queuedAt+15_000
        fun checkDeadline() {
            check()
            require(SystemClock.uptimeMillis()<deadline) { "本地截图等待超时。" }
        }
        var queueFinishedAt=queuedAt
        try {
            while(true) {
                checkDeadline()
                if(visionCaptureSlot.tryAcquire(50,java.util.concurrent.TimeUnit.MILLISECONDS))break
            }
        } finally {
            queueFinishedAt=SystemClock.uptimeMillis()
            visionMetrics.recordCaptureQueue(queueFinishedAt-queuedAt)
        }
        val acquiredAt=queueFinishedAt
        val future=java.util.concurrent.CompletableFuture<PhoneOcrFrame>()
        val handler=Handler(Looper.getMainLooper());val hidden=java.util.concurrent.atomic.AtomicBoolean(false)
        var inFlight=false
        var released=false
        val timingLock=Any()
        var throttleStarted:Long?=null
        var throttleMs=0L
        var timingClosed=false
        fun beginThrottle() = synchronized(timingLock) {
            if(!timingClosed)throttleStarted=SystemClock.uptimeMillis()
        }
        fun finishThrottle() {
            synchronized(timingLock) {
                throttleStarted?.let { throttleMs+=SystemClock.uptimeMillis()-it }
                throttleStarted=null
            }
        }
        fun restore(){if(hidden.compareAndSet(true,false))overlay?.restoreAfterScreenshot()}
        // Called only on the main looper. A cancelled request keeps its slot until
        // its system callback arrives, so a late callback cannot hide/restore a new capture.
        fun release() {
            if(inFlight||released)return
            released=true
            finishThrottle()
            try { restore() } finally { visionCaptureSlot.release() }
        }
        var attempts=0
        lateinit var capture:Runnable
        capture=Runnable {
            finishThrottle()
            if(future.isDone){release();return@Runnable}
            try {
                checkDeadline()
                val delay=visionCaptureTiming.delayMs(SystemClock.uptimeMillis())
                if(delay>0) {
                    beginThrottle()
                    handler.postDelayed(capture,delay);return@Runnable
                }
                val root=current(allowed)
                val pkg=root.packageName.toString();val window=root.windowId
                @Suppress("DEPRECATION") root.recycle()
                require(pkg!=packageName) { "不能识别控制器自身页面。" }
                val size=visualMetrics();val epoch=visualScrollEpoch
                val privacyBefore=visualPrivacy(allowed)
                checkDeadline()
                if(future.isDone){release();return@Runnable}
                visionCaptureTiming.attempted(SystemClock.uptimeMillis())
                visionMetrics.recordCaptureAttempt(attempts>0)
                attempts++
                inFlight=true
                takeScreenshot(android.view.Display.DEFAULT_DISPLAY,mainExecutor,object:TakeScreenshotCallback {
                    override fun onSuccess(shot:ScreenshotResult) {
                        visionMetrics.recordCaptureSuccess()
                        var pixels:Bitmap?=null
                        try {
                            if(future.isDone)return
                            val hardware=Bitmap.wrapHardwareBuffer(shot.hardwareBuffer,shot.colorSpace)?:error("截图不可读取。")
                            try { pixels=hardware.copy(Bitmap.Config.ARGB_8888,true) } finally { hardware.recycle() }
                            val bitmap=pixels?:error("截图不可复制。")
                            require(bitmap.width==size.first && bitmap.height==size.second) { "截屏坐标与显示尺寸不一致。" }
                            val privacyAfter=visualPrivacy(allowed)
                            val masks=privacyBefore.first+privacyAfter.first
                            val canvas=android.graphics.Canvas(bitmap);val paint=android.graphics.Paint().apply{color=android.graphics.Color.BLACK}
                            masks.forEach { canvas.drawRect(it,paint) }
                            val frame=PhoneOcrFrame(bitmap,pkg,window,size.third,epoch,shot.timestamp,privacyBefore.second||privacyAfter.second)
                            assertVisualFrame(frame,allowed);checkDeadline()
                            if(!future.complete(frame))frame.close()
                            pixels=null
                        } catch(e:Exception){future.completeExceptionally(e)}
                        finally {
                            try { pixels?.recycle();shot.hardwareBuffer.close() }
                            finally { inFlight=false;release() }
                        }
                    }
                    override fun onFailure(errorCode:Int) {
                        inFlight=false
                        if(errorCode==ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT && attempts<=12 && !future.isDone) {
                            visionCaptureTiming.intervalRejected()
                            beginThrottle()
                            handler.postDelayed(capture,visionCaptureTiming.delayMs(SystemClock.uptimeMillis()))
                        } else {
                            future.completeExceptionally(IllegalStateException("截图不可用（系统代码 $errorCode），请核对当前页面。"))
                            release()
                        }
                    }
                })
            } catch(e:Exception){inFlight=false;future.completeExceptionally(e);release()}
        }
        val start=Runnable {
            finishThrottle()
            try {
                if(future.isDone)release()
                else { checkDeadline();overlay?.suspendForScreenshot();hidden.set(true);handler.postDelayed(capture,32) }
            } catch(e:Exception){future.completeExceptionally(e);release()}
        }
        handler.post {
            val delay=(visionCaptureTiming.delayMs(SystemClock.uptimeMillis())-32).coerceAtLeast(0)
            if(delay>0)beginThrottle()
            handler.postDelayed(start,delay)
        }
        return try { visionAwait(future,::checkDeadline) } finally {
            // Freeze this call's timing at return, even when cancellation cleanup
            // or a system callback will run later on the main looper.
            val (endedAt,queuedMs)=synchronized(timingLock) {
                val end=SystemClock.uptimeMillis()
                throttleStarted?.let { throttleMs+=(end-it).coerceAtLeast(0) }
                throttleStarted=null
                timingClosed=true
                end to throttleMs
            }
            visionMetrics.recordCaptureQueue(queuedMs)
            visionMetrics.recordCapture(endedAt-acquiredAt-queuedMs)
            handler.post {
                handler.removeCallbacks(capture)
                handler.removeCallbacks(start)
                release()
            }
        }
    }

    internal fun visualGesture(frame:PhoneOcrFrame,box:List<Int>,direction:String?,allowed:Set<String>,beforeDispatch:()->Unit):Boolean {
        assertVisualFrame(frame,allowed)
        require(SystemClock.uptimeMillis()-frame.capturedAt<=1000) { "定位画面已过期，请重新识别。" }
        require(box.size==4 && box[0]>=0 && box[1]>=0 && box[2]<=frame.bitmap.width && box[3]<=frame.bitmap.height && box[2]>box[0] && box[3]>box[1])
        val x=(box[0]+box[2])/2f;val y=(box[1]+box[3])/2f
        val path=Path().apply {
            if(direction==null) moveTo(x,y)
            else {
                val distance=minOf(frame.bitmap.height*.25f,500f)
                when(direction){"up","forward"->{moveTo(x,(y+distance/2).coerceAtMost(frame.bitmap.height-2f));lineTo(x,(y-distance/2).coerceAtLeast(1f))};"down","backward"->{moveTo(x,(y-distance/2).coerceAtLeast(1f));lineTo(x,(y+distance/2).coerceAtMost(frame.bitmap.height-2f))};"left"->{moveTo((x+distance/2).coerceAtMost(frame.bitmap.width-2f),y);lineTo((x-distance/2).coerceAtLeast(1f),y)};"right"->{moveTo((x-distance/2).coerceAtLeast(1f),y);lineTo((x+distance/2).coerceAtMost(frame.bitmap.width-2f),y)};else->error("视觉滑动方向无效。")}
            }
        }
        beforeDispatch()
        return dispatchGesture(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path,0,if(direction==null)50 else 300)).build(),null,null)
    }

    fun screenshot(allowed:Set<String>,args:Map<String,Any?> = emptyMap()):Map<String,Any?>{
        require(android.os.Build.VERSION.SDK_INT>=30){"此系统没有无障碍截图接口。"}
        val result=java.util.concurrent.CompletableFuture<Map<String,Any?>>()
        val handler=Handler(Looper.getMainLooper())
        handler.post{
            try{val root=current(allowed);@Suppress("DEPRECATION") root.recycle();overlay?.suspendForScreenshot()
                handler.postDelayed({
                    try{val expected=current(allowed).let{it.packageName?.toString() to it.windowId}
                    takeScreenshot(android.view.Display.DEFAULT_DISPLAY,mainExecutor,object:TakeScreenshotCallback{
                        override fun onSuccess(shot:ScreenshotResult){try{
                            val actual=current(allowed);require(actual.packageName?.toString()==expected.first&&actual.windowId==expected.second){"截图过程中页面已变化，请重新观察。"}
                            val hardware=Bitmap.wrapHardwareBuffer(shot.hardwareBuffer,shot.colorSpace)?:error("截图不可读取。")
                            val copy=hardware.copy(Bitmap.Config.ARGB_8888,false);hardware.recycle();shot.hardwareBuffer.close()
                            val crop=args["crop"] as? List<*>;val region=if(crop!=null){require(crop.size==4);val values=crop.map{(it as Number).toInt()};require(values[0]>=0&&values[1]>=0&&values[2]>values[0]&&values[3]>values[1]&&values[2]<=copy.width&&values[3]<=copy.height);Bitmap.createBitmap(copy,values[0],values[1],values[2]-values[0],values[3]-values[1])}else copy
                            val maxWidth=(args["maxWidth"] as? Number)?.toInt()?:0;require(maxWidth>=0)
                            val scaled=if(maxWidth>0&&region.width>maxWidth)Bitmap.createScaledBitmap(region,maxWidth,maxOf(1,(region.height.toLong()*maxWidth/region.width).toInt()),true)else region
                            val jpeg=args["format"]=="jpeg";val quality=(args["quality"] as? Number)?.toInt()?:100;require(quality in 0..100)
                            val width=scaled.width;val height=scaled.height;val bytes=java.io.ByteArrayOutputStream().apply{scaled.compress(if(jpeg)Bitmap.CompressFormat.JPEG else Bitmap.CompressFormat.PNG,quality,this)}.toByteArray()
                            if(scaled!==region)scaled.recycle();if(region!==copy)region.recycle();copy.recycle()
                            result.complete(mapOf("image" to "data:image/${if(jpeg)"jpeg"else"png"};base64,"+android.util.Base64.encodeToString(bytes,android.util.Base64.NO_WRAP),"width" to width,"height" to height,"encoding" to if(jpeg)"jpeg"else"png","compression" to if(jpeg)"user_configured"else"lossless","package" to rootInActiveWindow?.packageName?.toString(),"overlayExcluded" to true))
                        }catch(e:Exception){result.completeExceptionally(e)}finally{overlay?.restoreAfterScreenshot()}}
                        override fun onFailure(errorCode:Int){overlay?.restoreAfterScreenshot();result.completeExceptionally(IllegalStateException("截图不可用（系统代码 $errorCode），安全窗口和系统限制不会绕过。"))}
                    })}catch(e:Exception){overlay?.restoreAfterScreenshot();result.completeExceptionally(e)}
                },220)
            }catch(e:Exception){overlay?.restoreAfterScreenshot();result.completeExceptionally(e)}
        }
        return result.get()
    }
}
