// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

        // ABI selection is controlled at build time (e.g. --split-per-abi for
        // F-Droid/release) so each shipped APK stays small without hard-coding a
        // single architecture here.
    }

    buildTypes {
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
