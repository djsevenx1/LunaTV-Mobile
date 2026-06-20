import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
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

  /// 点击短剧卡片
  void _onDramaTap(ShortDrama drama) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ShortDramaPlayerScreen(drama: drama),
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

/// 短剧播放器页面
class ShortDramaPlayerScreen extends StatefulWidget {
  final ShortDrama drama;

  const ShortDramaPlayerScreen({super.key, required this.drama});

  @override
  State<ShortDramaPlayerScreen> createState() => _ShortDramaPlayerScreenState();
}

class _ShortDramaPlayerScreenState extends State<ShortDramaPlayerScreen> {
  late final Player _player;
  late final VideoController _controller;

  // 阶段: detail (先看海报选集) / playing (全屏播放)
  String _phase = 'detail';

  // 详情
  bool _isLoadingDetail = true;
  ShortDramaDetail? _detail;
  String? _detailError;

  // 当前播放
  bool _isLoading = false;
  bool _isError = false;
  String _errorMessage = '';
  int _currentEpisode = 1;
  int _totalEpisodes = 1;
  String _videoUrl = '';
  String _videoName = '';

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _videoName = widget.drama.name;
    _loadDetail();
  }

  /// 加载详情 (只拉集数列表, 不解析播放地址)
  Future<void> _loadDetail() async {
    if (!mounted) return;
    setState(() {
      _isLoadingDetail = true;
      _detailError = null;
    });
    try {
      final detail =
          await ShortDramaService.getDetail(widget.drama.id.toString());
      if (!mounted) return;
      setState(() {
        _detail = detail;
        if (detail != null && detail.episodes.isNotEmpty) {
          _totalEpisodes = detail.episodes.length;
        } else if (widget.drama.episodeCount > 0) {
          _totalEpisodes = widget.drama.episodeCount;
        }
        _isLoadingDetail = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingDetail = false;
        _detailError = '加载详情失败: $e';
        if (widget.drama.episodeCount > 0) {
          _totalEpisodes = widget.drama.episodeCount;
        }
      });
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  /// 解析并播放指定集数
  Future<void> _playEpisode(int episode) async {
    if (!mounted) return;

    setState(() {
      _phase = 'playing';
      _isLoading = true;
      _isError = false;
      _errorMessage = '';
      _currentEpisode = episode;
    });

    try {
      final result = await ShortDramaService.parseEpisode(
        id: widget.drama.id,
        episode: episode - 1, // API 的 episode 从 0 开始
        name: widget.drama.name,
      );

      if (!mounted) return;

      if (result.code == 0 && result.data != null) {
        final data = result.data!;
        _videoUrl = data.proxyUrl.isNotEmpty ? data.proxyUrl : data.parsedUrl;
        // 如果详情加载成功则使用详细集数,否则用 parse 返回的
        if (_totalEpisodes <= 1 && data.totalEpisodes > 0) {
          _totalEpisodes = data.totalEpisodes;
        }
        _videoName =
            data.videoName.isNotEmpty ? data.videoName : widget.drama.name;

        if (_videoUrl.isNotEmpty) {
          await _player.open(Media(_videoUrl));
          if (!mounted) return;
          setState(() {
            _isLoading = false;
          });
        } else {
          setState(() {
            _isLoading = false;
            _isError = true;
            _errorMessage = '未获取到播放地址 (code=${result.code} msg=${result.msg})';
          });
        }
      } else {
        setState(() {
          _isLoading = false;
          _isError = true;
          _errorMessage = 'code=${result.code} ${result.msg.isNotEmpty ? result.msg : '解析失败'}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isError = true;
        _errorMessage = '播放错误: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        final isDark = themeService.isDarkMode;
        return PopScope(
          canPop: _phase == 'detail',
          onPopInvoked: (didPop) {
            if (didPop) return;
            if (_phase == 'playing') {
              // 从播放态退回 detail,清空视频
              setState(() {
                _phase = 'detail';
                _videoUrl = '';
              });
              try {
                _player.stop();
              } catch (_) {}
            }
          },
          child: Scaffold(
            backgroundColor: isDark
                ? const Color(0xFF121212)
                : const Color(0xFFF5F5F7),
            body: _phase == 'detail'
                ? _buildDetailView(themeService)
                : _buildPlayingView(themeService),
          ),
        );
      },
    );
  }

  /// 详情视图: 海报 + 标题 + 简介 + 集数网格 + 播放按钮
  Widget _buildDetailView(ThemeService themeService) {
    final isDark = themeService.isDarkMode;
    const greenColor = Color(0xFF22C55E);
    const greenColorLight = Color(0xFF10B981);
    final cover = widget.drama.backdrop.isNotEmpty
        ? widget.drama.backdrop
        : widget.drama.cover;
    final canPlay = _totalEpisodes > 0;

    return Stack(
      children: [
        // 主滚动内容
        Positioned.fill(
          child: CustomScrollView(
            slivers: [
              // 顶部条
              SliverAppBar(
                pinned: true,
                backgroundColor: isDark
                    ? const Color(0xFF1a1a1a)
                    : Colors.white,
                foregroundColor: isDark ? Colors.white : Colors.black87,
                elevation: 0,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                title: Text(
                  widget.drama.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),

              // 海报 + 简介头部
              SliverToBoxAdapter(
                child: _buildPosterHeader(cover, isDark),
              ),

              // 集数
              SliverToBoxAdapter(
                child: _buildEpisodeSection(themeService),
              ),

              // 简介
              if (widget.drama.description.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '简介',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF2c3e50),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.drama.description,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: isDark
                                ? const Color(0xFFb0b0b0)
                                : const Color(0xFF7f8c8d),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ),
        ),

        // 底部固定播放按钮
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              12 + MediaQuery.of(context).padding.bottom,
            ),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF1a1a1a)
                  : Colors.white,
              border: Border(
                top: BorderSide(
                  color: isDark
                      ? Colors.white.withOpacity(0.08)
                      : Colors.grey.withOpacity(0.2),
                ),
              ),
            ),
            child: GestureDetector(
              onTap: canPlay ? () => _playEpisode(1) : null,
              child: Container(
                height: 48,
                decoration: BoxDecoration(
                  gradient: canPlay
                      ? const LinearGradient(
                          colors: [greenColor, greenColorLight],
                        )
                      : null,
                  color: canPlay
                      ? null
                      : (isDark
                          ? Colors.white.withOpacity(0.08)
                          : Colors.grey[300]),
                  borderRadius: BorderRadius.circular(24),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.play_arrow,
                        color: Colors.white, size: 22),
                    const SizedBox(width: 6),
                    Text(
                      canPlay ? '播放 第1集' : '暂无可播放集数',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 海报 + 元信息 header
  Widget _buildPosterHeader(String cover, bool isDark) {
    return Stack(
      children: [
        // 背景封面 (模糊,半透明)
        if (cover.isNotEmpty)
          Positioned.fill(
            child: Image.network(
              cover,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: isDark ? const Color(0xFF1e1e1e) : Colors.grey[200],
              ),
            ),
          ),
        if (cover.isNotEmpty)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.55),
                    isDark ? const Color(0xFF121212) : const Color(0xFFF5F5F7),
                  ],
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左侧海报
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 110,
                  height: 160,
                  child: cover.isNotEmpty
                      ? Image.network(
                          cover,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: isDark
                                ? const Color(0xFF1e1e1e)
                                : Colors.grey[200],
                            child: const Icon(Icons.movie, color: Colors.white54),
                          ),
                        )
                      : Container(
                          color: isDark
                              ? const Color(0xFF1e1e1e)
                              : Colors.grey[200],
                          child: const Icon(Icons.movie, color: Colors.white54),
                        ),
                ),
              ),
              const SizedBox(width: 14),
              // 右侧元信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 80),
                    Text(
                      widget.drama.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : const Color(0xFF2c3e50),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (widget.drama.score > 0)
                      Row(
                        children: [
                          const Icon(Icons.star_rounded,
                              color: Color(0xFFFBBF24), size: 18),
                          const SizedBox(width: 4),
                          Text(
                            widget.drama.score.toStringAsFixed(1),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF2c3e50),
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 6),
                    if (widget.drama.author.isNotEmpty)
                      Text(
                        '导演: ${widget.drama.author}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? const Color(0xFFb0b0b0)
                              : const Color(0xFF7f8c8d),
                        ),
                      ),
                    if (widget.drama.updateTime.isNotEmpty)
                      Text(
                        '更新: ${widget.drama.updateTime}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? const Color(0xFFb0b0b0)
                              : const Color(0xFF7f8c8d),
                        ),
                      ),
                    Text(
                      _totalEpisodes > 1 ? '共 $_totalEpisodes 集' : '',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? const Color(0xFFb0b0b0)
                            : const Color(0xFF7f8c8d),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 集数网格
  Widget _buildEpisodeSection(ThemeService themeService) {
    final isDark = themeService.isDarkMode;
    const greenColor = Color(0xFF22C55E);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '选集',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : const Color(0xFF2c3e50),
                ),
              ),
              const Spacer(),
              if (_isLoadingDetail)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: greenColor,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_detailError != null)
            Text(
              _detailError!,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            )
          else if (_totalEpisodes >= 1)
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.6,
              ),
              itemCount: _totalEpisodes,
              itemBuilder: (context, index) {
                final episodeNum = index + 1;
                return GestureDetector(
                  onTap: () => _playEpisode(episodeNum),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF1e1e1e)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withOpacity(0.18)
                            : Colors.grey.shade300!,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$episodeNum',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : const Color(0xFF2c3e50),
                      ),
                    ),
                  ),
                );
              },
            )
          else
            Text(
              _isLoadingDetail ? '正在加载集数...' : '暂无可用集数',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
        ],
      ),
    );
  }

  /// 播放视图
  Widget _buildPlayingView(ThemeService themeService) {
    final isDark = themeService.isDarkMode;
    const greenColor = Color(0xFF22C55E);
    const greenColorLight = Color(0xFF10B981);

    return Column(
      children: [
        // 顶部条 (从播放退回到 detail)
        Container(
          color: isDark ? const Color(0xFF1a1a1a) : Colors.white,
          padding: EdgeInsets.fromLTRB(
            8,
            MediaQuery.of(context).padding.top + 4,
            8,
            4,
          ),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  Icons.arrow_back_ios_new,
                  size: 20,
                  color: isDark ? Colors.white : Colors.black87,
                ),
                onPressed: () {
                  setState(() => _phase = 'detail');
                  try {
                    _player.stop();
                  } catch (_) {}
                },
              ),
              Expanded(
                child: Text(
                  _videoName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : const Color(0xFF2c3e50),
                  ),
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
        ),

        // 播放器
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Video(controller: _controller),
              if (_isLoading)
                const CircularProgressIndicator(color: greenColor),
              if (_isError)
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline,
                        color: Colors.redAccent, size: 48),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        _errorMessage,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => _playEpisode(_currentEpisode),
                      child: const Text('重试',
                          style: TextStyle(color: greenColor)),
                    ),
                  ],
                ),
            ],
          ),
        ),

        // 集数选择条
        Expanded(
          child: Container(
            color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: greenColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '第$_currentEpisode集 / 共$_totalEpisodes集',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: greenColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '选集',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.white : const Color(0xFF2c3e50),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_totalEpisodes >= 1)
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 5,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 1.6,
                      ),
                      itemCount: _totalEpisodes,
                      itemBuilder: (context, index) {
                        final episodeNum = index + 1;
                        final isCurrent = episodeNum == _currentEpisode;
                        return GestureDetector(
                          onTap: () => _playEpisode(episodeNum),
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: isCurrent
                                  ? const LinearGradient(
                                      colors: [greenColor, greenColorLight],
                                    )
                                  : null,
                              color: !isCurrent
                                  ? (isDark
                                      ? Colors.white.withOpacity(0.08)
                                      : Colors.grey[100])
                                  : null,
                              borderRadius: BorderRadius.circular(8),
                              border: !isCurrent
                                  ? Border.all(
                                      color: isDark
                                          ? Colors.white.withOpacity(0.1)
                                          : Colors.grey.shade300!,
                                    )
                                  : null,
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '$episodeNum',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: isCurrent
                                    ? Colors.white
                                    : (isDark
                                        ? Colors.white
                                        : const Color(0xFF2c3e50)),
                              ),
                            ),
                          ),
                        );
                      },
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '暂无可用集数',
                        style: TextStyle(
                          color: isDark ? Colors.white60 : Colors.black54,
                          fontSize: 13,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
