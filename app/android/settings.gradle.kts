pluginManagement {
    // Flutter tooling: resolves the Flutter SDK from local.properties
    // (flutter.sdk) or the FLUTTER_ROOT environment variable (CI sets it
    // via subosito/flutter-action). Keep this block first, as generated
    // by `flutter create` for Flutter 3.35.
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        val localPropertiesFile = File(rootDir, "local.properties")
        if (localPropertiesFile.exists()) {
            properties.load(java.io.FileInputStream(localPropertiesFile))
            properties.getProperty("flutter.sdk")
        } else {
            null
        }
    } ?: System.getenv("FLUTTER_ROOT")
        ?: throw GradleException(
            "Flutter SDK not found. Define location with flutter.sdk in " +
                "local.properties or set the FLUTTER_ROOT environment variable."
        )
    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // Plugin versions MUST be declared here (settings phase).
    id("com.android.application") version "8.6.1" apply false
    id("org.jetbrains.kotlin.android") version "1.9.21" apply false
}

rootProject.name = "ph_player"
include(":app")
