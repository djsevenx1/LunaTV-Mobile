// lib/screens/source_browser_screen.dart
//
// v2.3.32.1 hotfix: 修源调用 + UI 1:1 web LunaTV /source-browser
//
// v2.3.32 上一版的错 (这版修):
//   1. detail 走 SourceBrowserService.getDetail 是错的 — web detail 走
//      /api/detail (downstream.getDetailFromApi), 返 GlobalSearchResult 含
//      douban_id / desc / class 字段. mobile 等价是 SearchService.getDetailSync
//      (返 SearchResult 含 doubanId / desc / class_). 这版改回 getDetailSync
//   2. doubanId 应该从 SearchResult.doubanId 拿, 不是 SourceBrowserDetail.vodDoubanId
//      (上一版我自己加的字段, web 没这个, 已回滚)
//   3. detail 没 doubanId 时 web 走 /api/search/one fallback 拿, 这版加
//      DownstreamService.searchFromApi 同源精确搜 fallback
//   4. UI 不是 1:1: 上一版用 M3 ChoiceChip 灰底 + 8px 圆角, web 是
//      border-2 + 渐变选中 + 2xl 圆角 + shadow-xl + blur 光晕 + fadeInUp
//      动画. 这版重写 UI 玻璃质感 1:1
//   5. auto-select: 上一版改成"不自动选", 跟 web useEffect auto-select
//      first source + 跟 TV/movie 自动用所有源 都不一致. 这版改回 auto-select
//
// web 1:1 源调用对照表:
//   源列表:   web /api/source-browser/sites
//             mobile SearchService.getActiveResources()
//   分类:     web /api/source-browser/categories?source=K (上游 ?ac=list)
//             mobile SourceBrowserService.getCategories(resource)
//   列表:     web /api/source-browser/list?source=K&type_id=T&page=N
//             mobile SourceBrowserService.getList(resource, typeId, page)
//   搜索:     web /api/source-browser/search?source=K&q=Q&page=N
//             mobile SourceBrowserService.search(resource, query, page)
//   详情:     web /api/detail?source=K&id=ID (downstream.getDetailFromApi)
//             mobile SearchService.getDetailSync(source, id)
//   豆瓣:     web /api/douban/details?id=D
//             mobile DoubanService.getDoubanDetails(context, doubanId)
//   Bangumi:  web /api/proxy/bangumi?path=v0/subjects/B
//             mobile BangumiService.getBangumiDetails(context, bangumiId)
//   search_one fallback: web /api/search/one?resourceId=K&q=Q
//             mobile DownstreamService.searchFromApi(resource, query)
//
// 「第一源不固定」原则:
//   - app 不内置任何源 (grep 全代码无 DEFAULT_SITES / DEFAULT_API / hardcoded)
//   - 源列表从 UserDataService 配的源拿 (用户配什么源就显示什么源)
//   - auto-select 第一个用户源是 UX (跟 web useEffect 同款, 跟 TV/movie
//     自动用所有源同款), 不是 hardcoded — 用户清空源列表后没源可 auto-select

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:luna_tv/models/bangumi.dart';
import 'package:luna_tv/models/douban_movie.dart';
import 'package:luna_tv/models/search_resource.dart';
import 'package:luna_tv/models/search_result.dart';
import 'package:luna_tv/models/source_browser.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/screens/player_screen.dart';
import 'package:luna_tv/services/bangumi_service.dart';
import 'package:luna_tv/services/downstream_service.dart';
import 'package:luna_tv/services/douban_service.dart';
import 'package:luna_tv/services/search_service.dart';
import 'package:luna_tv/services/source_browser_service.dart';

/// v2.3.32.1: 排序选项, 跟 web <select> 5 个 option 1:1
enum _SortBy {
  defaultSort('default', '默认'),
  titleAsc('title-asc', '标题 A→Z'),
  titleDesc('title-desc', '标题 Z→A'),
  yearAsc('year-asc', '年份↑'),
  yearDesc('year-desc', '年份↓');

  final String value;
  final String label;
  const _SortBy(this.value, this.label);
}

/// v2.3.32.1: mode 跟 web source-browser 同款 (URL ?mode=)
enum _Mode { category, search }

class SourceBrowserScreen extends StatefulWidget {
  const SourceBrowserScreen({super.key});

  @override
  State<SourceBrowserScreen> createState() => _SourceBrowserScreenState();
}

class _SourceBrowserScreenState extends State<SourceBrowserScreen> {
  // -------- source / category / items state --------
  List<SearchResource> _resources = const [];
  String? _selectedSourceKey; // null = 没源 / 还没 auto-select
  List<SourceCategory> _categories = const [];
  int? _selectedCategoryId;
  final List<SourceBrowserItem> _items = [];
  SourceBrowserPageMeta? _meta;
  bool _isLoadingSources = true;
  bool _isLoadingCategories = false;
  bool _isLoadingPage = false;
  bool _isLoadingMore = false;
  String? _error;
  bool _loadSourcesError = false;

  // -------- search / sort / filter state --------
  _Mode _mode = _Mode.category;
  String _searchQuery = '';
  _SortBy _sortBy = _SortBy.defaultSort;
  String? _filterYear;
  String _filterKeyword = '';
  Timer? _searchDebounce;

  // -------- infinite scroll throttle (web 700ms) --------
  DateTime _lastFetchAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _autoFillInProgress = false;

  // -------- controllers --------
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _filterKeywordController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadSources();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _filterKeywordController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  // -------- data load: sources --------

