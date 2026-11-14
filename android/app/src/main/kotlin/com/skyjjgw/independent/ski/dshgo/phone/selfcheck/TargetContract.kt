package com.skyjjgw.independent.ski.dshgo.phone.selfcheck

/** Fixed, inert local target shared by the Activity and the privileged tree verifier. */
internal object TargetContract {
    const val ACTIVITY_CLASS = "com.skyjjgw.independent.ski.dshgo.phone.selfcheck.PhoneSelfCheckTargetActivity"
    const val MARKER_ID = "phone_selfcheck_target_marker"
    const val COUNTER_ID = "phone_selfcheck_target_counter"
    const val BUTTON_ID = "phone_selfcheck_target_button"
    const val EDIT_ID = "phone_selfcheck_target_edit"
    const val PATTERN_ID = "phone_selfcheck_target_pattern"
    const val PHASE_ID = "phone_selfcheck_target_phase"
    const val ASCII_TEXT = "DSH check 42"
    const val ZH_TEXT = "自检通过四二"
    enum class Profile { C1, C2 }
    enum class FrameStage(val phase: Int) {
        CAPTURE(1), CONTINUITY_FIRST(2), CONTINUITY_SECOND(3), CONTINUITY_THIRD(4)
    }
    private val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    fun validRun(value: String): Boolean = uuid.matches(value)
    fun identifier(targetRun: String): String = "dsh-selfcheck-c1:$targetRun"
    fun marker(targetRun: String): String = "dsh-c1:$targetRun"
    fun counter(value: Int): String = value.toString()
    fun viewId(packageName: String, name: String): String = "$packageName:id/$name"
}
