# LunaTV-Mobile 修复日记

> 增量修复记录,每个版本按「现象 → 排查 → 根因 → 修复 → 影响」展开。CI 完成后把对应的 changelog (`https://github.com/djsevenx1/LunaTV-Mobile/releases/tag/<ver>`) 作为发布说明同步到 GitHub Release。
>
> 详细 changelog 在 `.github/changelogs.json`,本文件是「为什么会这么改」的工程叙事。

---

## v2.5.16 (2026-07-21) — 启动时不预加载短剧 (回退 v2.5.15) + 加 tab 缓存

### 现象

1. v2.5.15 装上后, **App 启动不预加载短剧**, 要切到底栏「短剧」tab 才开始拉
2. **「打开短剧 ai 分类后切换到其他分类再切换回来」重新加载, 不是加载好的状态**

### 排查

- 现象 1: logcat 看 0 HTTP 请求来自 short drama 模块, 直到切到短剧 tab 才看到
- 现象 2: 切回「ai 漫剧」tab, logcat 看到 1 个 `getListByTypeId` HTTP 请求, 重新拉

### 根因 (v2.5.15 改错方向)

v2.5.15 改 `PageView` → `PageView.builder` + KeepAlive 是为了「app 启动时不预加载短剧」(以为这是用户想要的), 但用户**实际想要的是相反的**:

> 「启动app时就要开始加载短剧类容图片数据等不是我点击才开始加载」

并且用户**还**想要切 tab 不重新拉:

> 「我打开短剧ai分类后切换到其他分类在切换回来应该是加载好的状态不应该再次加载」

v2.5.15 改完后变成:
- 启动不预加载 ❌ (用户要预加载)
- 切 tab 重新拉 ❌ (用户要切回走缓存)

两个核心需求都没满足。

### 修复

#### 1. 回退 v2.5.15 PageView 改动

`home_screen.dart` `_buildBottomNavPageView` 改回 `PageView(children: [6 Screen])`:
- 6 个 child 的 initState 在 app 启动时全部跑
- 短剧 tab 立刻发 ~9 个 HTTP 请求拉分类 + 全部推荐
- 切到短剧 tab 时数据已经在路上 / 已到, 图片已 cache 到磁盘, 直接显示
- 删除 v2.5.15 加的 `_KeepAliveTab` widget

#### 2. 加 per-tab 缓存

`short_drama_screen.dart`:

**字段**:
```dart
final Map<String, _TabCacheEntry> _tabCache = {};
```

**`_onTypeTabChanged` 切走 save / 切回 restore**:
```dart
// 切走前 save 当前 tab 状态
if (_selectedTypeTab.isNotEmpty) {
  _tabCache[_selectedTypeTab] = _TabCacheEntry(
    list: List.from(_dramaList),
    shownNames: Set.from(_shownNames),
    page: _page,
    hasMore: _hasMore,
  );
}

// 切回时检查 cache, 命中直接 restore, 不发 HTTP
final cached = _tabCache[tab];
if (cached != null) {
  setState(() {
    _selectedTypeTab = tab;
    _dramaList..clear()..addAll(cached.list);
    _shownNames..clear()..addAll(cached.shownNames);
    _page = cached.page;
    _hasMore = cached.hasMore;
    _isLoading = false;
    _isLoadingMore = false;
    _errorMessage = null;
  });
  return;
}

// 未命中, 调 _fetchDramaList
```

**`_fetchDramaList` 写入后 save + 下拉刷新时清 cache**:
```dart
// isRefresh (下拉刷新) 时清掉缓存 — 强制重新拉, 不走缓存
if (isRefresh) {
  _tabCache.remove(_selectedTypeTab);
}

// ... setState 写入 _dramaList ...

// 写入成功后 save 当前 tab 到 _tabCache
_tabCache[_selectedTypeTab] = _TabCacheEntry(
  list: List.from(_dramaList),
  shownNames: Set.from(_shownNames),
  page: _page,
  hasMore: _hasMore,
);
```

**新增 class** (文件末尾):
```dart
class _TabCacheEntry {
  final List<ShortDrama> list;
  final Set<String> shownNames;
  final int page;
  final bool hasMore;
  const _TabCacheEntry({required ...});
}
```

### 教训

v2.5.15 把用户「打开 app 就开始加载短剧」误读成「别在 app 启动时加载短剧」(因为旧版本 v2.5.14 之前的行为是「启动加载」, v2.5.15 改成「点击才加载」, 我以为这是优化), 实际用户**原话**是反过来的。