  Future<void> _loadSources() async {
    setState(() {
      _isLoadingSources = true;
      _loadSourcesError = false;
      _error = null;
    });
    try {
      final list = await SearchService.getActiveResources();
      if (!mounted) return;
      // v2.4.3: 把 _loadCategories 调用从 setState 内移出来, 跟 v2.4.2
      //   _loadCategories 把 _loadPage 移出来同款. 避免嵌套 setState
      //   + async race, 这是「一直显示加载内容」的根因.
      setState(() {
        _resources = list;
        _isLoadingSources = false;
        if (list.isNotEmpty) {
          _selectedSourceKey = list.first.key;
        } else {
          _selectedSourceKey = null;
          _error = '暂无可用源\n请先在「源管理」中添加订阅';
        }
        _categories = const [];
        _selectedCategoryId = null;
        _items.clear();
        _meta = null;
      });
      // auto-select 后立即拉分类 (在 setState 外, 跟 web useEffect 同款)
      if (list.isNotEmpty) {
        _loadCategories(list.first.key);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingSources = false;
        _loadSourcesError = true;
        _error = '加载源列表失败: $e';
      });
    }
  }

  // -------- data load: categories --------

  Future<void> _loadCategories(String sourceKey) async {
    final idx = _resources.indexWhere((r) => r.key == sourceKey);
    if (idx < 0) return;
    final r = _resources[idx];
    setState(() {
      _isLoadingCategories = true;
      _categories = const [];
      _selectedCategoryId = null;
      _items.clear();
      _meta = null;
      _error = null;
      _searchQuery = '';
      _searchController.clear();
      _filterYear = null;
      _filterKeywordController.clear();
      _filterKeyword = '';
      _mode = _Mode.category;
    });
    final cats = await SourceBrowserService.getCategories(r);
    if (!mounted) return;
    // v2.4.2: 把 _loadPage 调用从 setState 内移出来, 避免嵌套 setState
    //   + async race. 之前 v2.4.1 在 setState 内调 _loadPage(reset: true)
    //   会触发 _loadPage 内部 setState (_isLoadingPage=true) 跟外层
    //   setState 时序混乱, 导致用户反馈「一直显示加载内容」.
    if (cats != null && cats.isNotEmpty) {
      setState(() {
        _isLoadingCategories = false;
        _categories = cats;
        _selectedCategoryId = cats.first.typeId;
      });
      // auto-select 第一个分类后, 在 setState 外 fire-and-forget 调 _loadPage
      // v2.4.3: 删 reset 参数 (dead code), _loadPage() 默认 isLoadMore=false
      //   就是 reset 行为
      _loadPage();
    } else {
      setState(() {
        _isLoadingCategories = false;
        _categories = const [];
        _error = cats == null
            ? '加载分类失败 (源 API `?ac=list` 错误)'
            : '该源无分类 (可能 API 不支持 `?ac=list`)';
      });
    }
  }

  // -------- data load: page (list / search) --------

  Future<void> _loadPage({bool isLoadMore = false}) async {
    final key = _selectedSourceKey;
    if (key == null) return;
    final idx = _resources.indexWhere((r) => r.key == key);
    if (idx < 0) return;
    final r = _resources[idx];
    final typeId = _selectedCategoryId;
    final page = isLoadMore ? ((_meta?.page ?? 1) + 1) : 1;

    // v2.4.1: 跟 web page.tsx useEffect 1:1 — 分类模式下没选 category 不调 list
    //   web: if (activeSourceKey && activeCategory && mode === 'category') fetchItems(...)
    //   之前 mobile 用 typeId ?? 0 走 ?ac=videolist&t=0 → 上游返回不固定分类内容
    //   (这就是用户反馈「分类内容不匹配」的根因)
    if (_searchQuery.isEmpty && typeId == null) {
      setState(() {
        _isLoadingPage = false;
        _isLoadingMore = false;
        _items.clear();
        _meta = null;
      });
      return;
    }

    if (!isLoadMore) {
      setState(() {
        _isLoadingPage = true;
        _items.clear();
        _meta = null;
        _error = null;
      });
    } else {
      setState(() {
        _isLoadingMore = true;
      });
    }

    // v2.4.3: 跟 web fetchItems finally { setLoadingItems(false) } 1:1
    //   try/catch/finally 兜底, 防止任何异常导致 _isLoadingPage 卡在 true
    //   (SourceBrowserService._getJson 已吞异常返 null, 但加 try/finally
    //   是 defense in depth, 跟 web fetchItems 行 240-243 对齐)
    SourceBrowserPage? result;
    try {
      result = _searchQuery.isEmpty
          ? await SourceBrowserService.getList(r, typeId: typeId!, page: page)
          // v2.3.32.1: search 模式不传 typeId, 跟 web source-browser search route
          //   ?ac=videolist&wd=Q&pg=N 1:1 (web search route 不带 t 参数)
          : await SourceBrowserService.search(r,
              query: _searchQuery, page: page);
    } catch (e) {
      result = null;
    } finally {
      if (!mounted) return;
      setState(() {
        _isLoadingPage = false;
        _isLoadingMore = false;
        if (result == null) {
          if (!isLoadMore) {
            _error = '加载失败 (源 API 错误 / 网络不通)';
          }
        } else {
          _items.addAll(result.items);
          _meta = result.meta;
        }
        _lastFetchAt = DateTime.now();
      });
    }
  }

  // -------- infinite scroll --------

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_isLoadingMore) return;
    if (!(_meta?.hasMore ?? false)) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 300) {
      _throttledLoadMore();
    }
  }

  /// 700ms 节流 (跟 web lastFetchAtRef 700ms 1:1)
  Future<void> _throttledLoadMore() async {
    final now = DateTime.now();
    if (now.difference(_lastFetchAt).inMilliseconds < 700) return;
    _lastFetchAt = now;
    await _loadPage(isLoadMore: true);
    if (!mounted) return;
    _tryAutoFill();
  }

  /// 视口自动填满, 跟 web tryAutoFill 1:1
  Future<void> _tryAutoFill() async {
    if (_autoFillInProgress) return;
    if (_isLoadingPage || _isLoadingMore) return;
    if (!(_meta?.hasMore ?? false)) return;
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final viewport = _scrollController.position.viewportDimension;
    if (maxScroll > viewport + 100) return;

    _autoFillInProgress = true;
    try {
      for (int i = 0; i < 5; i++) {
        if (!(_meta?.hasMore ?? false)) break;
        if (_isLoadingPage || _isLoadingMore) break;
        final now = DateTime.now();
        if (now.difference(_lastFetchAt).inMilliseconds <= 400) break;
        _lastFetchAt = now;
        await _loadPage(isLoadMore: true);
        if (!mounted) break;
        if (!_scrollController.hasClients) break;
        final newMax = _scrollController.position.maxScrollExtent;
        if (newMax > _scrollController.position.viewportDimension + 100) break;
      }
    } finally {
      _autoFillInProgress = false;
    }
  }

  // -------- search / sort / filter handlers --------

  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      final newMode = v.trim().isEmpty ? _Mode.category : _Mode.search;
      if (_searchQuery == v.trim() && _mode == newMode) return;
      setState(() {
        _searchQuery = v.trim();
        _mode = newMode;
      });
      if (_selectedSourceKey != null) {
        _loadPage();
      }
    });
  }

  void _onSourceTap(String key) {
    if (_selectedSourceKey == key) return;
    setState(() {
      _selectedSourceKey = key;
    });
    _loadCategories(key);
  }

  void _onCategoryTap(int typeId) {
    if (_selectedCategoryId == typeId) return;
    setState(() {
      _selectedCategoryId = typeId;
    });
    _loadPage();
  }

  // -------- derived: filtered + sorted items (client-side) --------
  // 跟 web filteredAndSorted useMemo 1:1
  List<SourceBrowserItem> get _visibleItems {
    var arr = List<SourceBrowserItem>.from(_items);
    if (_filterKeyword.trim().isNotEmpty) {
      final kw = _filterKeyword.trim().toLowerCase();
      arr = arr.where((it) {
        return it.title.toLowerCase().contains(kw) ||
            it.remarks.toLowerCase().contains(kw);
      }).toList();
    }
    if (_filterYear != null && _filterYear!.isNotEmpty) {
      arr = arr.where((it) => it.year == _filterYear).toList();
    }
    switch (_sortBy) {
      case _SortBy.titleAsc:
        arr.sort((a, b) => a.title.compareTo(b.title));
        break;
      case _SortBy.titleDesc:
        arr.sort((a, b) => b.title.compareTo(a.title));
        break;
      case _SortBy.yearAsc:
        arr.sort(
            (a, b) => (int.tryParse(a.year) ?? 0) - (int.tryParse(b.year) ?? 0));
        break;
      case _SortBy.yearDesc:
        arr.sort(
            (a, b) => (int.tryParse(b.year) ?? 0) - (int.tryParse(a.year) ?? 0));
        break;
      case _SortBy.defaultSort:
        break;
    }
    return arr;
  }

  List<String> get _availableYears {
    final set = <String>{};
    for (final it in _items) {
      final y = it.year.trim();
      if (y.isNotEmpty) set.add(y);
    }
    final list = set.toList();
    list.sort((a, b) => (int.tryParse(b) ?? 0) - (int.tryParse(a) ?? 0));
    return list;
  }

  // -------- item tap → preview dialog --------

  Future<void> _onItemTap(SourceBrowserItem item) async {
    final key = _selectedSourceKey;
    if (key == null) return;
    final idx = _resources.indexWhere((r) => r.key == key);
    if (idx < 0) return;
    final r = _resources[idx];

    // v2.3.32.1 改: 跟 web /api/detail 1:1, 走 SearchService.getDetailSync
    //   拿 SearchResult (含 doubanId / desc / class_ / episodes 全套字段)
    //   而不是 SourceBrowserService.getDetail (字段不全)
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.6),
      builder: (dialogCtx) => _PreviewDialog(
        item: item,
        resource: r,
        loadDetail: () => SearchService.getDetailSync(r.key, item.id),
        loadSearchOne: (query) => DownstreamService.searchFromApi(r, query),
        onPlay: (searchResult) {
          Navigator.of(dialogCtx).pop();
          _playDetail(searchResult, r, item);
        },
      ),
    );
  }

  /// 跟 web goPlay 1:1, 用 SearchResult 构造 VideoInfo push PlayerScreen
  void _playDetail(
      SearchResult detail, SearchResource r, SourceBrowserItem item) {
    final videoInfo = VideoInfo(
      id: detail.id,
      source: r.key,
      title: detail.title.isEmpty ? item.title : detail.title,
      sourceName: r.name,
      year: detail.year.isEmpty || detail.year == 'unknown'
          ? item.year
          : detail.year,
      cover: detail.poster.isEmpty ? item.poster : detail.poster,
      index: 0,
      totalEpisodes: detail.episodes.length,
      playTime: 0,
      totalTime: 0,
      saveTime: 0,
      searchTitle: detail.title.isEmpty ? item.title : detail.title,
      // v2.3.32.1: doubanId 从 SearchResult.doubanId 拿 (web 同款)
      doubanId: detail.doubanId != null && detail.doubanId! > 0
          ? detail.doubanId.toString()
          : null,
    );
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlayerScreen(videoInfo: videoInfo)),
    );
  }

  // -------- build --------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Scaffold(
      body: Container(
        // v2.3.32.1: 1:1 web 渐变背景 (emerald/green/teal 模糊光晕)
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [Colors.grey.shade900, Colors.grey.shade800, Colors.grey.shade900]
                : [Colors.grey.shade50, Colors.white, Colors.grey.shade50],
          ),
        ),
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
            // Hero header
            SliverToBoxAdapter(child: _buildHeroHeader(theme, isDark)),
            // Source card
            SliverToBoxAdapter(child: _buildSourceCard(theme, isDark)),
            // Query & Sort card (源选了才显示)
            if (_selectedSourceKey != null)
              SliverToBoxAdapter(child: _buildQuerySortCard(theme, isDark)),
            // Categories & Items card (源选了才显示)
            if (_selectedSourceKey != null)
              SliverToBoxAdapter(
                child: _buildCategoriesItemsCard(theme, isDark),
              ),
            // 留底 padding
            const SliverToBoxAdapter(
              child: SizedBox(height: 40),
            ),
          ],
        ),
      ),
    );
  }

  // -------- Hero header (1:1 web 顶部渐变 icon + 标题) --------

  Widget _buildHeroHeader(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Stack(
        children: [
          // 模糊光晕
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xFF10B981).withOpacity(0.1),
                    Colors.green.withOpacity(0.1),
                    Colors.teal.withOpacity(0.1),
                  ],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: BackdropFilter(
                filter: ColorFilter.mode(
                  Colors.white.withOpacity(isDark ? 0.05 : 0.7),
                  BlendMode.srcOver,
                ),
                child: Container(color: Colors.transparent),
              ),
            ),
          ),
          // 实际内容
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isDark ? Colors.grey.shade800.withOpacity(0.8) : Colors.white.withOpacity(0.8),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark
                    ? Colors.grey.shade700.withOpacity(0.5)
                    : Colors.grey.shade300.withOpacity(0.5),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(isDark ? 0.3 : 0.08),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                // 渐变 icon (emerald → green → teal)
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [const Color(0xFF10B981), Colors.green, Colors.teal],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Color(0xFF10B981).withOpacity(0.4),
                        blurRadius: 15,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.layers, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 渐变标题
                      ShaderMask(
                        shaderCallback: (bounds) => const LinearGradient(
                          colors: [const Color(0xFF10B981), Colors.green, Colors.teal],
                        ).createShader(bounds),
                        child: const Text(
                          '源浏览器',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '按来源站与分类浏览内容，探索海量影视资源',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_resources.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Color(0xFF10B981).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Color(0xFF10B981).withOpacity(0.3),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.storage, size: 16, color: const Color(0xFF047857)),
                        const SizedBox(width: 4),
                        Text(
                          '${_resources.length} 个源可用',
                          style: TextStyle(
                            fontSize: 12,
                            color: const Color(0xFF047857),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------- Source card (1:1 web source section) --------

  Widget _buildSourceCard(ThemeData theme, bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [Colors.grey.shade800, Colors.teal.withOpacity(0.05), Colors.grey.shade800]
              : [Colors.white, Color(0xFF10B981).withOpacity(0.05), Colors.white],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.2 : 0.05),
            blurRadius: 15,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
                ),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Color(0xFF10B981).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.storage, size: 16, color: const Color(0xFF059669)),
                ),
                const SizedBox(width: 10),
                const Text(
                  '选择来源站',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (!_isLoadingSources && _resources.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Color(0xFF10B981).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_resources.length} 个',
                      style: TextStyle(
                        fontSize: 11,
                        color: const Color(0xFF047857),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Body: source pills
          Padding(
            padding: const EdgeInsets.all(20),
            child: _buildSourcePills(isDark),
          ),
        ],
      ),
    );
  }

  Widget _buildSourcePills(bool isDark) {
    if (_isLoadingSources) {
      return Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: const Color(0xFF059669),
            ),
          ),
          const SizedBox(width: 8),
          Text('加载中...', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
        ],
      );
    }
    if (_loadSourcesError) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 16, color: Colors.red.shade600),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error ?? '获取源失败',
                style: TextStyle(fontSize: 13, color: Colors.red.shade600),
              ),
            ),
          ],
        ),
      );
    }
    if (_resources.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.storage, size: 32, color: Colors.grey.shade400),
              ),
              const SizedBox(height: 12),
              Text('暂无可用来源', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
              const SizedBox(height: 4),
              Text(
                '请先在「源管理」中添加订阅\napp 不会内置任何源',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
              ),
            ],
          ),
        ),
      );
    }
    // v2.3.32.1: 1:1 web source button: border-2 + 渐变选中 + 2xl 圆角 + shadow + blur 光晕
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: _resources.map((r) {
        final selected = _selectedSourceKey == r.key;
        return GestureDetector(
          onTap: () => _onSourceTap(r.key),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              // 选中态: emerald → green 渐变
              gradient: selected
                  ? const LinearGradient(
                      colors: [const Color(0xFF10B981), Colors.green],
                    )
                  : null,
              color: selected ? null : (isDark ? Colors.grey.shade800 : Colors.white),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? Colors.transparent
                    : (isDark ? Colors.grey.shade600 : Colors.grey.shade400),
                width: 2,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: Color(0xFF10B981).withOpacity(0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Text(
              r.name, // v2.3.32.1: 不 strip emoji, 跟 web 1:1
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: selected ? Colors.white : (isDark ? Colors.grey.shade300 : Colors.grey.shade700),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  // -------- Query & Sort card (1:1 web 第二段) --------

  Widget _buildQuerySortCard(ThemeData theme, bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey.shade800 : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.2 : 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 第一行: 搜索框 + 清除 + 模式
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: '输入关键词并回车进行搜索；清空回车恢复分类',
                      hintStyle: const TextStyle(fontSize: 12),
                      prefixIcon: const Icon(Icons.search, size: 18),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
                        ),
                      ),
                      filled: true,
                      fillColor: isDark ? Colors.grey.shade700 : Colors.white,
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (_searchQuery.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () {
                      _searchController.clear();
                      _onSearchChanged('');
                    },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      minimumSize: Size.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      side: BorderSide(
                        color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
                      ),
                    ),
                    child: const Text('清除', style: TextStyle(fontSize: 11)),
                  ),
                ],
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: _mode == _Mode.search
                        ? Colors.indigo.withOpacity(0.15)
                        : (isDark ? Colors.grey.shade700 : Colors.grey.shade100),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _mode == _Mode.search ? '搜索' : '分类',
                    style: TextStyle(
                      fontSize: 11,
                      color: _mode == _Mode.search
                          ? Colors.indigo
                          : (isDark ? Colors.grey.shade400 : Colors.grey.shade600),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 第二行: 排序 / 年份 / 关键词 (grid-cols-2 同款)
            Row(
              children: [
                Expanded(child: _buildSortDropdown(isDark)),
                const SizedBox(width: 8),
                Expanded(child: _buildYearDropdown(isDark)),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 40,
                    child: TextField(
                      controller: _filterKeywordController,
                      onChanged: (v) => setState(() => _filterKeyword = v),
                      decoration: InputDecoration(
                        hintText: '地区/关键词',
                        hintStyle: const TextStyle(fontSize: 12),
                        prefixIcon: const Icon(Icons.filter_list, size: 16),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
                          ),
                        ),
                        filled: true,
                        fillColor: isDark ? Colors.grey.shade700 : Colors.white,
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSortDropdown(bool isDark) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey.shade700 : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
        ),
      ),
      child: PopupMenuButton<_SortBy>(
        initialValue: _sortBy,
        onSelected: (v) => setState(() => _sortBy = v),
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            Icon(Icons.sort, size: 16, color: Colors.grey.shade600),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _sortBy.label,
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: Colors.grey.shade600),
          ],
        ),
        itemBuilder: (_) => _SortBy.values
            .map((s) => PopupMenuItem(
                  value: s,
                  child: Text(s.label, style: const TextStyle(fontSize: 13)),
                ))
            .toList(),
      ),
    );
  }

  Widget _buildYearDropdown(bool isDark) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey.shade700 : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
        ),
      ),
      child: PopupMenuButton<String?>(
        initialValue: _filterYear,
        onSelected: (v) => setState(() => _filterYear = v),
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            Icon(Icons.calendar_today, size: 14, color: Colors.grey.shade600),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _filterYear ?? '全部年份',
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: Colors.grey.shade600),
          ],
        ),
        itemBuilder: (_) {
          final list = <PopupMenuEntry<String?>>[
            const PopupMenuItem<String?>(
              value: null,
              child: Text('全部年份', style: TextStyle(fontSize: 13)),
            ),
            if (_availableYears.isNotEmpty) const PopupMenuDivider(),
          ];
          for (final y in _availableYears) {
            list.add(PopupMenuItem<String?>(
                value: y, child: Text(y, style: const TextStyle(fontSize: 13))));
          }
          return list;
        },
      ),
    );
  }

  // -------- Categories & Items card (1:1 web 第三段) --------

  Widget _buildCategoriesItemsCard(ThemeData theme, bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [Colors.grey.shade800, Colors.blue.withOpacity(0.05), Colors.grey.shade800]
              : [Colors.white, Colors.blue.withOpacity(0.03), Colors.white],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.2 : 0.05),
            blurRadius: 15,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
                ),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.tv, size: 16, color: Colors.blue.shade600),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${(_resources.isEmpty ? '' : _resources.firstWhere((r) => r.key == _selectedSourceKey, orElse: () => _resources.first).name)} 分类',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_categories.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_categories.length} 个分类',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.blue.shade700,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Body
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_mode == _Mode.category) ...[
                  _buildCategoryPills(isDark),
                  const SizedBox(height: 20),
                ],
                _buildItemsGrid(isDark),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryPills(bool isDark) {
    if (_isLoadingCategories) {
      return Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.blue.shade600,
            ),
          ),
          const SizedBox(width: 8),
          Text('加载分类...', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
        ],
      );
    }
    if (_categories.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.tv, size: 28, color: Colors.grey.shade400),
              ),
              const SizedBox(height: 8),
              Text('暂无分类', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
            ],
          ),
        ),
      );
    }
    // v2.3.32.1: 1:1 web category button: border-2 + blue→indigo 渐变选中 + 2xl 圆角
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: _categories.map((c) {
        final selected = _selectedCategoryId == c.typeId;
        return GestureDetector(
          onTap: () => _onCategoryTap(c.typeId),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              gradient: selected
                  ? const LinearGradient(colors: [Colors.blue, Colors.indigo])
                  : null,
              color: selected ? null : (isDark ? Colors.grey.shade800 : Colors.white),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? Colors.transparent
                    : (isDark ? Colors.grey.shade600 : Colors.grey.shade400),
                width: 2,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: Colors.blue.withOpacity(0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Text(
              c.typeName,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: selected ? Colors.white : (isDark ? Colors.grey.shade300 : Colors.grey.shade700),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildItemsGrid(bool isDark) {
    if (_isLoadingPage && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.blue.shade600,
                ),
              ),
              const SizedBox(width: 8),
              Text('加载内容...', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
            ],
          ),
        ),
      );
    }
    if (_error != null && _items.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 16, color: Colors.red.shade600),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_error!, style: TextStyle(fontSize: 13, color: Colors.red.shade600)),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Column(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.grey.shade100, Colors.grey.shade200],
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(Icons.tv, size: 36, color: Colors.grey.shade400),
              ),
              const SizedBox(height: 12),
              Text('暂无内容', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
            ],
          ),
        ),
      );
    }
    final visible = _visibleItems;
    if (visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            children: [
              Icon(Icons.search_off, size: 48, color: Colors.grey.shade400),
              const SizedBox(height: 8),
              Text('无匹配结果', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
              const SizedBox(height: 4),
              Text('清空筛选条件试试', style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
            ],
          ),
        ),
      );
    }
    // v2.3.32.1: 1:1 web grid: 3 列 / 2xl 圆角 / border-2 / hover scale 1.1
    //   / 渐变遮罩 / 年份 top-right / 分类 bottom-left
    return Column(
      children: [
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 0.52,
            crossAxisSpacing: 10,
            mainAxisSpacing: 14,
          ),
          itemCount: visible.length,
          itemBuilder: (_, idx) => _ItemCard(
            item: visible[idx],
            isDark: isDark,
            onTap: () => _onItemTap(visible[idx]),
          ),
        ),
        const SizedBox(height: 16),
        // infinite loader sentinel (跟 web loadMoreRef 同款)
        if (_isLoadingMore)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.blue.shade600,
                ),
              ),
              const SizedBox(width: 8),
              Text('加载更多...', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            ],
          )
        else if (_meta?.hasMore ?? false)
          Text('下拉加载更多', style: TextStyle(fontSize: 11, color: Colors.grey.shade400))
        else
          Text('没有更多了', style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
      ],
    );
  }
}

