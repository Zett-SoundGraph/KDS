pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // 버전을 8.9.1에서 8.1.2로 낮춥니다.
    id("com.android.application") version "8.1.2" apply false
    // 코틀린 버전도 2.1.0에서 안정적인 1.8.22 또는 1.9.10으로 낮추는 것을 추천합니다.
    id("org.jetbrains.kotlin.android") version "1.8.22" apply false
}

include(":app")
