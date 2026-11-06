plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "com.example.liquidglass"
    compileSdk = 36
    ndkVersion = "27.1.12297006"
    defaultConfig {
        minSdk = 24
        externalNativeBuild { cmake { arguments += "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON" } }
    }
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_17.toString() }
}
dependencies { implementation("androidx.annotation:annotation:1.9.1") }
