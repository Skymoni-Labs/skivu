package com.skyjjgw.independent.ski.dshgo.phone.a11y

/** Observation identity is separate from an action target's stable fingerprint. */
internal class ScreenObservation(
    val packageName: String?,
    windows: List<UiWindow>,
    val screen: Box,
    val keyboardShown: Boolean?,
    val unavailable: Boolean,
    val incomplete: Boolean,
    val elements: List<String>,
) {
    // A masked screenshot does not authorize gestures on a password/code page, even after approval.
    val hasSecretFields = secretFieldBounds(windows).isNotEmpty()
    private data class Window(val id: Int, val kind: WindowKind, val packageName: String?, val title: String?, val bounds: Box)
    private val windows = windows.map { Window(it.id, it.kind, it.packageName, it.title, it.bounds) }

    fun comparableTo(previous: ScreenObservation): Boolean =
        !unavailable && !previous.unavailable && !incomplete && !previous.incomplete &&
            elements.isNotEmpty() && previous.elements.isNotEmpty()

    fun sameContext(previous: ScreenObservation): Boolean =
        packageName != null && packageName == previous.packageName && windows.isNotEmpty() &&
            windows == previous.windows && screen == previous.screen

    fun changedFrom(previous: ScreenObservation): Boolean =
        !sameContext(previous) || elements != previous.elements || keyboardShown != previous.keyboardShown

    fun keyboardChange(previous: ScreenObservation): String? {
        val sameWindows = packageName != null && packageName == previous.packageName &&
            windows.map { it.id to it.packageName } == previous.windows.map { it.id to it.packageName }
        if (!sameWindows) return null
        return when {
            previous.keyboardShown == true && keyboardShown == false -> ScreenVerdict.KEYBOARD_HIDDEN
            previous.keyboardShown == false && keyboardShown == true -> ScreenVerdict.KEYBOARD_SHOWN
            else -> null
        }
    }

    /** A canvas may have no numbered elements, but still has a usable, stable image viewport. */
    fun reusableCoordinates(previous: ScreenObservation): Boolean =
        !unavailable && !previous.unavailable && !incomplete && !previous.incomplete &&
            !hasSecretFields && !previous.hasSecretFields &&
            keyboardShown != null && keyboardShown == previous.keyboardShown &&
            sameContext(previous) && elements == previous.elements
}
