plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "org.skivu.engine.adb"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    defaultConfig { minSdk = 21 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { prefab = true }
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    implementation("androidx.annotation:annotation:1.9.1")
    implementation("org.bouncycastle:bcpkix-jdk18on:1.80")
    implementation("io.github.vvb2060.ndk:boringssl:20250114")
    compileOnly("dev.rikka.hidden:stub:4.4.0")
    implementation("org.lsposed.hiddenapibypass:hiddenapibypass:6.1")
}
