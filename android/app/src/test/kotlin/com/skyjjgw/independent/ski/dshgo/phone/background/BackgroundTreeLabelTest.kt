package com.skyjjgw.independent.ski.dshgo.phone.background

import com.skyjjgw.independent.ski.dshgo.phone.SafetyRules
import org.junit.Assert.*
import org.junit.Test

/**
 * The background display's element labels: a field recognised as secret by its hint or
 * description (not a password input, not a secure window) shows its name, never the code in it;
 * everything else reads as before.
 */
class BackgroundTreeLabelTest {
    /** What the privileged side computes per node, as in `toElement`. */
    private fun label(text: String?, hint: String = "", description: String = "", password: Boolean = false, showingHint: Boolean = false): String {
        val best = text?.takeIf { it.isNotBlank() } ?: description.ifBlank { hint }
        val secret = password || BackgroundTree.isSecretHint("$hint $description")
        val filled = !showingHint && !text.isNullOrBlank()
        return BackgroundTree.label(best, description.ifBlank { hint }, filled, password, secret)
    }

    @Test fun aCodeFieldShowsItsNameAndNeverItsCode() {
        assertEquals("请输入验证码 ${SafetyRules.MASK}", label("482913", hint = "请输入验证码"))
        assertEquals("短信验证码 ${SafetyRules.MASK}", label("482913", hint = "请输入", description = "短信验证码"))
        assertEquals("One-time code ${SafetyRules.MASK}", label("482913", description = "One-time code"))
        // Empty, or showing its hint: just the name, so the model can still find it.
        assertEquals("请输入验证码", label(null, hint = "请输入验证码"))
        assertEquals("请输入验证码", label("请输入验证码", hint = "请输入验证码", showingHint = true))
    }

    @Test fun aPasswordStillShowsNothing() {
        assertEquals("", label("hunter2", hint = "密码", password = true))
    }

    @Test fun ordinaryTextIsUntouched() {
        // No global 6-digit mask: an order number or a price stays readable.
        assertEquals("482913", label("482913"))
        assertEquals("取件码 482913", label("取件码 482913"))
        assertEquals("搜索", label(null, hint = "搜索"))
        assertEquals("«银行卡 ****1111»", label("4111 1111 1111 1111"))
    }
}
