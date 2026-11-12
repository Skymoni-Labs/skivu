package com.skyjjgw.independent.ski;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import org.json.JSONObject;

/** Test-APK-only IPC: the fixture activity runs in a separate Android process. */
public class PhoneOcrFixtureReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        PhoneOcrFixtureActivity current=PhoneOcrFixtureActivity.instance;
        if(current==null){setResultData("{\"alive\":false}");return;}
        if("move".equals(intent.getStringExtra("op")))current.moveButton();
        if("duplicateNext".equals(intent.getStringExtra("op")))current.addDuplicateNext();
        if("redraw".equals(intent.getStringExtra("op")))current.surface.invalidate();
        try {
            setResultData(new JSONObject().put("alive",true).put("page",current.page).put("taps",current.taps)
                .put("leftTaps",current.leftTaps).put("rightTaps",current.rightTaps).toString());
        } catch(Exception error){throw new IllegalStateException(error);}
    }
}
