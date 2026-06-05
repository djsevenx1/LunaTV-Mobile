pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    plugins {
        id("com.android.application") version "8.1.0" apply false
        id("com.android.library") version "8.1.0" apply false
        id("org.jetbrains.kotlin.android") version "1.9.0" apply false
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "luna_tv"
include(":app")

// Include Flutter Gradle Plugin from Flutter SDK
val flutterSdkPath = System.getenv("FLUTTER_ROOT") ?: throw GradleException("FLUTTER_ROOT not set")
includeBuild("$flutterSdkPath/packages/flutter_tools/gradle") {
    dependencySubstitution {
        substitute(module("dev.flutter:flutter-gradle-plugin")).using(project(":"))
    }
}