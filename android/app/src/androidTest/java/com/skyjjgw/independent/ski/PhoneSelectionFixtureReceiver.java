package com.skyjjgw.independent.ski;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Ordered result data stays in the isolated test APK process. */
public class PhoneSelectionFixtureReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        PhoneSelectionFixtureActivity activity = PhoneSelectionFixtureActivity.instance;
        if (activity == null) { setResultData("{\"alive\":false}"); return; }
        String operation = intent.getStringExtra("op");
        if ("ignore".equals(operation)) activity.ignoreTouches = true;
        if ("accept".equals(operation)) activity.ignoreTouches = false;
        setResultData(activity.snapshot().toString());
    }
}
