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
/// 从列表点卡片 → 直接进入播放第 1 集,集数条放在播放区下方
class ShortDramaPlayerScreen extends StatefulWidget {
  final ShortDrama drama;

  const ShortDramaPlayerScreen({super.key, required this.drama});

  @override
  State<ShortDramaPlayerScreen> createState() => _ShortDramaPlayerScreenState();
}

class _ShortDramaPlayerScreenState extends State<ShortDramaPlayerScreen> {
  late final Player _player;
  late final VideoController _controller;

  // 详情
  bool _isLoadingDetail = true;
  ShortDramaDetail? _detail;
  String? _detailError;

  // 当前播放
  bool _isLoading = true;
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
    // 先用列表里的 episodeCount 兜底,避免显示 1
    if (widget.drama.episodeCount > 0) {
      _totalEpisodes = widget.drama.episodeCount;
    }
    // 加载详情(拿准确集数),同时直接开始播放第 1 集
    _loadDetail();
    _playEpisode(1);
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
      // 优先从 detail 拿集数, 没有则用列表里 drama 的 episodeCount
      final detailTotal =
          (detail != null) ? detail.totalEpisodes : 0;
      if (detailTotal > 0) {
        _totalEpisodes = detailTotal;
      } else if (widget.drama.episodeCount > 0) {
        _totalEpisodes = widget.drama.episodeCount;
      }
      setState(() {
        _detail = detail;
        _isLoadingDetail = false;
        if (detail == null) {
          _detailError = '详情接口返回为空, 已用列表中的集数 (${_totalEpisodes})';
        } else if (detailTotal == 0 && widget.drama.episodeCount > 0) {
          _detailError =
              '详情接口未带集数字段, 已用列表中的集数 (${_totalEpisodes})';
        }
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
        return Scaffold(
          backgroundColor: isDark
              ? const Color(0xFF121212)
              : const Color(0xFFF5F5F7),
          body: _buildBody(themeService),
        );
      },
    );
  }

  /// 整体页面: 顶部条 + 播放器 + 滚动区(简介+集数)
  Widget _buildBody(ThemeService themeService) {
    final isDark = themeService.isDarkMode;
    const greenColor = Color(0xFF22C55E);
    const greenColorLight = Color(0xFF10B981);

    return Column(
      children: [
        // 顶部条
        Container(
          color: isDark ? const Color(0xFF1a1a1a) : Colors.white,
          padding: EdgeInsets.fromLTRB(
            8,
            MediaQuery.of(context).padding.top + 4,
            8,
            8,
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
                  try {
                    _player.stop();
                  } catch (_) {}
                  Navigator.of(context).pop();
                },
              ),
              Expanded(
                child: Text(
                  widget.drama.name,
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
          child: Container(
            color: Colors.black,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (_videoUrl.isNotEmpty) Video(controller: _controller),
                if (_isLoading)
                  const CircularProgressIndicator(color: greenColor),
                if (_isError)
                  Container(
                    color: Colors.black87,
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline,
                            color: Colors.redAccent, size: 48),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            _errorMessage,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () => _playEpisode(_currentEpisode),
                          child: const Text('重试',
                              style: TextStyle(color: greenColor)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),

        // 滚动区: 简介 + 集数
        Expanded(
          child: Container(
            color: isDark ? const Color(0xFF1a1a1a) : Colors.white,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 当前集数 / 总集数 badge
                  Row(
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
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: greenColor,
                          ),
                        ),
                      ),
                      if (_isLoadingDetail) ...[
                        const SizedBox(width: 8),
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: greenColor,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (_detailError != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      _detailError!,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white60 : Colors.black54,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),

                  // 简介
                  if (widget.drama.description.isNotEmpty) ...[
                    Text(
                      '简介',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : const Color(0xFF2c3e50),
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
                    const SizedBox(height: 16),
                  ],

                  // 选集 (>= 2 集才显示)
                  if (_totalEpisodes >= 2) ...[
                    Text(
                      '选集',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : const Color(0xFF2c3e50),
                      ),
                    ),
                    const SizedBox(height: 8),
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
                    ),
                  ] else if (_isLoadingDetail) ...[
                    Text(
                      '正在加载集数...',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? Colors.white60 : Colors.black54,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
