package com.skyjjgw.independent.ski

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle

/** A user-opened, one-session system consent flow. Tokens are never persisted or reused. */
class PhoneScreenCaptureActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val prefs = getSharedPreferences("skivu.device-engine.v1", 0)
        if (Build.VERSION.SDK_INT < 30 || !prefs.getBoolean("enabled", false) ||
            !prefs.getBoolean("control", false) || SkivuAccessibilityService.connected == null) { finish(); return }
        if (state != null) return
        val manager = getSystemService(MediaProjectionManager::class.java)
        val consent = if (Build.VERSION.SDK_INT >= 34)
            manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        else manager.createScreenCaptureIntent()
        @Suppress("DEPRECATION")
        startActivityForResult(consent, 1)
    }

    @Deprecated("Framework activity result entry point")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 1 && resultCode == RESULT_OK && data != null) {
            val prefs = getSharedPreferences("skivu.device-engine.v1", 0)
            if (prefs.getBoolean("enabled", false) && prefs.getBoolean("control", false) &&
                SkivuAccessibilityService.connected != null) {
                startForegroundService(Intent(this, PhoneScreenCaptureService::class.java)
                    .putExtra("resultCode", resultCode).putExtra("consent", data))
            }
        }
        finish()
    }
}
