package com.skyjjgw.independent.ski.dshgo.links

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.skyjjgw.independent.ski.MainActivity

/**
 * Receives `dshgo://` links and opened `.dshgo` files (the manifest's intent filters sit here,
 * not on MainActivity; shared ones go through share/ShareActivity) and hands them to the app's
 * own task.
 *
 * Apps like WeChat start a VIEW activity inside their own task, without
 * FLAG_ACTIVITY_NEW_TASK; aimed at MainActivity that would create a second Flutter activity
 * there. Forwarding with NEW_TASK | SINGLE_TOP | CLEAR_TOP brings the existing MainActivity
 * forward (closing a Custom Tab above it) and delivers the link through onNewIntent, or starts
 * the app with it. Read access to an opened `content:` URI is passed on with the intent.
 */
class LinkTrampolineActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val forward = Intent(intent).apply {
            setClass(this@LinkTrampolineActivity, MainActivity::class.java)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_GRANT_READ_URI_PERMISSION
        }
        try {
            startActivity(forward)
        } catch (_: Exception) {
            // Nothing to hand over to: the link is dropped.
        }
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
