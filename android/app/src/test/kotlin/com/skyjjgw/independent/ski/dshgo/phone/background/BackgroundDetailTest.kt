package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundDetailTest {
    @Test fun explicitDetailKeepsAButtonBeyondTheCompactPrefixWithItsOriginalIdAndBounds() {
        val elements = (1..160).map(::element)
        val count = BackgroundTree.detailPrefixCount(elements)
        assertEquals(160, count)
        val text = render(elements.take(count))
        assertTrue(text.contains("[121] 按钮 行121 @[0,121,720,122]"))
        assertEquals(121, elements.take(count)[120].id)
    }

    @Test fun utf8BudgetIncludesCoordinatesRegionsNotesAndMultibyteLabels() {
        val elements = (1..600).map { element(it).copy(
            label = "测😀".repeat(20), sensitive = true,
            region = if (it % 2 == 0) Region.TOP else Region.BOTTOM,
            states = listOf("已聚焦", "已选", "已勾选", "不可用", "可滚动", "密码·不可代填"),
        ) }
        val count = BackgroundTree.detailPrefixCount(elements)
        assertTrue(count in 1..599)
        val text = render(elements.take(count), overflow = elements.size - count, complete = false)
        assertTrue(text.toByteArray(Charsets.UTF_8).size <= BackgroundTree.DETAIL_TEXT_BYTES)
        assertTrue(text.contains("另有 ${600 - count} 项未列出"))
        assertTrue(text.contains("未读取的节点数量未知"))
        assertFalse(text.contains("[${count + 1}]"))
    }

    @Test fun deepIndentationConsumesTheTextBudgetWithoutRenumberingOrSplittingALine() {
        val elements = (1..600).map { element(it).copy(indent = 599) }
        val count = BackgroundTree.detailPrefixCount(elements)
        assertTrue(count in 1..119)
        val text = render(elements.take(count), overflow = 600 - count)
        assertTrue(text.toByteArray(Charsets.UTF_8).size <= BackgroundTree.DETAIL_TEXT_BYTES)
        assertTrue(text.contains("[$count] 按钮"))
        assertFalse(text.contains("[${count + 1}]"))
    }

    @Test fun oversizedFingerprintStopsThePrefixInsteadOfTruncatingOrSkippingItsIdentity() {
        val elements = listOf(element(1), element(2).copy(viewId = "x".repeat(4097)), element(3))
        assertEquals(1, BackgroundTree.detailPrefixCount(elements))
        assertEquals(4097, elements[1].viewId!!.length)
    }

    @Test fun largeViewIdsConsumeTheWireBudgetEvenWhenTheRenderedLabelsAreShort() {
        val elements = (1..600).map { element(it).copy(viewId = "界".repeat(4096)) }
        val count = BackgroundTree.detailPrefixCount(elements)
        assertTrue(count in 1..10)
        assertEquals((1..count).toList(), elements.take(count).map { it.id })
    }

    @Test fun reachingTraversalLimitNeverAddsACompletenessClaim() {
        val elements = (1..601).map { element(it).copy(label = "", bounds = null) }
        assertEquals(600, BackgroundTree.detailPrefixCount(elements))
        val text = render(elements.take(600), complete = false)
        assertTrue(text.contains("未读取的节点数量未知"))
        // The budget fixture appends a separate privacy note containing 未完整读取.
        // Check the renderer itself so that negative note is not a completeness claim.
        for (complete in listOf(true, null)) {
            val rendered = BackgroundTree.render("b-2147483648", "测😀".repeat(20), true, false,
                elements.take(1), background = true, poorTree = true, detailed = true, treeComplete = complete)
            assertFalse(rendered.contains("完整"))
        }
    }

    @Test fun legacyRenderIsUnchangedAndDoesNotInventCoordinatesOrScanMetadata() {
        val text = BackgroundTree.render("b1", "app", true, false,
            listOf(element(1).copy(bounds = null)), background = true, poorTree = false)
        assertFalse(text.contains("@["))
        assertFalse(text.contains("未读取"))
        assertFalse(text.contains("未列出"))
    }

    private fun element(id: Int) = Element(id, "按钮", "行$id", Region.MIDDLE,
        bounds = ElementBounds(0, id, 720, id + 1))

    private fun render(elements: List<Element>, overflow: Int = 0, complete: Boolean? = true) =
        BackgroundTree.render("b-2147483648", "测😀".repeat(20), true, false, elements,
            background = true, poorTree = true, overflow = overflow, detailed = true, treeComplete = complete) +
            "\n（本页含敏感输入或控件树未完整读取，已省略截图；可继续使用已脱敏的文字信息）"
}
