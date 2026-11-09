package com.skyjjgw.independent.ski;

import android.app.Activity;
import android.os.Bundle;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.drawable.BitmapDrawable;
import android.widget.*;
import android.view.View;

/** Standalone target APK fixture: Java avoids depending on the target app's
 * Kotlin stdlib, which AGP correctly excludes from the instrumentation APK. */
public class CloudFixtureActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state); show(getIntent());
    }
    @Override public void onNewIntent(Intent value) {
        super.onNewIntent(value);setIntent(value);show(value);
    }
    private void show(Intent value) {
        if (value.getBooleanExtra("large", false)) largeScreen(); else screen(false);
    }
    private void largeScreen() {
        android.util.DisplayMetrics metrics=getResources().getDisplayMetrics();
        java.util.Random random=new java.util.Random(2471);
        int[] pixels=new int[metrics.widthPixels*metrics.heightPixels];
        for(int i=0;i<pixels.length;i++) pixels[i]=0xff000000|random.nextInt(0xffffff);
        Bitmap bitmap=Bitmap.createBitmap(pixels,metrics.widthPixels,metrics.heightPixels,Bitmap.Config.ARGB_8888);
        FrameLayout root=new FrameLayout(this);root.setBackground(new BitmapDrawable(getResources(),bitmap));
        LinearLayout column=new LinearLayout(this);column.setOrientation(LinearLayout.VERTICAL);column.setPadding(0,(int)(48*metrics.density),0,0);
        StringBuilder longText=new StringBuilder("LONG_TEXT_");for(int i=0;i<700;i++)longText.append("中文内容");
        TextView text=new TextView(this);text.setText(longText);text.setTextSize(5f);column.addView(text,new LinearLayout.LayoutParams(-1,30));
        for(int row=0;row<50;row++) {
            LinearLayout line=new LinearLayout(this);
            for(int index=0;index<5;index++) {
                TextView node=new TextView(this);node.setText("BOUNDARY_NODE_"+(row*5+index));node.setTextSize(4f);node.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
                line.addView(node,new LinearLayout.LayoutParams(0,12,1f));
            }
            column.addView(line);
        }
        FrameLayout nested=new FrameLayout(this);nested.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);nested.setContentDescription("DEPTH_ROOT");FrameLayout top=nested;
        for(int i=0;i<36;i++) {
            FrameLayout child=new FrameLayout(this);child.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);child.setContentDescription("DEPTH_"+i);
            nested.addView(child,new FrameLayout.LayoutParams(-1,-1));nested=child;
        }
        TextView deepest=new TextView(this);deepest.setText("DEEPEST_REAL_NODE");deepest.setTextSize(8f);nested.addView(deepest);
        column.addView(top,new LinearLayout.LayoutParams(-1,28));root.addView(column);setContentView(root);
    }
    private void screen(boolean next) {
        LinearLayout column=new LinearLayout(this);column.setOrientation(LinearLayout.VERTICAL);column.setPadding(24,100,24,24);
        TextView title=new TextView(this);title.setId(android.R.id.title);title.setText(next?"第二页面":"通用手机操控验收");title.setTextSize(22f);column.addView(title);
        EditText edit=new EditText(this);edit.setId(android.R.id.edit);edit.setHint("输入验收内容");column.addView(edit);
        CheckBox check=new CheckBox(this);check.setId(android.R.id.checkbox);check.setText("启用测试选项");column.addView(check);
        Button button=new Button(this);button.setId(android.R.id.button1);button.setText("切换页面");button.setOnClickListener(v->screen(!next));column.addView(button);
        TextView single=new TextView(this);single.setText(next?"单选：选择负数":"单选：选择正数");column.addView(single);
        RadioGroup group=new RadioGroup(this);
        for(String label:new String[]{"A. −2","B. 2"}) {RadioButton radio=new RadioButton(this);radio.setText(label);group.addView(radio);}column.addView(group);
        TextView multiple=new TextView(this);multiple.setText("多选：选择正数");column.addView(multiple);
        for(String label:new String[]{"A. 2","B. 3"}) {CheckBox option=new CheckBox(this);option.setText(label);column.addView(option);}
        setContentView(column);
    }
}
