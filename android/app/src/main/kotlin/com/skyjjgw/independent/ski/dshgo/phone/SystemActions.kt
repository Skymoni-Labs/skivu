package com.skyjjgw.independent.ski.dshgo.phone

import com.skyjjgw.independent.ski.dshgo.i18n.AppStrings
import android.app.Activity
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.Settings
import com.skyjjgw.independent.ski.MainActivity
import com.skyjjgw.independent.ski.R
import com.skyjjgw.independent.ski.dshgo.phone.background.Reasons
import java.util.concurrent.CountDownLatch
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Whether one of this app's activities is resumed (the clipboard and background-start rules care). */
object AppVisibility : Application.ActivityLifecycleCallbacks {
    private val resumed = AtomicInteger()
    private val resumedActivities = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Activity, Boolean>())
    @Volatile private var registered = false

    val visible: Boolean get() = resumed.get() > 0
    fun isResumed(activity: Activity): Boolean = synchronized(resumedActivities) { activity in resumedActivities }

    fun register(app: Application) {
        if (registered) return
        registered = true
        app.registerActivityLifecycleCallbacks(this)
    }

    override fun onActivityResumed(activity: Activity) {
        synchronized(resumedActivities) { if (resumedActivities.add(activity)) resumed.incrementAndGet() }
    }

    override fun onActivityPaused(activity: Activity) {
        synchronized(resumedActivities) { if (resumedActivities.remove(activity)) resumed.decrementAndGet() }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = onActivityPaused(activity)
}

/** System tools on Android: no permission beyond what the app already has, plus SET_ALARM (normal). */
class SystemActions(private val app: Context) : SystemApi {
    private val pm: PackageManager = app.packageManager
    private val main = Handler(Looper.getMainLooper())
    private val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val ids = AtomicInteger(4100)
    @Volatile private var appsCache: Pair<Long, List<AppEntry>>? = null

    override fun apps(): List<AppEntry> {
        appsCache?.let { (at, list) -> if (System.currentTimeMillis() - at < 30_000) return list }
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val list = pm.queryIntentActivities(launcher, 0)
            .mapNotNull { ri ->
                val pkg = ri.activityInfo?.packageName ?: return@mapNotNull null
                AppEntry(ri.loadLabel(pm).toString().trim().orEmpty().ifEmpty { pkg },
                    PhoneAppIdentity(pkg, ri.activityInfo.applicationInfo.uid))
            }
            .distinctBy { it.packageName }
        appsCache = System.currentTimeMillis() to list
        return list
    }

    override fun isInstalled(pkg: String): Boolean = try {
        pm.getPackageInfo(pkg, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    private class NativeLaunch(
        override val target: SystemTarget,
        val intent: Intent,
        val filter: Intent,
        val flags: Int,
        val handler: SystemHandler?,
        val noticeWhat: String,
    ) : SystemLaunch

    private fun handler(info: ActivityInfo?): SystemHandler? {
        if (info == null || !info.exported) return null
        val application = info.applicationInfo ?: return null
        val pkg = info.packageName ?: return null
        val component = info.name ?: return null
        if (!application.enabled || application.packageName != pkg) return null
        val enabled = SystemHandlers.componentEnabled(info.enabled) {
            pm.getComponentEnabledSetting(ComponentName(pkg, component))
        }
        if (!enabled) return null
        return SystemHandler(pkg, component, application.uid)
    }

    private fun candidates(intent: Intent, flags: Int): List<SystemHandler>? {
        val out = ArrayList<SystemHandler>()
        for (result in pm.queryIntentActivities(intent, flags)) {
            out += handler(result.activityInfo) ?: return null
        }
        return out
    }

    /** Retain the original query Intent for PM checks; only the prepared Intent is submitted. */
    private fun prepare(intent: Intent, noticeWhat: String, flags: Int = PackageManager.MATCH_DEFAULT_ONLY,
                        allowChoice: Boolean = true, forceChoice: Boolean = false): Either<String, SystemLaunch> = try {
        val filter = Intent(intent)
        val candidates = candidates(filter, flags)
        if (candidates == null) unavailable()
        else if (forceChoice) {
            if (!SystemHandlers.valid(candidates, filter.`package`)) unavailable() else Either.Right(NativeLaunch(SystemTarget.UserChoice,
                Intent.createChooser(intent, AppStrings.get(app, R.string.phone_share_chooser))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), filter, flags, null, noticeWhat))
        } else {
            val info = pm.resolveActivity(filter, flags)?.activityInfo
            when (val resolution = SystemHandlers.resolve(candidates, handler(info), intent.`package`, allowChoice)) {
                null -> unavailable()
                is SystemResolution.Known -> {
                    val h = resolution.handler
                    val label = info!!.loadLabel(pm).toString().trim().ifEmpty { h.packageName }
                    val target = SystemTarget.Known(AppEntry(label, PhoneAppIdentity(h.packageName, h.uid)))
                    intent.component = ComponentName(h.packageName, h.component)
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    Either.Right(NativeLaunch(target, intent, filter, flags, h, noticeWhat))
                }
                SystemResolution.Choice -> Either.Right(NativeLaunch(SystemTarget.UserChoice,
                    Intent.createChooser(intent, AppStrings.get(app, R.string.phone_system_choose_handler))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), filter, flags, null, noticeWhat))
            }
        }
    } catch (_: Exception) { unavailable() }

