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

