package com.skyjjgw.independent.ski.dshgo.phone.background

/** Fixed private relation; model arguments never choose a native selector or register an App. */
internal object BackgroundNavigationProtocol {
    const val DESCRIPTOR = "markor-navigation-v1"
    const val PACKAGE = "net.gsantner.markor"
    val tabs = setOf("nav_notebook", "nav_todo", "nav_quicknote", "nav_more")
    data class Installation(val version: Long, val updated: Long, val signers: String)
    data class Expectation(val window: Int, val selected: String, val label: String, val readOnly: Boolean)
    data class Request(val execute: Boolean, val app: Installation, val expected: Expectation?)
    data class Facts(val window: Int, val selected: String, val label: String, val clickable: Boolean,
        val attempted: Boolean, val post: String)
    fun supported(value: Any?) = value is Int && value == 1
    private val common = setOf(Proto.OP, Proto.OWNER, Proto.PKG, Proto.TARGET_IDENTITY_VERSION, Proto.TARGET_UID,
        Proto.REPLAY_NAVIGATION, "mode", "descriptorId", "option", "appVersion", "appUpdated", "appSigningDigest")
    private val expectation = setOf("expectedWindowId", "expectedSelected", "expectedTargetLabel", "readOnly")
    fun request(keys: Set<String>, get: (String) -> Any?): Request? {
        val execute = when (get("mode")) { "inspect" -> false; "execute" -> true; else -> return null }
        if (keys != common + (if (execute) expectation else emptySet()) || get(Proto.OP) != Proto.OP_REPLAY_NAVIGATION ||
            !supported(get(Proto.REPLAY_NAVIGATION)) || !supported(get(Proto.TARGET_IDENTITY_VERSION)) ||
            get(Proto.PKG) != PACKAGE || (get(Proto.OWNER) as? String).isNullOrEmpty() ||
            (get(Proto.TARGET_UID) as? Int)?.let { it >= 0 } != true ||
            get("descriptorId") != DESCRIPTOR || get("option") != "more") return null
        val app = installation(get) ?: return null
        val expected = if (!execute) null else {
            val window = (get("expectedWindowId") as? Int)?.takeIf { it >= 0 } ?: return null
            val selected = (get("expectedSelected") as? String)?.takeIf { it in tabs } ?: return null
            val label = label(get("expectedTargetLabel")) ?: return null
            val readOnly = get("readOnly") as? Boolean ?: return null
            if (readOnly != (selected == "nav_more")) return null
            Expectation(window, selected, label, readOnly)
        }
        return Request(execute, app, expected)
    }
    fun installation(get: (String) -> Any?): Installation? {
        val version = (get("appVersion") as? Long)?.takeIf { it >= 0 } ?: return null
        val updated = (get("appUpdated") as? Long)?.takeIf { it >= 0 } ?: return null
        val signers = (get("appSigningDigest") as? String)?.takeIf { it.matches(Regex("[a-f0-9]{64}")) } ?: return null
        return Installation(version, updated, signers)
    }
    fun facts(keys: Set<String>, get: (String) -> Any?, request: Request): Facts? {
        if (keys != setOf("version", "mode", "windowId", "selected", "targetLabel", "targetClickable", "attempted", "post",
                "appVersion", "appUpdated", "appSigningDigest") || !supported(get("version")) ||
            get("mode") != (if (request.execute) "execute" else "inspect")) return null
        if (installation(get) != request.app) return null
        val window = (get("windowId") as? Int)?.takeIf { it >= 0 } ?: return null
        val selected = (get("selected") as? String)?.takeIf { it in tabs } ?: return null
        val label = label(get("targetLabel")) ?: return null
        val clickable = get("targetClickable") as? Boolean ?: return null
        val attempted = get("attempted") as? Boolean ?: return null
        val post = (get("post") as? String)?.takeIf { it in setOf("unknown", "different", "satisfied") } ?: return null
        if (!request.execute && (attempted || post != "unknown")) return null
        if (request.execute && (post == "unknown" || (post == "satisfied") != (selected == "nav_more"))) return null
        if (request.execute && !attempted && post == "different") return null
        request.expected?.let {
            if (window != it.window || label != it.label || it.readOnly && (attempted || post != "satisfied")) return null
        }
        return Facts(window, selected, label, clickable, attempted, post)
    }
    private fun label(value: Any?): String? = (value as? String)?.takeIf {
        it.isNotBlank() && it.toByteArray(Charsets.UTF_8).size <= 1024
    }
}
