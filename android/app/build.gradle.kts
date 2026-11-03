// App module build script. Kotlin DSL, matches the root script.

import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    // Required for Firebase, keep it or google-services.json is ignored.
    id("com.google.gms.google-services")
    id("kotlin-android")
    // Flutter plugin must load after the Android and Kotlin plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.towncare"

    // Must be 36 because tflite_flutter compiles against API 36.
    compileSdk = 36

    // No ndkVersion line, because no plugin here builds native code.

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.towncare"
        // Kept at your original value.
        minSdk = 26
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Debug key keeps release builds installable for the demo.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// Replaces kotlinOptions, which is a hard error on Kotlin 2.2.
kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}
