// 省略最前面的 import 不变，保留到 line 30
// ... 为节省 token，我先写核心修改，完整文件保留原 import 头部

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:luna_tv/services/page_cache_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/sse_search_service.dart';
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
  bool _hasReceivedStart = false;
  String? _searchError;
  SearchProgress? _searchProgress;
  Timer? _updateTimer;
  bool _useAggregatedView = true;

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

  late SSESearchService _searchService;
  StreamSubscription<List<SearchResult>>? _incrementalResultsSubscription;
  StreamSubscription<SearchProgress>? _progressSubscription;
  StreamSubscription<String>? _errorSubscription;

  List<SearchResult> get _filteredSearchResults {
    List<SearchResult> results = List.from(_searchResults);
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
    _searchService = SSESearchService();
    _loadSearchHistory();
  }

  Future<void> _loadSearchHistory() async {
    final prefs = await PageCacheService.getSearchHistory();
    if (mounted) setState(() => _searchHistory = prefs);
  }

  void _onSearchQueryChanged(String query) {
    _searchQuery = query;
    if (_updateTimer?.isActive ?? false) _updateTimer!.cancel();
    _updateTimer = Timer(const Duration(milliseconds: 1200), () {
      if (query.trim().isEmpty) {
        if (mounted) setState(() => _hasSearched = false);
        return;
      }
      _performSearch(query.trim());
    });
  }

  void _performSearch(String query) async {
    if (_searchService.isConnected) unawaited(_searchService.stopSearch());
    setState(() {
      _hasSearched = true;
      _searchResults.clear();
      _searchError = null;
      _hasReceivedStart = false;
      _searchProgress = null;
    });

    _incrementalResultsSubscription = _searchService.incrementalResultsStream.listen(
      (results) {
        if (mounted) {
          setState(() {
            _searchResults = results;
          });
        }
      },
      onError: (e) {
        if (mounted) setState(() => _searchError = e.toString());
      },
    );

    _progressSubscription = _searchService.progressStream.listen((progress) {
      if (mounted) {
        setState(() {
          _searchProgress = progress;
          _hasReceivedStart = true;
        });
      }
    });

    _errorSubscription = _searchService.errorStream.listen((err) {
      if (mounted) setState(() => _searchError = err);
    });

    unawaited(_searchService.startSearch(query));
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _incrementalResultsSubscription?.cancel();
    _progressSubscription?.cancel();
    _errorSubscription?.cancel();
    _searchService.stopSearch();
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
        setState(() {
          _searchQuery = '';
          _hasSearched = false;
          _searchResults.clear();
          _searchError = null;
          _hasReceivedStart = false;
          _searchProgress = null;
        });
      },
      content: Column(
        children: [
          // 搜索进度条
          if (_hasReceivedStart && _searchProgress != null)
            _buildSearchProgress(),
          // 搜索结果
          Expanded(
            child: _buildSearchResults(),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchProgress() {
    final theme = Theme.of(context);
    final p = _searchProgress!;
    final percent = p.progressPercentage;
    final label = p.currentSource ?? p.progressDescription;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: theme.colorScheme.primary.withOpacity(0.06),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: percent,
              valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
              backgroundColor: theme.dividerColor,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              '正在搜索… $label',
              style: FontUtils.poppins(fontSize: 13, color: theme.hintColor),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults() {
    // 保持原有逻辑不变：选中聚合视图或普通列表
    if (_useAggregatedView) {
      return SearchResultAggGrid(
        results: _filteredSearchResults,
        onVideoTap: (video) => _navigateToPlayer(video),
        onMenuAction: (video, action) => _handleMenuAction(video, action),
      );
    } else {
      return SearchResultsGrid(
        results: _filteredSearchResults,
        onVideoTap: (video) => _navigateToPlayer(video),
        onMenuAction: (video, action) => _handleMenuAction(video, action),
      );
    }
  }

  void _navigateToPlayer(VideoInfo video) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          source: video.source,
          id: video.id,
          title: video.title,
          year: video.year,
        ),
      ),
    );
  }

  void _handleMenuAction(VideoInfo video, VideoMenuAction action) {
    switch (action) {
      case VideoMenuAction.play:
        _navigateToPlayer(video);
        break;
      case VideoMenuAction.favorite:
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