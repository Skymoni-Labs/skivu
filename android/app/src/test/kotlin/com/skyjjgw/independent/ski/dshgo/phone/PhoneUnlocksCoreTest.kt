package com.skyjjgw.independent.ski.dshgo.phone

import java.time.ZoneId
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/**
 * 解除限制 through the real PhoneCore: a password typed once allowed never shows its value in the
 * action log or the status line, and a handoff after a hard refusal names the rule on its card.
 */
class PhoneUnlocksCoreTest {
    private val tasks = PhoneTasks()
    private var policies = PhonePolicies(confirmMode = ConfirmMode.ALWAYS)
    private val handoffs = mutableListOf<HandoffCause?>()
    private val statuses = mutableListOf<String?>()
    private var field = TargetInfo("s1", 1, "输入框", "支付密码", "example.app", "Example", true, true, true)
    private var foreground = "example.app"
    private var writes = 0
    private val log = ActionLog()

    private val driver = object : PhoneDriver {
        override val screen = PhoneScreen.MAIN
        override fun availability() = Availability(true)
        override fun foregroundPackage() = foreground
        override fun observe(detail: Boolean, image: Boolean) = ScreenSnapshot("s2", "Example", "Example", foreground)
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = error("unexpected collect")
        override fun target(screenId: String, elementId: Int) = field.copy(screenId = screenId, elementId = elementId, packageName = foreground)
        override fun perform(action: PhoneAction): ActionResult { writes++; return ActionResult(true, "done") }
        override fun open(target: PhoneAppIdentity) = error("unexpected open")
    }

    private val core = PhoneCore(object : PhoneEnv {
        override fun enabled() = true
        override fun policies() = policies
        override fun isLocked() = false
        override fun gate() = object : UserGate {
            override fun confirm(request: ConfirmRequest) = Decision.ALLOW_ONCE
            override fun handoff(reason: String, timeoutMs: Long): HandoffResult = error("the core passes the cause")
            override fun handoff(reason: String, timeoutMs: Long, cause: HandoffCause?): HandoffResult {
                handoffs += cause
                return HandoffResult.CONTINUE
            }
            override fun status(text: String?) { statuses += text }
        }
        override fun driver(screen: PhoneScreen) = if (screen == PhoneScreen.MAIN) driver else null
        override fun a11yState() = A11yState.CONNECTED
        override fun backgroundUnavailable() = "unavailable"
        override fun zone() = ZoneId.of("UTC")
        override fun notifyFix(kind: String) {}
        override fun sleep(ms: Long) {}
        override fun system(): SystemApi = error("unexpected system call")
    }, tasks, log)

    @After fun close() = core.worker.shutdown()

    private fun type(text: String) = core.call(PhoneToolCatalog.TYPE, mapOf("screen" to "s1", "id" to 1, "text" to text))
    private fun tap() = core.call(PhoneToolCatalog.TAP, mapOf("screen" to "s1", "id" to 1))
    private fun handoff() = core.call(PhoneToolCatalog.HANDOFF, mapOf("reason" to "输入支付密码后点继续"))

    @Test fun aLockedPasswordFieldIsRefusedAndItsLogEntryIsMasked() {
        assertTrue(type("135790").isError)
        assertEquals(0, writes)
        val entry = log.last()!!
        assertEquals("refused:secret-field", entry.decision)
        assertFalse(entry.summary.contains("135790"))
        assertFalse(entry.summary.contains("6"))
        assertTrue(entry.summary.contains(SafetyRules.MASK))
    }

    @Test fun anAllowedPasswordIsTypedWithItsValueNowhereButTheField() {
        policies = policies.copy(unlocks = PhoneUnlocks(secretFields = true))
        assertFalse(type("135790").isError)
        assertEquals(1, writes)
        val entry = log.last()!!
        assertEquals("allowed", entry.decision)
        assertTrue(entry.summary.contains(SafetyRules.MASK))
        assertFalse(entry.summary.contains("135790"))
        assertTrue(statuses.filterNotNull().isNotEmpty())
        assertTrue(statuses.filterNotNull().none { it.contains("135790") })
    }

    @Test fun anOrdinaryFieldKeepsItsLengthInTheLog() {
        field = TargetInfo("s1", 1, "输入框", "搜索", "example.app", "Example", false, false, true)
        assertFalse(type("咖啡").isError)
        val entry = log.last()!!
        assertFalse(entry.summary.contains(SafetyRules.MASK))
        assertTrue(entry.summary.contains("2"))
        assertTrue(statuses.filterNotNull().any { it.contains("咖啡") })
    }

    @Test fun theHandoffAfterAHardRefusalNamesTheRule() {
        assertTrue(type("135790").isError)
        assertFalse(handoff().isError)
        assertEquals(listOf<HandoffCause?>(HandoffCause.SECRET), handoffs)

        // Used once: the next handoff is the model's own.
        assertFalse(handoff().isError)
        assertEquals(null, handoffs.last())

        foreground = "com.android.settings"
        field = TargetInfo("s1", 1, "开关", "无障碍", "com.android.settings", "设置", false, false, false)
        assertTrue(tap().isError)
        assertEquals("refused:system-page", log.last()!!.decision)
        assertFalse(handoff().isError)
        assertEquals(HandoffCause.SYSTEM, handoffs.last())
    }

    @Test fun aWriteThatGoesThroughClearsTheRefusalBeforeIt() {
        assertTrue(type("135790").isError)
        field = TargetInfo("s1", 1, "按钮", "下一步", "example.app", "Example", false, false, false)
        assertFalse(tap().isError)
        assertFalse(handoff().isError)
        assertEquals(listOf<HandoffCause?>(null), handoffs)
    }

    @Test fun anotherTaskDoesNotInheritTheRefusal() {
        assertTrue(type("135790").isError)
        tasks.endTask()
        assertFalse(handoff().isError)
        assertEquals(listOf<HandoffCause?>(null), handoffs)
    }

    @Test fun liftedSystemPagesAreDrivenAndLoggedAsUsual() {
        policies = policies.copy(unlocks = PhoneUnlocks(systemPages = true))
        foreground = "com.android.settings"
        field = TargetInfo("s1", 1, "开关", "蓝牙", "com.android.settings", "设置", false, false, false)
        assertFalse(tap().isError)
        assertEquals(1, writes)
        val entry = log.last()!!
        assertEquals("allowed", entry.decision)
        assertEquals("设置", entry.app)
    }
}
