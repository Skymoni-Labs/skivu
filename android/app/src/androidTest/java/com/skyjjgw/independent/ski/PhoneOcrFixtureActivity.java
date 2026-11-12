package com.skyjjgw.independent.ski;

import android.app.Activity;
import android.os.Bundle;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.MotionEvent;
import android.view.View;

/** Actual raster text and touch handling, without accessible text/button nodes. */
public class PhoneOcrFixtureActivity extends Activity {
    public static volatile PhoneOcrFixtureActivity instance;
    public volatile int page = 1;
    public volatile int taps = 0;
    public volatile int leftTaps = 0;
    public volatile int rightTaps = 0;
    public volatile boolean moved = false;
    public volatile boolean duplicateNext = false;
    public volatile String confirmation = "";
    public View surface;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);instance=this;
        surface=new View(this) {
            final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
            final RectF button=new RectF();
            void text(Canvas c,String value,float y,int color) {
                paint.setColor(color);paint.setTextSize(getWidth()/18f);paint.setTextAlign(Paint.Align.CENTER);
                c.drawText(value,getWidth()/2f,y,paint);
            }
            @Override protected void onDraw(Canvas c) {
                c.drawColor(Color.WHITE);
                text(c,"屏幕识别测试",getHeight()*.13f,Color.BLACK);
                text(c,"第"+page+"页",getHeight()*.25f,Color.BLACK);
                paint.setTextSize(getWidth()/18f);paint.setTextAlign(Paint.Align.CENTER);paint.setColor(Color.BLACK);
                c.drawText("确定",getWidth()*.25f,getHeight()*.40f,paint);
                c.drawText("确定",getWidth()*.75f,getHeight()*.52f,paint);
                text(c,confirmation,getHeight()*.60f,Color.BLACK);
                float y=moved ? .82f : .66f;
                button.set(getWidth()*.2f,getHeight()*y,getWidth()*.8f,getHeight()*(y+.10f));
                paint.setColor(Color.rgb(30,100,210));c.drawRoundRect(button,16,16,paint);
                text(c,"下一页",button.centerY()+getWidth()/54f,Color.WHITE);
                if(duplicateNext)text(c,"下一页",getHeight()*.58f,Color.BLACK);
            }
            @Override public boolean onTouchEvent(MotionEvent e) {
                if(e.getAction()==MotionEvent.ACTION_UP) {
                    if(button.contains(e.getX(),e.getY())){page++;taps++;invalidate();}
                    else if(e.getY()>getHeight()*.34f&&e.getY()<getHeight()*.56f){if(e.getX()<getWidth()/2f){leftTaps++;confirmation="左侧已确认";}else{rightTaps++;confirmation="右侧已确认";}invalidate();}
                }
                return true;
            }
        };
        surface.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
        setContentView(surface);
    }
    public void moveButton(){moved=true;surface.invalidate();}
    public void addDuplicateNext(){duplicateNext=true;surface.invalidate();}
    @Override public void onDestroy(){if(instance==this)instance=null;super.onDestroy();}
}
