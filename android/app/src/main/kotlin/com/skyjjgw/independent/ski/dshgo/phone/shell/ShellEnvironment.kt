package com.skyjjgw.independent.ski.dshgo.phone.shell

/** Runtime implementation details must not leak into the user's final sh environment. */
internal fun shellEnvironment(inherited: Map<String, String> = System.getenv()): Map<String, String> = buildMap {
    put("PATH", "/system/bin:/system/xbin:/vendor/bin")
    put("HOME", "/data/local/tmp")
    put("TMPDIR", "/data/local/tmp")
    put("LANG", "C.UTF-8")
    for (key in listOf("ANDROID_ROOT", "ANDROID_DATA", "ANDROID_ART_ROOT", "ANDROID_I18N_ROOT", "ANDROID_TZDATA_ROOT")) {
        inherited[key]?.takeIf { it.startsWith('/') }?.let { put(key, it) }
    }
}

/** app_process needs the platform boot paths to avoid trying to rebuild protected dalvik caches. */
internal fun shellHelperEnvironment(
    classpath: String,
    inherited: Map<String, String> = System.getenv(),
    bootClasspathFallback: String? = System.getProperty("java.boot.class.path"),
): Map<String, String> = shellEnvironment(inherited).toMutableMap().apply {
    put("CLASSPATH", classpath)
    (inherited["BOOTCLASSPATH"]?.takeIf { it.isNotBlank() } ?: bootClasspathFallback)
        ?.takeIf { it.isNotBlank() }?.let { put("BOOTCLASSPATH", it) }
    inherited["DEX2OATBOOTCLASSPATH"]?.takeIf { it.isNotBlank() }?.let { put("DEX2OATBOOTCLASSPATH", it) }
}
