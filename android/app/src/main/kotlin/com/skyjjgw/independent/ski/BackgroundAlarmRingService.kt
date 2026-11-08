package com.skyjjgw.independent.ski

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.Settings

/** An audible alarm with notification actions; never opens an Activity itself. */
class BackgroundAlarmRingService : Service() {
    companion object {
        @Volatile private var instance: BackgroundAlarmRingService? = null
        fun stopAlarm(id: String) { instance?.let { service -> service.main.post { if (service.alarmId == id) service.finishRing("stopped") } } }
    }
    private val main = Handler(Looper.getMainLooper())
    private var alarmId = ""
    private var occurrence = -1L
    private var player: MediaPlayer? = null
    private var fallback: ToneGenerator? = null
    private var wake: PowerManager.WakeLock? = null
    private var sounding = false
    private var vibrator: Vibrator? = null
    override fun onCreate() { super.onCreate(); instance = this }
    override fun onBind(intent: Intent?): IBinder? = null
    private fun mark(state: String, onlyPending: Boolean = false) = BackgroundAlarms(this).use { it.markRing(alarmId, occurrence, state, onlyPending) }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra("id") ?: run { stopSelf(); return START_NOT_STICKY }
        val due = intent.getLongExtra("occurrence", -1)
        if (intent.action == "stop" || intent.action == "snooze") {
            if (id == alarmId && due == occurrence) {
                if (intent.action == "snooze") {
                    try { BackgroundAlarms(this).use { it.snooze(id, due) } } catch (_: Exception) { /* existing ring stays available to stop */ }
                } else finishRing("stopped")
            }
            if (alarmId.isEmpty()) stopSelf()
            return START_NOT_STICKY
        }
        if (id == alarmId && due == occurrence && sounding) return START_NOT_STICKY
        if (!BackgroundAlarms(this).use { it.ready() }) {
            BackgroundAlarms(this).use { it.markRing(id, due, "permission_lost", true) }
            if (!sounding) stopSelf()
            return START_NOT_STICKY
        }
        val valid = try { BackgroundAlarms(this).use { it.markRing(id, due, "starting", true) } } catch (_: Exception) { false }
        if (!valid) { if (!sounding) stopSelf(); return START_NOT_STICKY }
        if (alarmId.isNotEmpty()) { mark("superseded"); releaseAudio() }
        alarmId = id; occurrence = due
        try {
            BackgroundAlarms(this).use { it.ensureChannel() }
            fun action(name: String, code: Int): PendingIntent {
                val command = Intent(this, BackgroundAlarmRingService::class.java).setAction(name)
                    .putExtra("id", id).putExtra("occurrence", due)
                return PendingIntent.getService(this, code, command, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            }
            val open = PendingIntent.getActivity(this, 9303, Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, BackgroundAlarms.CHANNEL) else Notification.Builder(this)
            val label = intent.getStringExtra("label").orEmpty().ifEmpty { "小云闹钟" }
            val notification = builder.setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setContentTitle(label).setContentText("时间到了 · 可停止或稍后5分钟提醒")
                .setCategory(Notification.CATEGORY_ALARM).setOngoing(true).setContentIntent(open)
                .addAction(Notification.Action.Builder(null, "停止", action("stop", 9304)).build())
                .addAction(Notification.Action.Builder(null, "稍后5分钟", action("snooze", 9305)).build()).build()
            if (Build.VERSION.SDK_INT >= 34) startForeground(BackgroundAlarms.RING_NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
            else startForeground(BackgroundAlarms.RING_NOTIFICATION, notification)
            wake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:alarm").apply { acquire(125000) }
            sounding = true
            if (intent.getBooleanExtra("vibrate", true)) {
                @Suppress("DEPRECATION")
                val motor = getSystemService(VIBRATOR_SERVICE) as? Vibrator
                vibrator = motor
                if (Build.VERSION.SDK_INT >= 26) motor?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 350, 300, 350, 1000), 0))
                else { @Suppress("DEPRECATION") motor?.vibrate(longArrayOf(0, 350, 300, 350, 1000), 0) }
            }
            play()
            main.postDelayed({ if (id == alarmId && due == occurrence) finishRing("timeout") }, 120000)
        } catch (_: Exception) { finishRing("playback_failed") }
        return START_NOT_STICKY
    }
    private fun play() {
        try {
            val media = MediaPlayer()
            player = media
            media.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            media.setDataSource(this, Settings.System.DEFAULT_ALARM_ALERT_URI)
            media.isLooping = true
            media.setOnPreparedListener { if (sounding && player === it) { it.start(); mark("playing") } }
            media.setOnErrorListener { _, _, _ -> startFallback(); true }
            media.prepareAsync()
        } catch (_: Exception) { startFallback() }
    }
    private fun startFallback() {
        if (!sounding || fallback != null) return
        try {
            player?.release(); player = null
            val tone = ToneGenerator(AudioManager.STREAM_ALARM, 80)
            fallback = tone
            val pulse = object : Runnable {
                override fun run() {
                    if (sounding && fallback === tone) { tone.startTone(ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD, 700); main.postDelayed(this, 1600) }
                }
            }
            main.post(pulse); mark("playing_fallback")
        } catch (_: Exception) { finishRing("playback_failed") }
    }
    private fun releaseAudio() {
        sounding = false; main.removeCallbacksAndMessages(null)
        try { player?.release() } catch (_: Exception) {}; player = null
        try { fallback?.release() } catch (_: Exception) {}; fallback = null
        try { vibrator?.cancel() } catch (_: Exception) {}; vibrator = null
        wake?.let { if (it.isHeld) it.release() }; wake = null
    }
    private fun finishRing(state: String) { if (alarmId.isNotEmpty()) mark(state); releaseAudio(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
    override fun onDestroy() {
        if (sounding) mark("interrupted")
        releaseAudio(); if (instance === this) instance = null
        super.onDestroy()
    }
}
