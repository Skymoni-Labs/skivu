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
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        val deviceQa = providers.gradleProperty("skivuDeviceQa").orNull == "true" ||
            (project.findProperty("dart-defines") as? String).orEmpty().split(',').any {
                try { String(Base64.getDecoder().decode(it)) == "SKIVU_DEVICE_QA=true" } catch (_: Exception) { false }
            }
        val devicePreview = providers.gradleProperty("skivuDevicePreview").orNull == "true" ||
            (project.findProperty("dart-defines") as? String).orEmpty().split(',').any {
            try { String(Base64.getDecoder().decode(it)) == "SKIVU_DEVICE_PREVIEW=true" } catch (_: Exception) { false }
        }
        applicationId = when { deviceQa -> "com.skyjjgw.independent.ski.deviceqa"; devicePreview -> "com.skyjjgw.independent.ski.devicepreview"; else -> "com.skyjjgw.independent.ski" }
        manifestPlaceholders["skivuApplicationLabel"] = if(devicePreview) "Skivu 操控预览" else "@string/app_name"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
