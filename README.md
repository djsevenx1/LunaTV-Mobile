# LunaTV Mobile

> 一款基于 Flutter 的 LunaTV 移动端 / 桌面端客户端,跨平台支持 Android、iOS、macOS、Windows、Linux 和 Web。

LunaTV Mobile 是 [LunaTV](https://github.com/MoonTechLab/LunaTV) Web 版的官方移动端实现,提供一致的浏览体验和多端同步能力,主打开箱即用的多源聚合搜索 + 高质量本地播放。

## 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| Android | ✅ | 主目标,arm64-v8a / armeabi-v7a 拆分包 |
| iOS | ✅ | 未签名 IPA,需自行签名安装 |
| macOS | ✅ | ARM64 / x86_64 双架构 DMG |
| Windows | ✅ | 通过 Flutter Desktop |
| Linux | ✅ | 通过 Flutter Desktop |
| Web | ✅ | 通过 Flutter Web |

## 主要功能

### 内容浏览
- **首页轮播 + 多分区**:继续播放、热门电影、热门剧集、新番放送(Bangumi)、热门综艺、热门短剧
- **分类筛选**:电视剧/电影/综艺/动漫 多种筛选维度(类型、地区、年代、平台、排序)
- **短剧专区**:独立分类聚合,横滑切换
- **搜索**:全局搜索,跨源聚合结果
- **排行榜**:豆瓣热门内容

### 播放能力
- 基于 [media_kit](https://github.com/media-kit/media-kit) 的高性能播放器
- 自动判断视频横竖屏比例(`AspectRatio` + `SystemChrome`)
- 全屏沉浸式 + 系统 UI 自动隐藏/恢复
- 多源搜索播放(短剧点击直接进 PlayerScreen 走多源聚合)
- 断点续看 + 播放进度同步
- DLNA 投屏支持(`dlna_dart`)
- 选集 / 选源 / 详情面板一体化

### 账号与同步
- 自定义后端 API 地址(支持官方 / 自部署)
- 收藏 / 播放历史 / 搜索记录 本地持久化 + 服务器同步
- 多用户隔离(UserDataService)
- 主题切换(深色 / 浅色)

### 高级特性
- 豆瓣图片源切换:`official_cdn` / `cdn_tencent` / `cdn_aliyun` / `direct`
- Bangumi 图片自动升级 HTTPS + User-Agent(`lain.bgm.tv` 强制 UA)
- 豆瓣小图自动升级为 `l_ratio_poster` 大图(首页轮播等大图场景)
- 图片内存缓存按 `devicePixelRatio × 显示尺寸` 精确解码,避免模糊与内存浪费

## 截图预览

> 见仓库 `screenshots/` 目录(如有)或 GitHub Actions 构建产物中的运行截图

## 快速开始

### 环境要求

- Flutter SDK `3.22.2` 或更高
- Java JDK 17(Android 构建)
- Android SDK Platform 36 + Build-Tools 34.0.0
- Android NDK `29.0.14033849`(可选,媒体插件需要)
- Xcode 15+(iOS / macOS)

### 拉取代码

```bash
git clone https://github.com/djsevenx1/LunaTV-Mobile.git
cd LunaTV-Mobile
flutter pub get
```

### 本地构建

```bash
# 仅 Android APK
./build.sh --android-only

# 仅 iOS(未签名)
./build.sh --ios-only

# 仅 macOS(ARM64)
./build.sh --macos-arm64-only

# 仅 macOS(x86_64)
./build.sh --macos-x86-64-only

# 仅 Apple 平台(iOS + macOS,需要 macOS 主机)
./build.sh --apple-only

# 全平台并行构建(仅 macOS 主机)
./build.sh
```

直接调用 Flutter:

```bash
flutter run                       # 连接设备调试
flutter build apk --release       # Android
flutter build ios --release       # iOS
flutter build macos --release     # macOS
flutter build web                 # Web
```

### 输出产物

- Android APK: `build/app/outputs/flutter-apk/app-release.apk`(arm64-v8a + armeabi-v7a 拆分)
- iOS: `build/ios/iphoneos/Runner.ipa`(未签名)
- macOS DMG: `build/macos/Build/Products/Release/LunaTV-*.dmg`

## 项目结构

```
lib/
├── main.dart                  # 应用入口
├── app.dart                   # MaterialApp 配置
├── models/                    # 数据模型
│   ├── video_info.dart        # 视频信息(电影 / 剧集 / 短剧统一)
│   ├── play_record.dart       # 播放记录
│   ├── search_result.dart     # 搜索结果
│   ├── short_drama.dart       # 短剧模型
│   ├── douban_movie.dart      # 豆瓣模型
│   └── ...
├── services/                  # 服务层
│   ├── api_service.dart       # 主 API 服务
│   ├── douban_service.dart    # 豆瓣
│   ├── short_drama_service.dart   # 短剧
│   ├── theme_service.dart     # 主题
│   ├── user_data_service.dart # 用户数据
│   └── ...
├── screens/                   # 页面
│   ├── home_screen.dart       # 首页
│   ├── player_screen.dart     # 播放器页
│   ├── tv_screen.dart         # 剧集页
│   ├── short_drama_screen.dart    # 短剧页
│   ├── douban_detail_screen.dart  # 豆瓣详情
│   └── ...
├── widgets/                   # 通用组件
│   ├── hero_banner.dart       # 首页轮播
│   ├── video_card.dart        # 视频卡片
│   ├── short_drama_card.dart  # 短剧卡片
│   ├── player_sources_panel.dart
│   ├── player_details_panel.dart
│   ├── player_episodes_panel.dart
│   ├── hot_movies_section.dart
│   ├── hot_tv_section.dart
│   ├── bangumi_section.dart
│   ├── hot_short_drama_section.dart
│   ├── hot_show_section.dart
│   ├── recommendation_section.dart
│   └── ...
└── utils/                     # 工具
    ├── image_url.dart         # 图片 URL 处理(豆瓣 CDN 切换 / Bangumi UA / 大图升级)
    ├── font_utils.dart        # 字体工具
    └── device_utils.dart      # 设备工具
```

## CI/CD

GitHub Actions 在 `main` 分支每次 push 时自动构建并上传 APK 制品。

工作流文件: [.github/workflows/build.yml](.github/workflows/build.yml)

- Flutter: `3.22.2`
- JDK: Temurin 17
- Android SDK: 36
- Build-Tools: 34.0.0
- NDK: 29.0.14033849

构建产物在每个 run 的 Artifacts 区域下载(`app-release`)。

## 关键技术点

### 1. 图片 URL 统一处理

所有 `CachedNetworkImage` 的 URL 都会经过 [image_url.dart](lib/utils/image_url.dart) 处理:

```dart
getImageUrl(originalUrl, source, { upgradeDouban: false })
```

- **Douban**:根据用户配置替换 CDN 域名;`upgradeDouban: true` 时把 `s_ratio_poster` 升级为 `l_ratio_poster`(~600×900)
- **Bangumi**:协议相对 URL `//lain.bgm.tv/...` 升级为 HTTPS;自动追加 User-Agent(`lain.bgm.tv` 强制要求)
- **其他**:原样返回

`getImageRequestHeaders(url, source)` 返回对应源的请求头(Referer / UA)。

### 2. 播放器多源聚合

短剧 / 搜索结果点击进入 [PlayerScreen](lib/screens/player_screen.dart),自动按 `searchTitle` 在所有启用的视频源中搜索最优源,再回到选源 / 选集 / 播放流程。

### 3. 全屏方向自适应

根据视频实际宽高判断:
- 竖屏视频(高 > 宽):保持竖屏
- 横屏视频(宽 > 高):切横屏

参考 LunaTV Web 版 `ArtPlayer.autoOrientation` 实现,配合 `SystemChrome.setEnabledSystemUIMode(immersiveSticky)` 实现完整沉浸式全屏。

## 配置说明

应用首次启动会引导用户配置:
- **API 地址**:你的 LunaTV 服务地址(官方或自部署)
- **豆瓣图片源**:`official_cdn` / `cdn_tencent` / `cdn_aliyun` / `direct`
- **主题**:浅色 / 深色 / 跟随系统

可在「设置」页面随时修改。

## 贡献

欢迎 PR / Issue。请确保:
1. 通过 `flutter analyze`
2. 通过 `flutter test`(如添加了测试)
3. Commit 消息清晰,符合项目历史风格(参考 `feat: ...` / `fix: ...` / `refactor: ...`)

## 许可证

本项目使用 AGPL-3.0 许可证,与上游 LunaTV 保持一致。

## 致谢

- [LunaTV](https://github.com/MoonTechLab/LunaTV) — 原始 Web 项目
- [media_kit](https://github.com/media-kit/media-kit) — Flutter 媒体播放
- [dlna_dart](https://github.com/dlna-dart/dlna_dart) — DLNA 投屏
- [cached_network_image](https://github.com/Baseflow/flutter_cached_network_image) — 网络图片缓存
- [Bangumi](https://bangumi.tv/) — 番剧数据源
- [豆瓣](https://movie.douban.com/) — 影评与海报源

---

Made with ❤️ by the LunaTV Mobile contributors