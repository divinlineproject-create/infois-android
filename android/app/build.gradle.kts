import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Kunci rilis: android/key.properties (tidak ikut Git; cadangannya di ~/infois-keys).
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) {
        load(FileInputStream(file))
    }
}

android {
    namespace = "id.infois.infois"
    // Google Play: aplikasi baru & pembaruan wajib target Android 16 (API 36)
    // sejak 31 Agustus 2026. Flutter 3.29 masih default 35, jadi ditulis tetap.
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "id.infois.infois"
        // flutter_secure_storage & printer Bluetooth butuh Android 6+.
        minSdk = 23
        manifestPlaceholders["usesCleartextTraffic"] = "false"
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystoreProperties.getProperty("storeFile") != null) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            // Debug boleh memakai http:// (server lokal / emulator 10.0.2.2).
            manifestPlaceholders["usesCleartextTraffic"] = "true"
        }
        release {
            // Rilis ditandatangani kunci Infois; tanpa key.properties (mis. di
            // mesin pengembang lain) jatuh ke kunci debug supaya tetap bisa dibangun.
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
