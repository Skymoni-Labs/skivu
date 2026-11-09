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
import android.widget.*
import org.json.JSONObject
import kotlin.math.abs

/** Accessibility overlay is never a target window, never focusable, never an
 * Activity launch. Visual size and small touch targets are deliberately separate. */
class CloudOverlay(private val service:SkivuAccessibilityService){
    private val wm=service.getSystemService(WindowManager::class.java)
    private val main=Handler(Looper.getMainLooper())
    private var view:LinearLayout?=null;private var params:WindowManager.LayoutParams?=null
    private var expanded=false;private var suspended=0;private var revision="";private var drag=false
    private var current:Map<String,Any?>?=null;private var animator:ValueAnimator?=null
    private fun dp(n:Int)=(n*service.resources.displayMetrics.density+.5f).toInt()
    private val prefs=service.getSharedPreferences("cloud-overlay",0)
    fun refresh(){
        if(Looper.myLooper()!=Looper.getMainLooper()){main.post{refresh()};return}
        val state=ExecutionHub.currentPhone(service);val mode=ExecutionHub.mode(service)
        if(current?.get("taskId")!=state?.get("taskId")||mode!="compact")expanded=false
        current=state
        if(suspended>0||mode=="hidden"||state==null){remove();return}
        // Mode/phase updates never expand; expanded is solely a user gesture.
        val key="$mode:$expanded:${state["taskId"]}:${state["phase"]}:${state["action"]}:${state["canPause"]}:${state["canStop"]}"
        if(view!=null&&revision==key){clamp();return};revision=key
        val oldY=params?.y;val oldWidth=view?.width?:0;val oldHeight=view?.height?:0;remove(false)
        val panel=LinearLayout(service).apply{orientation=LinearLayout.VERTICAL;importantForAccessibility=View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS;isFocusable=false}
        val dot=mode=="dot"
        panel.setPadding(dp(if(dot)11 else 8),dp(if(dot)11 else 7),dp(if(dot)11 else 8),dp(if(dot)11 else 7))
        if(!dot)panel.background=GradientDrawable().apply{setColor(Color.rgb(28,30,35));cornerRadius=dp(20).toFloat();setStroke(dp(1),0x335f6470)}
        val header=LinearLayout(service).apply{gravity=Gravity.CENTER_VERTICAL}
        if(dot){header.addView(View(service).apply{background=GradientDrawable().apply{shape=GradientDrawable.OVAL;setColor(Color.WHITE);setStroke(dp(1),0xffc9ccd3.toInt())};elevation=dp(2).toFloat()},LinearLayout.LayoutParams(dp(10),dp(10)))}
        else{
            header.addView(Portrait(service,state["phase"].toString(),false),LinearLayout.LayoutParams(dp(22),dp(22)))
            header.addView(TextView(service).apply{text=ExecutionHub.label(state["phase"].toString());setTextColor(Color.WHITE);textSize=12f;setSingleLine();maxWidth=dp(146);setPadding(dp(7),0,dp(7),0)},LinearLayout.LayoutParams(-2,dp(22)))
            if(state["canStop"]==true)header.addView(control("■","停止当前任务"){runCatching{ExecutionHub.control(state["taskId"] as String,"stop")}},LinearLayout.LayoutParams(dp(28),dp(22)))
        }
        panel.addView(header)
        if(!dot&&expanded){
            val body=LinearLayout(service).apply{orientation=LinearLayout.HORIZONTAL;gravity=Gravity.CENTER_VERTICAL}
            body.addView(Portrait(service,state["phase"].toString(),true),LinearLayout.LayoutParams(dp(90),dp(80)))
            body.addView(TextView(service).apply{text=listOf(state["target"],state["action"],state["goal"]?.toString()?.take(90),state["evidence"]).filter{!it?.toString().isNullOrBlank()}.joinToString("\n");setTextColor(0xffeeeeee.toInt());textSize=12f;maxLines=7;maxWidth=dp(205)},LinearLayout.LayoutParams(dp(205),-2))
            panel.addView(body)
            val buttons=LinearLayout(service)
            if(state["canPause"]==true)buttons.addView(control("暂停","暂停当前任务"){runCatching{ExecutionHub.control(state["taskId"] as String,"pause")}})
            if(state["canResume"]==true)buttons.addView(control("继续","继续当前任务"){runCatching{ExecutionHub.control(state["taskId"] as String,"resume")}})
            buttons.addView(control("白点","缩成白点"){expanded=false;ExecutionHub.setMode(service,"dot")})
            buttons.addView(control("隐藏","隐藏悬浮层，任务继续"){expanded=false;ExecutionHub.setMode(service,"hidden")})
            panel.addView(buttons)
        }
        header.setOnClickListener{if(dot){expanded=false;ExecutionHub.setMode(service,"compact")}else{expanded=!expanded;refresh()}}
        val metrics=service.resources.displayMetrics
        panel.measure(View.MeasureSpec.makeMeasureSpec(metrics.widthPixels-dp(12),View.MeasureSpec.AT_MOST),View.MeasureSpec.makeMeasureSpec(metrics.heightPixels-dp(96),View.MeasureSpec.AT_MOST))
        val targetWidth=panel.measuredWidth;val targetHeight=panel.measuredHeight
        val lp=WindowManager.LayoutParams(targetWidth,targetHeight,WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            // WindowManager keeps every animated width centered, including after
            // rotation. Legacy horizontal drag preferences must not offset it.
            PixelFormat.TRANSLUCENT).apply{gravity=Gravity.TOP or Gravity.CENTER_HORIZONTAL;x=0;y=oldY?:(dp(48)+(metrics.heightPixels-dp(160))*prefs.getFloat("y",0f)).toInt();title="Skivu execution overlay";softInputMode=WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING}
        var downX=0f;var downY=0f;var startY=0
        header.setOnTouchListener{_,event->when(event.actionMasked){
            MotionEvent.ACTION_DOWN->{downX=event.rawX;downY=event.rawY;startY=lp.y;drag=false;false}
            MotionEvent.ACTION_MOVE->{if(abs(event.rawX-downX)>dp(6)||abs(event.rawY-downY)>dp(6))drag=true;if(drag){lp.y=startY+(event.rawY-downY).toInt();clamp();};drag}
            MotionEvent.ACTION_UP,MotionEvent.ACTION_CANCEL->{if(drag){persist();true}else false}
            else->false}}
        view=panel;params=lp
        try{wm.addView(panel,lp);panel.post{
            clamp()
            if(!reducedMotion()&&oldWidth>0&&oldHeight>0&&(oldWidth!=targetWidth||oldHeight!=targetHeight)){
                val endWidth=targetWidth;val endHeight=targetHeight
                animator=ValueAnimator.ofFloat(0f,1f).apply{duration=220;addUpdateListener{animation->if(view!==panel)return@addUpdateListener;val t=animation.animatedValue as Float;lp.width=(oldWidth+(endWidth-oldWidth)*t).toInt();lp.height=(oldHeight+(endHeight-oldHeight)*t).toInt();runCatching{wm.updateViewLayout(panel,lp)}};addListener(object:android.animation.AnimatorListenerAdapter(){override fun onAnimationEnd(animation:android.animation.Animator){if(view===panel){lp.width=endWidth;lp.height=endHeight;clamp()}}});start()}
            }else if(oldWidth==0&&!dot&&!reducedMotion()){panel.alpha=0f;panel.animate().alpha(1f).setDuration(220).start()}
        }}catch(_:Exception){view=null;params=null}
    }
    private fun reducedMotion()=Settings.Global.getFloat(service.contentResolver,Settings.Global.ANIMATOR_DURATION_SCALE,1f)==0f
    private fun control(label:String,description:String,action:()->Unit)=TextView(service).apply{text=label;contentDescription=description;setTextColor(Color.WHITE);textSize=12f;gravity=Gravity.CENTER;setPadding(dp(9),dp(5),dp(9),dp(5));setOnClickListener{action()};isFocusable=false}
    private fun clamp(){val v=view?:return;val p=params?:return
        val bounds=if(android.os.Build.VERSION.SDK_INT>=30)wm.currentWindowMetrics.bounds else Rect(0,0,service.resources.displayMetrics.widthPixels,service.resources.displayMetrics.heightPixels)
        var top=dp(32);var bottom=dp(32)
        if(android.os.Build.VERSION.SDK_INT>=30){val insets=wm.currentWindowMetrics.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout());top=maxOf(top,insets.top+dp(4));bottom=maxOf(bottom,insets.bottom+dp(4));bottom=maxOf(bottom,wm.currentWindowMetrics.windowInsets.getInsets(WindowInsets.Type.ime()).bottom+dp(4))}
        p.x=0;p.y=p.y.coerceIn(top,maxOf(top,bounds.height()-maxOf(dp(32),v.height)-bottom));runCatching{wm.updateViewLayout(v,p)}
    }
    private fun persist(){val p=params?:return;val m=service.resources.displayMetrics;prefs.edit().remove("x").putFloat("y",((p.y-dp(48)).toFloat()/maxOf(1,m.heightPixels-dp(160))).coerceIn(0f,1f)).apply()}
    fun suspendForScreenshot(){suspended++;remove()}
    fun restoreAfterScreenshot(){suspended=maxOf(0,suspended-1);refresh()}
    fun close(){remove()}
    internal fun reviewMetrics():Map<String,Any?> {val v=view;val p=params;val location=IntArray(2);v?.getLocationOnScreen(location);return mapOf("visible" to (v!=null),"mode" to ExecutionHub.mode(service),"expanded" to expanded,"x" to if(v!=null)location[0] else null,"y" to if(v!=null)location[1] else null,"width" to v?.width,"height" to v?.height,"avatarDp" to if(v!=null&&ExecutionHub.mode(service)=="compact")22 else 0,"focusable" to (p!=null&&p.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE==0))}
    private fun remove(reset:Boolean=true){animator?.cancel();view?.animate()?.cancel();view?.let{runCatching{wm.removeView(it)}};view=null;params=null;if(reset)revision=""}

    private class Portrait(context:Context,phase:String,private val half:Boolean):View(context){
        private val paint=Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        private val clips:List<Pair<Int,Int>>;private val atlas:Bitmap;private val columns:Int
        private val reduced=Settings.Global.getFloat(context.contentResolver,Settings.Global.ANIMATOR_DURATION_SCALE,1f)==0f
        private val start=SystemClock.uptimeMillis()
        private val once=phase=="completed"
        init{
            val name=when(phase){"observing"->"phone";"deciding"->"thinking";"acting","waiting"->"phone";"waiting_user"->"permission";"completed"->"complete";"failed","unknown"->"failed";"stopping","stopped","paused"->"paused";else->"checking"}
            val catalog=JSONObject(context.assets.open("flutter_assets/assets/branding/cloud_pet/workflow-v1.json").bufferedReader().use{it.readText()}).getJSONObject("packs").getJSONObject(name)
            columns=catalog.getInt("columns");atlas=BitmapFactory.decodeStream(context.assets.open("flutter_assets/"+catalog.getString("atlas")))
            val raw=catalog.getJSONObject("clips");val key=raw.keys().asSequence().first{it.startsWith("B_")};val frames=raw.getJSONArray(key);clips=(0 until frames.length()).map{frames.getJSONArray(it).let{row->row.getInt(0) to row.getInt(1)}}
            importantForAccessibility=IMPORTANT_FOR_ACCESSIBILITY_NO;isClickable=false;isFocusable=false
        }
        override fun onDraw(canvas:Canvas){super.onDraw(canvas);val duration=clips.sumOf{it.second};val timePassed=SystemClock.uptimeMillis()-start;var elapsed=if(reduced)0 else if(once)minOf(timePassed,duration.toLong()-1).toInt() else (timePassed%duration).toInt();var frame=clips.last().first;for((index,time) in clips){if(elapsed<time){frame=index;break};elapsed-=time}
            val x=frame%columns*256;val y=frame/columns*256
            canvas.save();if(!half){val clip=Path().apply{addCircle(width/2f,height/2f,minOf(width,height)/2f,Path.Direction.CW)};canvas.clipPath(clip)}
            val source=if(half)Rect(x,y,x+256,y+222)else Rect(x+18,y+15,x+218,y+177)
            canvas.drawBitmap(atlas,source,Rect(0,0,width,height),paint);canvas.restore();if(!reduced&&isAttachedToWindow&&(!once||timePassed<duration))postInvalidateDelayed(120)
        }
        override fun onDetachedFromWindow(){super.onDetachedFromWindow();atlas.recycle()}
    }
}
