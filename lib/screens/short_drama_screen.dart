import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:luna_tv/models/short_drama.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/screens/player_screen.dart';
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

  // 一级筛选：分类
  final List<String> _primaryTabs = const ['全部', '最近热门'];
  String _selectedPrimaryTab = '最近热门';

  // 二级筛选：类型（来自 API 的分类列表，前面会拼一个"全部"）
  List<String> _typeTabs = const ['全部'];
  String _selectedTypeTab = '全部';
  // 类型 -> 分类 typeId 的映射（"全部" 对应 null）
  final Map<String, int> _typeToCategoryId = {};

  // 列表数据
  final List<ShortDrama> _dramaList = [];
  int _page = 1;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String? _errorMessage;

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

  /// 加载分类列表
  Future<void> _loadCategories() async {
    final categories = await ShortDramaService.getCategories();
    if (!mounted) return;

    final typeTabs = <String>['全部'];
    final typeToId = <String, int>{'全部': -1};
    for (final c in categories) {
      if (!typeTabs.contains(c.typeName)) {
        typeTabs.add(c.typeName);
        typeToId[c.typeName] = c.typeId;
      }
    }

    setState(() {
      _typeTabs = typeTabs;
      _typeToCategoryId
        ..clear()
        ..addAll(typeToId);
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

  /// 根据当前筛选拉取数据
  Future<void> _fetchDramaList({bool isRefresh = false}) async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      if (isRefresh) {
        _dramaList.clear();
        _page = 1;
        _hasMore = true;
      }
      _errorMessage = null;
    });

    ShortDramaListResponse result;
    final selectedTypeId = _typeToCategoryId[_selectedTypeTab];

    if (_selectedPrimaryTab == '最近热门' ||
        _selectedTypeTab == '全部' ||
        selectedTypeId == null ||
        selectedTypeId == -1) {
      // 最近热门 / 全部类型 -> 走推荐接口
      result = await ShortDramaService.getRecommendResponse(
        category: selectedTypeId != null && selectedTypeId > 0
            ? selectedTypeId
            : null,
        page: _page,
        size: 20,
      );
    } else {
      // 指定类型 -> 走分类列表接口
      result = await ShortDramaService.getList(
        categoryId: selectedTypeId,
        page: _page,
        size: 20,
      );
    }

    if (!mounted) return;

    setState(() {
      _dramaList.addAll(result.list);
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

    ShortDramaListResponse result;
    final selectedTypeId = _typeToCategoryId[_selectedTypeTab];

    if (_selectedPrimaryTab == '最近热门' ||
        _selectedTypeTab == '全部' ||
        selectedTypeId == null ||
        selectedTypeId == -1) {
      result = await ShortDramaService.getRecommendResponse(
        category: selectedTypeId != null && selectedTypeId > 0
            ? selectedTypeId
            : null,
        page: _page,
        size: 20,
      );
    } else {
      result = await ShortDramaService.getList(
        categoryId: selectedTypeId,
        page: _page,
        size: 20,
      );
    }

    if (!mounted) return;
    setState(() {
      _dramaList.addAll(result.list);
      _hasMore = result.hasMore;
      _isLoadingMore = false;
    });
  }

  /// 下拉刷新
  Future<void> _refreshDramaList() async {
    await _fetchDramaList(isRefresh: true);
  }

  /// 切换一级分类
  void _onPrimaryTabChanged(String tab) {
    if (_selectedPrimaryTab == tab) return;
    setState(() {
      _selectedPrimaryTab = tab;
    });
    _fetchDramaList(isRefresh: true);
  }

  /// 切换二级类型
  void _onTypeTabChanged(String tab) {
    if (_selectedTypeTab == tab) return;
    setState(() {
      _selectedTypeTab = tab;
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

  /// 构建筛选区（与电视剧页风格一致：白底圆角容器 + 双行胶囊标签）
  Widget _buildFilterSection(ThemeService themeService) {
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildFilterRow(
            label: '分类',
            tabs: _primaryTabs,
            selectedTab: _selectedPrimaryTab,
            onTabChanged: _onPrimaryTabChanged,
          ),
          const SizedBox(height: 16),
          _buildFilterRow(
            label: '类型',
            tabs: _typeTabs,
            selectedTab: _selectedTypeTab,
            onTabChanged: _onTypeTabChanged,
          ),
        ],
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
    double cardWidth;
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
    } else {
      crossAxisCount = 3;
      horizontalPadding = 12;
    }

    final double gridWidth = screenWidth - horizontalPadding * 2;
    final double spacing = isPC ? 16.0 : 10.0;
    cardWidth = (gridWidth - spacing * (crossAxisCount - 1)) / crossAxisCount;

    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 16,
          crossAxisSpacing: spacing,
          childAspectRatio: cardWidth / (cardWidth * 1.5 + 22),
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