接到需求变更时, **先把用户原话抄到 todo**, 再列对比表 (旧行为 / 新行为 / 用户原话), 确认方向正确再改代码. v2.5.15 的方向错在没回头看「为什么 v2.5.14 之前要 eager build」 — 因为用户一直就是想要启动预加载的, 我以为是 bug 改成了 lazy, 实际改完把正确行为干掉了。

### 影响

- App 启动时短剧 tab 立刻发请求拉分类 + 全部推荐 (跟 v2.5.14 之前行为一致)
- 切 tab 走 cache: 切回时直接展示已加载的列表, **不发 HTTP, 不显示 loading**
- 下拉刷新强制重新拉, 不受 cache 影响 — 缓存不会导致用户看不到最新数据
- 切 tab race condition 仍由 v2.5.14 generation + v2.5.15 `_loadCategories` 覆盖守卫双层防护

### 修改文件

- `lib/screens/home_screen.dart`:
  - `_buildBottomNavPageView` 改回 `PageView(children: [6 Screen])`
  - 删除 `_KeepAliveTab` widget
- `lib/screens/short_drama_screen.dart`:
  - 新增 `Map<String, _TabCacheEntry> _tabCache` 字段
  - `_onTypeTabChanged` 切走 save / 切回 restore from cache
  - `_fetchDramaList` 写入成功后 save to cache; isRefresh 时 `_tabCache.remove`
  - 新增 `class _TabCacheEntry` 在文件末尾
- `pubspec.yaml`: 2.5.15+1 → 2.5.16+1
- `.github/changelogs.json`: 头部插 v2.5.16 entry

---

## v2.5.15 (2026-07-21) — 短剧切 tab 串内容 (v2.5.14 没修好) + 打开 app 就开始加载短剧

### 现象

1. v2.5.14 装上后,**「全部」tab loading 中切到「其他」tab,内容变成「全部」内容**
2. **App 一打开就开始加载短剧内容**,即使用户根本没切到短剧 tab

### 排查

- 复现 1: 选「全部」等 0.5-1s 切到「ai 漫剧」, 70% 触发「列表内容是全部」
- 复现 2: App 启动后看 logcat, 9+ 个 `tyyszyapi.com` / `wujinapi.com` / `lziapi.com` HTTP 请求在飞, 跟用户操作无关

### 根因 (两个独立 bug)

**Bug A — `_loadCategories` 完成时强制覆盖 `_selectedTypeTab = '全部'`**

```dart
// v2.5.5 - v2.5.14 都有这行
setState(() {
  ...
  _selectedTypeTab = _kAllTabKey;  // 强制设回「全部」
});
```

时序:
- T0: app 启动 → `_loadCategories` 启动 (await `getCategories`, ~1-2s)
- T1: 用户在 await 期间切到「ai 漫剧」 → `_onTypeTabChanged` → setState `_selectedTypeTab = 'ai 漫剧'` → `_fetchDramaList` (gen=1, typeId=52)
- T2: `_loadCategories` 完成 → setState `_selectedTypeTab = '全部'` **覆盖用户选择** → `_fetchDramaList` (gen=2, typeId=null, 拉「全部」)
- T3: gen=1 (ai 漫剧) 完成 → myGen(1) != 2 → 丢弃
- T4: gen=2 (全部) 完成 → setState `_dramaList = 全部内容`
- 结果: UI 高亮「全部」+ 内容「全部」

v2.5.14 的 generation 机制只丢了**已经发起**的旧请求, 但 `_loadCategories` 完成后又**重新发起**了 gen=2 (拉「全部」), generation 没能阻止这个 — 因为 gen=2 自身是新的、有效的请求, 只是它**不该被发起**。

**Bug B — PageView 一次性 build 所有 children**

`home_screen.dart:587`:
```dart
return PageView(
  ...
  children: [
    _buildHomeContentWithPageView(),
    const MovieScreen(),
    const TvScreen(),
    const AnimeScreen(),
    const ShortDramaScreen(),  // initState 立即跑, 拉 ~9 个 HTTP
    const ShowScreen(),
  ],
);
```

`PageView` 默认**一次性** build 所有 children, `ShortDramaScreen.initState` 调 `_loadCategories` + 完成后调 `_fetchDramaList`, 即使短剧 tab 远离 viewport (用户没切到) 也会发 HTTP。

### 修复

#### Bug A — `_loadCategories` 不再覆盖

