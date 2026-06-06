pluginManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "luna_tv"
include(":app")

val flutterSdk = providers.gradleProperty("flutter.sdk").orNull
    ?: System.getenv("FLUTTER_ROOT")
    ?: ""

if (flutterSdk.isNotBlank()) {
    apply(from = "$flutterSdk/packages/flutter_tools/gradle/app_plugin_loader.gradle")
}
