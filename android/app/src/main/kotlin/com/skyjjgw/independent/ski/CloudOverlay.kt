package com.skyjjgw.independent.ski

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.*
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.*
import android.view.animation.PathInterpolator
import android.widget.*
import org.json.JSONObject
import kotlin.math.abs

/** A single non-focusable, tightly bounded window morphs from its current shape.
 * State updates and reversed gestures never remove/re-add the window. */
class CloudOverlay(private val service:SkivuAccessibilityService){
    private val wm=service.getSystemService(WindowManager::class.java)
    private val main=Handler(Looper.getMainLooper())
    private var view:FrameLayout?=null
    private var surface:FrameLayout?=null
    private val localMorph get()=android.os.Build.VERSION.SDK_INT>=33
    private var visualWidth=0;private var visualHeight=0
    private var header:LinearLayout?=null
    private var body:LinearLayout?=null
    private var dot:View?=null
    private var params:WindowManager.LayoutParams?=null
    private var expanded=false;private var suspended=0;private var revision="";private var drag=false
    private var current:Map<String,Any?>?=null;private var animator:ValueAnimator?=null
    private var fraction=0f;private var corner=0f;private var generation=0
    private var targetWidth=0;private var targetHeight=0
    private val packs=mutableMapOf<String,PortraitPack>()
    private fun dp(n:Int)=(n*service.resources.displayMetrics.density+.5f).toInt()
    private val prefs=service.getSharedPreferences("cloud-overlay",0)
    private val shape=GradientDrawable().apply{setColor(Color.rgb(18,19,23));setStroke(dp(1),0x335f6470)}
    fun refresh(){
        if(Looper.myLooper()!=Looper.getMainLooper()){main.post{refresh()};return}
        val state=ExecutionHub.currentPhone(service);val mode=ExecutionHub.mode(service)
        if(current?.get("taskId")!=state?.get("taskId")||mode!="compact")expanded=false
        current=state
        if(suspended>0||mode=="hidden"||state==null){remove();return}
        ensureWindow()
        val key="$mode:${state["taskId"]}:${state["phase"]}:${state["action"]}:${state["target"]}:${state["goal"]}:${state["evidence"]}:${state["canPause"]}:${state["canResume"]}:${state["canStop"]}"
        if(revision!=key){revision=key;updateContents(state,mode)}
        val root=view?:return
        val bounds=bounds()
        val maxWidth=maxOf(dp(32),bounds.width()-dp(12))
        val isDot=mode=="dot"
        val compact=header!!
        compact.measure(View.MeasureSpec.makeMeasureSpec(maxWidth,View.MeasureSpec.AT_MOST),View.MeasureSpec.makeMeasureSpec(dp(36),View.MeasureSpec.EXACTLY))
        body!!.measure(View.MeasureSpec.makeMeasureSpec(minOf(dp(330),maxWidth),View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(maxOf(dp(60),bounds.height()-dp(120)),View.MeasureSpec.AT_MOST))
        val width=if(isDot)dp(32)else if(expanded)minOf(dp(330),maxWidth)else compact.measuredWidth.coerceAtMost(maxWidth)
        val height=if(isDot)dp(32)else if(expanded)minOf(dp(36)+body!!.measuredHeight,bounds.height()-dp(80))else dp(36)
        body!!.layoutParams=(body!!.layoutParams as FrameLayout.LayoutParams).apply{this.width=minOf(dp(330),maxWidth);topMargin=dp(36)}
        if(localMorph){
            val p=params?:return
            p.width=minOf(dp(330),maxWidth)
            p.height=minOf(maxOf(dp(260),height),bounds.height()-dp(80))
        }
        if(targetWidth==width&&targetHeight==height){clamp();return}
        targetWidth=width;targetHeight=height
        val lp=params?:return
        animator?.cancel()
        val fromWidth=visualWidth;val fromHeight=visualHeight;val fromFraction=fraction;val fromCorner=corner
        val endFraction=if(expanded&&!isDot)1f else 0f
        val endCorner=dp(if(expanded&&!isDot)28 else 18).toFloat()
        fun frame(t:Float){
            if(view!==root)return
            visualWidth=(fromWidth+(width-fromWidth)*t).toInt();visualHeight=(fromHeight+(height-fromHeight)*t).toInt()
            if(localMorph){root.layoutParams=(root.layoutParams as FrameLayout.LayoutParams).apply{this.width=visualWidth;this.height=visualHeight}}
            else{lp.width=visualWidth;lp.height=visualHeight}
            fraction=fromFraction+(endFraction-fromFraction)*t;corner=fromCorner+(endCorner-fromCorner)*t
            shape.cornerRadius=corner
            // Content arrives after the shell starts expanding; reversing uses
            // the rendered fraction, so neither text nor geometry snaps.
            val content=((fraction-.18f)/.82f).coerceIn(0f,1f)
            body!!.alpha=content;body!!.translationY=dp(7)*(1-content);body!!.scaleX=.96f+.04f*content;body!!.scaleY=.96f+.04f*content
            body!!.visibility=if(fraction>0f)View.VISIBLE else View.INVISIBLE
            body!!.isEnabled=expanded
            if(android.os.Build.VERSION.SDK_INT>=31)body!!.setRenderEffect(if(content in .01f.. .98f)RenderEffect.createBlurEffect(maxOf(.1f,dp(5)*(1-content)),maxOf(.1f,dp(5)*(1-content)),Shader.TileMode.CLAMP)else null)
            clamp()
        }
        if(reducedMotion()||fromWidth<=0){frame(1f)}else{
            animator=ValueAnimator.ofFloat(0f,1f).apply{duration=if(expanded)380 else 310;interpolator=PathInterpolator(.2f,0f,0f,1f);addUpdateListener{frame(it.animatedValue as Float)};start()}
        }
    }
    private fun ensureWindow(){
        if(view!=null)return
        val root=FrameLayout(service).apply{background=shape;clipToOutline=true;importantForAccessibility=View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS;isFocusable=false}
        val compact=LinearLayout(service).apply{gravity=Gravity.CENTER_VERTICAL;setPadding(dp(8),dp(7),dp(8),dp(7))}
        val details=LinearLayout(service).apply{orientation=LinearLayout.VERTICAL;setPadding(dp(8),0,dp(8),dp(9));visibility=View.INVISIBLE}
        val point=View(service).apply{background=GradientDrawable().apply{shape=GradientDrawable.OVAL;setColor(Color.WHITE);setStroke(dp(1),0xffc9ccd3.toInt())};elevation=dp(2).toFloat();visibility=View.GONE}
        root.addView(details,FrameLayout.LayoutParams(dp(330),-2).apply{topMargin=dp(36)})
        root.addView(compact,FrameLayout.LayoutParams(-1,dp(36)))
        root.addView(point,FrameLayout.LayoutParams(dp(10),dp(10),Gravity.CENTER))
        val metrics=service.resources.displayMetrics
        val lp=WindowManager.LayoutParams(dp(32),dp(36),WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT).apply{gravity=Gravity.TOP or Gravity.CENTER_HORIZONTAL;x=0;y=(dp(48)+(metrics.heightPixels-dp(160))*prefs.getFloat("y",0f)).toInt();title="Skivu execution overlay";softInputMode=WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING}
        var downX=0f;var downY=0f;var startY=0
        compact.setOnTouchListener{_,event->when(event.actionMasked){
            MotionEvent.ACTION_DOWN->{downX=event.rawX;downY=event.rawY;startY=lp.y;drag=false;false}
            MotionEvent.ACTION_MOVE->{if(abs(event.rawX-downX)>dp(6)||abs(event.rawY-downY)>dp(6))drag=true;if(drag){lp.y=startY+(event.rawY-downY).toInt();clamp()};drag}
            MotionEvent.ACTION_UP,MotionEvent.ACTION_CANCEL->{if(drag){persist();true}else false}
            else->false}}
        compact.setOnClickListener{if(ExecutionHub.mode(service)=="dot"){expanded=false;ExecutionHub.setMode(service,"compact")}else{expanded=!expanded;refresh()}}
        val window=if(localMorph)FrameLayout(service).apply{
            importantForAccessibility=View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            addView(root,FrameLayout.LayoutParams(dp(32),dp(36),Gravity.TOP or Gravity.CENTER_HORIZONTAL))
            viewTreeObserver.addOnPreDrawListener{
                // Android33 public touch-region API keeps transparent space
                // fully pass-through while visual morphs stay in one surface.
                rootSurfaceControl?.setTouchableRegion(Region(root.left,root.top,root.right,root.bottom))
                true
            }
        }else root
        if(localMorph){lp.width=minOf(dp(330),bounds().width()-dp(12));lp.height=minOf(dp(260),bounds().height()-dp(80));lp.flags=lp.flags or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS}
        visualWidth=dp(32);visualHeight=dp(36)
        surface=window;view=root;header=compact;body=details;dot=point;params=lp;corner=dp(18).toFloat();shape.cornerRadius=corner;generation++
        try{wm.addView(window,lp)}catch(_:Exception){view=null;params=null}
    }
    private fun updateContents(state:Map<String,Any?>,mode:String){
        val compact=header?:return;val details=body?:return;val isDot=mode=="dot"
        compact.removeAllViews();details.removeAllViews();dot?.visibility=if(isDot)View.VISIBLE else View.GONE
        view?.background=if(isDot)null else shape
        if(isDot)return
        compact.addView(portrait(state,false),LinearLayout.LayoutParams(dp(22),dp(22)))
        compact.addView(TextView(service).apply{text=ExecutionHub.label(state["phase"].toString());setTextColor(Color.WHITE);textSize=12f;setSingleLine();maxWidth=dp(180);setPadding(dp(7),0,dp(7),0)},LinearLayout.LayoutParams(-2,dp(22)))
        if(state["canStop"]==true)compact.addView(control("■","停止当前任务"){controlTask("stop")},LinearLayout.LayoutParams(dp(28),dp(22)))
        val row=LinearLayout(service).apply{gravity=Gravity.CENTER_VERTICAL}
        row.addView(portrait(state,true),LinearLayout.LayoutParams(dp(90),dp(80)))
        row.addView(TextView(service).apply{text=listOf(state["target"],state["action"],state["goal"],state["evidence"]).filter{!it?.toString().isNullOrBlank()}.joinToString("\n");setTextColor(0xffeeeeee.toInt());textSize=12f;maxLines=7;ellipsize=android.text.TextUtils.TruncateAt.END},LinearLayout.LayoutParams(0,-2,1f))
        details.addView(row)
        val buttons=LinearLayout(service)
        if(state["canPause"]==true)buttons.addView(control("暂停","暂停当前任务"){controlTask("pause")})
        if(state["canResume"]==true)buttons.addView(control("继续","继续当前任务"){controlTask("resume")})
        buttons.addView(control("白点","缩成白点"){expanded=false;ExecutionHub.setMode(service,"dot")})
        buttons.addView(control("隐藏","隐藏悬浮层，任务继续"){expanded=false;ExecutionHub.setMode(service,"hidden")})
        details.addView(buttons)
    }
    private fun controlTask(action:String){current?.get("taskId")?.toString()?.let{runCatching{ExecutionHub.control(it,action)}}}
    private fun portrait(state:Map<String,Any?>,half:Boolean):Portrait{
        val phase=state["phase"].toString();val name=when(phase){"observing"->"phone";"deciding"->"thinking";"acting","waiting"->"phone";"waiting_user"->"permission";"completed"->"complete";"failed","unknown"->"failed";"stopping","stopped","paused"->"paused";else->"checking"}
        val pack=packs.getOrPut(name){val catalog=JSONObject(service.assets.open("flutter_assets/assets/branding/cloud_pet/workflow-v1.json").bufferedReader().use{it.readText()}).getJSONObject("packs").getJSONObject(name);val raw=catalog.getJSONObject("clips");val frames=raw.getJSONArray(raw.keys().asSequence().first{it.startsWith("B_")});PortraitPack(BitmapFactory.decodeStream(service.assets.open("flutter_assets/"+catalog.getString("atlas"))),catalog.getInt("columns"),(0 until frames.length()).map{frames.getJSONArray(it).let{r->r.getInt(0) to r.getInt(1)}})}
        return Portrait(service,phase,half,pack)
    }
    private fun reducedMotion()=Settings.Global.getFloat(service.contentResolver,Settings.Global.ANIMATOR_DURATION_SCALE,1f)==0f
    private fun control(label:String,description:String,action:()->Unit)=TextView(service).apply{text=label;contentDescription=description;setTextColor(Color.WHITE);textSize=12f;gravity=Gravity.CENTER;setPadding(dp(9),dp(5),dp(9),dp(5));setOnClickListener{if(expanded||description=="停止当前任务")action()};isFocusable=false}
    private fun bounds()=if(android.os.Build.VERSION.SDK_INT>=30)wm.currentWindowMetrics.bounds else Rect(0,0,service.resources.displayMetrics.widthPixels,service.resources.displayMetrics.heightPixels)
    private fun clamp(){val v=surface?:return;val p=params?:return;val bounds=bounds();var top=dp(32);var bottom=dp(32)
        if(android.os.Build.VERSION.SDK_INT>=30){val insets=wm.currentWindowMetrics.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout());top=maxOf(top,insets.top+dp(4));bottom=maxOf(bottom,insets.bottom+dp(4));bottom=maxOf(bottom,wm.currentWindowMetrics.windowInsets.getInsets(WindowInsets.Type.ime()).bottom+dp(4))}
        p.x=0;p.width=minOf(p.width,bounds.width()-dp(12));p.y=p.y.coerceIn(top,maxOf(top,bounds.height()-maxOf(dp(32),visualHeight)-bottom));runCatching{wm.updateViewLayout(v,p)}
    }
    private fun persist(){val p=params?:return;val m=service.resources.displayMetrics;prefs.edit().remove("x").putFloat("y",((p.y-dp(48)).toFloat()/maxOf(1,m.heightPixels-dp(160))).coerceIn(0f,1f)).apply()}
    fun suspendForScreenshot(){suspended++;remove()}
    fun restoreAfterScreenshot(){suspended=maxOf(0,suspended-1);refresh()}
    fun close(){remove();packs.values.forEach{it.atlas.recycle()};packs.clear()}
    internal fun reviewMetrics():Map<String,Any?> {val v=view;val p=params;val location=IntArray(2);v?.getLocationOnScreen(location);return mapOf("visible" to (v!=null),"mode" to ExecutionHub.mode(service),"expanded" to expanded,"x" to if(v!=null)location[0] else null,"y" to if(v!=null)location[1] else null,"width" to v?.width,"height" to v?.height,"avatarDp" to if(v!=null&&ExecutionHub.mode(service)=="compact")22 else 0,"focusable" to (p!=null&&p.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE==0),"windowGeneration" to generation,"transition" to fraction)}
    private fun remove(){animator?.cancel();animator=null;surface?.let{runCatching{wm.removeView(it)}};surface=null;view=null;header=null;body=null;dot=null;params=null;revision="";targetWidth=0;targetHeight=0;fraction=0f}
    private data class PortraitPack(val atlas:Bitmap,val columns:Int,val clips:List<Pair<Int,Int>>)
    private class Portrait(context:Context,phase:String,private val half:Boolean,pack:PortraitPack):View(context){
        private val paint=Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        private val clips=pack.clips;private val atlas=pack.atlas;private val columns=pack.columns
        private val reduced=Settings.Global.getFloat(context.contentResolver,Settings.Global.ANIMATOR_DURATION_SCALE,1f)==0f
        private val start=SystemClock.uptimeMillis()
        private val once=phase=="completed"
        init{importantForAccessibility=IMPORTANT_FOR_ACCESSIBILITY_NO;isClickable=false;isFocusable=false}
        override fun onDraw(canvas:Canvas){super.onDraw(canvas);val duration=clips.sumOf{it.second};val timePassed=SystemClock.uptimeMillis()-start;var elapsed=if(reduced)0 else if(once)minOf(timePassed,duration.toLong()-1).toInt() else (timePassed%duration).toInt();var frame=clips.last().first;for((index,time) in clips){if(elapsed<time){frame=index;break};elapsed-=time}
            val x=frame%columns*256;val y=frame/columns*256
            canvas.save();if(!half){val clip=Path().apply{addCircle(width/2f,height/2f,minOf(width,height)/2f,Path.Direction.CW)};canvas.clipPath(clip)}
            val source=if(half)Rect(x,y,x+256,y+222)else Rect(x+18,y+15,x+218,y+177)
            canvas.drawBitmap(atlas,source,Rect(0,0,width,height),paint);canvas.restore();if(!reduced&&isAttachedToWindow&&(!once||timePassed<duration))postInvalidateDelayed(120)
        }

    }
}
