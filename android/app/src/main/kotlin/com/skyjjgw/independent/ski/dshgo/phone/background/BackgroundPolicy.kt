package com.skyjjgw.independent.ski.dshgo.phone.background

// Pure decision logic for 不打扰模式: display sizing, the hard-gate on which
// screens/windows must be handed back, and the sensitive-action test. No Android types,
// so it is unit-tested on the JVM and shared by the engine and the driver.

object BackgroundPolicy {
    /** User-selected viewport, fixed for one BackgroundDisplay instance, not a logical task. */
    enum class Viewport(val preset: String, val width: Int, val height: Int) {
        PORTRAIT("portrait", 720, 1600), LANDSCAPE("landscape", 1600, 720);
        companion object {
            fun parse(value: Any?): Viewport? = entries.firstOrNull { it.preset == value }
        }
    }

    /** Lowest Android the trusted, own-focus virtual display needs (OWN_FOCUS is 14+). */
    const val MIN_SDK = 34

    enum class Unready { OFF, ANDROID, SWITCHING, CHANNEL, UNKNOWN_MODE }

    /**
     * Why the selected mode is not ready, or null. The whole admission model: a mode other than
     * off, Android 14+, no channel switch in progress, and the channel's own reason (not installed,
     * not running, not authorized, not connected). Self-check results are not an input.
     */
    fun unready(mode: String, androidOk: Boolean, switching: Boolean, channelReason: String?): Unready? = when {
        mode == "off" -> Unready.OFF
        mode !in setOf("shizuku", "sui", "root", "adb") -> Unready.UNKNOWN_MODE
        !androidOk -> Unready.ANDROID
        switching -> Unready.SWITCHING
        channelReason != null -> Unready.CHANNEL
        else -> null
    }

    data class Capacity(val effective: Int, val reason: String?)

    /**
     * Background slots a new task may take now. [busy] is real momentary occupancy only (a channel
     * switch, a self-check run, a screen-off interruption, a keep restore). [peerLimit] is what the
     * live link carries, 0 when there is none.
     */
    fun capacity(mode: String, androidOk: Boolean, busy: Boolean, peerLimit: Int, configured: Int): Capacity = when {
        mode == "off" -> Capacity(0, "off")
        !androidOk -> Capacity(0, "unsupported")
        busy -> Capacity(0, "busy")
        peerLimit <= 0 -> Capacity(0, "connectionRequired")
        peerLimit < configured -> Capacity(peerLimit, "transportSerial")
        else -> Capacity(configured, null)
    }

    /**
     * Legacy request sizing, retaining its portrait-normalized aspect semantics.
     * Fixed viewport presets use Viewport instead; reversing these aspect arguments is not landscape.
     */
    fun displaySize(shortSide: Int, aspectW: Int, aspectH: Int): IntArray {
        val short = (shortSide / 2 * 2).coerceIn(360, 1080)
        val w = minOf(aspectW, aspectH).coerceAtLeast(1)
        val h = maxOf(aspectW, aspectH).coerceAtLeast(1)
        var long = (short.toLong() * h / w).toInt()
        long = (long / 2 * 2).coerceIn(short, short * 3)
        return intArrayOf(short, long)
    }

    /** True when this window must be handed back to the user rather than driven. */
    fun mustHandBack(secure: Boolean, locked: Boolean): Boolean = secure || locked

    /** Whether an action on an element needs confirmation, from its flags + label. */
    fun needsConfirm(flags: Int, label: String, submit: Boolean, firstInApp: Boolean): Boolean {
        if (firstInApp) return true
        if (submit) return true
        if (flags and Proto.FLAG_SENSITIVE != 0) return true
        return BackgroundTree.isSensitiveLabel(label)
    }
}
