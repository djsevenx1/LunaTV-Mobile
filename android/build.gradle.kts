allprojects {
    repositories {
        // 镜像策略: google() 在前 + 多个国内镜像兜底 + mavenCentral() 最后
        // 关键教训 (来自 v1.0.35 / v1.0.38 反复 502):
        //   1. Gradle 单个 repo 失败后整批 disable, 不是该 URL 跳过
        //   2. 单一镜像 (Aliyun) 不够稳, 必须多镜像互备
        //   3. Android 核心包 (com.android.tools.*) 优先走 google() 官方源
        //   4. 非 Android 核心包走 Aliyun → Huawei → Tencent → mavenCentral() 兜底链
        google()
        // Aliyun: 国内最快, 但偶尔 502
        maven { setUrl("https://maven.aliyun.com/repository/google") }
        maven { setUrl("https://maven.aliyun.com/repository/public") }
        maven { setUrl("https://maven.aliyun.com/repository/gradle-plugin") }
        // Huawei: 备用国内镜像, 跟 Aliyun 互备, 同样镜像 Maven Central
        maven { setUrl("https://repo.huaweicloud.com/repository/maven/") }
        maven { setUrl("https://mirrors.huaweicloud.com/repository/maven/") }
        // Tencent: 第三个国内镜像, 进一步降低全部挂的概率
        maven { setUrl("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/") }
        // mavenCentral() 兜底, CI runner 地区被墙时可能 403, 但其他都挂时还有它
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
