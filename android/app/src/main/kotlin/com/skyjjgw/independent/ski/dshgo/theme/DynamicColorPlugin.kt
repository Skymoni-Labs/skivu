package com.skyjjgw.independent.ski.dshgo.theme

import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Wallpaper colours for 设置 › 外观 › 跟随壁纸: MethodChannel `dsh/dynamic_color`
 * (see lib/state/appearance_state.dart).
 *
 * `palette` answers the system's Monet tones (`system_accent1_*`, `system_neutral1_500`) on
 * Android 12 and later, null before that. The app only takes the hue and chroma and builds its
 * own quiet palette from them, so no Material dependency is needed.
 */
class DynamicColorPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var methods: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "palette" -> result.success(palette())
            else -> result.notImplemented()
        }
    }

    private fun palette(): Map<String, Long>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        return runCatching {
            fun tone(id: Int): Long = context.getColor(id).toLong() and 0xFFFFFFFFL
            mapOf(
                "accent" to tone(android.R.color.system_accent1_500),
                "accentLight" to tone(android.R.color.system_accent1_600),
                "accentDark" to tone(android.R.color.system_accent1_200),
                "neutral" to tone(android.R.color.system_neutral1_500),
            )
        }.getOrNull()
    }

    companion object {
        private const val CHANNEL = "dsh/dynamic_color"
    }
}

/**
 * The palette's light accent, for notification colour: the Dart side keeps it in
 * SharedPreferences (`appearance.notify_color`) whenever the palette changes.
 */
object ThemeAccent {
    private const val PREFS = "FlutterSharedPreferences"
    private const val KEY = "flutter.appearance.notify_color"

    /** 雾蓝, until the app has written one. */
    private const val DEFAULT = 0xFF4B67B4.toInt()

    fun notificationColor(context: Context): Int = runCatching {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.contains(KEY)) prefs.getLong(KEY, 0L).toInt() else DEFAULT
    }.getOrDefault(DEFAULT)
}
