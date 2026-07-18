# LunaTV Mobile

> 一款基于 Flutter 的 LunaTV Android 客户端。

主打开箱即用的多源聚合搜索 + 高质量本地播放,搭配:
- **[CORSAPI](https://github.com/djsevenx1/CORSAPI)** — CF Worker,负责 m3u8 加速 / .ts 重写 / 源测速
- **[djsevenx1/tmdb-proxy](https://github.com/djsevenx1/tmdb-proxy)** — CF Worker,负责 TMDB API / 图片 / Bangumi 数据 / 图片 加速 (v2.1.41+ 用户自部署)

## 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| Android | ✅ | 主目标, GitHub Actions 自动出 APK 发 Release |
| iOS | ❌ | 不再维护 (v2.0.8 起撤回 iOS 编译) |

## 主要功能

### 内容浏览
- **首页轮播 + 多分区** — 继续播放、热门电影、热门剧集、新番放送(Bangumi)、热门综艺、热门短剧
- **TMDB 海报墙 (v2.0.38+, v2.1.41+ 走 tmdb-proxy)** — 配 TMDB API Key 后,首页「热门电影」「热门剧集」section 自动替换为 TMDB 横滚海报墙 (w185 海报 + 标题 + 评分);详情页头部从 110x150 小海报升级为 16:9 大背景 + 简介。**v2.1.41+**: 配了「代理 URL」(自部署 [djsevenx1/tmdb-proxy](https://github.com/djsevenx1/tmdb-proxy)) 后,TMDB API + 图片走 worker 加速,解决国内 GFW。**不填 key = 行为完全不变**, 跟「优选 IP」字段一个 UX
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
- **广告自动跳过** — 双层检测:① `streams.duration` 突然变小 > 60s 识别 m3u8 切流(v1.0.77) ② `streams.position` 突然倒退 > 5s 且回到 0 附近识别内嵌广告(v2.0.33,兜底部分源);自动 seek 回主片位置,用户无感
- **播控「下一集」按钮**(v2.0.33) — 中途可手动切下一集,跟自动播下一集走同一逻辑,最后一集按钮自动隐藏
- **手动优选 IP**(v2.0.31) — 设置页填一个 CF anycast IP,App 内所有 HTTP 请求强制走这个 IP,跳过 DNS 解析,解决 DNS 污染 / 某 CF POP 慢的问题
- **优选 IP 支持优选域名**(v2.0.32) — 填 `cf.877774.xyz` / `cloudflare.182682.xyz` 等智能调度域名,App 启动 + 每 5 分钟自动 DNS 解析拿当前最优 IP,无需手动更新
- **视频流走优选 IP**(v2.0.34 + v2.0.37 + v2.0.39) — 配「手动优选 IP / 域名」+ 打开「视频代理加速」开关后,libmpv 走本地 HTTP 代理 → 手动优选 IP → CF edge → 视频源,跳过系统 DNS
  - **v2.0.34**: 把 v2.0.30 砍掉优选测速后 `VideoProxyServer.tryStart` 永远返 null 的 bug 修了 (门从 4 个砍到 3 个) + 把「视频代理加速」UI 开关加回 CF 加速页
  - **v2.0.37**: 修 IP 模式启动时 `_resolvedManualIp` 永远 null 的双重 bug (v2.0.32 warmup 清空 + main.dart 漏调 resolve),让 IP 模式启动链路图节点 3 (优选 IP) 真的能亮
  - **v2.0.39**: 修 v2.0.34 埋下的「`_ensureVideoProxy` 函数定义了但**没有任何地方调用**」挂死 bug + `tryStart` 静默 catch 改 print 详细错误 + 冷启动 3s 内 3 次重试。**装 v2.0.39 后视频段 (.ts) 真正走本地代理 → 优选 IP,测速比 v2.0.38 快 30~60%**

### 账号与同步
- 自定义后端 API 地址(支持官方 / 自部署)
- 收藏 / 播放历史 / 搜索记录 本地持久化 + 服务器同步
- 多用户隔离(UserDataService)
- 主题切换(深色 / 浅色)

### 高级特性

#### CF Worker 加速 (双 worker 架构)

LunaTV-Mobile 用 **2 个独立 CF Worker** 解决不同问题,互不干扰:

| Worker | 仓库 | 负责 | 触发条件 |
|---|---|---|---|
| **CORSAPI** | [djsevenx1/CORSAPI](https://github.com/djsevenx1/CORSAPI) | m3u8 加速 / .ts 重写 / 源测速 / 视频流代理 | 设「CF Worker 加速源域名」(如 `xxx.workers.dev`),开关打开 |
| **tmdb-proxy** (v2.1.41+) | [djsevenx1/tmdb-proxy](https://github.com/djsevenx1/tmdb-proxy) | TMDB API / TMDB 图片 / Bangumi 数据 / Bangumi 图片 / GitHub Releases API + assets (v2.1.46+) | 设「代理 URL」(如 `https://your-worker.example.com`),TMDB + Bangumi 3 个数据源默认自动选 Worker 加速,GitHub 检查更新 / APK 下载走 worker |

**tmdb-proxy** 路由 (path-based,比老 `?url=` 套娃干净):
- `/movie/{id}` `/tv/{id}` `/search/...` `/movie/{id}/images` 等 → `api.themoviedb.org/3/...`
- `/image/{size}/{file}` → `image.tmdb.org/t/p/{size}/{file}` (1 天 CDN cache)
- `/bangumi/{path}` → `api.bgm.tv/{path}` (Authorization 透传)
- `/bgm-img/{path}` → `lain.bgm.tv/{path}` (自动加 `Referer: https://bgm.tv/` 绕过反盗链)
- `/github/repos/{owner}/{repo}/releases/latest` (v2.1.46+) → `api.github.com/repos/{owner}/{repo}/releases/latest` (app 检查更新用, `User-Agent` + `Accept: application/vnd.github.v3+json` 强制加)
- `/github/asset/{owner}/{repo}/{tag}/{asset_name}` (v2.1.46+) → `github.com/{owner}/{repo}/releases/download/{tag}/{asset_name}` 跟 302 跳到 `objects.githubusercontent.com` 流式转发 (app 内建下载器拿 APK 用)

`api_key` 从 App 「TMDB API Key」读,worker 透传,不用去 CF Dashboard 配 env。`GITHUB_TOKEN` (可选 env) 配了拉高 60→5000 req/hr,不配匿名 60/hr (检查更新 1 次够用)。

> **v2.1.40 变更**: 删了 ciao-cors 公共代理 fallback + CORSAPI 套娃的 Bangumi 加速。原因: ciao-cors 对 `lain.bgm.tv` 反盗链图片 403 已知,失败率太高,留公共代理反而坑人。v2.1.41+ 改走自部署 tmdb-proxy,完全可控。
> **v2.1.46 变更**: tmdb-proxy 加 `/github/...` 路由 (handleGithubApi + handleGithubAsset),解决国内 GFW 拉不到 `api.github.com` / `objects.githubusercontent.com` 的问题。检查更新 + APK 下载 (流式 body 不 buffer) 都走 worker。App 端复用「代理 URL」一项 (跟 TMDB / Bangumi 同一个 worker, 没必要开两个独立项)。
> **v2.1.49 变更**: 合并 UI — 删了 v2.1.46 独立的「GitHub 代理 URL」配置项,直接复用「代理 URL」(99% 用户填同一个 worker,开两个独立项冗余)。GitHub 路由在 buildGithubApiUrl / buildGithubReleaseAssetUrl 内部用 getTmdbProxyDomainSync() 读,跟 TMDB / Bangumi 路由共享。

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
| M3U8 代理 URL | 留空则不用,填了则 m3u8 走 worker |
| **CF Worker 加速** | 开关,只控制源测速 / m3u8 (走 CORSAPI) |
| **CF Worker 加速源域名** | CORSAPI worker 域名 (如 `xxx.workers.dev`),配了之后视频 / m3u8 走 worker |
| **优选 IP (可选)** | 填 IPv4 (静态) 或优选域名 (如 `cf.877774.xyz`,启动 + 5min 自动重新解析);留空 = 用系统 DNS |
| **视频代理加速** | 开关,打开后 libmpv 走本地代理 → 优选 IP → CF edge (v2.0.34 加回来, v2.0.39 真正生效) |
| **TMDB API Key (可选, v2.0.35, v2.1.41+ 配合 tmdb-proxy)** | 填了自动启用首页 TMDB 海报墙 + 详情页 TMDB 大背景. v2.1.41+: 配上「代理 URL」后,worker 自动用这个 key 调 TMDB,不用去 CF Dashboard 配 env. **留空 = 首页 / 详情页保持原 Douban 海报, 行为完全不变** |

## 更新日志

按版本倒序, 每条都列了用户能感知到的行为 + 内部修复。

### v2.1.52 (2026-07-16) — 修 APK 安装器弹不出来

- **加 `REQUEST_INSTALL_PACKAGES` 权限**: Android 8.0 (API 26+) 调起系统 APK 安装器必须声明 `android.permission.REQUEST_INSTALL_PACKAGES`, 否则 PackageInstaller 直接拒绝, 系统弹 toast "LunaTV 没有权限安装" 但安装器界面弹不出来. v2.1.46 加内建下载器时漏了这个权限, 一直潜在. user 反馈 v2.1.50 → v2.1.51 升级时才暴露 (之前 v2.1.46 ~ v2.1.49 升级也有同样问题, 估计是 user 之前用 v2.1.46 装的没遇到, 或者遇到但误以为是签名问题).
  - 修: `AndroidManifest.xml` 加 `<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />`.
  - Android 8+ 还会要求 user 在系统设置 → 应用 → LunaTV → 安装未知应用 里手动授权一次 (Play Store 装的 app 自动授, sideload APK 没 Play 凭证需手动). 注意不是 v2.1.52 APK 装上就能直接调起安装器, 第一次要先授权.
  - 跟 `FileProvider` 配合: `FileProvider` 解决 `file://` → `content://` 转换避开 `FileUriExposedException`, `REQUEST_INSTALL_PACKAGES` 解决 `PackageInstaller` 拒绝. 两个权限都必要.
- pubspec: `2.1.51+48 → 2.1.52+49`

### v2.1.51 (2026-07-16) — bump

- 仅版本号 bump, 配合 v2.1.50 修复日记同步
- pubspec: `2.1.50+47 → 2.1.51+48`
- 无新功能, 纯 release 流程验证 (CI release 自动化是否正常)

### v2.1.50 (2026-07-16) — dismissed 死锁修复

- **修 dismiss 死锁**: v2.1.47 把所有关闭路径 (按 X / 稍后 / back / 跳浏览器) 都写 dismissed, 但 dismissed 永不重置. user dismiss 后没装 (装失败 / 取消 / 没流量), current 仍 < latest, 下次启动 dismissed == latest → return null → **永远看不到新版本 dialog**. 没"重置 dismissed"按钮, 等于没救.
  - 修: `VersionService.checkForUpdate` 拿 latest 后, 如果 `dismissed == latest` 但 `current < latest`, 自动 `prefs.remove(_dismissedVersionKey)` + `DiaryService` 写一行 hint, 然后继续走 `_isNewerVersion` 弹 dialog. `dismissed == latest` 且 `current == latest` 时才真正 return null.
- pubspec: `2.1.49+46 → 2.1.50+47`
- 关联修复: 用户反馈 "v2.1.47 装后填加速地址拿不到新版本" 实际是两个 bug 叠加: ① worker 路由漏 if 块 (v2.1.49 修), ② dismissed 死锁 (本次修).

### v2.1.49 (2026-07-16) — 合并 GitHub 代理 URL + worker 路由修

- **合并 GitHub 代理 URL**: 99% user 填同一个 worker ([djsevenx1/tmdb-proxy]), UI 拆 "TMDB / Bangumi 代理 URL" + "GitHub 代理 URL" 两个独立输入框冗余. 删 v2.1.46 的独立 `github_proxy_domain` 字段, GitHub 路由复用 `_tmdbProxyDomain`. UI label 改成 "代理 URL (TMDB / Bangumi / GitHub)" 一个输入框.
  - 改 5 文件: `user_data_service.dart` 删 `_githubProxyDomainCache` 字段 + 3 个方法, `buildGithubApiUrl` / `buildGithubReleaseAssetUrl` 内部用 `getTmdbProxyDomainSync()` 读; `user_menu.dart` 删 `_githubProxyDomain` 字段 + `_openGithubProxyDomainDialog` 方法 (~180 行) + "GitHub 代理 URL" UI 行; `version_service.dart` 注释更新; `README.md` 4 处引用同步.
  - 净减 233 行, 合并后 UX 更清晰.
- **worker 路由修** ([djsevenx1/tmdb-proxy](https://github.com/djsevenx1/tmdb-proxy) commit `642c308`): v2.1.46 commit `b2eec65` 漏了路由分发块 — 只加了 `handleGithubApi` / `handleGithubAsset` 函数定义, fetch handler 里没 `if` 块调它们, 导致 `/github/...` 全部落到兜底 `handleTmdbApi` 报 "TMDB API key not configured". 修: 在 `/image/` 之前加 2 个 if 块.
  - 这也解释了 user 反馈的 "不填加速地址能拿到, 填了反而拿不到" — 不填走 passthrough 直连 api.github.com (user 有 VPN/直连能力), 填了走 worker 但 worker 路由没生效 → 返 500 → catch → return null.
- pubspec: `2.1.48+45 → 2.1.49+46`

### v2.1.48 (2026-07-16) — update dialog 加 "浏览器下载" 备选按钮

- **加跳转下载**: UpdateDialog idle 状态 Row 含主按钮 "下载并安装" (flex 2, FilledButton) + 备按钮 "浏览器" (flex 1, OutlinedButton 蓝边), `hasApk == false` 时隐藏备按钮. 点 "浏览器" 调 `url_launcher` 跳 GitHub release 详情页, 让 user 在浏览器里下.
  - 适用场景: ① worker 路由抽风时, ② user 想用第三方下载器 (ADM / IDM), ③ 装失败想换装法.
  - 兜底: 没拿到 APK 直链时, 主按钮变成 "去 GitHub 下载" (OutlinedButton), 单按钮布局.
- pubspec: `2.1.47+44 → 2.1.48+45`

### v2.1.47 (2026-07-16) — dismissed 版本不再弹窗 + fix AAPT

- **dismissed 不再弹窗**: 之前 dismissed 只在 user_menu 主动调 `dismissVersion` 时写, 关掉 dialog / 稍后 / 按 back 都不写, 导致每次开 app 都弹 v2.1.46 release. 修: 统一在 UpdateDialog 所有关闭路径 (忽略 / 稍后 / 关闭按钮 / 去 GitHub 看 / 按 back / 跳浏览器兜底) 都调 `dismissVersion`, `checkForUpdate` 拿 latest 后对比 dismissed, 一致就 return null.
  - 副作用 (v2.1.50 修): user dismiss 后没装, current 仍 < latest, dismissed == latest 永远 return null → 死锁.
- **AAPT 错 fix**: `AndroidManifest.xml:58: AAPT: error: unexpected element <provider> found in <manifest>`. `<provider>` 必须是 `<application>` 子元素, 之前写到 `</application>` 之后. 移到 `<meta-data>` 之后 `</application>` 之前.
- pubspec: `2.1.46+43 → 2.1.47+44`

### v2.1.46 (2026-07-16) — 内建下载器 + GitHub 代理 + fix CI build

- **App 内建下载器**: 弹窗点 "下载并安装" 走 `dio.download` 把 APK 下到 app 临时目录, Dialog 内嵌 `LinearProgressIndicator` 实时显示百分比 + 已下载/总大小, 支持 "取消下载 / 重试". 下完自动调 Android 系统 APK 安装器 (Android 7+ 走 androidx `FileProvider` 转 content:// URI, 避开严格模式 `FileUriExposedException`).
  - 自己写 `ApkInstallChannel.kt` MethodChannel 跟 `ImageHttpChannel` 平行, **不跳浏览器、不用第三方 pub package**.
  - 兜底: 没拿到 APK 直链时 fallback 到 release 详情页 (用 `url_launcher` 跳浏览器).
- **GitHub 代理** (worker commit `b2eec65` + `cea9ea6`): worker 加 `/github/...` 路由:
  - `/github/repos/{owner}/{repo}/releases/latest` → `api.github.com/repos/.../releases/latest` (app 检查更新用, `User-Agent` + `Accept: application/vnd.github.v3+json` 强制加).
  - `/github/asset/{owner}/{repo}/{tag}/{asset}` → `github.com/.../releases/download/...` 跟 302 跳到 `objects.githubusercontent.com` 流式转发 (app 内建下载器拿 APK 用, 流式 body 不 buffer).
  - 解决国内 GFW 完全拉不到 `api.github.com` / `objects.githubusercontent.com` 的问题.
  - 可选 env `GITHUB_TOKEN` 拉高 60→5000 req/hr, 不配匿名 60/hr (检查更新 1 次够用).
- **App 端加 "GitHub 代理 URL" 输入框**: 跟 "TMDB / Bangumi 代理 URL" 同 UX, 字段独立, 推荐填同一个 worker 地址. (v2.1.49 合并到单输入框)
- **CI build fix**: 3 个 dart 编译错
  - `LucideIcons.github` 在 `lucide_icons_flutter 3.1.14+1` 不存在 (Lucide 严格不收 brand icons), 改成 `LucideIcons.code`
  - `UpdateDialog.show` 找不到: `static show()` 写错位置 (写到了 `_UpdateDialogState` 子类里), 移到 `UpdateDialog` 类
  - `DioExceptionType.transformTimeout` 没 match (dio 5.10+ 新增): 加到 `connectionTimeout` case 一起处理
- pubspec: `2.1.45+42 → 2.1.46+43`

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
- [CORSAPI](https://github.com/djsevenx1/CORSAPI) — 配套 CF Worker 后端,处理 m3u8 加速 / .ts 重写 / 源测速 / 视频流代理
- [djsevenx1/tmdb-proxy](https://github.com/djsevenx1/tmdb-proxy) — 配套 CF Worker 后端,处理 TMDB API / 图片 + Bangumi 数据 / 图片 加速 (v2.1.41+, fork 自 [HuntzzZ/tmdb-proxy](https://github.com/HuntzzZ/tmdb-proxy))
- [HuntzzZ/tmdb-proxy](https://github.com/HuntzzZ/tmdb-proxy) — tmdb-proxy 上游项目
- [media_kit](https://github.com/media-kit/media-kit) — Flutter 媒体播放
- [dlna_dart](https://github.com/dlna-dart/dlna_dart) — DLNA 投屏
- [cached_network_image](https://github.com/Baseflow/flutter_cached_network_image) — 网络图片缓存
- [Bangumi](https://bangumi.tv/) — 番剧数据源
- [TMDB](https://www.themoviedb.org/) — 影视元数据源
- [豆瓣](https://movie.douban.com/) — 影评与海报源

> **v2.1.40 变更**: 删了 ciao-cors 公共代理依赖。`ciao-cors.is-an.org` 对 `lain.bgm.tv` 反盗链图片 403 已知,留公共代理失败率太高。TMDB / Bangumi 加速改走用户自部署的 tmdb-proxy,完全可控。