```dart
// v2.5.15
setState(() {
  _typeTabs = typeTabs;
  _typeToCategoryId
    ..clear()
    ..addAll(typeToId);
  // 只在未初始化时设回「全部」, 用户已切到「其他」tab 时不动
  if (_selectedTypeTab.isEmpty) {
    _selectedTypeTab = _kAllTabKey;
  }
});

// 只在 _dramaList 为空 + 没在 loading 时才自动拉, 避免覆盖 _onTypeTabChanged 已发起的请求
if (_dramaList.isEmpty && !_isLoading) {
  _fetchDramaList(isRefresh: true);
}
```

#### Bug B — PageView.builder + KeepAlive

`home_screen.dart`:
- `PageView` → `PageView.builder` (`itemCount: 6` + `itemBuilder` switch on index)
- 新加 `_KeepAliveTab` widget (`AutomaticKeepAliveClientMixin`, `wantKeepAlive = true`), 包每个 child

`PageView.builder` 默认只 build viewport 内 (当前页 + 左右各 1 页) 的 child, 远离的 child 不会 initState, 数据不会提前拉。`AutomaticKeepAliveClientMixin` 让已 build 过的 child 在 viewport 之外仍 keep alive, 切回来时 State 还在。

### 影响

- App 启动时短剧 tab 不再发 HTTP, 直到用户切到底栏「短剧」tab (viewport 内 build) 才会触发
- 切 tab 体验不变 (切回短剧 tab 数据 / 滚动位置都在, 不会 reload)
- 切 tab race condition 现在两层防护: generation 失配丢弃 + `_loadCategories` 不再覆盖用户选择

### 修改文件

- `lib/screens/short_drama_screen.dart`: `_loadCategories` 加 `if (_selectedTypeTab.isEmpty)` 守卫 + `if (_dramaList.isEmpty && !_isLoading)` 拉取守卫
- `lib/screens/home_screen.dart`: `_buildBottomNavPageView` 改 `PageView.builder` + 加 `_KeepAliveTab` widget
- `pubspec.yaml`: 2.5.14+1 → 2.5.15+1
- `.github/changelogs.json`: 头部插 v2.5.15 entry

---

## v2.5.14 (2026-07-21) — 短剧切 tab 偶尔显示上一个 tab 的内容

### 现象

短剧页面在「全部」tab 上点「ai 漫剧」,概率(不是必现)出现「列表内容还是全部分类」的串内容,顶部 tab 高亮却是 ai 漫剧。翻页 / 下拉刷新时偶发同样串内容。

### 排查

- 复现: 选「全部」等 1 秒立刻切到「ai 漫剧」,50% 触发。
- 反例: 等「全部」loading 完了再切任何 tab, 0% 触发。
- 直接定位 `ShortDramaScreen._fetchDramaList` 和 `_loadMoreDramaList` —— 两个 fire-and-forget async, 没有取消 / 丢弃机制。

### 根因

Race condition, 4 步时间线:

| t | 事件 | 状态 |
|---|---|---|
| 1 | 选「全部」→ `_fetchDramaList(isRefresh:true)` 启动 | `getRecommendResponse(size=60)` 3 源聚合, 慢 1-3s |
| 2 | 用户在 await 完成前点「ai 漫剧」 | `_selectedTypeTab = 'ai漫剧'`, 启动 `getListByTypeId(typeId=52)` 单源快 |
| 3 | t2 的 ai 漫剧结果先回来 | setState 把 ai 漫剧写入 `_dramaList` ✓ |
| 4 | t1 的「全部」结果后回来 | setState `addAll(全部内容)`, 覆盖了 ai 漫剧 → UI 高亮 ai 漫剧但列表是「全部」 |

`_loadMoreDramaList` 同样问题: 旧 tab 的 `_page++` await 完成时若已切到新 tab, 旧结果追加到新 tab 列表, 乱序且重复。

### 修复

`lib/screens/short_drama_screen.dart` 加 **Generation Counter**:

```dart
int _fetchGeneration = 0;

Future<void> _fetchDramaList({bool isRefresh = false}) async {
  final myGen = ++_fetchGeneration;   // 抢当前代
  // ... setState 清空 ...
  result = await ShortDramaDirectService.getRecommendResponse(...);
  if (myGen != _fetchGeneration) return;  // 已过期, 丢弃
  setState(() { _dramaList.addAll(result.list); ... });
}
```

`_loadMoreDramaList` 同样保护, 失配时 `_page--` 还原。

