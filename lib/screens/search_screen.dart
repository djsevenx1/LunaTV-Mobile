import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/services/page_cache_service.dart';
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
    setState(() {
      _hasSearched = true;
      _searchResults = [];
      _searchError = null;
      _isLoading = true;
    });
    try {
      final results = await ApiService.fetchSourcesData(query);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchError = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
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
          _searchResults = [];
          _searchError = null;
          _isLoading = false;
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
    if (_isLoading && _searchResults.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text(
              '搜索中...',
              style: TextStyle(fontSize: 13),
            ),
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