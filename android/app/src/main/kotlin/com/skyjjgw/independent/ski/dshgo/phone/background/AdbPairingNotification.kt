package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.i18n.AppStrings
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.skyjjgw.independent.ski.MainActivity
import com.skyjjgw.independent.ski.R

/**
 * LADB-style pairing helper: a heads-up notification carrying a [RemoteInput] text box, so the
 * person types the 6-digit code straight from the notification while the system's
 * 「无线调试 → 使用配对码配对设备」dialog (and Settings' pairing sheet) is on screen. The code is
 * handed to [BackgroundControl.adbPairFromNotification]; it is never sent anywhere else. Uses framework
 * android.app APIs only (minSdk 26), so no extra support-library dependency.
 */
object AdbPairingNotification {
    const val CHANNEL_ID = "dsh_phone_pairing"
    const val NOTIFICATION_ID = 0x05D4
    const val CODE_KEY = "dsh_pairing_code"
    private const val ACTION_SUBMIT = "com.skyjjgw.independent.ski.dshgo.PHONE_ADB_PAIR_CODE"

    fun show(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, AppStrings.get(context, R.string.pairing_channel), NotificationManager.IMPORTANCE_HIGH))
        val remoteInput = RemoteInput.Builder(CODE_KEY).setLabel(AppStrings.get(context, R.string.pairing_code)).build()
        val submit = Intent(ACTION_SUBMIT).setPackage(context.packageName)
        val pending = PendingIntent.getBroadcast(
            context, 0, submit, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
        val action = Notification.Action.Builder(0, AppStrings.get(context, R.string.pairing_enter), pending)
            .addRemoteInput(remoteInput)
            .setAllowGeneratedReplies(false)
            .build()
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setContentTitle(AppStrings.get(context, R.string.pairing_title))
            .setContentText(AppStrings.get(context, R.string.pairing_text))
            .setOngoing(true)
            .addAction(action)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
    }

    fun dismiss(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
    }

    /** Show the actual pairing result; a new attempt starts from the App's existing flow. */
    internal fun showResult(context: Context, result: Map<String, Any?>) {
        val text = if (result["ok"] == true) {
            AppStrings.get(context, R.string.pairing_complete)
        } else {
            val reason = result["reason"] as? String ?: AppStrings.get(context, R.string.pairing_failed)
            AppStrings.get(context, R.string.pairing_result_failure, reason)
        }
        val open = PendingIntent.getActivity(
            context, NOTIFICATION_ID,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        context.getSystemService(NotificationManager::class.java).notify(
            NOTIFICATION_ID,
            Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_dsh)
                .setContentTitle(AppStrings.get(context, R.string.pairing_title))
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setContentIntent(open)
                .setOnlyAlertOnce(true)
                .setAutoCancel(true)
                .build(),
        )
    }

    /** The code the person typed, or null. */
    fun codeFrom(intent: Intent): String? =
        RemoteInput.getResultsFromIntent(intent)?.getCharSequence(CODE_KEY)?.toString()?.trim()

    /** Registered in the manifest; forwards the typed code to the control object. */
    class Receiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val code = codeFrom(intent) ?: return
            Log.i("DshAdbPairing", "notification: received")
            // Pairing opens a socket, which the main thread may not (NetworkOnMainThreadException).
            BackgroundControl.get(context.applicationContext).adbPairFromNotification(code)
        }
    }
}