### 为什么是 generation 而不是 CancelToken

- `ShortDramaDirectService` 用 `http` 包的普通 `Future`, 没有 CancelToken 包装
- generation 计数 0 额外开销 0 复杂度, State 里一个 int 字段就够
- Flutter 官方推荐这种模式 (`flutter_bloc` 内部也是 `sequenceNumber` 思路)
- 跨冷启动也没问题: State 重建时 `_fetchGeneration = 0` 自然从头开始

### 影响

- 切 tab 速度感觉不到变化 (gen 计数是同步 1 行)
- 翻页 / 切 tab / 下拉刷新 三者现在互不打架, 后完成的旧请求被静默丢弃
- 已展示剧名去重 set (`_shownNames`) 仍按 v2.5.6 切 tab 时清空, 跟 generation 互补: set 负责「不重复同一部剧」, generation 负责「不写错 tab 的数据」

### 修改文件

- `lib/screens/short_drama_screen.dart`: 加 `_fetchGeneration` 字段 + `_fetchDramaList` / `_loadMoreDramaList` 启动时 `++_fetchGeneration`, await 后比对失配 return
- `pubspec.yaml`: 2.5.13+1 → 2.5.14+1
- `.github/changelogs.json`: 头部插 v2.5.14 entry

---

## v2.5.13 (2026-07-21) — 源浏览器 hero header 仍被状态栏切到 (修 v2.5.12 装上后没修好)

### 现象

v2.5.12 改完源浏览器后, 用户装上 APK 测, 「源浏览器」标题仍紧贴状态栏底沿。`v2.5.12` 在 `_buildHeroHeader` 内部用 `MediaQuery.padding.top` 算 `safeTop = max(24, viewPadding.top)`, 加 16dp 视觉缓冲, 理论上够, 但实测不够。

### 排查

- 截图复现: 标题 baseline 到状态栏底沿 ≤ 16dp, 视觉上几乎「贴着」
- 真根因不是 padding 数值不够, 而是**手算 MediaQuery 在某些 Android 设备 / 沉浸模式 / 厂商 ROM 下不可靠**: `padding.top` 经常报告 0, 只能 `viewPadding.top` 拿真值, 但具体行为 Flutter 没文档保证

### 修复

`lib/screens/source_browser_screen.dart` 改用 **Flutter 官方 `SafeArea`** 兜 status bar:

```dart
body: SafeArea(
  top: true,         // status bar 整段让出
  bottom: false,     // 页面自带 bottom nav, 不要给底部 nav bar 留白
  child: CustomScrollView(
    slivers: [
      SliverToBoxAdapter(child: _buildHeroHeader(theme, isDark)),
      ...
    ],
  ),
)
```

`_buildHeroHeader` 签名去掉 `BuildContext` 参数, padding top 改成纯视觉 8dp (status bar 让 SafeArea 走了)。

### 结果

最终 icon 离屏顶 = `statusBarHeight (≥24) + 8 + 20 = ≥ 52dp`, 视觉宽松。`SafeArea` 内部已经处理所有边界 case (挖孔 / 手势条 / 系统 bar 透明 / 沉浸模式), 比手算稳。

### 修改文件

- `lib/screens/source_browser_screen.dart`: body 加 `SafeArea(top:true, bottom:false)`, `_buildHeroHeader` 改签名 + 简化 padding
- `pubspec.yaml`: 2.5.12+1 → 2.5.13+1
- `.github/changelogs.json`: 头部插 v2.5.13 entry

---

## v2.5.12 (2026-07-21) — 源浏览器 hero header 被状态栏切到 (改对文件)

### 现象

源浏览器页面 (`SourceBrowserScreen`) 的 hero header 标题被状态栏切到, 用户反馈「整个界面往下挪一点或加一点空白」。

### 误判历史 (v2.5.9 / v2.5.10 / v2.5.11)

之前 3 个版本都改 `MainLayout._buildHeader` 顶部 padding, 但用户的截图里的页面是 **源浏览器 (`SourceBrowserScreen`)**, 那是**独立 Scaffold + CustomScrollView**, 跟 `main_layout` 完全无关 —— `MainLayout` 只在主 app 框架的 [首页 / 历史 / 收藏] tab 用, source browser 是用户点开的一个独立子页面, 自己的 Scaffold 没 SafeArea 也没 status bar top padding, hero header 紧贴状态栏底沿。

3 次改错文件, 用户怎么装都看不到变化。

