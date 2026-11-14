package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PrivilegedInputReasonTest {
    // InputManager answers false for a dispatch timeout too, after the event may have landed (#288).
    @Test fun anUnconfirmedInputIsNotCalledRejected() {
        val reason = Reasons.of("inputRejected")
        assertFalse(reason, reason.contains("拒绝"))
        assertTrue(reason, reason.contains("可能已发出"))
        assertTrue(reason, reason.contains("不要重复"))
    }

    @Test fun acceptedTextThenChangedTargetDoesNotClaimThatNoInputHappened() {
        val reason = Reasons.of("textTargetChanged", null, textAccepted = true)
        assertTrue(reason, reason.contains("已接受文字请求"))
        assertTrue(reason, reason.contains("焦点发生变化"))
        assertTrue(reason, reason.contains("不要自动重复输入或提交"))
        assertFalse(reason, reason.contains("未继续输入"))
    }

    @Test fun acceptedTextKeepsUnverifiedStatusForReadbackCancellationAndSubmitFailure() {
        for (code in listOf("textReadbackMismatch", "cancelled", "inputRejected", "deviceUnavailable", null)) {
            val reason = Reasons.of(code, null, textAccepted = true)
            assertTrue(reason, reason.contains("已接受文字请求"))
            assertTrue(reason, reason.contains("不要自动重复"))
            assertFalse(reason, reason.contains("已成功"))
        }
        assertTrue(Reasons.of("textReadbackMismatch", null, true).contains("回读与预期不一致"))
    }

    @Test fun identityFailurePreservesAcceptedTextWithoutReplayingOrClaimingSuccess() {
        for (code in listOf("targetIdentityChanged", "targetIdentityUnavailable")) {
            val accepted = Reasons.of(code, null, textAccepted = true)
            assertTrue(accepted.contains("已接受文字请求"))
            assertTrue(accepted.contains("不要自动重复"))
            assertFalse(accepted.contains("已成功"))
            val unknown = Reasons.of(code)
            assertFalse(unknown.contains("未执行"))
            assertFalse(unknown.contains("已关闭"))
        }
    }

    @Test fun absentAcceptanceKeepsExistingFailureAndDetailSemantics() {
        val expected = mapOf(
            "textTargetChanged" to "后台屏输入框或焦点已改变，未继续输入（detail）",
            "textUnsupported" to "此输入框不支持直接写入文字（detail）",
            "deviceUnavailable" to "不打扰模式暂不可用，请检查授权、服务和设备支持情况（detail）",
            null to "（detail）",
        )
        for ((code, message) in expected) {
            org.junit.Assert.assertEquals(message, Reasons.of(code, "detail", textAccepted = false))
            assertFalse(Reasons.of(code, null, false).contains("已接受文字请求"))
        }
    }

    @Test fun cleanupPendingAfterAcceptedTextNamesCleanupAndDoesNotInviteAnotherWrite() {
        val reason = Reasons.of("treeCleanupPending", "private detail", textAccepted = true)
        assertTrue(reason, reason.contains("已接受文字请求"))
        assertTrue(reason, reason.contains("树连接清理未确认"))
        assertTrue(reason, reason.contains("重试清理"))
        assertTrue(reason, reason.contains("不要自动重复输入或提交"))
        assertFalse(reason, reason.contains("private detail"))
        assertFalse(reason, reason.contains("请先重新观察"))
    }

    @Test fun cleanupPendingWithoutAcceptanceDoesNotClaimTheActionWasUnexecuted() {
        val reason = Reasons.of("treeCleanupPending")
        assertTrue(reason, reason.contains("重试清理"))
        assertFalse(reason, reason.contains("已接受"))
        assertFalse(reason, reason.contains("未执行"))
    }

    // The generic message hides which step failed; a report can only name it through the detail (#342).
    @Test fun aGenericFailureNamesTheStepWhenItIsKnown() {
        assertTrue(Reasons.of("deviceUnavailable", "adb closed").endsWith("（adb closed）"))
        assertFalse(Reasons.of("deviceUnavailable", null).contains("（"))
        assertTrue(Reasons.withDetail("gate", "adb closed").endsWith("（adb closed）"))
    }
}
