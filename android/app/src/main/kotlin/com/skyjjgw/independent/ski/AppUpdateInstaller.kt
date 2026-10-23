package com.skyjjgw.independent.ski

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import android.widget.Toast
import java.io.File

/** Stage verified bytes in a new system session, not a reusable file VIEW URI. */
object AppUpdateInstaller {
    private const val PREFS = "skivu_update_install"
    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    fun message(context: Context) = prefs(context).getString("message", "").orEmpty()

    fun submit(activity: Activity, file: File, version: Long) {
        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(activity.packageName)
            setSize(file.length())
            if (Build.VERSION.SDK_INT >= 26) setInstallReason(PackageManager.INSTALL_REASON_USER)
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
            if (Build.VERSION.SDK_INT >= 33) setPackageSource(PackageInstaller.PACKAGE_SOURCE_DOWNLOADED_FILE)
        }
        val id = installer.createSession(params)
        prefs(activity).edit().putInt("session", id).putLong("version", version).putString("message", "").apply()
        try {
            installer.openSession(id).use { session ->
                session.openWrite("base.apk", 0, file.length()).use { output ->
                    file.inputStream().use { input -> input.copyTo(output) }
                    session.fsync(output)
                }
                val callback = Intent(activity, AppUpdateInstallReceiver::class.java)
                    .setAction("${activity.packageName}.UPDATE_INSTALL.$id")
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                session.commit(PendingIntent.getBroadcast(activity, id, callback, flags).intentSender)
            }
            Log.i("SkivuUpdate", "Submitted session $id for version $version")
        } catch (error: Exception) {
            runCatching { installer.abandonSession(id) }
            prefs(activity).edit().putString("message", "系统未能准备更新，请重新下载后重试。").apply()
            throw error
        }
    }

    @Suppress("DEPRECATION")
    fun receive(context: Context, intent: Intent) {
        val id = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        val state = prefs(context)
        if (id < 0 || id != state.getInt("session", -1)) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        Log.i("SkivuUpdate", "Session $id status $status")
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            val confirm = if (Build.VERSION.SDK_INT >= 33)
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            else intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
            try {
                requireNotNull(confirm)
                context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (_: Exception) {
                state.edit().putString("message", "系统安装页面未能打开，请返回更新页重试。").apply()
                Toast.makeText(context, "系统安装页面未能打开，请返回更新页重试。", Toast.LENGTH_LONG).show()
            }
            return
        }
        val text = when (status) {
            PackageInstaller.STATUS_SUCCESS -> "更新已安装"
            PackageInstaller.STATUS_FAILURE_ABORTED -> "已取消安装，可再次点击安装更新。"
            PackageInstaller.STATUS_FAILURE_STORAGE -> "手机存储空间不足，请清理后重试。"
            PackageInstaller.STATUS_FAILURE_BLOCKED -> "系统未允许安装，请检查应用安装权限后重试。"
            PackageInstaller.STATUS_FAILURE_CONFLICT -> "安装版本或签名冲突，请重新下载官方更新包。"
            else -> "系统未能完成更新，请重新下载后重试。"
        }
        state.edit().putString("message", text).apply()
        if (status != PackageInstaller.STATUS_SUCCESS) Toast.makeText(context, text, Toast.LENGTH_LONG).show()
    }
}

class AppUpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = AppUpdateInstaller.receive(context, intent)
}
