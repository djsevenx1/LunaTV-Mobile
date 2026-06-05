buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.0")
    }
}

rootProject.name = "luna_tv"
include(":app")

// Flutter configuration
apply(from: "$System.env.FLUTTER_ROOT/packages/flutter_tools/gradle/app_plugin_loader.gradle")