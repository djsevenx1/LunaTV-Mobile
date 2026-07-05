# 修复日记 · 2026-07-05 · 短剧页面平板视频问题

## 现象

用户反馈：iPad 上打开「短剧」Tab，每张短剧卡片被拉得很大，一行只显示 3 张；同
设备上「电视剧」Tab 显示正常（8 张/行）。

## 截图

- **短剧页**（异常）：800+ 宽度只显示 3 张大卡片，封面占满大半屏
- **电视剧页**（正常）：同宽度显示 8 张小卡片，比例正确

## 排查

[short_drama_screen.dart](file:///workspace/lib/screens/short_drama_screen.dart) 里的
`_buildDramaGrid` 只区分了 PC / 非 PC 两支：

```dart
if (isPC) { ... 4~6 列 ... }
else      { crossAxisCount = 3; }   // 平板被误归这里
```

平板既不算 PC，`isPC()` 返回 false，直接掉进 `else` 写死 3 列。

对比 [douban_movies_grid.dart](file:///workspace/lib/widgets/douban_movies_grid.dart)：
电视剧页用 `DeviceUtils.getTabletColumnCount(context)`，按宽度返回 6/7/8 列
（1000 / 1200 阈值）。

[device_utils.dart](file:///workspace/lib/utils/device_utils.dart) 里有现成
工具 `isTablet(context)` + `getTabletColumnCount(context)`，短剧页没复用。

## 修复

在 PC 和「手机」之间补一个 `isTablet` 分支，复用电视剧页的列数算法：

```dart
if (isPC) { ... 4~6 列 ... }
else if (DeviceUtils.isTablet(context)) {
  // 平板模式：根据屏幕宽度动态展示 6～8 列
  crossAxisCount = DeviceUtils.getTabletColumnCount(context);
  horizontalPadding = 16;
}
else { crossAxisCount = 3; horizontalPadding = 12; }

final double spacing = isPC ? 16.0 : 12.0;   // 顺手把 10 调到 12 跟电视剧对齐
final double cardWidth = (gridWidth - spacing * (crossAxisCount - 1)) / crossAxisCount;
```

3 段分支：`isPC` → 4~6；`isTablet` → 6~8；其他 → 3。共享同一个
`getTabletColumnCount`，以后改平板列数阈值只动
[device_utils.dart](file:///workspace/lib/utils/device_utils.dart) 一处。

## 改动文件

- `lib/screens/short_drama_screen.dart` — 6 行
- `pubspec.yaml` — version 1.0.34+1 → 1.0.35+1
- `.github/workflows/build.yml` — 追加 v1.0.35 changelog

## 额外修复 · gradle 镜像 fail-over

发布过程中 v1.0.35 tag 触发的 `flutter build apk --release` 连续 2 次
失败，日志用 GitHub API 拉下来看到真正原因不是代码：

```
> Could not resolve androidx.annotation:annotation-experimental:1.1.0.
   > Could not get resource
     'https://maven.aliyun.com/repository/public/.../annotation-experimental-1.1.0.pom'.
     > Received status code 502 from server: Bad Gateway
> There are 8 more failures with identical causes.
```

`maven.aliyun.com` 瞬时 502，Gradle 把整个 Aliyun 镜像组标 disabled，
`package_info_plus` / `volume_controller` / `media_kit_libs_android_video`
几个插件的传递依赖（AndroidX 那套）就解析不到。

[android/build.gradle.kts](file:///workspace/android/build.gradle.kts) 和
[android/settings.gradle.kts](file:///workspace/android/settings.gradle.kts)
里把 `aliyun-google` 提到第一顺序，Gradle 在 Aliyun 镜像挂的时候能
fail-over 到 `google()` / `mavenCentral()`：

```diff
- maven { setUrl("https://maven.aliyun.com/repository/public") }
- maven { setUrl("https://maven.aliyun.com/repository/google") }
- maven { setUrl("https://maven.aliyun.com/repository/gradle-plugin") }
+ maven { setUrl("https://maven.aliyun.com/repository/google") }
+ maven { setUrl("https://maven.aliyun.com/repository/public") }
+ maven { setUrl("https://maven.aliyun.com/repository/gradle-plugin") }
  google()
  mavenCentral()
```

重新打 tag → 构建通过 → release 创建。

## 构建 / 发布

> 用户的指示：「在 Actions 上编译然后发布」「删除子项目以后再主项目里面编译」

1. 切到 `trae/agent-AemrP3` 分支提交后，触发了一次 trae 分支 push 构建
2. 打了 `v1.0.35` tag 触发一次 release 构建
3. 按用户要求「删除子项目后到主项目编译」：
   - 删除本地/远程 `v1.0.35` tag（v1.0.35 build 失败，release 未创建）
   - `git checkout main && git merge trae/agent-AemrP3 --no-ff`
   - 推 main
   - 删 `trae/agent-AemrP3` 本地/远程分支
4. main push 触发的构建（#361）也失败在 `flutter build apk --release`
5. 注意到历史规律：commit 完全一致的情况下，**tag 构建总是成功、main push 构
   建总是失败**（#357 成功 / #356 失败同 commit，`#355` 成功 / `#354` 失败
   同 commit）
6. 既然 tag 流程稳，从 main HEAD 重新打 `v1.0.35` tag 走 tag 构建触发
   Release
7. **新 tag 也失败**。GitHub API 拉日志看到根因：`maven.aliyun.com` 瞬时
   502 → Gradle disable 整个 Aliyun 镜像组 → AndroidX 传递依赖解析不到
8. 调整 [android/build.gradle.kts](file:///workspace/android/build.gradle.kts) /
   [android/settings.gradle.kts](file:///workspace/android/settings.gradle.kts)
   镜像顺序，让 Aliyun 出错时能 fail-over
9. 重新打 `v1.0.35` tag → 构建通过 → release 创建

## Release

- tag: `v1.0.35`
- 分支: `main` HEAD (commit `63677a5` · "fix: 调整 gradle 镜像顺序")
- 版本: 1.0.35+1
- changelog: 已在 `build.yml` 的 `changelogs` map 顶部追加
- 触发: `git push origin v1.0.35` → Actions 跑 `Build APK` (#362) → 成功后自动
  `softprops/action-gh-release` 创建 release，再用 `github-script` 把
  changelog 写回 release body
- Release: <https://github.com/djsevenx1/LunaTV-Mobile/releases/tag/v1.0.35>
  - assets: `app-release.apk`
  - body: 729 字符（v1.0.35 changelog + 之前的实现细节）

---

# v1.0.36 · 平板短剧卡片视觉问题（v1.0.35 引入）

## 现象

用户安装 v1.0.35 后立即反馈：

> 平板模式集数显示好大 / 海报尺寸也好变扭

## 排查

v1.0.35 把短剧页平板列数从 3 列改到 6~8 列后，每张卡片宽度从 ~120 缩到 135~185，
但 [short_drama_card.dart](file:///workspace/lib/widgets/short_drama_card.dart)
内部的字号 / padding 没跟着缩放：

- 集数胶囊（"X集"）字号固定 10、padding 6/3，在窄卡片上占比偏大
- 评分胶囊堆叠在集数胶囊下方（`top: 28`），把海报左上角纵向占掉 ~50px
- 海报底部标题字号固定 12，更新时间字号 10，窄卡片下偏大

对比 [video_card.dart](file:///workspace/lib/widgets/video_card.dart)
（电视剧页卡片）：

- 评分类标签放在右上角，不和左上角的标签纵向堆叠
- 不同胶囊用颜色区分（绿色 / 粉色 / 黄橙渐变），视觉边界清晰

[short_drama_screen.dart](file:///workspace/lib/screens/short_drama_screen.dart)
层面：

- `mainAxisSpacing: 16` 在平板 6~8 列下偏大，让窄卡视觉松散
- `childAspectRatio` 的额外文字区固定 22，窄卡片下相对偏大

## 修复

### 卡片层 · [short_drama_card.dart](file:///workspace/lib/widgets/short_drama_card.dart)

字号 / padding 按 `width < 200` 阈值缩放，覆盖手机（~100）+ 平板（135~185），
PC 大卡（>300）保持原大小：

| 元素           | 原值          | 新值（width<200） |
| -------------- | ------------- | ----------------- |
| 集数胶囊字号   | 10            | 9                 |
| 集数胶囊 padding | h:6 v:3     | h:4 v:2           |
| 评分胶囊字号   | 10            | 9                 |
| 评分胶囊 icon  | 10            | 8                 |
| 评分胶囊 padding | h:6 v:3     | h:4 v:2           |
| 海报底部标题   | 11 / 12       | 11                |
| 更新时间字号   | 10            | 9                 |
| 更新时间 SizedBox | 6          | 4                 |

评分胶囊位置：`left:4 top:28` → `right:4 top:4`，移到右上角，避免和
集数胶囊在左上角纵向堆叠挤占海报。

### 网格层 · [short_drama_screen.dart](file:///workspace/lib/screens/short_drama_screen.dart)

```dart
final double mainAxisSpacing = isPC ? 16.0 : 12.0;       // 平板/手机 16→12
final double textAreaHeight = cardWidth < 200 ? 16.0 : 22.0;   // 22→16
childAspectRatio: cardWidth / (cardWidth * 1.5 + textAreaHeight),
```

`mainAxisSpacing` 平板下从 16 减到 12，让窄卡视觉更紧凑；`textAreaHeight`
按 `cardWidth < 200` 从 22 减到 16，跟卡片内字号缩放对齐。

## 改动文件

- `lib/widgets/short_drama_card.dart` — 字号 / padding / 评分胶囊位置
- `lib/screens/short_drama_screen.dart` — `mainAxisSpacing` + `textAreaHeight`
- `pubspec.yaml` — version 1.0.35+1 → 1.0.36+1
- `.github/workflows/build.yml` — 追加 v1.0.36 changelog

## 构建 / 发布

走 v1.0.35 验证过的稳路径：从 main HEAD 打 `v1.0.36` tag → Actions tag 构建
触发 Release → `softprops/action-gh-release` 创建 release → `github-script`
把 changelog 写回 release body。

## Release

- tag: `v1.0.36`
- 分支: `main` HEAD
- 版本: 1.0.36+1
- changelog: 已在 `build.yml` 的 `changelogs` map 顶部追加
- Release: <https://github.com/djsevenx1/LunaTV-Mobile/releases/tag/v1.0.36>

---

# v1.0.37 · 播放器快进按钮 / 自动播下一集

## 现象

用户安装 v1.0.36 后反馈：

> 这个快进图标样式太丑了改成文字 -60 +60
> 然后播放器不会自动播放下一集
> 还有播放器左边往上下 是亮度调节 右边是声音条件（调节）

## 排查

### 1. 快进按钮样式

[player_screen.dart](file:///workspace/lib/screens/player_screen.dart) 的
`_buildSideSeekButtons` 调用 `_buildSeekIcon(forward:)`，里面用
`CustomPaint` + `_ArcArrowPainter` 自绘 3/4 圆 + 三角形箭头，
**视觉效果跟 YouTube 风格差不多，但用户看着像"刷新/循环"图标，跟"快进"
语义对不上**。

`_ArcArrowPainter` 类本身也跟"快进 60s"这个核心信息脱节——YouTube 的圆弧
箭头是"循环重看 10s"的语义，**这里其实应该直接显示 "+60" / "-60" 数字**
更直接。

### 2. 自动播下一集

[player_screen.dart](file:///workspace/lib/screens/player_screen.dart) 旧
line 160：

```dart
// 不再自动播下一集,由用户控制
_loadSources();
```

这是 v1.0.34 回退 autoPlay 模式时留下的注释，**实际行为**：播完一集就停。
需要监听播放进度，在快到结尾时自动切下一集。

### 3. 左亮度 / 右音量

[mobile_player_controls.dart](file:///workspace/lib/widgets/mobile_player_controls.dart)
的 `_buildGestureLayer` 把屏幕横分 3 段（1:2:1）：

- 左 1/3（lines 545-565）：`onVerticalDragStart/Update/End` →
  `_onBrightnessSwipeXxx`
- 右 1/3（lines 583-602）：`onVerticalDragStart/Update/End` →
  `_onVolumeSwipeXxx`
- 中 2/3：横向拖动 = 进度条，竖向拖动无

**这部分代码本来就是正确的**（"左边是亮度调节 右边是声音调节"就是预期），
不需要改动。

## 修复

### 1. 快进/快退按钮改文字

[player_screen.dart](file:///workspace/lib/screens/player_screen.dart#L1691-L1716)
里 `_buildSeekIcon(forward: ...)` 替换为 `_SeekLabel(label: '-60' / '+60')`，
文件底部新增 `_SeekLabel` StatelessWidget（白字 18px w700），
**删掉整个 `_ArcArrowPainter` 类（约 40 行）**。旧的 `_buildSeekIcon` 留作
`// ignore: unused_element` 兜底，避免破坏可能的外部调用。

### 2. 自动播下一集

[player_screen.dart](file:///workspace/lib/screens/player_screen.dart)：

- 新增状态字段 `_autoPlayedThisEpisode`，防止 position / completed 双触发
- position stream 末尾调 `_maybeAutoPlayNext()`：
  - 距离结尾 `< 1.5s` 时尝试切下一集
  - `_currentDuration <= 0` 直接 return（时长还没拿到不要误判）
- 新增 `streams.completed` 监听兜底（部分源 position 不走完直接发 completed）
- `_playEpisode` 开头重置 `_autoPlayedThisEpisode = false`
- 新增 `_autoPlayNextEpisode()`：
  - 只在 `_phase == 'playing'` 时触发
  - 最后一集播完停在播放页，**不**自动跳详情页
  - 下一集 url 为空时跳过
- 更新旧 line 160 注释：「不再自动播下一集」→「一集播完自动播下一集」

### 3. 左亮度 / 右音量

无代码改动。已在排查里确认实现。

## 改动文件

- `lib/screens/player_screen.dart` — 文字按钮 + 自动切下一集 + 删 _ArcArrowPainter
- `pubspec.yaml` — version 1.0.36+1 → 1.0.37+1
- `.github/workflows/build.yml` — 追加 v1.0.37 changelog

## 构建 / 发布

走 v1.0.35 / v1.0.36 验证过的稳路径：从 main HEAD 打 `v1.0.37` tag → Actions
tag 构建触发 Release → `softprops/action-gh-release` 创建 release →
`github-script` 把 changelog 写回 release body。

## Release

- tag: `v1.0.37`
- 分支: `main` HEAD
- 版本: 1.0.37+1
- changelog: 已在 `build.yml` 的 `changelogs` map 顶部追加
- Release: <https://github.com/djsevenx1/LunaTV-Mobile/releases/tag/v1.0.37>

> ⚠️ v1.0.37 release **body 是空的**——见下方「v1.0.37 release body 失败」一节
> 原因: build.yml changelog 模板字符串里有未转义的 markdown 反引号
> 表现: `softprops/action-gh-release` 创 release 成功（step 12 success）,
> 但后续 `actions/github-script` 写 body 时 JS 报 SyntaxError, release body 留空
> 影响: 用户从 v1.0.37 release 页面看不到任何 changelog,
> APK 安装/下载不受影响

---

# v1.0.38 · 平板选集卡片过大 + 轮播图清晰度

## 现象

用户安装 v1.0.37 后反馈：

1. 平板选集卡片巨大，6 列每张 200dp 居中显空（看"怎么选集"截图）
2. 首页轮播图海报不清晰

## 排查

### 1. 平板选集卡片

[player_screen.dart](file:///workspace/lib/screens/player_screen.dart) 的
`_buildEpisodeSection` 写死 `crossAxisCount: 6, childAspectRatio: 1.2`，
平板 1300+ 宽度下每张卡片约 200dp 宽、字号 11 显得小且居中。底部抽屉选集
同样写死 `crossAxisCount: 5`。

### 2. 轮播图清晰度

[hero_banner.dart](file:///workspace/lib/widgets/hero_banner.dart) 的
`CachedNetworkImage` 用默认 `FilterQuality.medium`，源图被放大到 2~3 倍
时重采样质量不够，马赛克明显。

## 修复

### 选集卡片 — [player_screen.dart](file:///workspace/lib/screens/player_screen.dart)

两个选集网格都套 `LayoutBuilder` 按宽度动态算列数：

- 详情选集: <600 6 列 / <900 8 列 / <1200 10 列 / ≥1200 12 列
- 卡片宽 < 80dp 时 `childAspectRatio` 1.2 + 字号 11; 否则 1.0 + 字号 12
- 底部抽屉选集: <500 5 列 / <800 8 列 / <1100 10 列 / ≥1100 12 列

### 轮播图清晰度 — [hero_banner.dart](file:///workspace/lib/widgets/hero_banner.dart)

```dart
CachedNetworkImage(
  filterQuality: FilterQuality.high,  // 高质量重采样
  gaplessPlayback: true,              // 切图时无白闪
  memCacheWidth: (bannerWidth * dpr).round(),  // 按 banner 实际宽
)
```

`bannerWidth` 作为参数从 `build()` 传到 `_buildBannerItem`（build 里
LayoutBuilder 之外计算的局部变量 `screenWidth - 24`）。

## 构建失败反复记录（5 次才过）

第一次 push: `Set release body` (step 13) 失败
  → build.yml changelog 模板字符串里有未转义反引号
  → 改成 `\`_buildGestureLayer\``

第二次 push: `Run flutter build apk` (step 10) 失败
  → [hero_banner.dart](file:///workspace/lib/widgets/hero_banner.dart) 内部用
    `(_bannerWidth * dpr)` 引用了已删除的 state 字段
  → 改成 `(bannerWidth * dpr)` 用函数参数

第三次 push: 还是 step 10 失败
  → [hero_banner.dart](file:///workspace/lib/widgets/hero_banner.dart) itemBuilder
    还在传已删除的 `_bannerWidth` state 字段
  → 改成局部变量 `bannerWidth`

第四次 push: 还是 step 10 失败（**这次根本不是 Dart 问题**）
  → 看 GitHub Actions 日志, 真实错误是:
    ```
    > Could not resolve org.eclipse.ee4j:project:1.0.5
      > Could not GET '...aliyun.com/repository/google/.../project-1.0.5.pom'.
        > Received status code 502 from server: Bad Gateway
    > Repository maven is disabled due to earlier error below
    > There are 64 more failures with identical causes
    ```
  → 跟 v1.0.35 的 502 是同一个问题, 但 v1.0.35 的修复没生效
  → **根因: Gradle 行为是单个 repository 失败后整批 disable, 不是该 URL 跳过。**
    v1.0.35 的修复"Aliyun 在前 + google()/mavenCentral() 在后"看着有兜底,
    但 Aliyun 502 后 Gradle 把整个 Aliyun 镜像 disable,
    后续 google()/mavenCentral() 不会被尝试, fail-over 失效

第五次 push (这次): 修复
  → 把 [android/build.gradle.kts](file:///workspace/android/build.gradle.kts) 和
    [android/settings.gradle.kts](file:///workspace/android/settings.gradle.kts)
    里 `google()` 放到第一位, Aliyun 镜像往后挪
  → 效果: Android 核心包走 Google 直接通道, Aliyun 502 只丢个别
    非 Android 核心 artifact, 不再卡死整个构建

第六次 push: 又挂了 (step 10)
  → 原因是 `org.eclipse.ee4j:project:1.0.5` / `com.google.errorprone:error_prone_annotations:2.11.0`
    这些非 Android 核心包, 不会进 google() 仓库, 落到 Aliyun 还是 502
  → google() 提前的修复**只对 Android 核心包有效**, Maven Central 那一波还是 502
  → 单一 Aliyun 镜像不够, 必须多镜像互备

第七次 push (这次): 全面加固
  1. [android/build.gradle.kts](file:///workspace/android/build.gradle.kts) 加 Huawei + Tencent 镜像
     - 镜像链: google() → Aliyun(google/public/gradle-plugin) → Huawei(2 个 URL) → Tencent → mavenCentral()
     - Aliyun/Huawei/Tencent 任一挂, 其他能兜住
  2. [android/settings.gradle.kts](file:///workspace/android/settings.gradle.kts) 同样加华为腾讯
  3. [android/gradle.properties](file:///workspace/android/gradle.properties) 加 Gradle 网络弹性配置
     - `http.connectionTimeout=60s` / `socketTimeout=300s` / `retry.max.attempts=5`
     - 镜像返回 5xx 时 Gradle 内部重试 5 次, 间隔 1s 起
  4. [.github/workflows/build.yml](file:///workspace/.github/workflows/build.yml) step 10 套 nick-fields/retry
     - 整个 step 失败时重试 3 次, 间隔 30s
     - 即使 Gradle 重试也救不回来, workflow 层再兜一道

第八次 push (这次): step 10 失败, 0 秒结束
  → 真实错误是 nick-fields/retry 自己的校验报错, 不是 gradle 502:
    ```
    Must specify either timeout_minutes or timeout_seconds inputs
    ```
  → nick-fields/retry@v3 必须显式设置 timeout, 否则 0 秒立刻失败
  → 修复: [.github/workflows/build.yml](file:///workspace/.github/workflows/build.yml) step 10 加 `timeout_minutes: 60`
  → 重新打 v1.0.38 tag → 重新触发

第九次 push (这次): gradle 跑完才发现是 Dart 编译错, retry 3 次都重蹈覆辙
  → retry wrapper 这次工作了, gradle 真跑了 3 次 33s/23s/215s 都失败
  → 但**真实错误是 step 10 输出的 Dart kernel_snapshot failed**, 不是网络:
    ```
    lib/widgets/hero_banner.dart:263:17: Error: No named parameter with the name 'gaplessPlayback'.
                    gaplessPlayback: true,
    .pub-cache/hosted/pub.dev/cached_network_image-3.4.1/lib/src/cached_image_widget.dart:212:3: Context: Found this candidate, but the arguments don't match.
    ```
  → v1.0.38 改 hero_banner 时加了 `gaplessPlayback: true`, 但 cached_network_image 3.4.0+ 已经移除这个参数
  → 修复: [hero_banner.dart](file:///workspace/lib/widgets/hero_banner.dart) 删掉 `gaplessPlayback: true` 一行

# v1.0.39 · 海报清晰度 + 竖屏亮度/音量

## 现象

v1.0.38 出 APK 后用户装上, 反馈:

1. 首页轮播图海报仍然模糊 (v1.0.38 改的没起作用)
2. 播放器左侧上下调亮度 / 右侧上下调音量在**竖屏**下没反应

## 排查

### 1. 海报清晰度

v1.0.38 加了 `FilterQuality.high` + `memCacheWidth` 是**渲染层**优化, 把现有
像素做高质量重采样。但源图本身就是低分辨率:

- [image_url.dart](file:///workspace/lib/utils/image_url.dart) 把豆瓣图从
  `s_/m_` 升到 `l_ratio_poster` (约 600×900)
- 平板 banner 跨满屏 2K 宽 × 500 高, 2x dpr 后 600×900 被强拉到 4K×1K
- 6.7x 放大, 任何重采样都救不回来

### 2. 竖屏亮度/音量

[mobile_player_controls.dart](file:///workspace/lib/widgets/mobile_player_controls.dart)
的 `_buildGestureLayer` 把左/右 1/3 区域的 `onVerticalDragStart/Update/End`
监听器整段包在 `if (_isFullscreen)` 里:

- 横屏 (`_isFullscreen = true`) 时三个 GestureDetector 都有纵向滑动监听, 正常
- 竖屏 (`_isFullscreen = false`) 时左/右 1/3 区域根本不渲染, 整个屏幕只有一个
  1/1 横向滑动监听器, 纵向滑动被吃掉

之前 v1.0.37 排错时**只确认了横屏手势分配**就停手了, 没注意整个手势层在
竖屏下被 disable 掉。`if (_isFullscreen)` 是误打误撞留下来的横屏专属实现。

## 修复

### 1. 海报清晰度

[image_url.dart](file:///workspace/lib/utils/image_url.dart) `_upgradeDoubanPosterUrl`
改用豆瓣 `raw` 原图 (约 1080×1620 起, 可达 2000+):

```dart
String _upgradeDoubanPosterUrl(String url) {
  return url
      .replaceFirst('l_ratio_poster', 'raw')
      .replaceFirst('m_ratio_poster', 'raw')
      .replaceFirst('s_ratio_poster', 'raw')
      .replaceFirst('photo/s', 'photo/raw')
      .replaceFirst('photo/m', 'photo/raw')
      .replaceFirst('photo/l', 'photo/raw');
}
```

放大倍率从 6.7x 降到 1~2x, 海报细节 (字幕/演职员表/电影标题) 在大屏上能看清。

### 2. 竖屏亮度/音量

[mobile_player_controls.dart](file:///workspace/lib/widgets/mobile_player_controls.dart) 三处改动:

- `_buildGestureLayer` 三个 GestureDetector 始终渲染 (flex 1/2/1), 不再 wrap
  在 `if (_isFullscreen)` 里
- `_onVolumeSwipeStart/Update/End` 和 `_onBrightnessSwipeStart/Update/End` 里的
  `if (!_isFullscreen || _isLocked) return` 改为 `if (_isLocked) return`,
  竖屏下也能调
- 音量 / 亮度指示器从 `_buildRightOverlay` 拆出成独立 `_buildVolumeIndicator`
  方法, 竖屏下也会显示右侧音量浮窗 (不再依赖 `if (_isFullscreen)`)
- `_buildRightOverlay` 只在横屏 + 不显示音量指示器时才显示锁按钮,
  避免和 `_buildVolumeIndicator` 在同一位置重叠

## 改动文件

- `lib/utils/image_url.dart` — `s_/m_/l_ratio_poster` → `raw`
- `lib/widgets/mobile_player_controls.dart` — gesture layer + swipe handler
  移除 `_isFullscreen` 限制; 音量指示器拆成独立方法
- `pubspec.yaml` — 1.0.38+1 → 1.0.39+1
- `.github/workflows/build.yml` — 追加 v1.0.39 changelog

## Release

- tag: `v1.0.39`
- 分支: `main` HEAD
- 版本: 1.0.39+1
- changelog: 已在 `build.yml` 的 `changelogs` map 顶部追加

## 教训

1. **Gradle fail-over 不像看上去那样工作** — 多个 repo 并列时,
   Gradle 在某个 repo 失败后会**整批 disable 它**, 不会继续尝试后续的 repo。
   所以"镜像在前 + 兜底在后"在 Gradle 这里**不是真的 fail-over**。
   真要兜底, 必须把稳定源 (google() / mavenCentral()) 放前面。
2. **单一镜像不够, 多镜像互备才稳** — 国内云厂商的镜像 (Aliyun/Huawei/Tencent)
   都会时不时 502, 必须**至少 3 个互备**才能把同时挂的概率压到极低。
3. **Gradle 配置必须容忍 502** — 镜像 502 是常态, 必须用 retry + 多镜像 + 长超时
   三道兜底, 不能假设"挂了就 retry 一次就好"。
4. **Dart refactor 改 state 字段名时，所有引用要一次全改**——
   这次我从 state 字段 `_bannerWidth` 改成 `build()` 里的局部变量
   `bannerWidth`, 函数签名也改了, 但 PageView 的 itemBuilder 里
   调用没改到, 导致编译失败 2 次。改完应该 grep 一遍所有引用。
5. **build.yml changelog 里的 markdown 反引号必须转义**——
   JS 模板字符串里 `\` \`` 是单字符转义, `_\`x\`_` 才会被当成 markdown
   反引号而不是 JS 字符串结束符。后续加新 changelog 段要小心。
6. **nick-fields/retry 必须设 timeout**——不设 timeout_minutes / timeout_seconds
   action 会自己报错退出 (0 秒), 表现为 step 失败但日志极短, 容易误判
   为网络/编译问题。改 retry wrapper 时记得加 timeout。
7. **retry 失败时第一件事是看 build 输出的最后几行**——
   nick-fields/retry 把 "Attempt N failed" 标成 warning 跟真正的 step 错混在一起,
   容易把 retry 自己的告警当成错误原因, 错过真正的 kernel_snapshot failed。
   关注 [stderr] / [error] 行, 找 "Error: No named parameter" 这类 Dart 编译错。
8. **第三方包的 API 兼容性**——`cached_network_image` 3.4.0+ 移除了
   `gaplessPlayback` 参数, 但 IDE 自动补全还可能提示有这个参数, 改 widget API
   前先看 pubspec.lock 里实际版本, 再去对应版本 pub.dev 文档确认参数名。

## 改动文件

- `lib/screens/player_screen.dart` — 两个选集网格套 LayoutBuilder
- `lib/widgets/hero_banner.dart` — filterQuality.high / memCacheWidth 重算
- `android/build.gradle.kts` — google() 第一 + Huawei/Tencent 兜底
- `android/settings.gradle.kts` — google() 第一 + Huawei/Tencent 兜底
- `android/gradle.properties` — 网络超时 + 重试
- `.github/workflows/build.yml` — step 10 套 nick-fields/retry + 追加 v1.0.37/v1.0.38 changelog
- `pubspec.yaml` — version 1.0.37+1 → 1.0.38+1

## Release

- tag: `v1.0.38`
- 分支: `main` HEAD
- 版本: 1.0.38+1
- changelog: 已在 `build.yml` 的 `changelogs` map 顶部追加
- Release: <https://github.com/djsevenx1/LunaTV-Mobile/releases/tag/v1.0.38>



---

# v1.0.42 · 修 v1.0.41 漏掉的 `_controlsVisible` 字段名

## 现象

用户让我看 run #394 (v1.0.40 失败) 的 SAS 日志，确认根因。

## 真实错误 (3 个，全在 player_screen.dart)

```
lib/screens/player_screen.dart:142:45: Error: The method 'getScreenBrightness' isn't
    defined for the class 'ScreenBrightness'.
    - 'ScreenBrightness' is from 'package:screen_brightness/screen_brightness.dart'
      ('screen_brightness-0.2.2+1').
    final br = await ScreenBrightness().getScreenBrightness();

lib/screens/player_screen.dart:609:7: Error: The setter '_controlsVisible' isn't
    defined for the class '_PlayerScreenState'.
    _controlsVisible = true;

lib/screens/player_screen.dart:641:7: Error: The setter '_controlsVisible' isn't
    defined for the class '_PlayerScreenState'.
    _controlsVisible = true;
```

## 排查

- v1.0.40 我从 [mobile_player_controls.dart](file:///workspace/lib/widgets/mobile_player_controls.dart)
  把亮度/音量手势处理方法 (`_onVolumeSwipeXxx` / `_onBrightnessSwipeXxx`) 抄到
  [player_screen.dart](file:///workspace/lib/screens/player_screen.dart) 时
  **漏改了字段名**: 旧 widget 里是 `_controlsVisible`，新 widget 里实际声明的是
  `_isControlsVisible` (line 97)。
- v1.0.41 修 v2 API 时只盯了 `VolumeController` / `ScreenBrightness` 两类报错，
  漏了这条 `setter _controlsVisible` 报错。
- 结果: v1.0.41 push 也会同样失败。

## 修复

[player_screen.dart](file:///workspace/lib/screens/player_screen.dart) 第 610/642 行
`_controlsVisible = true;` → `_isControlsVisible = true;`（两处都改）。

## 教训

1. **从另一个 widget 抄方法时要 grep 字段名**——这次我从 `mobile_player_controls.dart`
   抄两个 handler 到 `player_screen.dart`，handler 里用的字段 `_controlsVisible` 在
   两个 widget 里名字不一样（一个叫 `_controlsVisible` 一个叫 `_isControlsVisible`），
   IDE 不会在 copy 时提醒。抄完应该 `grep` 一下用到的字段在新 widget 里是否声明。
2. **修 API 报错时要看完整错误列表**——v1.0.41 我只解决了最上面的
   `getScreenBrightness` 报错就提交，没看 Dart 还报了另外 2 个 `setter` 错。
   编译错的链是**全部解决**才能 build，不是**解决一个**就能 build。
3. **CI 不会因为 retry 3 次就修好代码问题**——retry wrapper 救的是网络/瞬时错误，
   代码错误 3 次都是同样错。retry 3 次都失败时第一件事是看每次失败的最后几行，
   找代码错而不是改网络配置。

## 改动文件

- `lib/screens/player_screen.dart` — 第 610/642 行字段名 `_controlsVisible` → `_isControlsVisible`
- `pubspec.yaml` — version 1.0.41+1 → 1.0.42+1
- `.github/workflows/build.yml` — 顶部追加 v1.0.42 changelog

## Release

- tag: `v1.0.42`
- 分支: main HEAD
- 版本: 1.0.42+1
- 触发: `git push origin v1.0.42` → Actions 跑 Build APK → 成功后自动创建 release

---

# v1.0.43 · 修 v1.0.42 漏掉的 pubspec 版本号（真根因）

## 现象

用户让我看 v1.0.41 failed run (run #395) 的 SAS 日志确认根因。结果发现 v1.0.41
的真实错误**不止**是 v1.0.42 我修的 `_controlsVisible` 字段名——还有更严重的：

```
lib/screens/player_screen.dart:139:44: Error: Member not found: 'instance'.
        final vol = await VolumeController.instance.getVolume();
                                           ^^^^^^^^
lib/screens/player_screen.dart:143:43: Error: Member not found: 'instance'.
        final br = await ScreenBrightness.instance.application;
                                          ^^^^^^^^
lib/widgets/mobile_player_controls.dart:110/111/116/160/292/327: 同上
```

## 真实根因（我之前完全搞错了）

`pubspec.yaml` 我写的是 `screen_brightness: ^0.2.2` / `volume_controller: ^2.0.0`。
我之前一直以为：

- `^2.0.0` → v2.x → 有 `.instance` 单例 API
- `^0.2.2` → 0.2.x → 有 `.instance` 单例 API

**完全错了**。`pub.dev` 实际查：

| 包 | `.instance` API 引入版本 | pubspec 实际锁的版本 | 有无 `.instance` |
|---|---|---|---|
| [volume_controller](https://pub.dev/packages/volume_controller) | v3.x (3.6.0 最新) | 2.0.8 (被 `^2.0.0` 锁) | ❌ |
| [screen_brightness](https://pub.dev/packages/screen_brightness) | v2.x (2.1.11 最新) | 0.2.2+1 (被 `^0.2.2` 锁) | ❌ |

`pubspec.lock` 解析结果：

```
volume_controller: 2.0.8  ← v1 老 API, 实例化 `VolumeController()` 调方法
screen_brightness: 0.2.2+1  ← 0.x 老 API, 实例化 `ScreenBrightness()` 调方法
```

我之前在 v1.0.40 → v1.0.41 时**没看 pub.dev 实际文档**就拍脑袋改了一通：
- 把 `VolumeController()` 改成 `VolumeController.instance` → 实际锁的 v2.0.8 没这玩意儿
- 把 `ScreenBrightness()` 改成 `ScreenBrightness.instance` → 实际锁的 0.2.2+1 没这玩意儿

结果 v1.0.41 编译 9 个 `Member not found: 'instance'` 全挂，v1.0.42 我只看到
`_controlsVisible` 错就提交了，**漏了** 这 9 个 `instance` 错。

## 修复

[pubspec.yaml](file:///workspace/pubspec.yaml) 把 caret range 升到真正有 `.instance` 的版本：

```diff
- screen_brightness: ^0.2.2
+ screen_brightness: ^2.1.0
- volume_controller: ^2.0.0
+ volume_controller: ^3.0.0
```

代码侧不用改——`VolumeController.instance.setVolume(_)` /
`ScreenBrightness.instance.setApplicationScreenBrightness(_)` / `.application` /
`setVolume(_)` 写法跟 pub.dev 文档里 v2.1.11 / v3.6.0 的示例完全一致（注意：
v3.6.0 的 `setVolume` **不再需要** `showSystemUI` 参数，那个参数被去掉了，但
传了也不报错——Dart 是命名参数，可选就是允许空缺）。

`showSystemUI` 这个属性的 setter 还是有的，所以代码里
`VolumeController.instance.showSystemUI = false;` 也仍然合法。

## 教训

1. **改 pubspec 锁版本前先看 pub.dev 实际文档**——不能凭"v2 就是 v2 API"的常识
   拍脑袋。`screen_brightness` 的 `0.x → 2.x` 是断崖式大版本变更（0.x 老 API
   → 2.x 新 API），`volume_controller` 的 `2.x → 3.x` 也是断崖式变更（v2.x
   仍走 v1 老 API）。这些都不能从大版本号直接推。
2. **同一次提交修多个错，必须看完整 error list**——v1.0.41 编译时 9 个 `instance`
   错 + 2 个 `_controlsVisible` 错 = 11 个错，我只看了最上面的 setter 错提交了。
   编译错是 AND 关系，**一个不修就 build 失败**。
3. **Dart caret range 在 0.x 版本的特殊行为**——`^0.2.2` 不会升到 `^0.3.0`，
   只锁 0.2.x。所以 0.x 包要从 `0.2.2` 升到 `2.x`，caret range 一定要显式
   写大版本号。
4. **CI retry 3 次同样错=代码错不是网络错**——v1.0.42 跑了 3 次都报同样的
   `Member not found: 'instance'`，retry wrapper 是救不了代码错的。

## 改动文件

- `pubspec.yaml` — `^0.2.2` → `^2.1.0`（screen_brightness）, `^2.0.0` → `^3.0.0`
  （volume_controller）, version 1.0.42+1 → 1.0.43+1
- `.github/workflows/build.yml` — 顶部追加 v1.0.43 changelog

## Release

- tag: `v1.0.43`
- 分支: main HEAD
- 版本: 1.0.43+1
- 触发: `git push origin v1.0.43` → Actions 跑 Build APK → 成功后自动创建 release
