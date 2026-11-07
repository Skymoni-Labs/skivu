package com.skyjjgw.independent.ski

import androidx.test.runner.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppAlphabetAcceptanceTest {
    @Test fun chineseAppNamesUseSystemPinyinAndAsciiNamesRemainSearchable() {
        val alphabet = AppAlphabet()
        assertEquals("bohao", alphabet.fields("拨号")["sortName"])
        assertEquals("shezhi", alphabet.fields("设置")["sortName"])
        assertEquals("xinxi", alphabet.fields("信息")["sortName"])
        assertTrue(alphabet.fields("设置")["searchName"]!!.split(" ").contains("sz"))
        assertEquals("playstore", alphabet.fields("Play Store")["sortName"])
        assertEquals("qqshezhi", alphabet.fields("QQ设置")["sortName"])
        assertEquals("1password", alphabet.fields("1Password")["sortName"])
    }
}
