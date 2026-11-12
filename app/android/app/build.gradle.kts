// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ABI selection follows the target platform Flutter was invoked with
// (`--target-platform android-arm64`, which `make build`/`build-release` and
// the F-Droid recipe pass). Gradle called directly (no target-platform
// property) falls back to the phone target, arm64-v8a.
val flutterTargetPlatform = (project.findProperty("target-platform") as String?)
    ?: "android-arm64"
val androidAbi = when {
    flutterTargetPlatform.contains("arm64") -> "arm64-v8a"
    flutterTargetPlatform.contains("android-arm") -> "armeabi-v7a"
    flutterTargetPlatform.contains("x64") -> "x86_64"
    else -> "arm64-v8a"
}

android {
    namespace = "app.against_yesterday"
    compileSdk = flutter.compileSdkVersion
    // Pin the NDK for reproducible/F-Droid builds (matches this Flutter SDK).
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.against_yesterday"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        // Flutter's Gradle plugin adds ABI filters for every platform to each
        // build type when the build is not split per ABI. Narrow them back to
        // the one ABI being built, so the non-split APK does not carry engine
        // or plugin libraries for other architectures.
        listOf("debug", "release").forEach { buildTypeName ->
            named(buildTypeName) {
                ndk {
                    abiFilters.clear()
                    abiFilters.add(androidAbi)
                }
            }
        }

        release {
            // Unsigned release APKs for reproducible/F-Droid builds (F-Droid signs
            // artifacts itself). For a locally signed release, configure a signing
            // config here or pass one at build time.
        }
    }
}

flutter {
    source = "../.."
}
