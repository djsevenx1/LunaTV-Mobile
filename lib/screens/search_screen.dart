import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:luna_tv/services/page_cache_service.dart';
import 'package:luna_tv/services/search_result_ranker.dart';
import 'package:luna_tv/services/sse_search_service.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/services/douban_service.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/local_mode_storage_service.dart';
import 'package:luna_tv/models/search_result.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/widgets/video_menu_bottom_sheet.dart';
import 'package:luna_tv/widgets/custom_switch.dart';
import 'package:luna_tv/widgets/favorites_grid.dart';
import 'package:luna_tv/widgets/search_result_agg_grid.dart';
import 'package:luna_tv/widgets/search_results_grid.dart';
import 'package:luna_tv/widgets/filter_options_selector.dart';
import 'package:luna_tv/widgets/filter_pill_hover.dart';
import 'package:luna_tv/widgets/main_layout.dart';
import 'package:luna_tv/utils/font_utils.dart';
import 'package:luna_tv/utils/device_utils.dart';
import 'package:luna_tv/screens/player_screen.dart';

// SearchProgress model 已经在 sse_search_service.dart 定义过，懒得重复，直接引用

enum SortOrder { none, asc, desc }

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with TickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  String _searchQuery = '';
  List<String> _searchHistory = [];
  List<SearchResult> _searchResults = [];
  bool _hasSearched = false;
  // v2.5.26: 加 loading 状态, 搜索中给用户即时反馈 (之前搜索时显示空状态, 用户以为卡死)
  bool _isLoading = false;
  String? _searchError;
  Timer? _updateTimer;
  bool _useAggregatedView = true;

  // 搜索代际 guard. debounce 缩短到 400ms 后, 用户还在输入就可能触发
  //   新搜索, 旧搜索的 await 晚返回会覆盖新搜索的空/loading 状态, 导致"结果突然消失".
  //   每次发起新搜索递增 generation, await 返回后校验, 不匹配就丢弃结果.
  int _searchGeneration = 0;

  // v2.6.7: 改用 SSESearchService 走客户端直连 + SSE 增量推回 (跟 Selene 一致).
  //   本地模式 → 客户端直连资源站 ?ac=videolist&wd=... 并行搜, 自维护源
  //   (LocalModeStorageService 存的) 也能搜.
  //   非本地模式 → 后端 /api/search/ws SSE 推流, 后端按 source+id 去重,
  //   每搜完一个 source 就推回 source_result 事件.
  //   之前 _performSearch 走 ApiService.fetchSourcesData → 后端 /api/search
  //   聚合接口 → 后端按 title+year+type 跨源合并 (e.g. 18 源同剧聚成 1 条
  //   SearchResult + 17 条进 extraSources) → SearchResultAggGrid 拿到
  //   1 条 SearchResult 只能显示 1 个源名. 跟 web 的 source_names.join(',')
  //   行为不一致. 改 SSE 后后端不再做跨源合并, 18 条全推回, SearchResultAggGrid
  //   按 title+year+类型 自己聚合 + join 所有源名, 跟 web 一致.
  final SSESearchService _sseSearchService = SSESearchService();
  StreamSubscription<List<SearchResult>>? _incrementalResultsSubscription;
  StreamSubscription<SearchProgress>? _progressSubscription;
  StreamSubscription<String>? _errorSubscription;
  SearchProgress? _searchProgress;

  // v2.6.9: 精确搜索开关 — 跟 web 端 exactSearch 1:1, 默认开.
  //   开: 搜「凡人修仙传」只显示 title 含「凡人修仙传」的剧 (凡人修仙传 /
  //       凡人修仙传 新版 等), 不显示「凡人修仙之风起」/「仙林外传」
  //       等不相关卡片. 关: 显示全部结果 (跟 v2.6.8 行为一致).
  //   持久化到 SharedPreferences key 'exact_search' (跟 web 端 localStorage
  //   key 'exactSearch' 1:1), 跨 app 重启保留用户选择.
  bool _exactSearch = true;

  // v2.6.16: 每个源的结果数 — 用户反馈「奈飞工厂源app搜不到内容」, 但
  //   实际是源 API 本身就没数据. 搜完时拉取 sourceResultCounts, 渲染成
  //   "奈飞工厂 0 条 / 普通源 5 条" 提示, 用户能区分「源没数据」vs
  //   「app 没搜这个源」. 折叠起来, 默认不占 UI 空间, 长按展开.
  Map<String, int> _sourceResultCounts = {};
  Map<String, String> _sourceKeyToName = {};
  bool _showSourceDebug = false;

  // 筛选/排序状态（保持不变）
  String _selectedSource = 'all';
  String _selectedYear = 'all';
  String _selectedTitle = 'all';
  SortOrder _yearSortOrder = SortOrder.none;

  // 长按删除相关状态
  String? _deletingHistoryItem;
  AnimationController? _deleteAnimationController;
  Animation<double>? _deleteAnimation;

  // hover 状态
  String? _hoveredHistoryItem;
  String? _hoveredDeleteButton;
  String? _hoveredFilterPill;
  bool _isYearSortHovered = false;
  bool _isClearHistoryButtonHovered = false;

  List<SearchResult> get _filteredSearchResults {
    // v2.6.7: 过滤 0 集源 — 下游 DownstreamService.searchPage 和后端
    //   /api/search/ws 都过滤了 episodes.isEmpty, 但 SSE 增量结果 addAll
    //   (line 169) 和 SearchResultAggGrid 聚合都没二次过滤. 一旦某个
    //   SearchResult 漏过 (例如未来加新 source / 后端 SSE 改动 / 缓存里
    //   存进 0 集) 就会显示"0集"卡片污染结果. 这里兜底过滤.
    List<SearchResult> results =
        _searchResults.where((r) => r.episodes.isNotEmpty).toList();
    // v2.6.9: 精确搜索过滤 (跟 web 端 page.tsx:602-615 titleContainsQuery
    //   + exactSearch 1:1). web 端聚合前先 filter title 包含 query, 不相关
    //   卡片 (搜"凡人修仙传" 出现"凡人修仙之风起" / "仙林外传" / "修仙外传"
    //   等 title 不含 query 的剧) 默认被过滤. app 端之前只有相关性排序,
    //   低分卡片 (10-20 分) 仍混在前面, 体感"搜索太随意了".
    //   精确搜索默认开, 跟 web 默认行为一致. 关掉 (_exactSearch=false)
    //   返回 v2.6.8 行为, 让用户能看到全部结果.
    if (_exactSearch) {
      results = results
          .where((r) => SearchResultRanker.resultMatchesQuery(r, _searchQuery))
          .toList();
    }
    // v2.6.7: 相关性排序, 跟 web 端 search-ranking.ts 1:1. 之前 SSE 拿到
    //   结果直接 addAll, 不相关卡片 (搜"凡人修仙传" 出现"凡人修仙之风起" /
    //   "仙林外传" 等) 跟相关卡片混在一起显示. 跟 web 行为对齐:
    //   完全匹配 100 / 开头匹配 80 / 包含 60 / 模糊 20-40 + 年份/豆瓣加分.
    results = SearchResultRanker.rankSearchResults(results, _searchQuery);
    if (_selectedSource != 'all') results = results.where((r) => r.sourceName == _selectedSource).toList();
    if (_selectedYear != 'all') results = results.where((r) => r.year == _selectedYear).toList();
    if (_selectedTitle != 'all') results = results.where((r) => r.title == _selectedTitle).toList();
    if (_yearSortOrder != SortOrder.none) {
      results.sort((a, b) {
        final yearAIsNum = int.tryParse(a.year) != null;
        final yearBIsNum = int.tryParse(b.year) != null;
        if (yearAIsNum && !yearBIsNum) return -1;
        if (!yearAIsNum && yearBIsNum) return 1;
        if (!yearAIsNum && !yearBIsNum) return 0;
        final yearA = int.parse(a.year);
        final yearB = int.parse(b.year);
        return _yearSortOrder == SortOrder.desc ? yearB.compareTo(yearA) : yearA.compareTo(yearB);
      });
    }
    return results;
  }

  @override
  void initState() {
    super.initState();
    _loadSearchHistory();
    // v2.6.9: 加载精确搜索开关 (跟 web 端 page.tsx 读 localStorage 一致).
    unawaited(_loadExactSearch());
  }

  Future<void> _loadExactSearch() async {
    final v = await UserDataService.getExactSearch();
    if (mounted) setState(() => _exactSearch = v);
  }

  // v2.6.24: fire-and-forget 拉源列表. 主搜索 /api/search/ws 启动不阻塞
  //   这个 getSearchResources (80 源配置读 DB, 后端 0.5-2s). 失败时
  //   _sourceKeyToName 保持空 Map, debug 面板不显示, 不影响搜索.
  Future<void> _loadSourceKeyToName(int gen) async {
    try {
      final isLocalMode = await UserDataService.getIsLocalMode();
      final resources = isLocalMode
          ? await LocalModeStorageService.getSearchSources()
          : await ApiService.getSearchResources();
      if (!mounted || gen != _searchGeneration) return;
      setState(() {
        _sourceKeyToName = {
          for (final r in resources.where((r) => !r.disabled)) r.key: r.name
        };
      });
    } catch (_) {
      // 兜底, 失败不污染状态
    }
  }

  Future<void> _loadSearchHistory() async {
    final result = await PageCacheService().getSearchHistory(context);
    if (mounted) {
      setState(() => _searchHistory = result.data ?? const <String>[]);
    }
  }

  void _onSearchQueryChanged(String query) {
    // v2.6.20: 对齐 Selene 行为 — 输入只更新文本, 不触发主搜索.
    //   之前 100ms debounce + 边输边搜虽然"看起来跟手", 但实际每次按键
    //   都递增 _searchGeneration + cancel 旧 SSE + 重启新 SSE, 浪费
    //   网络/CPU. Selene 是回车/点搜索按钮才搜, 体感"快"是因为不浪费
    //   请求, 单次搜索能跑完所有源. LunaTV-Mobile 之前 5 源没结果用户
    //   体感"慢", 根因是重复打断正在搜的 SSE, 不是搜索本身慢.
    //   现在: 输入只更新 _searchQuery, 触发 main_layout 内的 suggestions
    //   搜索建议. 主搜索只在 onSearchSubmitted 触发, 跟 Selene 一致.
    setState(() {
      _searchQuery = query;
    });
  }

  Future<void> _performSearch(String query) async {
    // v2.6.32: 搜索不返回结果的根本原因修复 + 启动速度优化.
    //
    // 根本原因: 之前先 await stopSearch() (把 _incrementalResultsController
    //   设为 null), 然后订阅 stream — 此时 incrementalResultsStream 返回
    //   const Stream.empty(), listener 永远收不到事件! 之后 startSearch
    //   创建新的流控制器, 但 listener 已经订阅了 empty stream.
    //
    // 修复: 先 startSearch (创建新流控制器 + 发起 SSE), 再订阅 stream.
    //   startSearch 内部快速取消旧连接 (不 await), SSE 请求是 fire-and-forget,
    //   返回后流控制器已就绪, SSE 结果还没到达 (需网络往返), listener
    //   会在第一批事件之前完成订阅.
    //
    // 速度优化: 旧搜索取消改 fire-and-forget, 不 await. 之前 4 个 await
    //   (cancel x3 + stopSearch) + stopSearch 内部 3 个 await close = 7 个
    //   async 操作串行排队, 拖慢 SSE 请求发起. 现在 0 个 await, SSE 请求
    //   立即发起.
    unawaited(_incrementalResultsSubscription?.cancel());
    unawaited(_progressSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());

    final gen = ++_searchGeneration;
    setState(() {
      _hasSearched = true;
      _searchResults = [];
      _searchError = null;
      _isLoading = true;
      _searchProgress = null;
      _sourceResultCounts = {};
    });

    unawaited(_loadSourceKeyToName(gen));

    // v2.6.32: 先 startSearch — 内部快速取消旧连接 + 创建新流控制器 +
    //   发起 SSE 请求 (fire-and-forget). 返回后流控制器已就绪.
    try {
      await _sseSearchService.startSearch(query);
    } catch (e) {
      if (!mounted || gen != _searchGeneration) return;
      setState(() {
        _searchError = e.toString();
        _isLoading = false;
      });
      return;
    }

    // v2.6.32: 在 startSearch 之后订阅 — 此时流控制器已创建.
    //   SSE 请求是 fire-and-forget, startSearch 返回后结果还没到达
    //   (需 TCP/TLS 握手 + 后端处理 ~1s), listener 会在第一批事件
    //   之前完成订阅.
    _incrementalResultsSubscription = _sseSearchService
        .incrementalResultsStream
        .listen((incrementalResults) {
      if (!mounted || gen != _searchGeneration) return;
      if (incrementalResults.isEmpty) return;
      final filtered = incrementalResults
          .where((r) => r.episodes.isNotEmpty)
          .toList();
      if (filtered.isEmpty) return;
      setState(() {
        _searchResults = [..._searchResults, ...filtered];
      });
    });

    _progressSubscription = _sseSearchService.progressStream.listen((progress) {
      if (!mounted || gen != _searchGeneration) return;
      setState(() {
        _searchProgress = progress;
        if (progress.isComplete) {
          _isLoading = false;
          _sourceResultCounts = _sseSearchService.sourceResultCounts;
        }
      });
    });

    _errorSubscription = _sseSearchService.errorStream.listen((error) {
      if (!mounted || gen != _searchGeneration) return;
      setState(() {
        _searchError = error;
        _isLoading = false;
      });
    });
  }

  /// v2.6.22: 删 _runSearchFallback / _runMultiNameSearch 两个方法体,
  ///   走纯 SSE 增量推回, 跟 Selene 1:1. 之前 8s /api/search 兜底 +
  ///   3s 豆瓣别名搜 fire /api/search 聚合 (后端 80 源 Promise.allSettled),
  ///   跟主路 SSE 并发跑 80*5=400 源, 后端/资源站全打满, SSE 主路
  ///   跟着卡, 结果数还被 _exactSearch subsequence 过滤 (凡人修仙之风起 /
  ///   仙林外传等) — 用户体感「搜得没 Selene 全, 又慢」根因.

  @override
  void dispose() {
    _updateTimer?.cancel();
    _incrementalResultsSubscription?.cancel();
    _progressSubscription?.cancel();
    _errorSubscription?.cancel();
    // 异步 stopSearch 不 await — dispose 是 sync, fire-and-forget
    //   SSESearchService.stopSearch 内部会关 _client / _subscription.
    unawaited(_sseSearchService.stopSearch());
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MainLayout(
      isSearchMode: true,
      selectedTopTab: '',
      onTopTabChanged: (_) {},
      currentBottomNavIndex: -1,
      onBottomNavChanged: (_) {},
      searchController: _searchController,
      searchFocusNode: _searchFocusNode,
      searchQuery: _searchQuery,
      onSearchQueryChanged: _onSearchQueryChanged,
      onSearchSubmitted: (q) => _performSearch(q.trim()),
      onClearSearch: () {
        if (_searchController.hasListeners) _searchController.clear();
        // v2.5.27: 清空时让进行中的搜索作废
        _searchGeneration++;
        // v2.6.7: 清空时也停掉 SSE, 不然旧搜索的结果还会继续推回
        unawaited(_sseSearchService.stopSearch());
        _incrementalResultsSubscription?.cancel();
        _progressSubscription?.cancel();
        _errorSubscription?.cancel();
        setState(() {
          _searchQuery = '';
          _hasSearched = false;
          _searchResults = [];
          _searchError = null;
          _isLoading = false;
          _searchProgress = null;
        });
      },
      content: Column(
        children: [
          // 错误提示
          if (_searchError != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.red.withOpacity(0.1),
              child: Text(
                '搜索失败: $_searchError',
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
          // v2.6.9: 精确搜索开关 — 跟 web 端 SettingsPanel 暴露的 toggle
          //   一致. 默认开, 用户可关掉看全部结果 (兜底). 用 Switch + 简短
          //   标签, 跟搜索结果区同列, 不占额外导航.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Text('精确搜索',
                    style: TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(width: 8),
                Switch(
                  value: _exactSearch,
                  onChanged: (v) {
                    setState(() => _exactSearch = v);
                    unawaited(UserDataService.saveExactSearch(v));
                  },
                ),
                const SizedBox(width: 8),
                Text(
                  _exactSearch
                      ? '只显示剧名含「$_searchQuery」的剧'
                      : '显示全部结果 (低相关也展示)',
                  style: const TextStyle(fontSize: 11, color: Colors.black45),
                ),
              ],
            ),
          ),
          // v2.6.33: 删顶部 banner — 用户反馈上下都有进度条, 去掉上面的.
          //   之前 Column 内 + Stack 内各渲染一次 _buildTopLoadingBanner (图2
          //   重复两个), 加上 Column 内旧进度条 (图1 上下各一个). 现在全删,
          //   只保留 Stack 内底部 footer (_buildSearchFooter), 搜索进度统一
          //   在底部显示.
          // v2.6.16: 每个源的结果数 — 用户反馈「奈飞工厂源app搜不到内容」,
          //   加这个折叠面板, 让用户看到每个源搜出多少条. 0 条的源用红字标,
          //   区分「源被 app 搜了但 API 没数据」vs「app 没搜这个源」.
          //   默认收起, 避免干扰主结果视图; 用户点 "查看 X 个源" 才展开.
          if (_hasSearched && _sourceResultCounts.isNotEmpty)
            _buildSourceResultDebugPanel(),
          // 搜索结果
          // v2.6.33: 只保留底部 footer, 删掉 Stack 内顶部 banner.
          //   搜索进度统一在底部显示, 不再上下重复.
          Expanded(
            child: Stack(
              children: [
                // 底层 — 结果区 grid, 永远渲染
                Positioned.fill(
                  child: _buildSearchResults(),
                ),
                // 底部 footer — 搜索进度/完成指示, fixed 屏幕底部
                if (_hasSearched)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: _buildSearchFooter(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// v2.6.16: 每个源的结果数 — 折叠面板, 显示"奈飞工厂 0 条 / 普通源 5 条"等,
  ///   让用户区分「源没数据」vs「app 没搜这个源」.
  ///   0 条源用红色, 正常源用绿色. 默认收起, 标题栏显示总览.
  Widget _buildSourceResultDebugPanel() {
    // 按 sourceName 排序, 0 条的排前面 (异常优先展示)
    final entries = _sourceKeyToName.entries
        .map((e) => MapEntry(
            e.value,
            _sourceResultCounts[e.key] ?? -1)) // -1 = app 没搜这个源
        .toList();
    entries.sort((a, b) {
      // -1 (没搜) 排第一, 0 (搜了但没数据) 排第二, >0 排后面
      if (a.value == -1 && b.value != -1) return -1;
      if (a.value != -1 && b.value == -1) return 1;
      if (a.value == 0 && b.value > 0) return -1;
      if (a.value > 0 && b.value == 0) return 1;
      return a.key.compareTo(b.key);
    });

    final zeroCount = entries.where((e) => e.value == 0).length;
    final notSearchedCount = entries.where((e) => e.value == -1).length;
    final hitCount = entries.where((e) => e.value > 0).length;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFf5f5f5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _showSourceDebug = !_showSourceDebug),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.info_outline,
                      size: 14, color: Colors.black54),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '搜索源详情 — 命中 $hitCount 个 / 0 条 $zeroCount 个'
                      '${notSearchedCount > 0 ? ' / 未搜 $notSearchedCount 个' : ''}',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.black87),
                    ),
                  ),
                  Icon(_showSourceDebug
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 16,
                      color: Colors.black54),
                ],
              ),
            ),
          ),
          if (_showSourceDebug)
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final e in entries)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: e.value > 0
                                  ? Colors.green
                                  : (e.value == 0
                                      ? Colors.red
                                      : Colors.grey),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              e.key,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.black87),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            e.value == -1 ? '未搜' : '${e.value} 条',
                            style: TextStyle(
                              fontSize: 11,
                              color: e.value > 0
                                  ? Colors.green
                                  : (e.value == 0
                                      ? Colors.red
                                      : Colors.grey),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  const Text(
                    '• 绿色 = 搜到结果  •  红色 = 源被搜了但没数据  •  灰色 = app 未搜',
                    style: TextStyle(fontSize: 9, color: Colors.black45),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchResults() {
    // v2.6.30: 删 footer 渲染 — footer 改 fixed 屏幕底部 (跟 web 端
    //   page.tsx:2461 `fixed bottom-0 left-0 right-0 z-50` 1:1). 之前
    //   footer 在 Column 末尾占位, 结果多时 (18 源满结果) 需要滚到
    //   最底才能看到完成徽章, 体感"半天不错搜索结果". 改 Stack + Positioned
    //   fixed 覆盖在结果区上, 跟 web 完全一致.
    // v2.6.28: 架构级大改 — 跟 web 端 (LunaTV-web/src/app/search/page.tsx:2300-2470) 1:1
    //   渲染. 之前 `_isLoading && _searchResults.isEmpty` 二态门 (line 607-630) 强制
    //   loading 转圈必须等第一批 source_result 到达, 慢源场景用户看 20s 转圈.
    //
    //   web 端的模式: 结果区**永远渲染** searchResults (从 start 事件起累积), 跟
    //   `isLoading` 完全解耦. `isLoading = streamedQuery.isFetching` 只用于:
    //   1) 标题区小转圈 + "5/18" 进度
    //   2) Footer 底部小条 banner "正在搜索更多结果..." (仅当 results.length > 0)
    //   3) Footer 大徽章 "搜索完成 共 N 个" (仅当 !isLoading && results.length > 0)
    //
    //   翻译到 Flutter:
    //   - `_isLoading` = "stream 还在跑, 还没收 complete 事件" (跟 web isFetching 同款)
    //   - **永远** 渲染结果区 (空就空, SearchResultAggGrid / SearchResultsGrid 内部
    //     自己处理 empty state, 跟 web VideoCard empty 行为一致)
    //   - 加 `_buildSearchFooterBanner` 底部小条 + `_buildSearchFooterComplete` 底部
    //     大徽章, 跟 web line 2460-2470 1:1
    //   - 删 v2.6.27 的 3s 兜底定时器 (line 60-71 字段 + line 230-235 / 257-265 /
    //     348-350 / 381-384 所有 cancel 防御) — 现在 loading 不再"门控"结果, 没
    //     兜底必要. Loading 永远 true 直到 complete, 体感"还在搜"是正确语义, 不
    //     兜底. v2.6.27 changelog 描述的 3s loading 兜底场景, 跟 web 不一致, 是
    //     "前端硬编了个假门" 的 hack. 删
    //
    //   行为对比 (搜「凡人修仙传」, 18 源后端):
    //   | 场景 | 改前 (v2.6.27) | 改后 (v2.6.28) | web (Selene) |
    //   | 第一源 1s 到, 18 源全 3s 到 | 1s 出第一批, 3s 后 footer "正在搜" → 18s 出 "完成" | 1s 出第一批, 3s 后 footer "正在搜" → 18s 出 "完成" | 同 |
    //   | 第一源 10s 到, 慢源 20s | 3s 兜底关 loading, 10s 出结果, 20s 出 footer "完成" | 10s 出结果, 20s 出 footer "完成" (banner 一直在底部) | 同 |
    //   | 一直 0 结果 (没人搜) | 3s 兜底关 loading, 显示空态, 20s 出 "完成 0 个" | 一直显示空态 (0 results), 20s 出 footer "完成 0 个" | 同 (web 是空网格 + footer "完成 0 个") |
    final themeService = Provider.of<ThemeService>(context, listen: false);
    return _useAggregatedView
        ? SearchResultAggGrid(
            results: _filteredSearchResults,
            themeService: themeService,
            hasReceivedStart: _hasSearched,
            onVideoTap: (video) => _navigateToPlayer(video),
            onGlobalMenuAction: (video, action) => _handleMenuAction(video, action),
          )
        : SearchResultsGrid(
            results: _filteredSearchResults,
            themeService: themeService,
            hasReceivedStart: _hasSearched,
            onVideoTap: (video) => _navigateToPlayer(video),
            onGlobalMenuAction: (video, action) => _handleMenuAction(video, action),
          );
  }

  /// v2.6.33: 删 _buildTopLoadingBanner — 用户反馈上下都有进度条,
  ///   去掉上面的, 统一用底部 _buildSearchFooter 显示搜索进度.

  /// v2.6.28: Footer banner — 跟 web 端 (LunaTV-web/src/app/search/page.tsx:2460-2470) 1:1.
  ///   - isLoading && results.length > 0 → "正在搜索更多结果..." 底部小条
  ///   - !isLoading && results.length > 0 → "搜索完成 共 N 个" 大徽章
  ///   - 都不是 → null (不渲染, 跟 web 一样)
  ///
  /// v2.6.30: footer 改 fixed 屏幕底部 (跟 web `fixed bottom-0` 1:1).
  ///   在 build 里用 Stack + Positioned(bottom: 0) 浮在结果区上. 之前
  ///   `_buildSearchResults` 内 Column 末尾占位, 结果多时需滚到底才能
  ///   看到完成徽章. 改 fixed 后永远可见, 跟 web 完全一致.
  /// v2.6.30: "正在搜索更多结果..." 小条里加「已找到 N 个」实时数字.
  ///   web 端 page.tsx:2464 「正在搜索更多结果...」无数字, 只有完成时
  ///   大徽章显示总数. 用户反馈「半天不错搜索结果」, 体感想知道"搜到
  ///   多少了", 移动端体验上比 web 端更需要这个数字. 加在 (X / Y) 后面,
  ///   跟源完成度一并显示, 用户能直观看到结果数在涨.
  Widget _buildSearchFooter() {
    final hasResults = _filteredSearchResults.isNotEmpty;
    final resultCount = _filteredSearchResults.length;
    // v2.6.33: 搜索中 (有无结果都显示) — 统一底部进度条, 删了顶部 banner 后
    //   启动阶段 (无结果) 也要在底部显示进度.
    if (_isLoading) {
      final completed = _searchProgress?.completedSources ?? 0;
      final total = _searchProgress?.totalSources ?? 0;
      final current = _searchProgress?.currentSource;
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF10B981),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hasResults
                    ? '正在搜索更多结果... ($completed / $total)  已找到 $resultCount 个'
                    : '搜索中... ($completed / $total)${current != null ? '  $current' : ''}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    if (!_isLoading && hasResults) {
      // 大徽章, 跟 web "搜索完成 共 N 个" 1:1.
      //   fixed 屏幕底部覆盖, 永远可见, 搜完一抬头就能看到 "搜索完成 共 N 个"
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFEFF6FF), Color(0xFFEEF2FF), Color(0xFFF3E8FF)],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFBFDBFE)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xFF3B82F6), Color(0xFF8B5CF6)],
                ),
              ),
              child: const Icon(Icons.check, color: Colors.white, size: 22),
            ),
            const SizedBox(height: 6),
            const Text(
              '搜索完成',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '共找到 $resultCount 个结果',
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF6B7280),
              ),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  void _navigateToPlayer(VideoInfo video) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(videoInfo: video),
      ),
    );
  }

  void _handleMenuAction(VideoInfo video, VideoMenuAction action) {
    switch (action) {
      case VideoMenuAction.play:
        _navigateToPlayer(video);
        break;
      // v2.5.77: 搜索 / 聚合长按菜单的"收藏"和"取消收藏"都走 toggleFavorite,
      //   它内部 isFavoritedSync() 检查, 已收藏→removeFavorite, 未收藏→addFavorite.
      //   之前只有 case VideoMenuAction.favorite, 视频菜单
      //   (video_menu_bottom_sheet.dart::from=='search'/agg) 已收藏时返回 unfavorite,
      //   但 search_screen 这里没 case unfavorite → 点了取消收藏没反应.
      //   现在两个 case 都路由到同一个 toggleFavorite, 行为一致.
      case VideoMenuAction.favorite:
      case VideoMenuAction.unfavorite:
        unawaited(PageCacheService().toggleFavorite(
          video.source,
          video.id,
          {
            'title': video.title,
            'source_name': video.sourceName,
            'year': video.year,
            'cover': video.cover,
            'total_episodes': video.totalEpisodes,
            'save_time': video.saveTime,
          },
          context,
        ));
        break;
      case VideoMenuAction.doubanDetail:
        Navigator.of(context, rootNavigator: true).pushNamed(
          '/douban-detail',
          arguments: {
            'id': video.id,
            'kind': video.sourceName.toLowerCase().contains('movie') ? 'movie' : 'tv',
            'title': video.title,
            'poster': video.cover,
          },
        );
        break;
      default:
        break;
    }
  }
}