import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:luna_tv/services/page_cache_service.dart';
import 'package:luna_tv/services/search_result_ranker.dart';
import 'package:luna_tv/services/sse_search_service.dart';
import 'package:luna_tv/services/theme_service.dart';
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
  }

  Future<void> _loadSearchHistory() async {
    final result = await PageCacheService().getSearchHistory(context);
    if (mounted) {
      setState(() => _searchHistory = result.data ?? const <String>[]);
    }
  }

  void _onSearchQueryChanged(String query) {
    _searchQuery = query;
    if (_updateTimer?.isActive ?? false) _updateTimer!.cancel();
    // v2.5.26: debounce 800→400ms. 800ms 偏长, 用户输入完到触发搜索的等待感明显.
    // 400ms 既能避免逐字抖动, 又让搜索更"跟手".
    // v2.5.27: 用户继续输入时, 让进行中的旧搜索结果作废, 避免覆盖新状态.
    _searchGeneration++;
    _updateTimer = Timer(const Duration(milliseconds: 400), () {
      if (query.trim().isEmpty) {
        if (mounted) {
          setState(() {
            _hasSearched = false;
            _isLoading = false;
          });
        }
        return;
      }
      _performSearch(query.trim());
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
    });

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
          // 搜索结果
          Expanded(
            child: _buildSearchResults(),
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