### 修复

改 `lib/screens/source_browser_screen.dart` 的 `_buildHeroHeader`:

```dart
Widget _buildHeroHeader(BuildContext context, ThemeData theme, bool isDark) {
  final mediaQuery = MediaQuery.of(context);
  final mediaTop = mediaQuery.padding.top;
  final viewTop = mediaQuery.viewPadding.top;
  final baseTop = viewTop > mediaTop ? viewTop : mediaTop;
  final safeTop = baseTop < 24.0 ? 24.0 : baseTop;
  return Container(
    padding: EdgeInsets.fromLTRB(16, safeTop + 16, 16, 8),  // 16 → safeTop + 16
    ...
  );
}
```

### 撤回 v2.5.9-v2.5.11

3 个 `git revert` 撤回到 v2.5.8 hotfix 状态, 不再动 `main_layout.dart`。详见 `v2.5.9-v2.5.11 REVERTED` changelog 条目。

### 修改文件

- `lib/screens/source_browser_screen.dart`: `_buildHeroHeader` 接 `BuildContext`, padding top 16 → safeTop + 16
- `pubspec.yaml`: 2.5.8+1 → 2.5.12+1 (跳过被 revert 的 9/10/11)
- `.github/changelogs.json`: 头部插 v2.5.12 + 撤回说明条目

---

## v2.5.9-v2.5.11 REVERTED — 状态栏挡住 header, 改错文件

### 现象 (用户原话)

「你之前改错了吧」 —— v2.5.9 / v2.5.10 / v2.5.11 三个版本都改 `MainLayout._buildHeader` 顶部 padding, 但用户实际看到状态栏挡住的是 **源浏览器页面 (`SourceBrowserScreen`)**, 那是**独立 Scaffold**, 跟 main_layout 完全无关。

### Reverted commits

| commit | 说明 |
|---|---|
| `3a8816b` v2.5.9 | 改 main_layout `max(24, padding.top) + 8` |
| `6bd49b7` v2.5.10 | 改 main_layout `max(40, viewPadding.top) + 8` |
| `880d66f` v2.5.11 | 改 main_layout 加 SafeArea 整 body 包住 |

Revert commits: `9b243fe` (v2.5.11), `a1ba4d4` (v2.5.10), `72a2ba8` (v2.5.9)。

### 教训

收到状态栏相关反馈时, 第一步看截图确认**是哪个页面**, 不要假设是 home / main app 框架。源浏览器这种「独立子页面 (自己的 Scaffold)」很容易被误判为「主 app 框架」。

---

## v2.5.8 (2026-07-21) — v2.5.7 编译失败 hotfix

### 现象

v2.5.7 release workflow 跑 Android build 失败 4 次 (retry_on: error 尝试 4 次都失败)。CI 编译错误:

```
lib/screens/player_screen.dart:1112:41: Error: The getter 'message'
isn't defined for the class 'DataOperationResult<void>'.
```

### 根因

v2.5.7 在 `_toggleFavorite` 里写了 `result.message ?? '收藏操作失败'` 做 SnackBar 失败提示。但 `DataOperationResult<T>` 实际字段是 `errorMessage` (nullable String), **没有 `message` getter**。之前看视频 / 历史页有同款写法 (走 `ApiService` Response, 那个有 `message` 字段), 直接套用错了, 没核对 model 定义。

### 修复

```dart
- SnackBar(content: Text(result.message ?? '收藏操作失败'))
+ SnackBar(content: Text(result.errorMessage ?? '收藏操作失败'))
```

一处改动, 全项目 grep 确认无其他 `result.message` 残留。

### 影响

v2.5.7 编译失败, GitHub release 页面 v2.5.7 tag **没有** APK, 用户拿不到 v2.5.7。v2.5.8 是唯一可下载的「收藏修复」版本。

### 修改文件

- `lib/screens/player_screen.dart`: `result.message` → `result.errorMessage`
- `pubspec.yaml`: 2.5.7+1 → 2.5.8+1

---

## v2.5.7 (2026-07-21) — 收藏页看不到影片 + 历史/收藏 tab 走 PageView

### 现象

1. 播放器点亮收藏后, 收藏页看不到影片
2. 点击「历史」/「收藏」, 不应该 push 独立全屏页面, 应该跟「首页」tab 一样在一个 PageView 内左右滑切

### 根因

