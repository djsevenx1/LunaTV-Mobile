import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:luna_tv/models/short_drama.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/screens/player_screen.dart';
// v2.5.3: 列表/分类/图片走 ShortDramaDirectService (直连 3 源, 不依赖
//   serverUrl). 播放解析仍走 ShortDramaService.parseEpisode (serverUrl
//   后端代理, 含反爬/防盗链/CDN 缓存).
import 'package:luna_tv/services/short_drama_direct_service.dart';
import 'package:luna_tv/services/short_drama_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/widgets/short_drama_card.dart';
import 'package:luna_tv/widgets/pulsing_dots_indicator.dart';
import 'package:luna_tv/widgets/capsule_tab_switcher.dart';
import 'package:luna_tv/utils/font_utils.dart';
import 'package:luna_tv/utils/device_utils.dart';

/// 短剧页面
class ShortDramaScreen extends StatefulWidget {
  const ShortDramaScreen({super.key});

  @override
  State<ShortDramaScreen> createState() => _ShortDramaScreenState();
}

class _ShortDramaScreenState extends State<ShortDramaScreen> {
  final ScrollController _scrollController = ScrollController();

  // 类型筛选（来自 API 的分类列表，去掉名字为"短剧"的项）
  List<String> _typeTabs = const [];
  String _selectedTypeTab = '';
  // 类型 -> 分类 typeId 的映射. 「全部」tab 不进 map, 走 _fetchDramaList 兜底逻辑.
  final Map<String, int> _typeToCategoryId = {};
  // 「全部」tab 的 key (selectedTypeTab 用这个字符串表示「全部」)
  static const String _kAllTabKey = '全部';

  // 列表数据
  final List<ShortDrama> _dramaList = [];
  int _page = 1;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String? _errorMessage;
  // v2.5.6: 「全部」tab 用的 page 状态 (跟子分类 tab 的 _page 共享).
  // 已展示的剧名集合, 翻页去重用.
  final Set<String> _shownNames = {};

