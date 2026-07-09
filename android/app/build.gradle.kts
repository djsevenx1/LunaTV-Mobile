import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.moontechlab.lunatv"
    compileSdk = 36
    ndkVersion = "29.0.14033849"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "org.moontechlab.lunatv"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        // 从 pubspec.yaml 读 version (经 workflow sed 同步)
        // Kotlin DSL 里 flutter.versionCode/versionName 是方法, 调用方式不稳定
        // 直接解析 pubspec.yaml 最稳
        val pubspecFile = rootProject.file("../pubspec.yaml")
        val versionLine = pubspecFile.readLines().first { it.startsWith("version:") }
        val versionStr = versionLine.substringAfter("version:").trim()
        // 格式: <name>+<code> 或只有 <name> (无 + 后缀, 默认 code=1)
        val parts = versionStr.split("+")
        versionName = parts[0]
        versionCode = if (parts.size > 1) parts[1].toInt() else 1
    }

    // 固定 release 签名 (keystore 提交在仓库 android/app/release.keystore)
    // 每次 CI 构建签名一致, 可以正常覆盖安装
    signingConfigs {
        create("release") {
            storeFile = file("release.keystore")
            storePassword = "lunatv2024"
            keyAlias = "lunatv"
            keyPassword = "lunatv2024"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
        debug {
            isMinifyEnabled = false
        }
    }
}

flutter {
    source = "../.."
}
