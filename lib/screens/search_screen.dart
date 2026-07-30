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

  // v2.5.27: 搜索代际 guard. debounce 缩短到 400ms 后, 用户还在输入就可能触发
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
    // v2.6.7: 改用 SSESearchService — 走客户端直连 (本地模式) 或
    //   后端 /api/search/ws SSE 增量推回, 跟 Selene 行为一致.
    //   取消旧订阅, 防增量结果混到新搜索里.
    await _incrementalResultsSubscription?.cancel();
    await _progressSubscription?.cancel();
    await _errorSubscription?.cancel();
    await _sseSearchService.stopSearch();

    final gen = ++_searchGeneration;
    setState(() {
      _hasSearched = true;
      _searchResults = [];
      _searchError = null;
      _isLoading = true;
      _searchProgress = null;
      _sourceResultCounts = {};
    });

    // v2.6.16: 拿源列表建 key→name 映射, 用于显示每个源的结果数
    try {
      final isLocalMode = await UserDataService.getIsLocalMode();
      final resources = isLocalMode
          ? await LocalModeStorageService.getSearchSources()
          : await ApiService.getSearchResources();
      if (mounted && gen == _searchGeneration) {
        setState(() {
          _sourceKeyToName = {
            for (final r in resources.where((r) => !r.disabled)) r.key: r.name
          };
        });
      }
    } catch (_) {}

    // 增量结果: 每个 source 完成搜索就推回一批, addAll 到 _searchResults.
    //   SearchResultAggGrid 内部按 title+year+类型 聚合并 join 所有源名,
    //   跟 web 行为一致.
    _incrementalResultsSubscription = _sseSearchService
        .incrementalResultsStream
        .listen((incrementalResults) {
      if (!mounted || gen != _searchGeneration) return;
      if (incrementalResults.isEmpty) return;
      // v2.6.7: SSE 增量结果 addAll 前再过滤一次 0 集源, 兜底. 下游
      //   DownstreamService.searchPage 和后端 /api/search/ws 都过滤了
      //   episodes.isEmpty, 但以防某个 source 漏过滤 (未来加新 source /
      //   缓存被污染), 客户端这里再卡一道, 避免"0集"卡片污染结果.
      final filtered = incrementalResults
          .where((r) => r.episodes.isNotEmpty)
          .toList();
      if (filtered.isEmpty) return;
      setState(() {
        _searchResults = [..._searchResults, ...filtered];
        _isLoading = false; // 第一批结果到了就取消 loading, 让用户看到东西
      });
    });

    // 进度: 显示"已完成 X / 总共 Y 个源"
    _progressSubscription = _sseSearchService.progressStream.listen((progress) {
      if (!mounted || gen != _searchGeneration) return;
      setState(() {
        _searchProgress = progress;
        if (progress.isComplete) {
          _isLoading = false;
          // v2.6.16: 搜完拉取每个源的结果数, 让用户看到哪些源 0 条
          _sourceResultCounts = _sseSearchService.sourceResultCounts;
        }
      });
    });

    // 错误
    _errorSubscription = _sseSearchService.errorStream.listen((error) {
      if (!mounted || gen != _searchGeneration) return;
      setState(() {
        _searchError = error;
        _isLoading = false;
      });
    });

    // v2.6.22: 删 fire 兜底 + 别名搜 — 跟 Selene 1:1, 走纯 SSE 增量推回.
    //   v2.6.21 changelog 写了删, 但代码没动, 这版补删.
    //   之前 _runSearchFallback 8s 后 fire /api/search 聚合 (后端 80 源
    //   Promise.allSettled 等最慢 20s) + _runMultiNameSearch 3s 后 fire
    //   豆瓣别名 (每个别名并行 80 源), 跟 SSE 主路同时并发 80*5=400 源,
    //   后端 CPU/网络/资源站全打满, SSE 主路跟着卡, 结果数还被
    //   _exactSearch subsequence 过滤 (凡人修仙之风起 / 仙林外传等) —
    //   用户体感「搜得没 Selene 全, 又慢」根因.

    try {
      await _sseSearchService.startSearch(query);
    } catch (e) {
      if (!mounted || gen != _searchGeneration) return;
      setState(() {
        _searchError = e.toString();
        _isLoading = false;
      });
    }
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
          // v2.6.7: SSE 搜索进度条 — 结果已出但还没搜完时, 顶部显示细进度,
          //   让用户知道"还有源在搜, 别急着滚到底". 搜完 (_isComplete) 或
          //   还没搜 (_searchProgress == null) 时不显示.
          if (_searchProgress != null &&
              !_searchProgress!.isComplete &&
              _searchProgress!.totalSources > 0 &&
              _searchResults.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '搜索中 ${_searchProgress!.completedSources} / ${_searchProgress!.totalSources}'
                      '${_searchProgress!.currentSource != null ? ' — ${_searchProgress!.currentSource}' : ''}',
                      style: const TextStyle(fontSize: 11, color: Colors.black54),
                    ),
                  ),
                ],
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
          // v2.6.16: 每个源的结果数 — 用户反馈「奈飞工厂源app搜不到内容」,
          //   加这个折叠面板, 让用户看到每个源搜出多少条. 0 条的源用红字标,
          //   区分「源被 app 搜了但 API 没数据」vs「app 没搜这个源」.
          //   默认收起, 避免干扰主结果视图; 用户点 "查看 X 个源" 才展开.
          if (_hasSearched && _sourceResultCounts.isNotEmpty)
            _buildSourceResultDebugPanel(),
          // 搜索结果
          Expanded(
            child: _buildSearchResults(),
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
    // v2.5.26: 搜索中且还没结果时显示 loading, 给用户即时反馈
    // v2.6.7: 加进度条 + 当前源名, 让用户看到"5/18 个源完成"这种进度,
    //   SSE 增量推回时第一批结果到了就显示结果, 进度条继续在结果上方跑.
    if (_isLoading && _searchResults.isEmpty) {
      final progress = _searchProgress;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            const Text(
              '搜索中...',
              style: TextStyle(fontSize: 13),
            ),
            if (progress != null && progress.totalSources > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${progress.completedSources} / ${progress.totalSources} 个源'
                '${progress.currentSource != null ? ' (${progress.currentSource})' : ''}',
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ],
          ],
        ),
      );
    }
    final themeService = Provider.of<ThemeService>(context, listen: false);
    // 保持原有逻辑不变：选中聚合视图或普通列表
    if (_useAggregatedView) {
      return SearchResultAggGrid(
        results: _filteredSearchResults,
        themeService: themeService,
        hasReceivedStart: _hasSearched,
        onVideoTap: (video) => _navigateToPlayer(video),
        onGlobalMenuAction: (video, action) => _handleMenuAction(video, action),
      );
    } else {
      return SearchResultsGrid(
        results: _filteredSearchResults,
        themeService: themeService,
        hasReceivedStart: _hasSearched,
        onVideoTap: (video) => _navigateToPlayer(video),
        onGlobalMenuAction: (video, action) => _handleMenuAction(video, action),
      );
    }
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