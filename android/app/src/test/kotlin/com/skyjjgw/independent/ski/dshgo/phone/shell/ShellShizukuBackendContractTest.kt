package com.skyjjgw.independent.ski.dshgo.phone.shell

import java.io.File
import org.junit.Assert.*
import org.junit.Test

/** Prevent a manually frozen service version from reusing an APK-bound host across upgrades. */
class ShellShizukuBackendContractTest {
    @Test fun bothShizukuServicesTrackTheInstalledApkVersion() {
        val phone = File("src/main/kotlin/com/skyjjgw/independent/ski/dshgo/phone")
        for (path in listOf("shell/ShellShizukuBackend.kt", "background/ShizukuStarter.kt")) {
            val source = File(phone, path).readText()
            assertTrue(path, source.contains("context.packageManager.getPackageInfo(context.packageName, 0).versionCode"))
            assertTrue(path, source.contains(".version(serviceVersion)"))
            assertFalse(path, Regex("\\.version\\(\\d+\\)").containsMatchIn(source))
        }
    }
}