// =====================================================================
// Item card (1:1 web item card: 2xl 圆角 + border-2 + 渐变遮罩 +
//   年份 top-right + 分类 bottom-left + hover scale 1.1 + 阴影)
// =====================================================================

class _ItemCard extends StatefulWidget {
  final SourceBrowserItem item;
  final bool isDark;
  final VoidCallback onTap;
  const _ItemCard({required this.item, required this.isDark, required this.onTap});

  @override
  State<_ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends State<_ItemCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isDark = widget.isDark;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          transform: Matrix4.translationValues(0, _hovering ? -4 : 0, 0),
          decoration: BoxDecoration(
            color: isDark ? Colors.grey.shade800 : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hovering
                  ? Colors.blue.withOpacity(0.6)
                  : (isDark ? Colors.grey.shade700 : Colors.grey.shade300),
              width: 2,
            ),
            boxShadow: _hovering
                ? [
                    BoxShadow(
                      color: Colors.blue.withOpacity(0.2),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withOpacity(isDark ? 0.15 : 0.03),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 海报 (aspect 2:3, 跟 web 同款)
                AspectRatio(
                  aspectRatio: 2 / 3,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 海报
                      item.poster.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: item.poster,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => Container(
                                color: isDark ? Colors.grey.shade700 : Colors.grey.shade100,
                                child: Icon(Icons.movie, size: 28, color: Colors.grey.shade400),
                              ),
                              errorWidget: (_, __, ___) => Container(
                                color: isDark ? Colors.grey.shade700 : Colors.grey.shade100,
                                child: Icon(Icons.broken_image, size: 28, color: Colors.grey.shade400),
                              ),
                            )
                          : Container(
                              color: isDark ? Colors.grey.shade700 : Colors.grey.shade100,
                              child: Icon(Icons.tv, size: 28, color: Colors.grey.shade400),
                            ),
                      // hover 渐变遮罩 (跟 web group-hover:from-blue-500/10 同款)
                      if (_hovering)
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [
                                Colors.blue.withOpacity(0.1),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      // 年份标签 (top-right, 跟 web 同款)
                      if (item.year.isNotEmpty)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.7),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              item.year,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      // 分类标签 (bottom-left, 跟 web bg-blue-500/90 同款)
                      if (item.typeName.isNotEmpty)
                        Positioned(
                          bottom: 6,
                          left: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blue.withOpacity(0.9),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              item.typeName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // 标题 + 备注
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: _hovering
                              ? Colors.blue
                              : (isDark ? Colors.white : Colors.grey.shade900),
                          height: 1.3,
                        ),
                      ),
                      if (item.remarks.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          item.remarks,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: isDark ? Colors.grey.shade400 : Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// v2.3.32.1: 全屏 preview dialog (1:1 web preview modal)
//
// 关键改造:
//   1. detail 走 SearchService.getDetailSync → SearchResult (含 doubanId)
//      不是 SourceBrowserService.getDetail → SourceBrowserDetail
//   2. doubanId 从 SearchResult.doubanId 拿, 跟 web data.douban_id 同字段
//   3. detail 没 doubanId 时走 DownstreamService.searchFromApi fallback
//      跟 web /api/search/one?resourceId=K&q=Q 1:1, 同源精确搜拿 doubanId
//   4. 简介三段式 fallback (跟 web 1:1):
//      previewData.desc → previewSearchPick.desc → item.remarks
//   5. 豆瓣 section 加 plot_summary (剧情简介, 跟 web d.plot_summary 同款)
//   6. Bangumi section 加 name_cn 标题 (跟 web name_cn || name 同款)
// =====================================================================

class _PreviewDialog extends StatefulWidget {
  final SourceBrowserItem item;
  final SearchResource resource;
  // v2.3.32.1: detail 调用注入 (跟 web /api/detail 1:1, 返 SearchResult)
  final Future<List<SearchResult>> Function() loadDetail;
  // search_one fallback (跟 web /api/search/one 1:1)
  final Future<List<SearchResult>> Function(String query) loadSearchOne;
  // 播放回调 (用 screen context push, 避免 dialog context 失效)
  final void Function(SearchResult detail) onPlay;

  const _PreviewDialog({
    required this.item,
    required this.resource,
    required this.loadDetail,
    required this.loadSearchOne,
    required this.onPlay,
  });

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  bool _isLoading = true;
  String? _error;
  SearchResult? _detail;
  SearchResult? _searchPick; // search_one fallback 找到的同源匹配
  int? _doubanId; // 跟 web previewDoubanId 同款

  bool _isDoubanLoading = false;
  bool _isBangumiLoading = false;
  DoubanMovieDetails? _douban;
  BangumiDetails? _bangumi;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  /// v2.3.32.1: 1:1 web openPreview
  ///   1. 调 /api/detail 拿 detail (SearchResult)
  ///   2. 从 detail.douban_id 拿 doubanId
  ///   3. 没 doubanId 走 /api/search/one fallback 拿 (跟 web 同款)
  ///   4. 有 doubanId + 6 位 → Bangumi, 否则 → 豆瓣
  Future<void> _loadAll() async {
    try {
      final results = await widget.loadDetail();
      if (!mounted) return;
      if (results.isEmpty) {
        setState(() {
          _isLoading = false;
          _error = '未找到匹配的视频源';
        });
        return;
      }
      final detail = results.first;
      // v2.3.32.1: 跟 web data?.douban_id ? Number(data.douban_id) : null 同款
      int? dId = (detail.doubanId != null && detail.doubanId! > 0)
          ? detail.doubanId
          : null;

      setState(() {
        _detail = detail;
        _doubanId = dId;
        _isLoading = false;
      });

      // v2.3.32.1: search_one fallback (跟 web 1:1)
      //   detail 没 doubanId 时, 在当前源内精确搜标题拿 doubanId
      if (dId == null) {
        final normalize = (String s) => s.replaceAll(RegExp(r'\s+'), '').toLowerCase();
        final variants = <String>{
          widget.item.title,
          widget.item.title.replaceAll(RegExp(r'\s+'), ''),
        }.where((s) => s.isNotEmpty).toList();
        final targetNorm = normalize(widget.item.title);
        for (final v in variants) {
          try {
            final list = await widget.loadSearchOne(v);
            if (!mounted) return;
            // 优先标题+年份匹配
            SearchResult? pick;
            for (final r in list) {
              if (normalize(r.title) != targetNorm) continue;
              if (widget.item.year.isNotEmpty &&
                  r.year.isNotEmpty &&
                  r.year.toLowerCase() != widget.item.year.toLowerCase()) {
                continue;
              }
              if (r.doubanId != null && r.doubanId! > 0) {
                pick = r;
                break;
              }
            }
            // fallback 只匹配标题
            pick ??= list.cast<SearchResult?>().firstWhere(
                  (r) =>
                      r != null &&
                      normalize(r.title) == targetNorm &&
                      r.doubanId != null &&
                      r.doubanId! > 0,
                  orElse: () => null,
                );
            if (pick != null && pick.doubanId != null && pick.doubanId! > 0) {
              setState(() {
                _doubanId = pick!.doubanId;
                _searchPick = pick;
              });
              break;
            }
          } catch (_) {
            // ignore
          }
        }
      }

      // v2.3.32.1: 6 位 ID 走 Bangumi, 其它走豆瓣 (跟 web isBangumiId 1:1)
      final finalDId = _doubanId;
      if (finalDId != null && finalDId > 0) {
        if (_isBangumiId(finalDId)) {
          await _loadBangumi(finalDId);
        } else {
          await _loadDouban(finalDId);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  /// 跟 web isBangumiId = (id) => id > 0 && id.toString().length === 6 1:1
  bool _isBangumiId(int id) => id > 0 && id.toString().length == 6;

  Future<void> _loadDouban(int dId) async {
    setState(() => _isDoubanLoading = true);
    try {
      final resp = await DoubanService.getDoubanDetails(
        context,
        doubanId: dId.toString(),
      );
      if (!mounted) return;
      if (resp.success && resp.data != null) {
        setState(() => _douban = resp.data);
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isDoubanLoading = false);
    }
  }

  Future<void> _loadBangumi(int bId) async {
    setState(() => _isBangumiLoading = true);
    try {
      final resp = await BangumiService.getBangumiDetails(
        context,
        bangumiId: bId.toString(),
      );
      if (!mounted) return;
      if (resp.success && resp.data != null) {
        setState(() => _bangumi = resp.data);
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isBangumiLoading = false);
    }
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 700),
        decoration: BoxDecoration(
          // v2.3.32.1: 1:1 web 模糊背景 + 渐变
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [Colors.grey.shade800, Colors.blue.withOpacity(0.05), Colors.grey.shade800]
                : [Colors.white, Colors.blue.withOpacity(0.03), Colors.white],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 30,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(theme, isDark),
            Flexible(child: _buildBody(theme, isDark)),
            _buildFooter(theme, isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      decoration: BoxDecoration(
        color: (isDark ? Colors.grey.shade800 : Colors.white).withOpacity(0.8),
        border: Border(
          bottom: BorderSide(
            color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Colors.blue, Colors.indigo]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.blue.withOpacity(0.3),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(Icons.tv, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.item.title.isEmpty ? '详情预览' : widget.item.title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme, bool isDark) {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Colors.blue.shade600,
              ),
            ),
            const SizedBox(height: 12),
            Text('加载详情...', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40, color: Colors.red.shade400),
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(fontSize: 13, color: Colors.red.shade600)),
            ],
          ),
        ),
      );
    }
    final d = _detail;
    final item = widget.item;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左: 海报 (1:1 web md:sticky md:top-0)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 120,
              height: 170,
              child: (d?.poster.isNotEmpty ?? false)
                  ? CachedNetworkImage(
                      imageUrl: d!.poster,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _placeholderPoster(isDark),
                    )
                  : (item.poster.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: item.poster,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _placeholderPoster(isDark),
                        )
                      : _placeholderPoster(isDark)),
            ),
          ),
          const SizedBox(width: 16),
          // 右: 元数据 + 简介 + 豆瓣/Bangumi
          Expanded(child: _buildRightColumn(theme, isDark, d, item)),
        ],
      ),
    );
  }

  Widget _placeholderPoster(bool isDark) {
    return Container(
      color: isDark ? Colors.grey.shade700 : Colors.grey.shade100,
      child: Center(
        child: Icon(Icons.tv, size: 36, color: Colors.grey.shade400),
      ),
    );
  }

  Widget _buildRightColumn(
      ThemeData theme, bool isDark, SearchResult? d, SourceBrowserItem item) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题 + 评分徽章 + 外链
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            Text(
              (d?.title.isNotEmpty ?? false) ? d!.title : item.title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            // 评分徽章
            if (_douban?.rate != null && _douban!.rate!.isNotEmpty)
              _badge('豆瓣 ${_douban!.rate}', Colors.green),
            if (_bangumi != null && _bangumi!.rating.score > 0)
              _badge('Bangumi ${_bangumi!.rating.score.toStringAsFixed(1)}', Colors.purple),
            // 外链
            if (_douban?.id != null)
              _linkChip('豆瓣', Colors.blue,
                  () => _openExternal('https://movie.douban.com/subject/${_douban!.id}/')),
            if (_bangumi != null && _doubanId != null)
              _linkChip('Bangumi', Colors.purple,
                  () => _openExternal('https://bgm.tv/subject/$_doubanId')),
          ],
        ),
        const SizedBox(height: 8),
        // 年份 + 来源
        Text(
          '年份: ${(d?.year.isNotEmpty ?? false) && d!.year != 'unknown' ? d.year : item.year}',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        Text(
          '来源: ${widget.resource.name}',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 8),
        // 类型标签
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (item.typeName.isNotEmpty) _tag(item.typeName, isDark),
            if (d?.class_ != null && d!.class_!.isNotEmpty) _tag(d.class_!, isDark),
            if (_douban != null) ...[
              ..._douban!.genres.map((g) => _tag(g, isDark)),
              ..._douban!.countries.map((c) => _tag(c, isDark)),
              ..._douban!.languages.map((l) => _tag(l, isDark)),
            ],
            if (_bangumi != null)
              ..._bangumi!.tags.take(5).map((t) => _tag(t, isDark)),
          ],
        ),
        const SizedBox(height: 12),
        // 简介 (三段式 fallback, 跟 web 1:1)
        //   previewData.desc → previewSearchPick.desc → item.remarks
        _buildDescription(isDark, d, item),
        // 豆瓣 section
        if (_isDoubanLoading)
          _loadingRow('加载豆瓣信息...')
        else if (_douban != null)
          _buildDoubanSection(isDark, _douban!),
        // Bangumi section
        if (_isBangumiLoading)
          _loadingRow('加载 Bangumi 信息...')
        else if (_bangumi != null)
          _buildBangumiSection(isDark, _bangumi!),
      ],
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _linkChip(String text, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.open_in_new, size: 12, color: color),
          const SizedBox(width: 2),
          Text(' $text', style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }

  Widget _tag(String text, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey.shade700 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: const TextStyle(fontSize: 10)),
    );
  }

  Widget _loadingRow(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  /// v2.3.32.1: 1:1 web 简介三段式 fallback
  ///   previewData.desc → previewSearchPick.desc → item.remarks
  Widget _buildDescription(bool isDark, SearchResult? d, SourceBrowserItem item) {
    String? desc;
    if (d?.desc != null && d!.desc!.trim().isNotEmpty) {
      desc = d.desc!.trim();
    } else if (_searchPick?.desc != null && _searchPick!.desc!.trim().isNotEmpty) {
      desc = _searchPick!.desc!.trim();
    } else if (item.remarks.isNotEmpty) {
      desc = item.remarks;
    }
    if (desc == null || desc.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 140),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey.shade900.withOpacity(0.5) : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? Colors.grey.shade700 : Colors.grey.shade200),
      ),
      child: SingleChildScrollView(
        child: Text(
          desc,
          style: TextStyle(fontSize: 12, height: 1.5, color: Colors.grey.shade700),
        ),
      ),
    );
  }

  Widget _buildDoubanSection(bool isDark, DoubanMovieDetails d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        const Text('豆瓣信息', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        if (d.title.isNotEmpty)
          Text('标题: ${d.title}${(d.rate != null && d.rate!.isNotEmpty) ? "（评分 ${d.rate}）" : ""}',
              style: const TextStyle(fontSize: 12)),
        if (d.directors.isNotEmpty)
          Text('导演: ${d.directors.join('、')}', style: const TextStyle(fontSize: 12)),
        if (d.screenwriters.isNotEmpty)
          Text('编剧: ${d.screenwriters.join('、')}', style: const TextStyle(fontSize: 12)),
        if (d.actors.isNotEmpty)
          Text('主演: ${d.actors.take(8).join('、')}${d.actors.length > 8 ? "…" : ""}',
              style: const TextStyle(fontSize: 12)),
        if (d.releaseDate != null && d.releaseDate!.isNotEmpty)
          Text('首播/上映: ${d.releaseDate}', style: const TextStyle(fontSize: 12)),
        if (d.totalEpisodes != null || d.duration != null)
          Text(
            [
              if (d.totalEpisodes != null) '集数: ${d.totalEpisodes}',
              if (d.duration != null) '片长: ${d.duration} 分钟',
            ].join(' '),
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        // v2.3.32.1: plot_summary 剧情简介 (跟 web d.plot_summary 1:1)
        if (d.summary != null && d.summary!.trim().isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isDark ? Colors.grey.shade900.withOpacity(0.3) : Colors.grey.shade50,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              d.summary!.trim(),
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.5),
            ),
          ),
      ],
    );
  }

  Widget _buildBangumiSection(bool isDark, BangumiDetails b) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        const Text('Bangumi 信息', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        // v2.3.32.1: name_cn || name 标题 (跟 web 1:1)
        // BangumiDetails.nameCn 是 String?, 需要 null-safe 访问
        Text(
          '标题: ${(b.nameCn != null && b.nameCn!.isNotEmpty) ? b.nameCn : b.name}'
          '${b.rating.score > 0 ? "（评分 ${b.rating.score.toStringAsFixed(1)}）" : ""}',
          style: const TextStyle(fontSize: 12),
        ),
        if (b.date != null && b.date!.isNotEmpty)
          Text('首播: ${b.date}', style: const TextStyle(fontSize: 12)),
        if (b.eps > 0) Text('集数: ${b.eps}', style: const TextStyle(fontSize: 12)),
        if (b.infobox.isNotEmpty) ...[
          const SizedBox(height: 4),
          ...b.infobox.take(8).map((s) => Text(s, style: const TextStyle(fontSize: 11))),
        ],
        if (b.summary.trim().isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isDark ? Colors.grey.shade900.withOpacity(0.3) : Colors.grey.shade50,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              b.summary.trim(),
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.5),
            ),
          ),
      ],
    );
  }

  Widget _buildFooter(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [Colors.grey.shade800.withOpacity(0.9), Colors.blue.withOpacity(0.05), Colors.grey.shade800.withOpacity(0.9)]
              : [Colors.white.withOpacity(0.9), Colors.blue.withOpacity(0.03), Colors.white.withOpacity(0.9)],
        ),
        border: Border(
          top: BorderSide(
            color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
          ),
        ),
      ),
      child: Row(
        children: [
          // 来源 class 圆点 (跟 web previewData.class 1:1)
          if (_detail?.class_ != null && _detail!.class_!.isNotEmpty) ...[
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Colors.blue,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              _detail!.class_!,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ],
          const Spacer(),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              side: BorderSide(
                color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
                width: 2,
              ),
            ),
            child: const Text('取消'),
          ),
          const SizedBox(width: 10),
          // 1:1 web 立即播放: blue→indigo 渐变 + shadow + scale
          ElevatedButton.icon(
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('立即播放'),
            onPressed: _detail == null ? null : () => widget.onPlay(_detail!),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              backgroundColor: Colors.transparent,
              foregroundColor: Colors.white,
              elevation: 0,
              shadowColor: Colors.transparent,
            ).copyWith(
              backgroundColor: MaterialStateProperty.all(Colors.transparent),
              foregroundColor: MaterialStateProperty.all(Colors.white),
            ),
            // 渐变背景用 container 包
          ).wrapGradient(),
        ],
      ),
    );
  }
}

// Extension: 给 ElevatedButton 包渐变背景
extension _GradientButton on Widget {
  Widget wrapGradient() {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Colors.blue, Colors.indigo]),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: this,
    );
  }
}
