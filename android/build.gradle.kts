allprojects {
    repositories {
        // 镜像策略: google() 在前 + 多个国内镜像兜底 + mavenCentral() 最后
        // 关键教训 (来自 v1.0.35 / v1.0.38 / v2.2.0+53 反复 502):
        //   1. Gradle 单个 repo 失败后整批 disable, 不是该 URL 跳过
        //   2. 单一镜像 (Aliyun) 不够稳, 必须多镜像互备
        //   3. Android 核心包 (com.android.tools.*) 优先走 google() 官方源
        //   4. 镜像顺序很关键: aliyun 挂 → 后面的兜底镜像得有人能命中, 不能
        //      让 huaweicloud / tencent 都堆在 aliyun 之后
        //   5. v2.2.0+53 aliyun 持续 502, 把 huaweicloud/tencent 提到前面做主用镜像,
        //      aliyun 放最后做"加速"用 (aliyun 200 时比 huawei 快, 但 502 概率高)
        google()
        // Huawei: 互备, 现在最稳 (2026-07 aliyun 抽风时还能用)
        maven { setUrl("https://repo.huaweicloud.com/repository/maven/") }
        maven { setUrl("https://mirrors.huaweicloud.com/repository/maven/") }
        // Tencent: 第三个国内镜像, 进一步降低全部挂的概率
        maven { setUrl("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/") }
        // Aliyun: 国内最快, 但 2026-07 反复 502, 放最后做加速
        maven { setUrl("https://maven.aliyun.com/repository/google") }
        maven { setUrl("https://maven.aliyun.com/repository/public") }
        maven { setUrl("https://maven.aliyun.com/repository/gradle-plugin") }
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
