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
    private var observation = ""
    private var observedPackage = ""
    private var observedWindow = -1
    private var observedAt = 0L
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
        super.onDestroy()
    }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if(event?.packageName?.toString()==packageName)return
        if(event==null)return
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
        nodes.clear()
        observation = ""
    }

    private fun current(allowed: Set<String>): AccessibilityNodeInfo {
        require(!getSystemService(android.app.KeyguardManager::class.java).isDeviceLocked&&getSystemService(android.os.PowerManager::class.java).isInteractive){"手机已锁屏或屏幕不可操作，请解锁后核对；没有重放动作。"}
        val root = rootInActiveWindow ?: error("当前没有可观察的界面。")
        val target = root.packageName?.toString().orEmpty()
        require(target != packageName && target in allowed) { "当前软件不在授权范围内。" }
        return root
    }

    fun observe(allowed: Set<String>): Map<String, Any?> {
        clearObservation()
        val root = current(allowed)
        observedPackage = root.packageName.toString()
        observedWindow = root.windowId
        observedAt = SystemClock.uptimeMillis()
        observation = UUID.randomUUID().toString()
        val rows = mutableListOf<Map<String, Any?>>()
        fun walk(node: AccessibilityNodeInfo, parent: String?, depth: Int) {
            if (rows.size >= 160 || depth > 24 || !node.isVisibleToUser) return
            val id = "n_${rows.size}"
            val bounds = Rect().also { node.getBoundsInScreen(it) }
            val secret = node.isPassword
            @Suppress("DEPRECATION")
            nodes[id] = AccessibilityNodeInfo.obtain(node)
            rows += mapOf(
                "id" to id, "parentId" to parent,
                "text" to if (secret) "" else node.text?.toString()?.take(500).orEmpty(),
                "description" to if (secret) "" else node.contentDescription?.toString()?.take(300).orEmpty(),
                "viewId" to node.viewIdResourceName.orEmpty(),
                "class" to node.className?.toString().orEmpty(),
                "password" to secret, "editable" to node.isEditable,
                "enabled" to node.isEnabled, "checkable" to node.isCheckable,
                "checked" to node.isChecked, "selected" to node.isSelected,
                "clickable" to node.isClickable, "scrollable" to node.isScrollable,
                "bounds" to listOf(bounds.left, bounds.top, bounds.right, bounds.bottom)
            )
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                walk(child, id, depth + 1)
                @Suppress("DEPRECATION") child.recycle()
            }
        }
        walk(root, null, 0)
        @Suppress("DEPRECATION") root.recycle()
        return mapOf("observationId" to observation, "package" to observedPackage,
            "windowId" to observedWindow, "elements" to rows)
    }

    fun act(tool: String, args: Map<String, Any?>, allowed: Set<String>, beforeDispatch: () -> Unit, requestId:String="",owner:String=""): Boolean {
        val root = current(allowed)
        val matches = root.packageName?.toString() == observedPackage && root.windowId == observedWindow
        @Suppress("DEPRECATION") root.recycle()
        if (tool == "ui.back" || tool == "ui.home") {
            require(args.isEmpty()) { "界面动作参数无效。" }
            val original=nodes.values.map{it.text?.toString().orEmpty()}.filter{it.isNotBlank()}.toSet()
            if(requestId.isNotEmpty())proofs[requestId]=Proof(tool,owner,observedPackage,"","",false,false,false,original)
            clearObservation()
            beforeDispatch()
            return performGlobalAction(if (tool == "ui.back") GLOBAL_ACTION_BACK else GLOBAL_ACTION_HOME)
        }
        require(observation.isNotEmpty() && args["observationId"] == observation && matches &&
            SystemClock.uptimeMillis() - observedAt < 60_000) { "界面观察已过期，请重新观察。" }
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
        require(observedPackage !in setOf("com.android.settings", "com.android.permissioncontroller", "com.google.android.permissioncontroller")) {
            "系统权限管理页面由用户操作；请使用明确的系统接口修改设置。"
        }
        val texts=nodes.values.flatMap{listOf(it.text?.toString().orEmpty(),"node:${it.viewIdResourceName.orEmpty()}:${it.text?.toString().orEmpty()}:${it.contentDescription?.toString().orEmpty()}")}.filter{it.isNotBlank()}.toSet()
        val proof=Proof(tool,owner,observedPackage,node.viewIdResourceName.orEmpty(),if(tool=="ui.input")args["text"].toString() else node.text?.toString().orEmpty(),node.isChecked,node.isSelected,node.isCheckable,texts)
        val result = when (tool) {
            "ui.tap" -> { beforeDispatch(); node.performAction(AccessibilityNodeInfo.ACTION_CLICK) }
            "ui.longPress" -> {beforeDispatch();node.performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK)}
            "ui.swipe" -> {
                require(args["direction"] in listOf("up","down","left","right"))
                val b=Rect().also{node.getBoundsInScreen(it)};require(b.width()>20&&b.height()>20)
                var x1=b.centerX().toFloat();var y1=b.centerY().toFloat();var x2=x1;var y2=y1
                when(args["direction"]){"up"->{y1=b.top+b.height()*.8f;y2=b.top+b.height()*.2f};"down"->{y1=b.top+b.height()*.2f;y2=b.top+b.height()*.8f};"left"->{x1=b.left+b.width()*.8f;x2=b.left+b.width()*.2f};else->{x1=b.left+b.width()*.2f;x2=b.left+b.width()*.8f}}
                beforeDispatch();dispatchGesture(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(Path().apply{moveTo(x1,y1);lineTo(x2,y2)},0,350)).build(),null,null)
            }
            "ui.input" -> {
                val text = args["text"] as? String ?: error("缺少输入文字。")
                require(text.length <= 12000 && !text.contains('\u0000') && node.isEditable)
                beforeDispatch()
                node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                })
            }
            "ui.scroll" -> {
                require(args["direction"] in listOf("forward", "backward"))
                beforeDispatch()
                node.performAction(if (args["direction"] == "forward") AccessibilityNodeInfo.ACTION_SCROLL_FORWARD else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
            }
            else -> error("不支持的界面操作。")
        }
        if(result&&requestId.isNotEmpty()){proofs[requestId]=proof;while(proofs.size>100)proofs.remove(proofs.keys.first())}
        clearObservation()
        return result
    }

    fun verify(args:Map<String,Any?>,allowed:Set<String>,owner:String):Map<String,Any?>{
        val id=args["requestId"] as? String?:error("缺少原动作编号。")
        val proof=proofs[id]?:error("原动作证据不在当前会话，结果仍待核对，不能重放。")
        require(proof.owner==owner){"不能核对其他会话的动作。"}
        @Suppress("UNCHECKED_CAST") val expect=args["expect"] as? Map<String,Any?>?:error("缺少明确核对条件。")
        val snapshot=observe(allowed)
        @Suppress("UNCHECKED_CAST") val rows=snapshot["elements"] as List<Map<String,Any?>>
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
        return mapOf("matched" to matched,"verifiedRequestId" to if(matched)id else null,"package" to snapshot["package"],"observationId" to snapshot["observationId"],"verification" to "fresh_ui_predicate","elements" to rows)
    }

    fun screenshot(allowed:Set<String>):Map<String,Any?>{
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
                            val scaled=Bitmap.createScaledBitmap(copy, minOf(720,copy.width),maxOf(1,(copy.height.toLong()*minOf(720,copy.width)/copy.width).toInt()),true)
                            val bytes=java.io.ByteArrayOutputStream().apply{scaled.compress(Bitmap.CompressFormat.JPEG,78,this)}.toByteArray();if(scaled!==copy)scaled.recycle();copy.recycle();require(bytes.size<=600000)
                            result.complete(mapOf("image" to "data:image/jpeg;base64,"+android.util.Base64.encodeToString(bytes,android.util.Base64.NO_WRAP),"package" to rootInActiveWindow?.packageName?.toString(),"overlayExcluded" to true))
                        }catch(e:Exception){result.completeExceptionally(e)}finally{overlay?.restoreAfterScreenshot()}}
                        override fun onFailure(errorCode:Int){overlay?.restoreAfterScreenshot();result.completeExceptionally(IllegalStateException("截图不可用（系统代码 $errorCode），安全窗口和系统限制不会绕过。"))}
                    })}catch(e:Exception){overlay?.restoreAfterScreenshot();result.completeExceptionally(e)}
                },220)
            }catch(e:Exception){overlay?.restoreAfterScreenshot();result.completeExceptionally(e)}
        }
        return result.get(8,java.util.concurrent.TimeUnit.SECONDS)
    }
}
