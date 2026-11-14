import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.skyjjgw.independent.ski"
    compileSdk = flutter.compileSdkVersion
    buildFeatures { buildConfig = true }
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }
    packaging {
        jniLibs.useLegacyPackaging = true
        resources.excludes += "META-INF/versions/9/OSGI-INF/MANIFEST.MF"
    }
    androidResources { noCompress += "bin" }
    sourceSets["main"].assets.srcDir("cloud-assets")
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }

    defaultConfig {
        val dshGoQa = providers.gradleProperty("skivuDshGoQa").orNull == "true"
        val phoneFlowQa = providers.gradleProperty("skivuPhoneFlowQa").orNull == "true"
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        val deviceQa = providers.gradleProperty("skivuDeviceQa").orNull == "true" ||
            (project.findProperty("dart-defines") as? String).orEmpty().split(',').any {
                try { String(Base64.getDecoder().decode(it)) == "SKIVU_DEVICE_QA=true" } catch (_: Exception) { false }
            }
        val devicePreview = providers.gradleProperty("skivuDevicePreview").orNull == "true" ||
            (project.findProperty("dart-defines") as? String).orEmpty().split(',').any {
            try { String(Base64.getDecoder().decode(it)) == "SKIVU_DEVICE_PREVIEW=true" } catch (_: Exception) { false }
        }
        val runtimeQa = (project.findProperty("dart-defines") as? String).orEmpty().split(',').any {
            try { String(Base64.getDecoder().decode(it)) == "SKIVU_RUNTIME_QA=true" } catch (_: Exception) { false }
        }
        val engineQa = (project.findProperty("dart-defines") as? String).orEmpty().split(',').any {
            try { String(Base64.getDecoder().decode(it)) == "SKIVU_ENGINE_QA=true" } catch (_: Exception) { false }
        }
        val purgeQa = (project.findProperty("dart-defines") as? String).orEmpty().split(',').any {
            try { String(Base64.getDecoder().decode(it)) == "SKIVU_PURGE_QA=true" } catch (_: Exception) { false }
        }
        val updateQa = (project.findProperty("dart-defines") as? String).orEmpty().split(',').any {
            try { String(Base64.getDecoder().decode(it)) == "SKIVU_UPDATE_QA=true" } catch (_: Exception) { false }
        }
        applicationId = when { phoneFlowQa -> "com.skyjjgw.independent.ski.phoneflowqa"; updateQa -> "com.skyjjgw.independent.ski.updateqa"; purgeQa -> "com.skyjjgw.independent.ski.purgeqa"; engineQa -> "com.skyjjgw.independent.ski.engineqa"; runtimeQa -> "com.skyjjgw.independent.ski.runtimeqa"; deviceQa -> "com.skyjjgw.independent.ski.deviceqa"; devicePreview -> "com.skyjjgw.independent.ski.devicepreview"; else -> "com.skyjjgw.independent.ski" }
        if (dshGoQa) applicationId = "com.skyjjgw.independent.ski.dshgoqa"
        manifestPlaceholders["skivuQaDocumentsAuthority"] = "$applicationId.test.documents"
        manifestPlaceholders["skivuApplicationLabel"] = if(dshGoQa) "Skivu 操控验收" else if(phoneFlowQa) "Skivu 流程验收" else if(devicePreview) "Skivu 操控预览" else "@string/app_name"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            proguardFiles("proguard-rules.pro")
            // Native Maven dependencies contain additional ABIs. Advertise only
            // the architectures for which this release includes Flutter engines.
            run {
                val abiNames = mapOf("android-arm" to "armeabi-v7a", "android-arm64" to "arm64-v8a", "android-x64" to "x86_64")
                val platforms = providers.gradleProperty("target-platform").orElse("android-arm,android-arm64,android-x64").get().split(',')
                ndk.abiFilters.clear()
                ndk.abiFilters.addAll(platforms.map { requireNotNull(abiNames[it]) { "Unsupported Flutter platform: $it" } })
            }
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
dependencies { implementation(project(":skymoni_glass")) }
dependencies { implementation(project(":embedded_adb")) }
dependencies {
    // Bundle the Chinese recognizer: offline inference, including first use.
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    testImplementation("junit:junit:4.13.2")
    // 2.11.2 includes Android 15+ blocked-background-network tracking fixes.
    implementation("androidx.work:work-runtime:2.11.2")
    implementation("com.google.guava:guava:33.3.1-android")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    androidTestImplementation("androidx.test:runner:1.2.0")
    androidTestImplementation("junit:junit:4.12")
}

// Pinned dsh-go phone module: original Shizuku/self-ADB privileged transports.
dependencies {
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    implementation("com.github.MuntashirAkon:libadb-android:3.1.1")
    implementation("org.conscrypt:conscrypt-android:2.8.0")
    implementation("org.bouncycastle:bcpkix-jdk15to18:1.81")
    testImplementation("org.json:json:20240303")
}
