package com.skyjjgw.independent.ski;

import android.app.Activity;
import android.os.Bundle;
import android.widget.*;

/** Disposable native controls, installed only in the instrumentation APK. */
public class DshGoFixtureActivity extends Activity {
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        getWindow().setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
        LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setPadding(40,80,40,40);
        root.setFocusableInTouchMode(true);
        TextView title=new TextView(this);title.setId(android.R.id.text1);title.setText("Skivu DSH Go fixture "+getIntent().getStringExtra("qaMarker"));title.setTextSize(24);root.addView(title);
        TextView counter=new TextView(this);counter.setText("点击计数 0");counter.setTextSize(20);root.addView(counter);
        EditText input=new EditText(this);input.setId(android.R.id.edit);input.setHint("测试内容");input.setContentDescription("测试内容");input.setSingleLine(true);root.addView(input);
        TextView echo=new TextView(this);root.addView(echo);
        input.addTextChangedListener(new android.text.TextWatcher(){public void beforeTextChanged(CharSequence s,int a,int c,int n){}public void onTextChanged(CharSequence s,int a,int b,int c){echo.setText("实际输入 "+s);}public void afterTextChanged(android.text.Editable e){}});
        CheckBox option=new CheckBox(this);option.setText("测试选项");root.addView(option);
        Button add=new Button(this);add.setId(android.R.id.button1);add.setText("增加计数");root.addView(add);
        int[] clicks={0};
        add.setOnClickListener(v->{clicks[0]++;counter.setText("点击计数 "+clicks[0]);});
        Button next=new Button(this);next.setId(android.R.id.button2);next.setText("下一页");root.addView(next);
        next.setOnClickListener(v->{title.setText("Skivu fixture 第二页");add.setVisibility(android.view.View.GONE);});
        Button delayed=new Button(this);delayed.setId(android.R.id.button3);delayed.setText("计数后延迟回执");root.addView(delayed);
        delayed.setOnClickListener(v->{
            clicks[0]++;counter.setText("点击计数 "+clicks[0]);
            String host=getIntent().getStringExtra("qaHostPackage");
            if(host!=null)sendBroadcast(new android.content.Intent("com.skyjjgw.independent.ski.DSHGO_QA_EFFECT").setPackage(host).putExtra("token",getIntent().getStringExtra("qaSignalToken")));
            try{Thread.sleep(1800);}catch(InterruptedException e){Thread.currentThread().interrupt();}
        });
        setContentView(root);
        root.requestFocus();
    }
}
