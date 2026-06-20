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

/// 短剧详情 + 播放页
/// 仿照 PlayerScreen 风格: 两阶段
///   1. detail  - 顶部条 + 海报/元信息 + 选集网格 + 底部固定播放按钮
///   2. playing - 全屏播放 + 返回可回 detail
class ShortDramaPlayerScreen extends StatefulWidget {
  final ShortDrama drama;

  const ShortDramaPlayerScreen({super.key, required this.drama});

  @override
  State<ShortDramaPlayerScreen> createState() => _ShortDramaPlayerScreenState();
}

class _ShortDramaPlayerScreenState extends State<ShortDramaPlayerScreen> {
  late final Player _player;
  late final VideoController _controller;

  // 阶段: detail (先看详情) / playing (全屏播放)
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

  // 源/线路
  // 短剧后端只提供 1 个源 (短剧数据源), 但每集返回两个 url: proxy / direct
  String _directUrl = '';   // 原始 m3u8
  String _proxyUrl = '';    // 后端代理过的 m3u8 (解决跨域)
  bool _useProxy = true;    // 默认走代理
  bool _hasSource = true;   // 短剧只有一个源 (固定 true)

  // 调试面板
  bool _showDebug = false;
  String _debugInfo = '';

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _videoName = widget.drama.name;
    // 先用列表里的 episodeCount 兜底
    if (widget.drama.episodeCount > 0) {
      _totalEpisodes = widget.drama.episodeCount;
    }
    // 加载详情拿准确集数
    _loadDetail();
    // 主动用 parseEpisode 探测集数 (后端 detail 接口没实现时兜底)
    _probeEpisodes();
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
      final detailTotal =
          (detail != null) ? detail.totalEpisodes : 0;
      if (detailTotal > 0) {
        _totalEpisodes = detailTotal;
      } else if (widget.drama.episodeCount > 0) {
        _totalEpisodes = widget.drama.episodeCount;
      }
      // 拼装调试信息 (用户可见)
      final dbg = StringBuffer();
      dbg.writeln('list.episodeCount=${widget.drama.episodeCount}');
      dbg.writeln('detail.title=${detail?.title ?? "<空>"}');
      dbg.writeln('detail.poster=${detail?.poster ?? "<空>"}');
      dbg.writeln('detail.episodes=${detail?.episodes.length ?? 0}');
      dbg.writeln('detail.episodesTitles=${detail?.episodesTitles.length ?? 0}');
      dbg.writeln('detail.episodeCount=${detail?.episodeCount ?? 0}');
      dbg.writeln('final._totalEpisodes=$_totalEpisodes');
      setState(() {
        _detail = detail;
        _isLoadingDetail = false;
        _debugInfo = dbg.toString();
        if (detail == null) {
          _detailError = '正在加载剧集信息…';
        } else if (detailTotal == 0 && widget.drama.episodeCount > 0) {
          _detailError = '正在加载剧集信息…';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingDetail = false;
        _detailError = '正在加载剧集信息…';
        _debugInfo = 'detail 异常: $e';
        if (widget.drama.episodeCount > 0) {
          _totalEpisodes = widget.drama.episodeCount;
        }
      });
    }
  }

  @override
  void dispose() {
    try {
      _player.stop();
    } catch (_) {}
    _player.dispose();
    super.dispose();
  }

  /// 用 parseEpisode 探测第 0 集, 拿 totalEpisodes 字段作为集数兜底
  /// 后端的 detail 接口没返回任何集数字段时, parseEpisode 返回的 totalEpisodes 才是真值
  Future<void> _probeEpisodes() async {
    try {
      // 等详情接口先跑一会儿, 避免两个请求竞争
      await Future.delayed(const Duration(milliseconds: 200));
      final result = await ShortDramaService.parseEpisode(
        id: widget.drama.id,
        episode: 0,
        name: widget.drama.name,
      );
      if (!mounted) return;
      if (result.code == 0 &&
          result.data != null &&
          result.data!.totalEpisodes > 0) {
        // 强制用 parse 探测结果覆盖
        setState(() {
          _totalEpisodes = result.data!.totalEpisodes;
          _debugInfo = '${_debugInfo}\nprobe._totalEpisodes=${_totalEpisodes}';
        });
      } else {
        // 把 probe 的错误也写进调试
        setState(() {
          _debugInfo =
              '${_debugInfo}\nprobe.code=${result.code} msg=${result.msg}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _debugInfo = '${_debugInfo}\nprobe.error=$e';
      });
    }
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
        _directUrl = data.parsedUrl;
        _proxyUrl = data.proxyUrl;
        _videoUrl = _pickUrl();
        if (data.totalEpisodes > 0) {
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
            _errorMessage = '未获取到播放地址,请稍后重试';
          });
        }
      } else {
        setState(() {
          _isLoading = false;
          _isError = true;
          _errorMessage = result.msg.isNotEmpty
              ? '播放失败: ${result.msg}'
              : '播放失败,请稍后重试';
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

  /// 根据 _useProxy 选 url (proxy 优先, 没有则用 direct)
  String _pickUrl() {
    if (_useProxy && _proxyUrl.isNotEmpty) return _proxyUrl;
    if (_directUrl.isNotEmpty) return _directUrl;
    return _proxyUrl; // 兜底
  }

  /// 切换解析线路 (proxy / direct), 不重新 parse, 只换 url
  Future<void> _switchLine(bool useProxy) async {
    if (_useProxy == useProxy) return;
    setState(() {
      _useProxy = useProxy;
      _videoUrl = _pickUrl();
    });
    if (_videoUrl.isNotEmpty) {
      await _player.open(Media(_videoUrl));
    }
  }

  /// 退到详情 (不清空 player, 节省下次进入时间)
  void _backToDetail() {
    try {
      _player.stop();
    } catch (_) {}
    setState(() {
      _phase = 'detail';
      _videoUrl = '';
      _isError = false;
      _errorMessage = '';
    });
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
              _backToDetail();
            }
          },
          child: Scaffold(
            backgroundColor: isDark
                ? const Color(0xFF121212)
                : const Color(0xFFF5F5F7),
            body: SafeArea(
              child: _phase == 'detail'
                  ? _buildDetailView(isDark)
                  : _buildPlayingView(isDark),
            ),
          ),
        );
      },
    );
  }

  // ===================== 详情阶段 =====================

  Widget _buildDetailView(bool isDark) {
    return Column(
      children: [
        // 顶部 bar
        _buildDetailTopBar(isDark),
        // 滚动内容
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 海报 + 元信息
                _buildPosterHeader(isDark),
                // 源/线路
                _buildSourceSection(isDark),
                // 选集网格
                _buildEpisodeSection(isDark),
                // 简介
                if (widget.drama.description.isNotEmpty)
                  _buildDescription(isDark),
                // 调试面板 (折叠)
                _buildDebugPanel(isDark),
                const SizedBox(height: 100),
              ],
            ),
          ),
        ),
        // 底部固定播放按钮
        _buildBottomPlayButton(isDark),
      ],
    );
  }

  Widget _buildDetailTopBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back,
                color: isDark ? Colors.white : Colors.black),
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Text(
              widget.drama.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : const Color(0xFF2c3e50),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPosterHeader(bool isDark) {
    final cover = widget.drama.backdrop.isNotEmpty
        ? widget.drama.backdrop
        : widget.drama.cover;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
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
                        child: const Icon(Icons.movie,
                            color: Colors.white54),
                      ),
                    )
                  : Container(
                      color: isDark
                          ? const Color(0xFF1e1e1e)
                          : Colors.grey[200],
                      child: const Icon(Icons.movie,
                          color: Colors.white54),
                    ),
            ),
          ),
          const SizedBox(width: 14),
          // 右侧元信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                const SizedBox(height: 6),
                if (_totalEpisodes > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF22C55E).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '共 $_totalEpisodes 集',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF22C55E),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 源/线路模块
  /// 短剧后端只有 1 个源(短剧数据源), 这里显示源名称 + 解析线路切换
  Widget _buildSourceSection(bool isDark) {
    const greenColor = Color(0xFF22C55E);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '源',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : const Color(0xFF2c3e50),
            ),
          ),
          const SizedBox(height: 8),
          // 源 (固定 1 个 - 短剧)
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF1e1e1e)
                  : Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: greenColor.withOpacity(0.5),
                width: 1.2,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: greenColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '短剧',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? Colors.white
                          : const Color(0xFF2c3e50),
                    ),
                  ),
                ),
                Text(
                  '默认',
                  style: TextStyle(
                    fontSize: 11,
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
    );
  }

  Widget _buildEpisodeSection(bool isDark) {
    const greenColor = Color(0xFF22C55E);
    const greenColorLight = Color(0xFF10B981);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
          if (_totalEpisodes >= 2)
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
                        color: isDark
                            ? Colors.white
                            : const Color(0xFF2c3e50),
                      ),
                    ),
                  ),
                );
              },
            )
          else if (_isLoadingDetail)
            Text(
              '正在加载集数...',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            )
          else
            Text(
              '点击播放试播,集数将在解析后显示',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDescription(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
        ],
      ),
    );
  }

  Widget _buildDebugPanel(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1a1a1a) : const Color(0xFFf3f4f6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            InkWell(
              onTap: () => setState(() => _showDebug = !_showDebug),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      Icons.bug_report,
                      size: 16,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '调试信息 (点开)',
                      style: TextStyle(
                        fontSize: 12,
                        color:
                            isDark ? Colors.white60 : Colors.black54,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      _showDebug
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 18,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ],
                ),
              ),
            ),
            if (_showDebug)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: SelectableText(
                  _debugInfo.isEmpty
                      ? '(暂无, 请等待详情接口加载完成)'
                      : _debugInfo,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    height: 1.4,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomPlayButton(bool isDark) {
    const greenColor = Color(0xFF22C55E);
    const greenColorLight = Color(0xFF10B981);
    // 即便 _totalEpisodes=0 (后端 detail 接口没返回), 仍允许点播放试播, parseEpisode 会回填
    final canPlay = true;
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        12 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1a1a1a) : Colors.white,
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
    );
  }

  // ===================== 播放阶段 =====================

  Widget _buildPlayingView(bool isDark) {
    const greenColor = Color(0xFF22C55E);
    const greenColorLight = Color(0xFF10B981);
    return Column(
      children: [
        // 顶部条 (返回 detail)
        Container(
          color: isDark ? const Color(0xFF1a1a1a) : Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  Icons.arrow_back_ios_new,
                  size: 20,
                  color: isDark ? Colors.white : Colors.black87,
                ),
                onPressed: _backToDetail,
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
                          onPressed: () =>
                              _playEpisode(_currentEpisode),
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
        // 集数 + 简介 滚动区
        Expanded(
          child: Container(
            color: isDark ? const Color(0xFF1a1a1a) : Colors.white,
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
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: greenColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (widget.drama.description.isNotEmpty) ...[
                    Text(
                      '简介',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
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
                    const SizedBox(height: 16),
                  ],
                  if (_totalEpisodes >= 2) ...[
                    Text(
                      '选集',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? Colors.white
                            : const Color(0xFF2c3e50),
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
                        final isCurrent =
                            episodeNum == _currentEpisode;
                        return GestureDetector(
                          onTap: () => _playEpisode(episodeNum),
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: isCurrent
                                  ? const LinearGradient(
                                      colors: [
                                        greenColor,
                                        greenColorLight
                                      ],
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