  @override
  void initState() {
    super.initState();
    _loadCategories();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// v2.5.5: 加载分类列表 — 走 ShortDramaDirectService (写死分类, 0 延迟).
  /// v2.5.5 起: 分类 tab 最前面插入「全部」tab, 点击走 3 源聚合 getRecommend.
  Future<void> _loadCategories() async {
    final categories = await ShortDramaDirectService.getCategories();
    if (!mounted) return;

    // 过滤掉 "短剧" (被「全部」tab 替代, 「全部」走 3 源聚合)
    final typeTabs = <String>[_kAllTabKey]; // 「全部」永远排第一
    final typeToId = <String, int>{};
    for (final c in categories) {
      final name = c.typeName.trim();
      if (name.isEmpty) continue;
      if (name == '短剧') continue; // 主类被「全部」替代
      if (name == '全部') continue; // 不会出现在 getCategories 返回里, 兜底
      if (typeTabs.contains(name)) continue;
      typeTabs.add(name);
      typeToId[name] = c.typeId;
    }

    setState(() {
      _typeTabs = typeTabs;
      _typeToCategoryId
        ..clear()
        ..addAll(typeToId);
      // 默认选中「全部」tab (第一位)
      _selectedTypeTab = _kAllTabKey;
    });

    // 初次加载：根据当前筛选状态拉取
    _fetchDramaList(isRefresh: true);
  }

  /// 处理滚动事件，上拉加载更多
  void _handleScroll() {
    if (!mounted) return;

    if (_scrollController.hasClients) {
      final position = _scrollController.position;

      if (position.maxScrollExtent <= 0) {
        if (_hasMore && !_isLoading && !_isLoadingMore && _dramaList.isNotEmpty) {
          _loadMoreDramaList();
        }
        return;
      }

      const double threshold = 100.0;
      if (position.pixels >= position.maxScrollExtent - threshold) {
        _loadMoreDramaList();
      }
    }
  }

  /// v2.5.6: 根据当前筛选拉取数据 — 走 ShortDramaDirectService.
  /// - 选中「全部」tab (selectedTypeTab == _kAllTabKey) → 3 源全聚合
  ///   + 去重 (getRecommendResponse, size=60 一次性, 但可翻页拉更多)
  /// - 选中具体子类 (typeId=64-69/62/63/52) → 该源按 type_id 拉 + 分页
  Future<void> _fetchDramaList({bool isRefresh = false}) async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      if (isRefresh) {
        _dramaList.clear();
        _page = 1;
        _hasMore = true;
        _shownNames.clear(); // v2.5.6: 切 tab / 刷新时清空去重 set
      }
      _errorMessage = null;
    });

    final selectedTypeId = _currentSelectedTypeId();
    ShortDramaListResponse result;
    if (selectedTypeId == null) {
      // 「全部」tab: 3 源聚合推荐
      result = await ShortDramaDirectService.getRecommendResponse(
        page: 1,
        size: 60,
        excludeNames: isRefresh ? null : _shownNames,
      );
    } else {
      result = await ShortDramaDirectService.getListByTypeId(
        typeId: selectedTypeId,
        page: _page,
        size: 20,
      );
    }

    if (!mounted) return;

    setState(() {
      _dramaList.addAll(result.list);
      // v2.5.6: 把新拉的剧名加入 _shownNames (下次翻页排除)
      for (final d in result.list) {
        if (d.name.isNotEmpty) _shownNames.add(d.name);
      }
      _hasMore = result.hasMore;
      _isLoading = false;
    });
  }

  /// 加载更多
  Future<void> _loadMoreDramaList() async {
    if (!mounted) return;
    if (_isLoading || _isLoadingMore || !_hasMore) return;

    setState(() {
      _isLoadingMore = true;
    });

    _page++;

    final selectedTypeId = _currentSelectedTypeId();
    ShortDramaListResponse result;
    if (selectedTypeId == null) {
      // 「全部」tab 翻页: 拉下一页
      result = await ShortDramaDirectService.getRecommendResponse(
        page: _page,
        size: 60,
        excludeNames: _shownNames,
      );
    } else {
      result = await ShortDramaDirectService.getListByTypeId(
        typeId: selectedTypeId,
        page: _page,
        size: 20,
      );
    }

    if (!mounted) return;
    setState(() {
      _dramaList.addAll(result.list);
      for (final d in result.list) {
        if (d.name.isNotEmpty) _shownNames.add(d.name);
      }
      _hasMore = result.hasMore;
      _isLoadingMore = false;
    });
  }

  /// v2.5.5: 当前选中 tab 的 typeId. 返回 null 表示「全部」(走聚合).
  int? _currentSelectedTypeId() {
    if (_selectedTypeTab == _kAllTabKey) return null;
    final id = _typeToCategoryId[_selectedTypeTab];
    if (id == null || id <= 0) return null;
    return id;
  }

  /// 下拉刷新
  Future<void> _refreshDramaList() async {
    await _fetchDramaList(isRefresh: true);
  }

  /// 切换类型
  void _onTypeTabChanged(String tab) {
    if (_selectedTypeTab == tab) return;
    setState(() {
      _selectedTypeTab = tab;
      // v2.5.6: 切 tab 时清空去重 set (「全部」和子分类的去重不能混)
      _shownNames.clear();
      _page = 1;
    });
    _fetchDramaList(isRefresh: true);
  }

  /// 点击短剧卡片 - 和电视剧/电影一样，跳转 PlayerScreen 走多源搜索播放
  void _onDramaTap(ShortDrama drama) {
    final cover = drama.backdrop.isNotEmpty ? drama.backdrop : drama.cover;
    final videoInfo = VideoInfo(
      id: drama.id.toString(),
      source: '',
      title: drama.name,
      sourceName: '',
      year: '',
      cover: cover,
      index: 0,
      totalEpisodes: drama.episodeCount,
      playTime: 0,
      totalTime: 0,
      saveTime: 0,
      searchTitle: drama.name,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PlayerScreen(videoInfo: videoInfo),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return RefreshIndicator(
          onRefresh: _refreshDramaList,
          color: const Color(0xFF22C55E),
          child: CustomScrollView(
            controller: _scrollController,
            slivers: [
              // 顶部标题
              SliverToBoxAdapter(
                child: _buildHeader(themeService),
              ),
              // 筛选区（与电视剧页风格一致：白底圆角容器，双行标签）
              SliverToBoxAdapter(
                child: _buildFilterSection(themeService),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              // 内容区域
              if (_isLoading && _dramaList.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: PulsingDotsIndicator(),
                  ),
                )
              else if (_errorMessage != null && _dramaList.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _buildErrorState(themeService),
                )
              else if (_dramaList.isEmpty && !_isLoading)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _buildEmptyState(themeService),
                )
              else
                _buildDramaGrid(themeService),
              // 底部加载更多指示器
              if (_dramaList.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: _buildBottomIndicator(themeService),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 构建顶部标题
  Widget _buildHeader(ThemeService themeService) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '短剧',
            style: FontUtils.poppins(context,
              fontSize: 28,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).textTheme.titleLarge?.color,
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 20, // 固定高度确保一致性
            child: Text(
              '精彩短剧，一刷到底',
              style: FontUtils.poppins(context,
                fontSize: 14,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建筛选区（白底圆角容器，仅保留类型胶囊标签）
  Widget _buildFilterSection(ThemeService themeService) {
    if (_typeTabs.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: themeService.isDarkMode
            ? Colors.white.withOpacity(0.1)
            : Colors.white.withOpacity(0.8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: _buildFilterRow(
        label: '类型',
        tabs: _typeTabs,
        selectedTab: _selectedTypeTab,
        onTabChanged: _onTypeTabChanged,
      ),
    );
  }

  /// 构建单行筛选行（标题 + 横向胶囊标签）
  Widget _buildFilterRow({
    required String label,
    required List<String> tabs,
    required String selectedTab,
    required ValueChanged<String> onTabChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: FontUtils.poppins(context,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).textTheme.bodyMedium?.color,
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: CapsuleTabSwitcher(
            tabs: tabs,
            selectedTab: selectedTab,
            onTabChanged: onTabChanged,
          ),
        ),
      ],
    );
  }

  /// 构建短剧网格
  Widget _buildDramaGrid(ThemeService themeService) {
    final bool isPC = DeviceUtils.isPC();
    final double screenWidth = MediaQuery.of(context).size.width;

    int crossAxisCount;
    double horizontalPadding;

    if (isPC) {
      if (screenWidth > 1200) {
        crossAxisCount = 6;
      } else if (screenWidth > 900) {
        crossAxisCount = 5;
      } else {
        crossAxisCount = 4;
      }
      horizontalPadding = 24;
    } else if (DeviceUtils.isTablet(context)) {
      // 平板模式：根据屏幕宽度动态展示 6～8 列
      crossAxisCount = DeviceUtils.getTabletColumnCount(context);
      horizontalPadding = 16;
    } else {
      crossAxisCount = 3;
      horizontalPadding = 12;
    }

    final double gridWidth = screenWidth - horizontalPadding * 2;
    final double spacing = isPC ? 16.0 : 12.0;
    final double cardWidth = (gridWidth - spacing * (crossAxisCount - 1)) / crossAxisCount;
    // 平板 6~8 列下卡片更窄,行间距收紧 + 文字区按 cardWidth 缩放,避免海报视觉松散
    final double mainAxisSpacing = isPC ? 16.0 : 12.0;
    // PC 大卡文字区给 22,手机/平板窄卡统一给 16,与 ShortDramaCard 内部缩字号一致
    final double textAreaHeight = cardWidth < 200 ? 16.0 : 22.0;

    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: mainAxisSpacing,
          crossAxisSpacing: spacing,
          childAspectRatio: cardWidth / (cardWidth * 1.5 + textAreaHeight),
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final drama = _dramaList[index];
            return ShortDramaCard(
              drama: drama,
              cardWidth: cardWidth,
              onTap: () => _onDramaTap(drama),
            );
          },
          childCount: _dramaList.length,
        ),
      ),
    );
  }

  /// 构建空状态
  Widget _buildEmptyState(ThemeService themeService) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.movie_filter_outlined,
            size: 64,
            color: themeService.isDarkMode
                ? Colors.white.withOpacity(0.3)
                : Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            '暂无短剧内容',
            style: FontUtils.poppins(context,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: themeService.isDarkMode
                  ? const Color(0xFFb0b0b0)
                  : const Color(0xFF7f8c8d),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '下拉刷新试试',
            style: FontUtils.poppins(context,
              fontSize: 13,
              color: themeService.isDarkMode
                  ? Colors.white.withOpacity(0.4)
                  : Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建错误状态
  Widget _buildErrorState(ThemeService themeService) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: themeService.isDarkMode
                ? Colors.white.withOpacity(0.3)
                : Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            _errorMessage ?? '加载失败',
            style: FontUtils.poppins(context,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: themeService.isDarkMode
                  ? const Color(0xFFb0b0b0)
                  : const Color(0xFF7f8c8d),
            ),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: _refreshDramaList,
            child: Text(
              '重试',
              style: FontUtils.poppins(context,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF27ae60),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建底部指示器
  Widget _buildBottomIndicator(ThemeService themeService) {
    if (_isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: PulsingDotsIndicator(),
      );
    }

    if (!_hasMore && _dramaList.isNotEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          children: [
            Container(
              width: 60,
              height: 2,
              decoration: BoxDecoration(
                color: themeService.isDarkMode
                    ? Colors.white.withOpacity(0.3)
                    : Colors.grey.withOpacity(0.4),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '已经到底啦~',
              style: FontUtils.poppins(context,
                fontSize: 14,
                color: themeService.isDarkMode
                    ? Colors.white.withOpacity(0.6)
                    : Colors.grey[600],
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '共 ${_dramaList.length} 部短剧',
              style: FontUtils.poppins(context,
                fontSize: 12,
                color: themeService.isDarkMode
                    ? Colors.white.withOpacity(0.4)
                    : Colors.grey[500],
                fontWeight: FontWeight.w300,
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox(height: 50);
  }
}