    private fun unavailable(): Either.Left<String> = Either.Left(Reasons.of("targetIdentityUnavailable"))

    override fun prepareLaunch(app: AppEntry): Either<String, SystemLaunch> = try {
        val intent = pm.getLaunchIntentForPackage(app.packageName)
        if (intent == null) unavailable() else {
            // Launcher Intents need not match CATEGORY_DEFAULT. Keep the PM's exact launcher.
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            val plan = prepare(intent, AppStrings.get(this.app, R.string.phone_notice_open_app, app.label),
                flags = 0, allowChoice = false)
            when (plan) {
                is Either.Left -> plan
                is Either.Right -> if ((plan.value.target as SystemTarget.Known).app.packageName == app.packageName) plan else unavailable()
            }
        }
    } catch (_: Exception) { unavailable() }

    override fun prepareUrl(url: String): Either<String, SystemLaunch> {
        return prepare(Intent(Intent.ACTION_VIEW, Uri.parse(url))
            .addCategory(Intent.CATEGORY_BROWSABLE).apply { selector = null },
            AppStrings.get(app, R.string.phone_notice_open_url))
    }

    override fun prepareIntent(spec: IntentSpec, selectedApp: AppEntry?): Either<String, SystemLaunch> = try {
        when (spec) {
            is IntentSpec.Alarm -> {
                val intent = Intent(AlarmClock.ACTION_SET_ALARM)
                    .putExtra(AlarmClock.EXTRA_HOUR, spec.hour)
                    .putExtra(AlarmClock.EXTRA_MINUTES, spec.minute)
                spec.message?.let { intent.putExtra(AlarmClock.EXTRA_MESSAGE, it) }
                if (spec.days.isNotEmpty()) intent.putExtra(AlarmClock.EXTRA_DAYS, ArrayList(spec.days.map { it % 7 + 1 }))
                prepare(intent, AppStrings.get(app, R.string.phone_notice_alarm))
            }
            is IntentSpec.Timer -> {
                val intent = Intent(AlarmClock.ACTION_SET_TIMER)
                    .putExtra(AlarmClock.EXTRA_LENGTH, spec.seconds).putExtra(AlarmClock.EXTRA_SKIP_UI, false)
                spec.message?.let { intent.putExtra(AlarmClock.EXTRA_MESSAGE, it) }
                prepare(intent, AppStrings.get(app, R.string.phone_notice_timer))
            }
            is IntentSpec.Calendar -> {
                val intent = Intent(Intent.ACTION_INSERT).setData(CalendarContract.Events.CONTENT_URI)
                    .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, spec.beginMs)
                    .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, spec.endMs)
                    .putExtra(CalendarContract.EXTRA_EVENT_ALL_DAY, spec.allDay)
                    .putExtra(CalendarContract.Events.TITLE, spec.title)
                spec.location?.let { intent.putExtra(CalendarContract.Events.EVENT_LOCATION, it) }
                spec.description?.let { intent.putExtra(CalendarContract.Events.DESCRIPTION, it) }
                prepare(intent, AppStrings.get(app, R.string.phone_notice_calendar))
            }
            is IntentSpec.Dial -> prepare(Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode(spec.number))),
                AppStrings.get(app, R.string.phone_notice_dial))
            is IntentSpec.SmsDraft -> prepare(Intent(Intent.ACTION_SENDTO,
                Uri.parse("smsto:" + (spec.number?.let { Uri.encode(it) } ?: ""))).putExtra("sms_body", spec.text),
                AppStrings.get(app, R.string.phone_notice_sms))
            is IntentSpec.Share -> {
                val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, spec.text)
                if (selectedApp != null) {
                    intent.setPackage(selectedApp.packageName)
                    prepare(intent, AppStrings.get(app, R.string.phone_notice_share_to, selectedApp.label))
                } else prepare(intent, AppStrings.get(app, R.string.phone_notice_share), forceChoice = true)
            }
            is IntentSpec.Navigate -> navigate(spec)
            is IntentSpec.Settings -> settings(spec, selectedApp)
        }
    } catch (_: Exception) { unavailable() }

    /** Fallback is preparation only, before any safety decision or platform start. */
    private fun navigate(spec: IntentSpec.Navigate): Either<String, SystemLaunch> {
        val choices = when (spec.map) {
            "amap" -> listOf(NavUris.amap(spec) to NavUris.AMAP)
            "baidu" -> listOf(NavUris.baidu(spec) to NavUris.BAIDU)
            else -> listOf(NavUris.amap(spec) to NavUris.AMAP, NavUris.baidu(spec) to NavUris.BAIDU)
        }
        for ((uri, pkg) in choices) {
            if (!isInstalled(pkg)) continue
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri)).setPackage(pkg)
            if (pm.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) == null) continue
            return prepare(intent, AppStrings.get(app, R.string.phone_notice_navigate))
        }
        return prepare(Intent(Intent.ACTION_VIEW, Uri.parse(NavUris.geo(spec))),
            AppStrings.get(app, R.string.phone_notice_navigate))
    }

    private fun settings(spec: IntentSpec.Settings, selectedApp: AppEntry?): Either<String, SystemLaunch> {
        val action = when (spec.page) {
            "home" -> Settings.ACTION_SETTINGS
            "wifi" -> Settings.ACTION_WIFI_SETTINGS
            "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS
            "mobile_network" -> Settings.ACTION_WIRELESS_SETTINGS
            "airplane" -> Settings.ACTION_AIRPLANE_MODE_SETTINGS
            "display" -> Settings.ACTION_DISPLAY_SETTINGS
            "sound" -> Settings.ACTION_SOUND_SETTINGS
            "battery" -> Intent.ACTION_POWER_USAGE_SUMMARY
            "location" -> Settings.ACTION_LOCATION_SOURCE_SETTINGS
            "date" -> Settings.ACTION_DATE_SETTINGS
            "language" -> Settings.ACTION_LOCALE_SETTINGS
            "storage" -> Settings.ACTION_INTERNAL_STORAGE_SETTINGS
            "nfc" -> Settings.ACTION_NFC_SETTINGS
            "app_notifications" -> Settings.ACTION_APP_NOTIFICATION_SETTINGS
            else -> return unavailable()
        }
        var intent = Intent(action)
        if (spec.page == "app_notifications") {
            if (selectedApp == null) return unavailable()
            intent.putExtra(Settings.EXTRA_APP_PACKAGE, selectedApp.packageName)
        }
        if (pm.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) == null) {
            if (spec.page == "battery") intent = Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
            if (pm.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) == null) intent = Intent(Settings.ACTION_SETTINGS)
        }
        return prepare(intent, AppStrings.get(app, R.string.phone_notice_settings))
    }

    override fun launch(plan: SystemLaunch, dispatch: PhoneTasks.SystemDispatch): SysResult {
        val native = plan as? NativeLaunch ?: return SysResult(false, Reasons.of("targetIdentityUnavailable"))
        val unchanged = try {
            val candidates = candidates(native.filter, native.flags)
            val h = native.handler
            candidates != null && SystemHandlers.valid(candidates, native.filter.`package`) &&
                (h == null || (h in candidates &&
                    handler(pm.getActivityInfo(ComponentName(h.packageName, h.component), 0)) == h))
        } catch (_: Exception) { false }
        if (!unchanged) return SysResult(false, Reasons.of("targetIdentityChanged"))
        // PM checks do not hold a task lock. Stop can revoke up to the existing commit point.
        if (!dispatch.commitStart()) throw InterruptedException(PhoneTasks.STOPPED_MESSAGE)
        try {
            app.startActivity(native.intent)
        } catch (_: RuntimeException) {
            return SysResult(false, AppStrings.get(app, R.string.phone_system_start_rejected, native.noticeWhat), native.target)
        }
        val attempted = AppStrings.get(app, R.string.phone_system_start_attempted, native.noticeWhat)
        val exempt = AppVisibility.visible || PhoneRegistry.mainDriver != null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
        if (exempt) return SysResult(true, attempted, native.target)
        // A separate commitment: a stop during startActivity must not start a new review.
        // The Core uses its existing task-owned handoff; this never replays the original Intent.
        if (!dispatch.commitNotice()) {
            Thread.currentThread().interrupt()
            return SysResult(true, attempted, native.target)
        }
        return SysResult(true, attempted, native.target, requiresReview = true)
    }

    override fun notify(title: String, text: String): SysResult {
        if (!nm.areNotificationsEnabled()) {
            // l10n:keep agent tool result
            return SysResult(false, "DSH 没有通知权限，通知发不出去。请用户在系统设置里允许 DSH 发通知。")
        }
        ensureChannel(CHANNEL_NOTIFY, AppStrings.get(app, R.string.phone_reminder_channel), NotificationManager.IMPORTANCE_DEFAULT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            nm.getNotificationChannel(CHANNEL_NOTIFY)?.importance == NotificationManager.IMPORTANCE_NONE) {
            // l10n:keep agent tool result
            return SysResult(false, "DSH 的「${AppStrings.get(app, R.string.phone_reminder_channel)}」通知渠道已关闭。请用户在系统设置中开启该渠道后再试。")
        }
        val open = PendingIntent.getActivity(
            app, 0, Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = builder(CHANNEL_NOTIFY)
            .setContentTitle(title.take(100))
            .setContentText(text.take(500))
            .setStyle(Notification.BigTextStyle().bigText(text.take(2000)))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        nm.notify(TAG, ids.incrementAndGet(), n)
        // l10n:keep agent tool result
        return SysResult(true, "已发通知「${SafetyRules.quoteText(title, 30)}」。")
    }

    override fun clipboardSet(text: String): SysResult {
        // l10n:keep agent tool result
        if (text.length > 100_000) return SysResult(false, "内容太长（超过 10 万字）。")
        val ok = onMain {
            val cm = app.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("DSH", text))
            true
        } == true
        // l10n:keep agent tool result
        return if (ok) SysResult(true, "已写入剪贴板（${text.length} 字）。") else SysResult(false, "写剪贴板失败。")
    }

    override fun clipboardGet(): SysResult {
        val visible = AppVisibility.visible
        val text = onMain {
            val cm = app.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(app)?.toString()
        }
        if (text.isNullOrEmpty()) {
            return if (visible || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                // l10n:keep agent tool result
                SysResult(true, "剪贴板是空的。")
            } else {
                // l10n:keep agent tool result
                SysResult(false, "读不到剪贴板：系统只允许前台应用读，DSH 不在前台。请用户切回 DSH 再说，或直接把内容发给你。")
            }
        }
        val limit = 20_000
        // Keep a complete surrogate pair out of the preview when it crosses the limit.
        val end = if (text.length > limit && text[limit - 1].isHighSurrogate() && text[limit].isLowSurrogate()) limit - 1 else limit
        // l10n:keep agent tool result
        val shown = if (text.length > limit) text.take(end) + "\n…（后面还有 ${text.length - end} 字）" else text
        // l10n:keep agent tool result
        return SysResult(true, "剪贴板内容：\n$shown")
    }

    private fun <T> onMain(block: () -> T): T? {
        if (Looper.myLooper() == Looper.getMainLooper()) return runCatching(block).getOrNull()
        var out: T? = null
        val done = CountDownLatch(1)
        val task = FutureTask<Unit> {
            out = runCatching(block).getOrNull()
            done.countDown()
        }
        main.post(task)
        try {
            if (!done.await(3, TimeUnit.SECONDS)) {
                task.cancel(false) // Revoke queued work; an operation already running is not interrupted.
            }
        } catch (e: InterruptedException) {
            task.cancel(false)
            throw e
        }
        return out
    }

    private fun ensureChannel(id: String, name: String, importance: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        nm.createNotificationChannel(NotificationChannel(id, name, importance))
    }

    private fun builder(channel: String): Notification.Builder {
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(app, channel)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(app)
        }
        return b.setSmallIcon(R.drawable.ic_stat_dsh)
    }

    companion object {
        private const val TAG = "dsh-phone-sys"
        const val CHANNEL_NOTIFY = "dsh-phone-notify"
    }
}
