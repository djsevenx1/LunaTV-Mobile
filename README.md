# LunaTV Mobile

> 一款基于 Flutter 的 LunaTV Android 客户端。

主打开箱即用的多源聚合搜索 + 高质量本地播放,搭配:
- **[djsevenx1/tmdb-proxy](https://github.com/djsevenx1/tmdb-proxy)** — CF Worker,负责 TMDB API / 图片 / Bangumi 数据 / 图片 / GitHub 更新加速 (用户自部署)

## 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| Android | ✅ | 主目标, GitHub Actions 自动出 APK 发 Release |
| iOS | ❌ | 不再维护 (v2.0.8 起撤回 iOS 编译) |

## 主要功能

### 内容浏览
- **首页轮播 + 多分区** — 继续播放、热门电影、热门剧集、新番放送(Bangumi)、热门综艺、热门短剧
- **TMDB 海报墙 (v2.0.38+, v2.1.41+ 走 tmdb-proxy)** — 配 TMDB API Key 后,首页「热门电影」「热门剧集」section 自动替换为 TMDB 横滚海报墙 (w185 海报 + 标题 + 评分);详情页头部从 110x150 小海报升级为 16:9 大背景 + 简介。**v2.1.41+**: 配了「代理 URL」(自部署 [djsevenx1/tmdb-proxy](https://github.com/djsevenx1/tmdb-proxy)) 后,TMDB API + 图片走 worker 加速,解决国内 GFW。**不填 key = 行为完全不变**
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

#### TMDB / Bangumi / GitHub 加速

LunaTV-Mobile 保留用户自部署的 **tmdb-proxy** Worker,只负责元数据、图片和更新下载加速,不再参与视频播放链路:

| Worker | 仓库 | 负责 | 触发条件 |
|---|---|---|---|
| **tmdb-proxy** | [djsevenx1/tmdb-proxy](https://github.com/djsevenx1/tmdb-proxy) | TMDB API / TMDB 图片 / Bangumi 数据 / Bangumi 图片 / GitHub Releases API + assets | 设「代理 URL」(如 `https://your-worker.example.com`),TMDB / Bangumi 数据源选 Worker 加速,GitHub 检查更新 / APK 下载走 worker |

**tmdb-proxy** 路由 (path-based,比老 `?url=` 套娃干净):
- `/movie/{id}` `/tv/{id}` `/search/...` `/movie/{id}/images` 等 → `api.themoviedb.org/3/...`
- `/image/{size}/{file}` → `image.tmdb.org/t/p/{size}/{file}` (1 天 CDN cache)
- `/bangumi/{path}` → `api.bgm.tv/{path}` (Authorization 透传)
- `/bgm-img/{path}` → `lain.bgm.tv/{path}` (自动加 `Referer: https://bgm.tv/` 绕过反盗链)
- `/github/repos/{owner}/{repo}/releases/latest` (v2.1.46+) → `api.github.com/repos/{owner}/{repo}/releases/latest` (app 检查更新用, `User-Agent` + `Accept: application/vnd.github.v3+json` 强制加)
- `/github/asset/{owner}/{repo}/{tag}/{asset_name}` (v2.1.46+) → `github.com/{owner}/{repo}/releases/download/{tag}/{asset_name}` 跟 302 跳到 `objects.githubusercontent.com` 流式转发 (app 内建下载器拿 APK 用)

`api_key` 从 App 「TMDB API Key」读,worker 透传,不用去 CF Dashboard 配 env。`GITHUB_TOKEN` (可选 env) 配了拉高 60→5000 req/hr,不配匿名 60/hr (检查更新 1 次够用)。

#### 图片源

| 数据源 | 选项 | 说明 |
|---|---|---|
| **豆瓣数据源** | `直连` / 4 种 CDN | v0.77 起默认,4 种 CDN 切换 |
| **豆瓣图片源** | `直连` / 4 种 CDN | 登录豆瓣后小图自动升级为 `l_ratio_poster` 大图 |
| **TMDB 数据源** (v2.1.41+) | `TMDB Worker 加速` / `直连` | 2 选 1,没「已关闭」(用户反馈),默认按 worker URL 配没配决定 |
| **Bangumi 数据源** (v2.1.42+) | `Bangumi Worker 加速` / `直连` | v2.1.40 整个删, v2.1.42 加回,2 选 1,跟数据源 / 图片源共享 worker URL |
| **Bangumi 图片源** (v2.1.42+) | `Bangumi Worker 加速` / `直连` | 同上,数据 / 图片是 2 个独立开关 |

- Bangumi 强制补 `LunaTV-Mobile/1.0 (https://github.com/...)` UA (api.bgm.tv v0 API 严格校验)
- 豆瓣小图自动升级为 `l_ratio_poster` 大图 (首页轮播等大图场景)
- 图片内存缓存按 `devicePixelRatio × 显示尺寸` 精确解码,避免模糊与内存浪费

#### 软件更新 (v2.1.46+)
- 检查更新从 GitHub API `assets` 抽 `.apk` 直链
- **App 内建下载器 (v2.1.46+)** — 弹窗点「下载并安装」直接走 `dio.download` 把 APK 下到 app 临时目录, Dialog 内嵌 LinearProgressIndicator 实时显示百分比 + 已下载/总大小, 支持「取消下载 / 重试」. 下完自动调 Android 系统 APK 安装器 (Android 7+ 走 androidx `FileProvider` 转 content:// URI, 避开严格模式 `FileUriExposedException`), 用户在安装器里点「安装」即生效. **不跳浏览器、不用第三方 pub package, 自己写 `ApkInstallChannel.kt` MethodChannel 跟 `ImageHttpChannel` 平行**
- **GitHub 代理 (v2.1.46+, UI 合并 v2.1.49+)** — 配了「代理 URL」(自部署 [djsevenx1/tmdb-proxy](https://github.com/djsevenx1/tmdb-proxy), 跟 TMDB / Bangumi 共用同一个 URL) 后, ① 检查更新走 worker 的 `/github/repos/.../releases/latest`, ② app 内建下载器下 APK 走 worker 的 `/github/asset/{owner}/{repo}/{tag}/{asset}` (跟 302 跳到 `objects.githubusercontent.com` 流式转发). 解决国内 GFW 完全拉不到 `api.github.com` / `objects.githubusercontent.com` 的问题
- 拿不到 apk 链接 fallback 到 release 详情页 (用 `url_launcher` 跳浏览器)

## 自部署视频后端 (lunatv-cf-backend)

App 默认对接官方 [LunaTV Web](https://github.com/MoonTechLab/LunaTV) 后端,也可改用 [djsevenx1/lunatv-cf-backend](https://github.com/djsevenx1/lunatv-cf-backend) —— 一个**完全跑在 Cloudflare Pages 边缘**的替代后端,无需 Node.js / 数据库 / Redis,纯 CF Worker + KV。

### 跟 LunaTV Web 对比

| 维度 | LunaTV Web | lunatv-cf-backend |
|---|---|---|
| 部署 | Node.js + DB + Redis | 5 分钟 Cloudflare Pages 一键 |
| 维护 | 跟随 Next.js / DB schema 更新 | 0 (Worker 边缘运行, KV 存数据) |
| 视频 API | 代理 maccms 源 (外部后端) | **自包含**:Worker 直接调源 API + 解析 maccms `vod_play_url` |
| 账号 / 收藏 / 历史 | DB | CF KV (账号 bcrypt 加密) |
| 月成本 | 服务器费用 | 免费额度内 (KV < 100MB 够 ~100 账号) |
| 视频功能 | 完整 | 跨源搜索 / 详情 / SSE 流式搜 / 源浏览器 / 番剧日历 / 豆瓣 / 短剧  |
| 额外能力 | — | 源标记 + 过滤开关 (v0.8) |

### 部署步骤 (5 分钟)

1. Fork [djsevenx1/lunatv-cf-backend](https://github.com/djsevenx1/lunatv-cf-backend)
2. Cloudflare 控制台 → Pages → Connect to Git → 选你的 fork
3. Build settings: `Build command` 留空,`Build output` = 根目录
4. `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` 加到 fork 的 GitHub Secrets,首次 push 自动建 KV namespace 并 commit 回 `wrangler.toml`
5. 部署完拿到 `https://<your-subdomain>.pages.dev`

### App 配置

1. App → 设置 → 「API 地址」填入 CF Pages URL
2. 首次打开会引导注册账号(自带账号系统,bcrypt + Salt)
3. 「源管理」→ 「导入订阅」粘贴 LunaTV 订阅(Base58 / JSON / URL 任意),或手动「+ 新增源」加 maccms 公开资源站
4. 主页「搜索」即可跨源聚合,详情页自动解析 m3u8 选集播放

### 内容过滤 (v0.8+)

每个视频源可在 Web UI 标记为。Web UI 顶部有「仅本账号」开关,默认关闭 ;开启 → 该账号 app 看到所有源,App 根据 `adult` 字段显示标签。账号之间互不影响。

### 端点兼容表

App 所有调用的后端端点都已自包含实现,不依赖任何外部后端:

| 端点 | 用途 |
|---|---|
| `POST /api/login` / `/register` / `/logout` | 账号 |
| `GET /api/me` / `/favorites` / `/playrecords` / `/searchhistory` | 同步 |
| `GET/POST/PUT/DELETE /api/sources` `/api/sources/import` | 源管理 |
| `GET/PUT /api/config` | 每账号偏好 (adult_enabled) |
| `GET /api/search/resources` | 源列表(给 app) |
| `GET /api/search?q=` `/search/one?resourceId=&q=` | 跨源 / 单源搜索 |
| `GET /api/search/suggestions?keyword=` `/api/search/ws?q=` | 搜建议 / SSE 流式搜 |
| `GET /api/detail?source=&id=` | 视频详情 + maccms 解析 |
| `GET /api/source-browser/{sites,categories,list,search}` | 源浏览器(分类/列表/搜) |
| `GET /api/release-calendar` | 番剧日历(抓 bgm.tv) |
| `GET /api/douban/details?id=` `/api/netdisk/search?wd=` `/api/proxy/bangumi?path=` | 第三方内容 |

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
| **TMDB 数据源** (v2.1.41+) | `TMDB Worker 加速` / `直连`,2 选 1 |
| **Bangumi 数据源** (v2.1.42+) | `Bangumi Worker 加速` / `直连`,2 选 1 |
| **Bangumi 图片源** (v2.1.42+) | `Bangumi Worker 加速` / `直连`,2 选 1,跟数据源独立 |
| **代理 URL** (v2.1.41+, 改名 v2.1.42, 合并 GitHub v2.1.49) | 自部署 [djsevenx1/tmdb-proxy](https://github.com/djsevenx1/tmdb-proxy) 拿到的 https://xxx.pages.dev,空 = 全部走直连. **同一个 URL 同时服务 TMDB / Bangumi / GitHub 三套路由** (TMDB `/movie/...` + `/image/...`、Bangumi `/bangumi/...` + `/bgm-img/...`、GitHub `/github/...` + `/github/asset/...`) |
| **TMDB API Key (可选, v2.0.35, v2.1.41+ 配合 tmdb-proxy)** | 填了自动启用首页 TMDB 海报墙 + 详情页 TMDB 大背景. v2.1.41+: 配上「代理 URL」后,worker 自动用这个 key 调 TMDB,不用去 CF Dashboard 配 env. **留空 = 首页 / 详情页保持原 Douban 海报, 行为完全不变** |

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
- [djsevenx1/tmdb-proxy](https://github.com/djsevenx1/tmdb-proxy) — 配套 CF Worker 后端,处理 TMDB API / 图片 + Bangumi 数据 / 图片 + GitHub 更新加速
- [djsevenx1/lunatv-cf-backend](https://github.com/djsevenx1/lunatv-cf-backend) — 自包含视频后端 (账号 / 收藏 / 历史 / 源管理 + 视频搜索 / 详情),纯 CF Worker + KV,无需外部服务
- [AndroidX Media3 ExoPlayer](https://developer.android.com/media/media3/exoplayer) — Android 媒体播放
- [dlna_dart](https://github.com/dlna-dart/dlna_dart) — DLNA 投屏
- [cached_network_image](https://github.com/Baseflow/flutter_cached_network_image) — 网络图片缓存
- [Bangumi](https://bangumi.tv/) — 番剧数据源
- [TMDB](https://www.themoviedb.org/) — 影视元数据源
- [豆瓣](https://movie.douban.com/) — 影评与海报源
