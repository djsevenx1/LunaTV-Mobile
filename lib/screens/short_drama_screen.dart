import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:luna_tv/models/short_drama.dart';
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

  // 分类数据
  List<String> _categories = [];
  String _selectedCategory = '';

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
    _fetchDramaList(isRefresh: true);
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
    setState(() {
      _categories = categories;
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

      const double threshold = 50.0;
      if (position.pixels >= position.maxScrollExtent - threshold) {
        _loadMoreDramaList();
      }
    }
  }

  /// 获取短剧列表
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

    final category =
        (_selectedCategory.isEmpty || _selectedCategory == '全部')
            ? null
            : _selectedCategory;

    final result = await ShortDramaService.getList(
      category: category,
      page: _page,
    );

    if (!mounted) return;

    setState(() {
      _dramaList.addAll(result);
      if (result.isEmpty) {
        _hasMore = false;
      }
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

    final category =
        (_selectedCategory.isEmpty || _selectedCategory == '全部')
            ? null
            : _selectedCategory;

    final result = await ShortDramaService.getList(
      category: category,
      page: _page,
    );

    if (!mounted) return;

    setState(() {
      _dramaList.addAll(result);
      if (result.isEmpty) {
        _hasMore = false;
      }
      _isLoadingMore = false;
    });
  }

  /// 下拉刷新
  Future<void> _refreshDramaList() async {
    await _fetchDramaList(isRefresh: true);
  }

  /// 切换分类
  void _onCategoryChanged(String category) {
    if (!mounted) return;
    setState(() {
      _selectedCategory = category;
    });
    _fetchDramaList(isRefresh: true);
  }

  /// 点击短剧卡片
  void _onDramaTap(ShortDrama drama) {
    // 跳转到播放器页面
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _ShortDramaPlayerScreen(drama: drama),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return RefreshIndicator(
          onRefresh: _refreshDramaList,
          color: const Color(0xFF27ae60),
          child: CustomScrollView(
            controller: _scrollController,
            slivers: [
              // 顶部标题
              SliverToBoxAdapter(
                child: _buildHeader(themeService),
              ),
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
              else if (_dramaList.isEmpty)
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
              color: themeService.isDarkMode
                  ? const Color(0xFFffffff)
                  : const Color(0xFF2c3e50),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 20,
            child: Text(
              '精选短剧内容',
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

  /// 构建分类横向滚动标签
  Widget _buildCategoryTabs(ThemeService themeService) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          // "全部" 标签始终显示
          _buildCategoryChip(
            label: '全部',
            isSelected: _selectedCategory.isEmpty || _selectedCategory == '全部',
            themeService: themeService,
          ),
          const SizedBox(width: 8),
          // API 返回的分类标签
          ..._categories.map((category) {
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _buildCategoryChip(
                label: category,
                isSelected: _selectedCategory == category,
                themeService: themeService,
              ),
            );
          }),
        ],
      ),
    );
  }

  /// 构建单个分类标签
  Widget _buildCategoryChip({
    required String label,
    required bool isSelected,
    required ThemeService themeService,
  }) {
    return GestureDetector(
      onTap: () => _onCategoryChanged(label),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF27ae60)
              : (themeService.isDarkMode
                  ? Colors.white.withOpacity(0.1)
                  : Colors.grey[200]),
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

    // 根据屏幕宽度计算每行卡片数量和卡片宽度
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
      crossAxisCount = 2;
      horizontalPadding = 16;
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
          childAspectRatio: cardWidth / (cardWidth * 1.4 + 0),
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

/// 短剧播放器页面（占位）
class _ShortDramaPlayerScreen extends StatefulWidget {
  final ShortDrama drama;

  const _ShortDramaPlayerScreen({required this.drama});

  @override
  State<_ShortDramaPlayerScreen> createState() =>
      _ShortDramaPlayerScreenState();
}

class _ShortDramaPlayerScreenState extends State<_ShortDramaPlayerScreen> {
  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return Scaffold(
          backgroundColor: themeService.isDarkMode
              ? const Color(0xFF1e1e1e)
              : Colors.white,
          appBar: AppBar(
            backgroundColor: themeService.isDarkMode
                ? const Color(0xFF1e1e1e)
                : Colors.white,
            foregroundColor: themeService.isDarkMode
                ? const Color(0xFFffffff)
                : const Color(0xFF2c3e50),
            elevation: 0,
            title: Text(
              widget.drama.title,
              style: FontUtils.poppins(context,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 播放器占位区域
                Container(
                  width: double.infinity,
                  height: 200,
                  decoration: BoxDecoration(
                    color: themeService.isDarkMode
                        ? const Color(0xFF333333)
                        : Colors.grey[200],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.play_circle_outline,
                      size: 64,
                      color: Color(0xFF27ae60),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // 短剧信息
                Text(
                  widget.drama.title,
                  style: FontUtils.poppins(context,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: themeService.isDarkMode
                        ? const Color(0xFFffffff)
                        : const Color(0xFF2c3e50),
                  ),
                ),
                const SizedBox(height: 8),
                // 集数标签
                if (widget.drama.episodeCount > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF27ae60).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '共${widget.drama.episodeCount}集',
                      style: FontUtils.poppins(context,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF27ae60),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                // 简介
                if (widget.drama.description.isNotEmpty) ...[
                  Text(
                    '简介',
                    style: FontUtils.poppins(context,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: themeService.isDarkMode
                          ? const Color(0xFFffffff)
                          : const Color(0xFF2c3e50),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.drama.description,
                    style: FontUtils.poppins(context,
                      fontSize: 14,
                      color: themeService.isDarkMode
                          ? const Color(0xFFb0b0b0)
                          : const Color(0xFF7f8c8d),
                      height: 1.5,
                    ),
                  ),
                ],
                // 剧集列表
                if (widget.drama.episodes.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    '选集',
                    style: FontUtils.poppins(context,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: themeService.isDarkMode
                          ? const Color(0xFFffffff)
                          : const Color(0xFF2c3e50),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: widget.drama.episodes.asMap().entries.map((entry) {
                      final index = entry.key;
                      final episode = entry.value;
                      return GestureDetector(
                        onTap: () {
                          // TODO: 播放指定集数
                        },
                        child: Container(
                          width: 48,
                          height: 36,
                          decoration: BoxDecoration(
                            color: themeService.isDarkMode
                                ? Colors.white.withOpacity(0.1)
                                : Colors.grey[200],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${index + 1}',
                            style: FontUtils.poppins(context,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: themeService.isDarkMode
                                  ? const Color(0xFFffffff)
                                  : const Color(0xFF2c3e50),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
