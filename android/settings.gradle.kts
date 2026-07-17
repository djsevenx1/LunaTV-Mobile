pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }
    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")
    repositories {
        // 跟 android/build.gradle.kts 同样的策略, 顺序对齐, 防止 plugin resolution
        // 跟主项目走不同镜像链. v2.2.0+53 aliyun 502 把整个链拖死, 把 huawei/tencent
        // 提到 aliyun 前面, 跟主项目保持一致.
        google()
        maven { setUrl("https://repo.huaweicloud.com/repository/maven/") }
        maven { setUrl("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/") }
        maven { setUrl("https://maven.aliyun.com/repository/google") }
        maven { setUrl("https://maven.aliyun.com/repository/public") }
        maven { setUrl("https://maven.aliyun.com/repository/gradle-plugin") }
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

include(":app")
