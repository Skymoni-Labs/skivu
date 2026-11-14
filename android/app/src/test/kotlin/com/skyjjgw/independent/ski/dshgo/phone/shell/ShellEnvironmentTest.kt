package com.skyjjgw.independent.ski.dshgo.phone.shell

import org.junit.Assert.*
import org.junit.Test

class ShellEnvironmentTest {
    private val inherited = mapOf(
        "PATH" to "/untrusted/bin", "HOME" to "/old/home", "LD_PRELOAD" to "/untrusted/lib.so",
        "LD_LIBRARY_PATH" to "/untrusted/lib", "CLASSPATH" to "/untrusted/old.jar",
        "BOOTCLASSPATH" to "/apex/com.android.art/javalib/core-oj.jar:/system/framework/framework.jar",
        "DEX2OATBOOTCLASSPATH" to "/apex/com.android.art/javalib/core-oj.jar",
        "ANDROID_ROOT" to "/system", "ANDROID_DATA" to "/data",
        "ANDROID_ART_ROOT" to "/apex/com.android.art", "SECRET_TOKEN" to "do-not-inherit",
    )

    @Test fun helperRetainsOnlyRequiredBootRuntimePaths() {
        val result = shellHelperEnvironment("/trusted/probe.jar", inherited, "/fallback.jar")
        assertEquals(inherited["BOOTCLASSPATH"], result["BOOTCLASSPATH"])
        assertEquals(inherited["DEX2OATBOOTCLASSPATH"], result["DEX2OATBOOTCLASSPATH"])
        assertEquals("/trusted/probe.jar", result["CLASSPATH"])
        assertEquals("/apex/com.android.art", result["ANDROID_ART_ROOT"])
        assertFalse(result.containsKey("LD_PRELOAD"))
        assertFalse(result.containsKey("LD_LIBRARY_PATH"))
        assertFalse(result.containsKey("SECRET_TOKEN"))
    }

    @Test fun finalShellDoesNotInheritBootOrHelperClasspath() {
        val result = shellEnvironment(inherited)
        assertFalse(result.containsKey("BOOTCLASSPATH"))
        assertFalse(result.containsKey("DEX2OATBOOTCLASSPATH"))
        assertFalse(result.containsKey("CLASSPATH"))
        assertFalse(result.containsKey("LD_PRELOAD"))
        assertFalse(result.containsKey("SECRET_TOKEN"))
        assertEquals("/system/bin:/system/xbin:/vendor/bin", result["PATH"])
        assertEquals("/data/local/tmp", result["HOME"])
    }

    @Test fun helperFallsBackOnlyForMissingBootClasspath() {
        val noBoot = inherited - "BOOTCLASSPATH"
        val result = shellHelperEnvironment("/trusted/probe.jar", noBoot, "/fallback/core.jar")
        assertEquals("/fallback/core.jar", result["BOOTCLASSPATH"])
        assertEquals(inherited["DEX2OATBOOTCLASSPATH"], result["DEX2OATBOOTCLASSPATH"])
        assertEquals("/fallback.jar", shellHelperEnvironment("/trusted.jar", mapOf("BOOTCLASSPATH" to ""), "/fallback.jar")["BOOTCLASSPATH"])
    }

    @Test fun missingBootPathsDoNotBecomeLiteralNullOrEmptyEntries() {
        val result = shellHelperEnvironment("/trusted.jar", emptyMap(), null)
        assertFalse(result.containsKey("BOOTCLASSPATH"))
        assertFalse(result.containsKey("DEX2OATBOOTCLASSPATH"))
        assertEquals("/trusted.jar", result["CLASSPATH"])
    }
}
