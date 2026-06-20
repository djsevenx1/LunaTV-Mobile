import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:luna_tv/models/short_drama.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/screens/player_screen.dart';
import 'package:luna_tv/services/short_drama_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/widgets/short_drama_card.dart';
import 'package:luna_tv/widgets/pulsing_dots_indicator.dart';
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
  final TextEditingController _searchController = TextEditingController();

  // 分类数据
  List<ShortDramaCategory> _categories = [];
  int? _selectedCategoryId;

  // 搜索
  String _searchQuery = '';
  bool _isSearchMode = false;

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
    _searchController.dispose();
    super.dispose();
  }

  /// 加载分类列表
  Future<void> _loadCategories() async {
    final categories = await ShortDramaService.getCategories();
    if (!mounted) return;
    setState(() {
      _categories = categories;
      // 默认选中第一个分类
      if (categories.isNotEmpty && _selectedCategoryId == null) {
        _selectedCategoryId = categories.first.typeId;
        _fetchDramaList(isRefresh: true);
      }
    });
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

  /// 获取短剧列表
  Future<void> _fetchDramaList({bool isRefresh = false}) async {
    if (!mounted) return;

    // 搜索模式或分类模式
    if (_isSearchMode && _searchQuery.isNotEmpty) {
      setState(() {
        _isLoading = true;
        if (isRefresh) {
          _dramaList.clear();
          _page = 1;
          _hasMore = true;
        }
        _errorMessage = null;
      });

      final result = await ShortDramaService.search(_searchQuery, page: _page);

      if (!mounted) return;

      setState(() {
        _dramaList.addAll(result.list);
        _hasMore = result.hasMore;
        _isLoading = false;
      });
      return;
    }

    // 分类模式
    if (_selectedCategoryId == null) {
      setState(() {
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      if (isRefresh) {
        _dramaList.clear();
        _page = 1;
        _hasMore = true;
      }
      _errorMessage = null;
    });

    final result = await ShortDramaService.getList(
      categoryId: _selectedCategoryId!,
      page: _page,
    );

    if (!mounted) return;

    setState(() {
      _dramaList.addAll(result.list);
      _hasMore = result.hasMore;
      _isLoading = false;
      // 如果当前分类为空，自动跳到下一个分类
      if (result.list.isEmpty && _categories.isNotEmpty && !_isSearchMode) {
        _autoSwitchToNextCategory();
      }
    });
  }

  /// 自动切换到下一个有内容的分类
  void _autoSwitchToNextCategory() {
    if (_selectedCategoryId == null || _categories.isEmpty) return;

    final currentIndex = _categories.indexWhere(
      (c) => c.typeId == _selectedCategoryId,
    );
    if (currentIndex >= 0 && currentIndex < _categories.length - 1) {
      final nextCategory = _categories[currentIndex + 1];
      // 延迟切换，避免在 build 中调用 setState
      Future.microtask(() {
        if (mounted) {
          _onCategoryChanged(nextCategory.typeId);
        }
      });
    }
  }

  /// 加载更多
  Future<void> _loadMoreDramaList() async {
    if (!mounted) return;
    if (_isLoading || _isLoadingMore || !_hasMore) return;

    setState(() {
      _isLoadingMore = true;
    });

    _page++;

    if (_isSearchMode && _searchQuery.isNotEmpty) {
      final result = await ShortDramaService.search(_searchQuery, page: _page);
      if (!mounted) return;
      setState(() {
        _dramaList.addAll(result.list);
        _hasMore = result.hasMore;
        _isLoadingMore = false;
      });
    } else if (_selectedCategoryId != null) {
      final result = await ShortDramaService.getList(
        categoryId: _selectedCategoryId!,
        page: _page,
      );
      if (!mounted) return;
      setState(() {
        _dramaList.addAll(result.list);
        _hasMore = result.hasMore;
        _isLoadingMore = false;
      });
    } else {
      setState(() {
        _isLoadingMore = false;
      });
    }
  }

  /// 下拉刷新
  Future<void> _refreshDramaList() async {
    await _fetchDramaList(isRefresh: true);
  }

  /// 切换分类
  void _onCategoryChanged(int categoryId) {
    if (!mounted) return;
    setState(() {
      _selectedCategoryId = categoryId;
      _isSearchMode = false;
      _searchController.clear();
    });
    _fetchDramaList(isRefresh: true);
  }

  /// 执行搜索
  void _onSearch(String query) {
    if (query.isEmpty) {
      _onClearSearch();
      return;
    }
    setState(() {
      _searchQuery = query;
      _isSearchMode = true;
    });
    _fetchDramaList(isRefresh: true);
  }

  /// 清除搜索
  void _onClearSearch() {
    setState(() {
      _searchQuery = '';
      _isSearchMode = false;
      _searchController.clear();
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
              // 搜索栏
              SliverToBoxAdapter(
                child: _buildSearchBar(themeService),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
              // 分类横向滚动标签
              SliverToBoxAdapter(
                child: _buildCategoryTabs(themeService),
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
            '短剧频道',
            style: FontUtils.poppins(context,
              fontSize: 28,
              fontWeight: FontWeight.w600,
              color: themeService.isDarkMode
                  ? const Color(0xFFffffff)
                  : const Color(0xFF2c3e50),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 20,
            child: Text(
              '精彩短剧，一刷到底',
              style: FontUtils.poppins(context,
                fontSize: 14,
                color: themeService.isDarkMode
                    ? const Color(0xFFb0b0b0)
                    : const Color(0xFF7f8c8d),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建搜索栏
  Widget _buildSearchBar(ThemeService themeService) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: themeService.isDarkMode
              ? Colors.white.withOpacity(0.08)
              : Colors.grey[100],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: themeService.isDarkMode
                ? Colors.white.withOpacity(0.1)
                : Colors.grey[300]!,
            width: 0.5,
          ),
        ),
        child: TextField(
          controller: _searchController,
          onSubmitted: _onSearch,
          style: FontUtils.poppins(context, fontSize: 14),
          decoration: InputDecoration(
            hintText: '搜索短剧...',
            hintStyle: FontUtils.poppins(context,
              fontSize: 14,
              color: themeService.isDarkMode
                  ? const Color(0xFF888888)
                  : const Color(0xFF999999),
            ),
            prefixIcon: Icon(
              Icons.search,
              color: themeService.isDarkMode
                  ? const Color(0xFF888888)
                  : const Color(0xFF999999),
              size: 20,
            ),
            suffixIcon: _isSearchMode
                ? IconButton(
                    icon: Icon(
                      Icons.close,
                      color: themeService.isDarkMode
                          ? const Color(0xFF888888)
                          : const Color(0xFF999999),
                      size: 18,
                    ),
                    onPressed: _onClearSearch,
                  )
                : null,
            border: InputBorder.none,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ),
    );
  }

  /// 构建分类横向滚动标签
  Widget _buildCategoryTabs(ThemeService themeService) {
    if (_categories.isEmpty) {
      return const SizedBox(height: 40);
    }
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: _categories.map((category) {
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _buildCategoryChip(
              label: category.typeName,
              isSelected: _selectedCategoryId == category.typeId,
              themeService: themeService,
              onTap: () => _onCategoryChanged(category.typeId),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// 构建单个分类标签
  Widget _buildCategoryChip({
    required String label,
    required bool isSelected,
    required ThemeService themeService,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          gradient: isSelected
              ? const LinearGradient(
                  colors: [Color(0xFF22C55E), Color(0xFF10B981)],
                )
              : null,
          color: !isSelected
              ? (themeService.isDarkMode
                  ? Colors.white.withOpacity(0.1)
                  : Colors.grey[200])
              : null,
          borderRadius: BorderRadius.circular(20),
          border: isSelected
              ? null
              : Border.all(
                  color: themeService.isDarkMode
                      ? Colors.white.withOpacity(0.2)
                      : Colors.grey[400]!,
                  width: 0.5,
                ),
        ),
        child: Text(
          label,
          style: FontUtils.poppins(context,
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
            color: isSelected
                ? Colors.white
                : (themeService.isDarkMode
                    ? const Color(0xFFb0b0b0)
                    : const Color(0xFF7f8c8d)),
          ),
        ),
      ),
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
            _isSearchMode ? '未找到相关短剧' : '暂无短剧内容',
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
