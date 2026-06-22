# LunaTV Mobile

> 一款基于 Flutter 的 LunaTV 移动端 / 桌面端客户端,跨平台支持 Android、iOS、macOS、Windows、Linux 和 Web。

主打开箱即用的多源聚合搜索 + 高质量本地播放,搭配 **[CORSAPI](https://github.com/djsevenx1/CORSAPI)** 配套 CF Worker 解决 Bangumi / 源加速 / m3u8 重写。

## 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| Android | ✅ | 主目标,arm64-v8a / armeabi-v7a 拆分包, GitHub Actions 自动出 APK 发 Release |
| iOS | ⚠️ | 代码层面支持,但本仓库 CI 只跑 ubuntu-latest,不出 IPA。要 iOS 包请自行在 macOS 主机 `./build.sh --ios-only` |
| macOS | ⚠️ | 同上,代码支持,需自行在 macOS 主机 `./build.sh --macos-arm64-only` / `--macos-x86-64-only` |
| Windows | ⚠️ | 代码支持,但 Linux 主机跑不了(需 Windows 主机 + Visual Studio),未验证 |
| Linux | ⚠️ | 代码支持,需 Linux 主机 + GTK 头文件,未验证 |
| Web | ⚠️ | 代码支持,理论上 `flutter build web` 可出,但 media_kit / dlna_dart 在 Web 平台有限制,未验证 |

> **现实情况**:目前只 Android 是开箱即用、出包的。其他平台「代码层面」能编,但**没在 CI 里跑过**,也没出 release。要 macOS DMG / Windows installer / Web 包需要你自己拉代码到对应平台编译。

## 主要功能

### 内容浏览
- **首页轮播 + 多分区** — 继续播放、热门电影、热门剧集、新番放送(Bangumi)、热门综艺、热门短剧
- **分类筛选** — 电视剧 / 电影 / 综艺 / 动漫 多种筛选维度(类型、地区、年代、平台、排序)
- **短剧专区** — 独立分类聚合,横滑切换
- **搜索** — 全局搜索,跨源聚合结果
- **排行榜** — 豆瓣热门内容

### 播放能力
- 基于 [media_kit](https://github.com/media-kit/media-kit) 的高性能播放器
- 自动判断视频横竖屏比例(`AspectRatio` + `SystemChrome`)
- 全屏沉浸式 + 系统 UI 自动隐藏/恢复
- 多源搜索播放(短剧点击直接进 PlayerScreen 走多源聚合)
- **播放源去重** — 后端同 `source` key 注册多个 API 时,前端按 key 去重保留集数最多的(避免 3 个「爱奇艺」)
- 断点续看 + 播放进度同步
- DLNA 投屏支持(`dlna_dart`)
- 选集 / 选源 / 详情面板一体化
- **返回时主动 stop player** — 从播放视图返回详情视图时 player.stop() + 退全屏,后台不再继续播

### 账号与同步
- 自定义后端 API 地址(支持官方 / 自部署)
- 收藏 / 播放历史 / 搜索记录 本地持久化 + 服务器同步
- 多用户隔离(UserDataService)
- 主题切换(深色 / 浅色)

### 高级特性

#### 🌐 CF Worker 加速 + Bangumi 代理

搭配配套的 [CORSAPI](https://github.com/djsevenx1/CORSAPI) Cloudflare Worker,菜单填入 worker 域名即可启用:

| 模块 | 走法 |
|---|---|
| **CF Worker 加速(源测速 / m3u8)** | 走 worker `/m3u8?url=` 端点,自动重写 .ts 链接 |
| **Bangumi 数据(api.bgm.tv/calendar + /v0/subjects/...)** | worker → ciao-cors → 直连, 多级 fallback |
| **Bangumi 图片(lain.bgm.tv)** | worker, 自动补 `App/Version (URL)` UA + `Referer: https://bgm.tv/` |

> **关键**:CF Worker 域名配了,即使「CF Worker 加速」开关关着,Bangumi 代理也会生效(只认域名不认开关,符合预期)。

#### 📷 图片源
- **豆瓣图片源**:`official_cdn` / `cdn_tencent` / `cdn_aliyun` / `direct`
- **Bangumi 数据源**:`直连` / `Cors Proxy By Zwei` / `CF Worker 加速`
- **Bangumi 图片源**:`直连` / `Cors Proxy By Zwei` / `CF Worker 加速`
- Bangumi 强制补 `LunaTV-Mobile/1.0 (https://github.com/...)` UA(api.bgm.tv v0 API 严格校验)
- 豆瓣小图自动升级为 `l_ratio_poster` 大图(首页轮播等大图场景)
- 图片内存缓存按 `devicePixelRatio × 显示尺寸` 精确解码,避免模糊与内存浪费

#### 📲 软件更新
- 检查更新从 GitHub API `assets` 抽 `.apk` 直链
- 「下载并安装 vX.X.X」按钮直接走系统下载管理器,不用跳浏览器
- 拿不到 apk 链接才 fallback 到 release 详情页

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
├── main.dart                  # 应用入口 (含 UserDataService.warmupCfWorkerConfig)
├── app.dart                   # MaterialApp 配置
├── models/                    # 数据模型
│   ├── video_info.dart        # 视频信息(电影 / 剧集 / 短剧统一)
│   ├── play_record.dart       # 播放记录
│   ├── search_result.dart     # 搜索结果
│   ├── short_drama.dart       # 短剧模型
│   ├── douban_movie.dart      # 豆瓣模型
│   └── ...
├── services/                  # 服务层
│   ├── api_service.dart       # 主 API 服务 (含播放源去重)
│   ├── bangumi_service.dart   # Bangumi (calendar / subjects, 多级 fallback)
│   ├── douban_service.dart    # 豆瓣
│   ├── short_drama_service.dart   # 短剧
│   ├── theme_service.dart     # 主题
│   ├── user_data_service.dart # 用户数据 (含 CF Worker 配置缓存)
│   ├── version_service.dart   # 版本检测 (从 GitHub API 抽 APK 直链)
│   └── ...
├── screens/                   # 页面
│   ├── home_screen.dart       # 首页
│   ├── player_screen.dart     # 播放器页 (PopScope stop player)
│   ├── tv_screen.dart         # 剧集页
│   ├── short_drama_screen.dart    # 短剧页
│   ├── douban_detail_screen.dart  # 豆瓣详情
│   └── ...
├── widgets/                   # 通用组件
│   ├── hero_banner.dart       # 首页轮播
│   ├── video_card.dart        # 视频卡片
│   ├── user_menu.dart         # 用户菜单 (CF Worker 加速 / Bangumi 源 / 优选测速)
│   ├── update_dialog.dart     # 更新弹窗 (直接下 APK)
│   ├── player_sources_panel.dart
│   ├── player_details_panel.dart
│   ├── player_episodes_panel.dart
│   ├── bangumi_section.dart   # Bangumi 番剧 section
│   ├── bangumi_grid.dart      # Bangumi 列表
│   └── ...
└── utils/                     # 工具
    ├── image_url.dart         # 图片 URL 处理 (豆瓣 CDN 切换 / Bangumi UA / 代理 URL 兼容)
    ├── font_utils.dart        # 字体工具
    └── device_utils.dart      # 设备工具
```

## CI/CD

GitHub Actions 在 `main` 分支 push + 打 tag `v*.*.*` 时自动构建并发布 Release。

工作流文件: [.github/workflows/build.yml](.github/workflows/build.yml)

- Flutter: `3.22.2`
- JDK: Temurin 17
- Android SDK: 36
- Build-Tools: 34.0.0
- NDK: 29.0.14033849

每次 push 构建的 APK 在 run 的 Artifacts 区域(`app-release`),
打 `vX.Y.Z` tag 触发构建会自动发 [Release](https://github.com/djsevenx1/LunaTV-Mobile/releases) 并上传 APK。

## 关键技术点

### 1. 图片 URL 统一处理

所有 `CachedNetworkImage` 的 URL 都会经过 [image_url.dart](lib/utils/image_url.dart) 处理:

```dart
getImageUrl(originalUrl, source, { upgradeDouban: false })
```

- **Douban** — 根据用户配置替换 CDN 域名;`upgradeDouban: true` 时把 `s_ratio_poster` 升级为 `l_ratio_poster`(~600×900)
- **Bangumi** — 协议相对 URL `//lain.bgm.tv/...` 升级为 HTTPS;走 CF Worker 时把 `bgm.tv` 域名 URL 编码包在 `?url=` 里也能被检测出
- **其他** — 原样返回

`getImageRequestHeaders(url, source)` 返回对应源的请求头(Referer / UA),
关键点:**全 URL 搜 `bgm.tv`**,即使被 worker 包成 `?url=<encoded>` 也能命中补上 UA + Referer。

### 2. Bangumi 多级 fallback

`bangumi_service.dart` 里 worker / ciao-cors / 直连三级 fallback:

```
1. CF Worker  → 失败
2. ciao-cors (公共 CORS 代理)  → 失败
3. 直连 api.bgm.tv
```

15s 超时,失败返 null 后走下一级,保证至少有数据。

### 3. 播放源去重

`ApiService.fetchSourcesData` 按 `source` key 去重,同 key 保留集数最多的那条。
后端 iqiyi 这种源注册 3 个 API 时,前端只显示 1 个「爱奇艺」。

### 4. 播放器返回时 stop player

`player_screen.dart` 的 `PopScope.onPopInvoked` 转换 phase + 顶部返回箭头 onTap,
都先 `await _player.stop()` 再 setState,避免 detail 视图上 player 还在后台播。

### 5. 全屏方向自适应

根据视频实际宽高判断:
- 竖屏视频(高 > 宽):保持竖屏
- 横屏视频(宽 > 高):切横屏

参考 LunaTV Web 版 `ArtPlayer.autoOrientation` 实现,配合 `SystemChrome.setEnabledSystemUIMode(immersiveSticky)` 实现完整沉浸式全屏。

## 配置说明

应用首次启动会引导用户配置:
- **API 地址** — 你的 LunaTV 服务地址(官方或自部署)
- **豆瓣图片源** — `official_cdn` / `cdn_tencent` / `cdn_aliyun` / `direct`
- **主题** — 浅色 / 深色 / 跟随系统

可在「设置」页面随时修改。

### 进阶配置(用户菜单)

| 配置 | 说明 |
|---|---|
| 优选测速 | 启动时给源测速,排第一的优先 |
| 本地搜索 | 启用本地缓存加速搜索 |
| 豆瓣数据源 | `直连` / 4 种 CDN 切换 |
| 豆瓣图片源 | `直连` / 4 种 CDN 切换 |
| Bangumi 数据源 | `直连` / `Cors Proxy By Zwei` / `CF Worker 加速` |
| Bangumi 图片源 | `直连` / `Cors Proxy By Zwei` / `CF Worker 加速` |
| M3U8 代理 URL | 留空则不用,填了则 m3u8 走 worker |
| **CF Worker 加速** | 开关,只控制源测速 / m3u8 |
| **CF Worker 加速源域名** | worker 域名 (如 `xxx.workers.dev`),配了之后 Bangumi 代理也自动启用(不受上面开关影响) |

## 贡献

欢迎 PR / Issue。请确保:
1. 通过 `flutter analyze`
2. 通过 `flutter test`(如添加了测试)
3. Commit 消息清晰,符合项目历史风格(参考 `feat: ...` / `fix: ...` / `refactor: ...`)

## 许可证

本项目使用 AGPL-3.0 许可证,与上游 LunaTV 保持一致。

## 致谢

- [LunaTV](https://github.com/MoonTechLab/LunaTV) — 原始 Web 项目
- [CORSAPI](https://github.com/djsevenx1/CORSAPI) — 配套 CF Worker 后端,处理 Bangumi 代理 / m3u8 重写
- [media_kit](https://github.com/media-kit/media-kit) — Flutter 媒体播放
- [dlna_dart](https://github.com/dlna-dart/dlna_dart) — DLNA 投屏
- [cached_network_image](https://github.com/Baseflow/flutter_cached_network_image) — 网络图片缓存
- [Bangumi](https://bangumi.tv/) — 番剧数据源
- [豆瓣](https://movie.douban.com/) — 影评与海报源
- [ciao-cors](https://ciao-cors.is-an.org/) — 公共 CORS 代理,Bangumi 数据 fallback

---

Made with ❤️ by the LunaTV Mobile contributors