- `PlayerScreen._toggleFavorite` 只往 SharedPreferences 写了一个**孤立的** bool key `fav_<source>_<id>`, 没调任何 `ApiService.favorite` / `PageCacheService.addFavorite`。收藏页读的是 `PageCacheService().getFavorites(context)` (后端权威源 + 本地缓存), 这个孤立的 bool 不在收藏列表里, 所以永远显示不出来。
- `HomeScreen._onTopTabChanged` 在 case '播放历史' / '收藏夹' 里 `await Navigator.pushNamed('/history')` 或 `/favorites`, 打开独立全屏页面, 跟图一样式 (tab 切换) 不一致。

### 修复

#### 收藏修复

`player_screen.dart` `_toggleFavorite` / `_loadFavorite` 改用 `PageCacheService`:

- `_favoriteSourceKey()`: 短剧页 `videoInfo.source = ''` (ShortDramaScreen._onDramaTap 没传 source), 用 `__shortdrama__` 作 source 名, 避免空字符串 key 冲突
- `_favoriteData()`: 包装 videoInfo 字段到 `PageCacheService` 期望的 `Map<String, dynamic>` 格式
- `_loadFavorite`: `PageCacheService().isFavoritedSync(source, id)` 同步查, 跟视频源后端 + 本地缓存一致
- `_toggleFavorite`: `PageCacheService().toggleFavorite(source, id, _favoriteData(), context)`, 内部走 ApiService.favorite / unfavorite + 本地缓存。失败回滚 UI + SnackBar, 成功后 `FavoritesGrid.refreshFavorites()` 通知收藏 tab 立即刷新

#### 历史/收藏 tab 走 PageView

`home_screen.dart` 重写 `_onTypeTabChanged` 三个 case:

```dart
case '播放历史': pageIndex = 1; break;  // 不 push, 走 PageView
case '收藏夹':   pageIndex = 2; break;  // 不 push, 走 PageView
```

`/history` 和 `/favorites` 路由仍保留 (main.dart:100-101), 万一别处有 pushNamed 还能用。但 HomeScreen 不再走这两个路由。

### 修改文件

- `lib/screens/player_screen.dart`: 重写 _toggleFavorite + _loadFavorite + 新增 _favoriteSourceKey / _favoriteData helper + FavoritesGrid.refreshFavorites
- `lib/screens/home_screen.dart`: 重写 _onTypeTabChanged 三个 case, pushNamed → pageIndex + animateToPage

---

## v2.5.6 (2026-07-21) — 短剧「全部」tab 只有 20 部

### 现象

短剧「全部」tab 只显示 20 部, 用户觉得「怎么只有 20 部」。

### 根因

TVBox 协议每页固定 20 条 (`size` 参数只是 hint, 实际返回数 ≤ 20), v2.5.5 之前 `getRecommend` 一次拉 1 页 = 20 条。

### 修复

`lib/services/short_drama_direct_service.dart`:

- `_DirectSource` 加 `pages` 字段, 默认 3 页
- `getRecommendResponse` 方法: 聚合 3 源, 按 `pages=3` 串行 / 并发拉多页, 去重合并

修后 3 源 9 type 聚合 ≈ 540 条原始, 去重后 100-300 条展示。

### 副作用 / 风险

- 3 源 × 3 页 = 9 次 HTTP 请求, 单次失败 fallback 单源 (有重试)
- 切 tab / 翻页 race condition 没处理 (v2.5.14 才修)

### 修改文件

- `lib/services/short_drama_direct_service.dart`: `_DirectSource.pages` 字段 + `getRecommendResponse` 方法
- `pubspec.yaml`: 2.5.5+1 → 2.5.6+1

---

## v2.5.5 (2026-07-21) — 短剧分类 tab 第一位加「全部」

### 现象

短剧分类 tab 列表第一位应该加「全部」(聚合 3 源), 不应该直接以「短剧」主类打头。

### 修复

`lib/screens/short_drama_screen.dart`:

- `_typeTabs` 永远第一位插入 `_kAllTabKey = '全部'`
- 过滤掉分类列表里名为「短剧」的主类 (被「全部」替代)
- 选「全部」tab 时走 `_currentSelectedTypeId() == null` 兜底 → `getRecommendResponse` 3 源聚合
- 选具体子类时走 `getListByTypeId(typeId)` 单源单 type

### 修改文件

- `lib/screens/short_drama_screen.dart`: `_loadCategories` 加「全部」tab + 过滤「短剧」主类
- `pubspec.yaml`: 2.5.4+1 → 2.5.5+1
