allprojects {
    repositories {
        // 关键: google() 放第一位
        // v1.0.35 / v1.0.38 的失败教训 — 把 Aliyun 放第一位时, 一旦 Aliyun 502
        // Gradle 会把整个 Aliyun 镜像 disable, 后续 google() / mavenCentral() 不会被尝试
        // (Gradle 行为: 单个 repo 失败后该 repo 整批跳过, 不是该 URL 跳过)
        // 现在 google() 在前 + Aliyun 在后: Android 核心包走 Google 快速通道,
        // Aliyun 只在 google() 没找到时兜底, 即使 Aliyun 502 也只丢个别 artifact 不影响主流程
        google()
        maven { setUrl("https://maven.aliyun.com/repository/google") }
        maven { setUrl("https://maven.aliyun.com/repository/public") }
        maven { setUrl("https://maven.aliyun.com/repository/gradle-plugin") }
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory
    .dir("../../build")
    .get()

rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
