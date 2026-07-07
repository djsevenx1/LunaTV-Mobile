# LunaTV Mobile

> 一款基于 Flutter 的 LunaTV 客户端,支持 Android 和 iOS。

主打开箱即用的多源聚合搜索 + 高质量本地播放,搭配 **[CORSAPI](https://github.com/djsevenx1/CORSAPI)** 配套 CF Worker 解决 Bangumi / 源加速 / m3u8 重写。

## 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| Android | ✅ | 主目标, GitHub Actions 自动出 APK 发 Release |
| iOS | ✅ | CI 自动编译,无签名 (需用户用 Xcode / AltStore 自签后安装), 从 Actions artifact 下载 |

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
- **广告自动跳过** — 检测 m3u8 广告流切流 (duration 突然变小 > 60s), 自动 seek 回主片位置跳过广告

### 账号与同步
- 自定义后端 API 地址(支持官方 / 自部署)
- 收藏 / 播放历史 / 搜索记录 本地持久化 + 服务器同步
- 多用户隔离(UserDataService)
- 主题切换(深色 / 浅色)

### 高级特性

#### CF Worker 加速 + Bangumi 代理

搭配配套的 [CORSAPI](https://github.com/djsevenx1/CORSAPI) Cloudflare Worker,菜单填入 worker 域名即可启用:

| 模块 | 走法 |
|---|---|
| **CF Worker 加速(源测速 / m3u8)** | 走 worker `/m3u8?url=` 端点,自动重写 .ts 链接 |
| **Bangumi 数据(api.bgm.tv/calendar + /v0/subjects/...)** | worker → ciao-cors → 直连, 多级 fallback |
| **Bangumi 图片(lain.bgm.tv)** | worker, 自动补 `App/Version (URL)` UA + `Referer: https://bgm.tv/` |

> **关键**:CF Worker 域名配了,即使「CF Worker 加速」开关关着,Bangumi 代理也会生效(只认域名不认开关,符合预期)。

#### 图片源
- **豆瓣图片源**:`official_cdn` / `cdn_tencent` / `cdn_aliyun` / `direct`
- **Bangumi 数据源**:`直连` / `Cors Proxy By Zwei` / `CF Worker 加速`
- **Bangumi 图片源**:`直连` / `Cors Proxy By Zwei` / `CF Worker 加速`
- Bangumi 强制补 `LunaTV-Mobile/1.0 (https://github.com/...)` UA(api.bgm.tv v0 API 严格校验)
- 豆瓣小图自动升级为 `l_ratio_poster` 大图(首页轮播等大图场景)
- 图片内存缓存按 `devicePixelRatio × 显示尺寸` 精确解码,避免模糊与内存浪费

#### 软件更新
- 检查更新从 GitHub API `assets` 抽 `.apk` 直链
- 「下载并安装 vX.X.X」按钮直接走系统下载管理器,不用跳浏览器
- 拿不到 apk 链接才 fallback 到 release 详情页

## 快速开始

### 环境要求

- Flutter SDK `3.22.2` 或更高
- Java JDK 17(Android 构建)
- Android SDK Platform 36 + Build-Tools 34.0.0
- Android NDK `29.0.14033849`(可选,媒体插件需要)
- Xcode 15+(iOS 构建)

### 拉取代码

```bash
git clone https://github.com/djsevenx1/LunaTV-Mobile.git
cd LunaTV-Mobile
flutter pub get
```

### 本地构建

```bash
flutter build apk --release       # Android
flutter build ios --release --no-codesign  # iOS (无签名)
```

### 输出产物

- Android APK: `build/app/outputs/flutter-apk/app-release.apk`
- iOS: `build/ios/iphoneos/Runner.app` (无签名,需自签)

## CI/CD

GitHub Actions 在 `main` 分支 push + 打 tag `v*.*.*` 时自动构建。

工作流文件: [.github/workflows/build.yml](.github/workflows/build.yml)

- **Android**: ubuntu-latest, APK 上传到 GitHub Release
- **iOS**: macos-latest, `--no-codesign` 模式, Runner.app 上传到 Actions artifact (需用户自签安装)
- Flutter: `3.22.2` / JDK: Temurin 17 / Android SDK: 36 / Build-Tools: 34.0.0 / NDK: 29.0.14033849

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
- [Selene](https://github.com/MoonTechLab/Selene) — Flutter 移动端/桌面端源起项目
- [CORSAPI](https://github.com/djsevenx1/CORSAPI) — 配套 CF Worker 后端,处理 Bangumi 代理 / m3u8 重写
- [media_kit](https://github.com/media-kit/media-kit) — Flutter 媒体播放
- [dlna_dart](https://github.com/dlna-dart/dlna_dart) — DLNA 投屏
- [cached_network_image](https://github.com/Baseflow/flutter_cached_network_image) — 网络图片缓存
- [Bangumi](https://bangumi.tv/) — 番剧数据源
- [豆瓣](https://movie.douban.com/) — 影评与海报源
- [ciao-cors](https://ciao-cors.is-an.org/) — 公共 CORS 代理,Bangumi 数据 fallback
