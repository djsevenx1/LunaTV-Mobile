# LunaTV Mobile

> 一款基于 Flutter 的 LunaTV Android 客户端。

主打开箱即用的多源聚合搜索 + 高质量本地播放。

## 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| Android | ✅ | 主目标, GitHub Actions 自动出 APK 发 Release |
| iOS | ❌ | 不再维护 (v2.0.8 起撤回 iOS 编译) |

## 主要功能

### 内容浏览
- **首页轮播 + 多分区** — 继续播放、热门电影、热门剧集、新番放送(Bangumi)、热门综艺、热门短剧
- **TMDB 海报墙 (v2.0.38+)** — 配 TMDB API Key 后,首页「热门电影」「热门剧集」section 自动替换为 TMDB 横滚海报墙 (w185 海报 + 标题 + 评分);详情页头部从 110x150 小海报升级为 16:9 大背景 + 简介。**不填 key = 行为完全不变**
- **分类筛选** — 电视剧 / 电影 / 综艺 / 动漫 多种筛选维度(类型、地区、年代、平台、排序)
- **短剧专区** — 独立分类聚合,横滑切换
- **搜索** — 全局搜索,跨源聚合结果
- **排行榜** — 豆瓣热门内容

### 播放能力
- 基于 AndroidX Media3 ExoPlayer 的高性能播放器
- 自动判断视频横竖屏比例(`AspectRatio` + `SystemChrome`)
- 全屏沉浸式 + 系统 UI 自动隐藏/恢复
- 多源搜索播放(短剧点击直接进 PlayerScreen 走多源聚合)
- **播放源去重** — 后端同 `source` key 注册多个 API 时,前端按 key 去重保留集数最多的
- 断点续看 + 播放进度同步
- DLNA 投屏支持(`dlna_dart`)
- 选集 / 选源 / 详情面板一体化
- **返回时主动 stop player** — 从播放视图返回详情视图时 player.stop() + 退全屏,后台不再继续播
- **播控「下一集」按钮**(v2.0.33) — 中途可手动切下一集,跟自动播下一集走同一逻辑,最后一集按钮自动隐藏

### 账号与同步
- 自定义后端 API 地址(支持官方 / 自部署)
- 收藏 / 播放历史 / 搜索记录 本地持久化 + 服务器同步
- 多用户隔离(UserDataService)
- 主题切换(深色 / 浅色)

### 高级特性

#### 图片源

| 数据源 | 选项 | 说明 |
|---|---|---|
| **豆瓣数据源** | `直连` / 4 种 CDN | v0.77 起默认,4 种 CDN 切换 |
| **豆瓣图片源** | `直连` / 4 种 CDN | 登录豆瓣后小图自动升级为 `l_ratio_poster` 大图 |
| **TMDB 数据源** (v2.1.41+) | `直连` / `自定义` | 默认直连 |
| **Bangumi 数据源** (v2.1.42+) | `直连` / `自定义` | 2 选 1 |
| **Bangumi 图片源** (v2.1.42+) | `直连` / `自定义` | 同上,数据 / 图片是 2 个独立开关 |

- Bangumi 强制补 `LunaTV-Mobile/1.0 (https://github.com/...)` UA (api.bgm.tv v0 API 严格校验)
- 豆瓣小图自动升级为 `l_ratio_poster` 大图 (首页轮播等大图场景)
- 图片内存缓存按 `devicePixelRatio × 显示尺寸` 精确解码,避免模糊与内存浪费

#### 软件更新 (v2.1.46+)
- 检查更新从 GitHub API `assets` 抽 `.apk` 直链
- **App 内建下载器 (v2.1.46+)** — 弹窗点「下载并安装」直接走 `dio.download` 把 APK 下到 app 临时目录, Dialog 内嵌 LinearProgressIndicator 实时显示百分比 + 已下载/总大小, 支持「取消下载 / 重试」. 下完自动调 Android 系统 APK 安装器 (Android 7+ 走 androidx `FileProvider` 转 content:// URI, 避开严格模式 `FileUriExposedException`), 用户在安装器里点「安装」即生效
- 拿不到 apk 链接 fallback 到 release 详情页 (用 `url_launcher` 跳浏览器)

## 快速开始

### 环境要求

- Flutter SDK `3.22.2` 或更高
- Java JDK 17
- Android SDK Platform 36 + Build-Tools 34.0.0
- Android NDK `29.0.14033849`(可选,媒体插件需要)

### 拉取代码

```bash
git clone https://github.com/djsevenx1/LunaTV-Mobile.git
cd LunaTV-Mobile
flutter pub get
```

### 本地构建

```bash
flutter build apk --release
```

### 输出产物

- Android APK: `build/app/outputs/flutter-apk/app-release.apk`

## CI/CD

GitHub Actions 在 `main` 分支 push + 打 tag `v*.*.*` 时自动构建。

工作流文件: [.github/workflows/build.yml](.github/workflows/build.yml)

- **Android**: ubuntu-latest, APK 上传到 GitHub Release
- Flutter: `3.22.2` / JDK: Temurin 17 / Android SDK: 36 / Build-Tools: 34.0.0 / NDK: 29.0.14033849
- v2.0.8 起撤回 iOS 编译 (用户决定), CI 改单 job 模式, 时间减半

## 配置说明

应用首次启动会引导用户配置:
- **API 地址** — 你的 LunaTV 服务地址(官方或自部署)
- **豆瓣图片源** — `official_cdn` / `cdn_tencent` / `cdn_aliyun` / `direct`
- **主题** — 浅色 / 深色 / 跟随系统

可在「设置」页面随时修改。

### 进阶配置(用户菜单)

| 配置 | 说明 |
|---|---|
| 本地搜索 | 启用本地缓存加速搜索 |
| 豆瓣数据源 | `直连` / 4 种 CDN 切换 |
| 豆瓣图片源 | `直连` / 4 种 CDN 切换 |
| **TMDB 数据源** (v2.1.41+) | `直连` / `自定义`,2 选 1 |
| **Bangumi 数据源** (v2.1.42+) | `直连` / `自定义`,2 选 1 |
| **Bangumi 图片源** (v2.1.42+) | `直连` / `自定义`,2 选 1,跟数据源独立 |
| **TMDB API Key (可选, v2.0.35)** | 填了自动启用首页 TMDB 海报墙 + 详情页 TMDB 大背景. **留空 = 首页 / 详情页保持原 Douban 海报, 行为完全不变** |

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
- [AndroidX Media3 ExoPlayer](https://developer.android.com/media/media3/exoplayer) — Android 媒体播放
- [dlna_dart](https://github.com/dlna-dart/dlna_dart) — DLNA 投屏
- [cached_network_image](https://github.com/Baseflow/flutter_cached_network_image) — 网络图片缓存
- [Bangumi](https://bangumi.tv/) — 番剧数据源
- [TMDB](https://www.themoviedb.org/) — 影视元数据源
- [豆瓣](https://movie.douban.com/) — 影评与海报源
