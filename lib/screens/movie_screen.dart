import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import '../widgets/capsule_tab_switcher.dart';
import '../widgets/custom_refresh_indicator.dart';
import '../widgets/douban_movies_grid.dart';
import '../services/douban_service.dart';
import '../models/douban_movie.dart';
import '../models/video_info.dart';
import '../widgets/video_menu_bottom_sheet.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/pulsing_dots_indicator.dart';
import 'player_screen.dart';
import '../widgets/filter_pill_hover.dart';
import '../utils/device_utils.dart';
import '../utils/font_utils.dart';
import '../widgets/filter_options_selector.dart';

class MovieScreen extends StatefulWidget {
  const MovieScreen({super.key});

  @override
  State<MovieScreen> createState() => _MovieScreenState();
}

class _MovieScreenState extends State<MovieScreen> {
  // 电影的一级选择器选项
  final List<SelectorOption> _moviePrimaryOptions = const [
    SelectorOption(label: '全部', value: '全部'),
    SelectorOption(label: '热门电影', value: '热门'),
    SelectorOption(label: '最新电影', value: '最新'),
    SelectorOption(label: '豆瓣高分', value: '豆瓣高分'),
    SelectorOption(label: '冷门佳片', value: '冷门佳片'),
  ];

  // 电影的二级选择器选项 (旧版)
  final List<SelectorOption> _movieSecondaryOptions = const [
    SelectorOption(label: '全部', value: '全部'),
    SelectorOption(label: '华语', value: '华语'),
    SelectorOption(label: '欧美', value: '欧美'),
    SelectorOption(label: '韩国', value: '韩国'),
    SelectorOption(label: '日本', value: '日本'),
  ];

  // 新的筛选选项
  final List<SelectorOption> _movieTypeOptions = const [
    SelectorOption(label: '全部', value: 'all'),
    SelectorOption(label: '喜剧', value: 'comedy'),
    SelectorOption(label: '爱情', value: 'romance'),
    SelectorOption(label: '动作', value: 'action'),
    SelectorOption(label: '科幻', value: 'sci-fi'),
    SelectorOption(label: '悬疑', value: 'suspense'),
    SelectorOption(label: '犯罪', value: 'crime'),
    SelectorOption(label: '惊悚', value: 'thriller'),
    SelectorOption(label: '冒险', value: 'adventure'),
    SelectorOption(label: '音乐', value: 'music'),
    SelectorOption(label: '历史', value: 'history'),
    SelectorOption(label: '奇幻', value: 'fantasy'),
    SelectorOption(label: '恐怖', value: 'horror'),
    SelectorOption(label: '战争', value: 'war'),
    SelectorOption(label: '传记', value: 'biography'),
    SelectorOption(label: '歌舞', value: 'musical'),
    SelectorOption(label: '武侠', value: 'wuxia'),
    SelectorOption(label: '情色', value: 'erotic'),
    SelectorOption(label: '灾难', value: 'disaster'),
    SelectorOption(label: '西部', value: 'western'),
    SelectorOption(label: '纪录片', value: 'documentary'),
    SelectorOption(label: '短片', value: 'short'),
  ];

  final List<SelectorOption> _movieRegionOptions = const [
    SelectorOption(label: '全部', value: 'all'),
    SelectorOption(label: '华语', value: 'chinese'),
    SelectorOption(label: '欧美', value: 'western'),
    SelectorOption(label: '韩国', value: 'korean'),
    SelectorOption(label: '日本', value: 'japanese'),
    SelectorOption(label: '中国大陆', value: 'mainland_china'),
    SelectorOption(label: '美国', value: 'usa'),
    SelectorOption(label: '中国香港', value: 'hong_kong'),
    SelectorOption(label: '中国台湾', value: 'taiwan'),
    SelectorOption(label: '英国', value: 'uk'),
    SelectorOption(label: '法国', value: 'france'),
    SelectorOption(label: '德国', value: 'germany'),
    SelectorOption(label: '意大利', value: 'italy'),
    SelectorOption(label: '西班牙', value: 'spain'),
    SelectorOption(label: '印度', value: 'india'),
    SelectorOption(label: '泰国', value: 'thailand'),
    SelectorOption(label: '俄罗斯', value: 'russia'),
    SelectorOption(label: '加拿大', value: 'canada'),
    SelectorOption(label: '澳大利亚', value: 'australia'),
    SelectorOption(label: '爱尔兰', value: 'ireland'),
    SelectorOption(label: '瑞典', value: 'sweden'),
    SelectorOption(label: '巴西', value: 'brazil'),
    SelectorOption(label: '丹麦', value: 'denmark'),
  ];

  final List<SelectorOption> _movieYearOptions = const [
    SelectorOption(label: '全部', value: 'all'),
    SelectorOption(label: '2020年代', value: '2020s'),
    SelectorOption(label: '2025', value: '2025'),
    SelectorOption(label: '2024', value: '2024'),
    SelectorOption(label: '2023', value: '2023'),
    SelectorOption(label: '2022', value: '2022'),
    SelectorOption(label: '2021', value: '2021'),
    SelectorOption(label: '2020', value: '2020'),
    SelectorOption(label: '2019', value: '2019'),
    SelectorOption(label: '2010年代', value: '2010s'),
    SelectorOption(label: '2000年代', value: '2000s'),
    SelectorOption(label: '90年代', value: '1990s'),
    SelectorOption(label: '80年代', value: '1980s'),
    SelectorOption(label: '70年代', value: '1970s'),
    SelectorOption(label: '60年代', value: '1960s'),
    SelectorOption(label: '更早', value: 'earlier'),
  ];

  final List<SelectorOption> _movieSortOptions = const [
    SelectorOption(label: '综合排序', value: 'T'),
    SelectorOption(label: '近期热度', value: 'U'),
    SelectorOption(label: '首映时间', value: 'R'),
    SelectorOption(label: '高分优先', value: 'S'),
  ];

  String _selectedCategoryValue = '热门';
  String _selectedRegionValue = '全部'; // 旧版地区筛选

  // 新版筛选状态
  String _selectedMovieType = 'all';
  String _selectedMovieRegion = 'all';
  String _selectedMovieYear = 'all';
  String _selectedMovieSort = 'T';

  final ScrollController _scrollController = ScrollController();
  final List<DoubanMovie> _movies = [];
  int _page = 0;
  final int _pageLimit = 25;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String? _errorMessage;

  /// 获取当前筛选状态
  String _getCurrentFilterState() {
    return '$_selectedCategoryValue|$_selectedRegionValue|$_selectedMovieType|$_selectedMovieRegion|$_selectedMovieYear|$_selectedMovieSort';
  }

  @override
  void initState() {
    super.initState();
    _fetchMovies(isRefresh: true);
    _scrollController.addListener(() {
      _handleScroll();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 处理滚动事件，支持内容不足一屏时的加载更多
  void _handleScroll() {
    if (_scrollController.hasClients) {
      final position = _scrollController.position;

      // 如果内容不足以滚动（maxScrollExtent <= 0），直接尝试加载更多
      if (position.maxScrollExtent <= 0) {
        // 检查是否有更多数据且当前不在加载中
        if (_hasMore && !_isLoading && !_isLoadingMore && _movies.isNotEmpty) {
          _loadMoreMovies();
        }
        return;
      }

      // 正常滚动情况：当滚动到距离底部50像素内时触发加载
      const double threshold = 50.0;
      if (position.pixels >= position.maxScrollExtent - threshold) {
        _loadMoreMovies();
      }
    }
  }

  /// 检查内容是否不足一屏，如果是则自动加载更多
  void _checkAndLoadMoreIfNeeded() {
    if (!mounted ||
        !_scrollController.hasClients ||
        !_hasMore ||
        _isLoading ||
        _isLoadingMore) {
      return;
    }

    final position = _scrollController.position;

    // 如果内容不足以滚动，说明没有填满屏幕，自动加载更多
    if (position.maxScrollExtent <= 0 && _movies.isNotEmpty) {
      _loadMoreMovies();
    }
  }

  Future<void> _fetchMovies({bool isRefresh = false}) async {
    // 记录发起请求时的筛选状态
    final requestFilterState = _getCurrentFilterState();

    setState(() {
      _isLoading = true;
      if (isRefresh) {
        _movies.clear();
        _page = 0;
        _hasMore = true;
      }
      _errorMessage = null;
    });

    if (_selectedCategoryValue == '全部') {
      // 将界面选项转换为豆瓣API参数
      String categoryValue = _selectedMovieType;
      String regionValue = _selectedMovieRegion;
      String yearValue = _selectedMovieYear;

      // 转换地区参数为中文标签
      if (regionValue != 'all') {
        regionValue =
            _movieRegionOptions.firstWhere((e) => e.value == regionValue).label;
      }

      // 转换年代参数为中文标签
      if (yearValue != 'all') {
        yearValue =
            _movieYearOptions.firstWhere((e) => e.value == yearValue).label;
      }

      // 转换类型参数为中文标签
      if (categoryValue != 'all') {
        categoryValue =
            _movieTypeOptions.firstWhere((e) => e.value == categoryValue).label;
      }

      final params = DoubanRecommendsParams(
        kind: 'movie',
        category: categoryValue,
        region: regionValue,
        year: yearValue,
        sort: _selectedMovieSort,
        pageLimit: _pageLimit,
        page: _page,
      );

      final result = await DoubanService.fetchDoubanRecommends(
        context,
        params,
      );
      if (mounted) {
        // 检查当前筛选状态是否仍然与发起请求时一致
        if (requestFilterState != _getCurrentFilterState()) {
          // 筛选状态已改变，忽略这个过期的响应
          return;
        }

        setState(() {
          if (result.success && result.data != null) {
            _movies.addAll(result.data!);
            _page++;
            // 只有当返回的数据为空时才停止分页
            if (result.data!.isEmpty) {
              _hasMore = false;
            }
          } else {
            _errorMessage = result.message ?? '加载失败';
          }
          _isLoading = false;
        });

        // 如果是刷新且内容不足一屏，尝试自动加载更多
        if (isRefresh && result.success && result.data != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _checkAndLoadMoreIfNeeded();
          });
        }
      }
    } else {
      final result = await DoubanService.getCategoryData(
        context,
        kind: 'movie',
        category: _selectedCategoryValue,
        type: _selectedRegionValue,
        page: _page,
        pageLimit: _pageLimit,
      );

      if (mounted) {
        // 检查当前筛选状态是否仍然与发起请求时一致
        if (requestFilterState != _getCurrentFilterState()) {
          // 筛选状态已改变，忽略这个过期的响应
          return;
        }

        setState(() {
          if (result.success && result.data != null) {
            _movies.addAll(result.data!);
            _page++;
            // 只有当返回的数据为空时才停止分页
            if (result.data!.isEmpty) {
              _hasMore = false;
            }
          } else {
            _errorMessage = result.message ?? '加载失败';
          }
          _isLoading = false;
        });

        // 如果是刷新且内容不足一屏，尝试自动加载更多
        if (isRefresh && result.success && result.data != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _checkAndLoadMoreIfNeeded();
          });
        }
      }
    }
  }

  Future<void> _loadMoreMovies() async {
    if (_isLoading || _isLoadingMore || !_hasMore) return;

    // 记录发起请求时的筛选状态
    final requestFilterState = _getCurrentFilterState();

    setState(() {
      _isLoadingMore = true;
    });

    if (_selectedCategoryValue == '全部') {
      // 将界面选项转换为豆瓣API参数
      String categoryValue = _selectedMovieType;
      String regionValue = _selectedMovieRegion;
      String yearValue = _selectedMovieYear;

      // 转换地区参数为中文标签
      if (regionValue != 'all') {
        regionValue =
            _movieRegionOptions.firstWhere((e) => e.value == regionValue).label;
      }

      // 转换年代参数为中文标签
      if (yearValue != 'all') {
        yearValue =
            _movieYearOptions.firstWhere((e) => e.value == yearValue).label;
      }

      // 转换类型参数为中文标签
      if (categoryValue != 'all') {
        categoryValue =
            _movieTypeOptions.firstWhere((e) => e.value == categoryValue).label;
      }

      final params = DoubanRecommendsParams(
        kind: 'movie',
        category: categoryValue,
        region: regionValue,
        year: yearValue,
        sort: _selectedMovieSort,
        pageLimit: _pageLimit,
        page: _page,
      );

      final result = await DoubanService.fetchDoubanRecommends(
        context,
        params,
      );
      if (mounted) {
        // 检查当前筛选状态是否仍然与发起请求时一致
        if (requestFilterState != _getCurrentFilterState()) {
          // 筛选状态已改变，忽略这个过期的响应
          return;
        }

        setState(() {
          if (result.success && result.data != null) {
            _movies.addAll(result.data!);
            _page++;
            // 只有当返回的数据为空时才停止分页
            if (result.data!.isEmpty) {
              _hasMore = false;
            }
          } else {
            // Can show a toast or a small error indicator at the bottom
          }
          _isLoadingMore = false;
        });
      }
    } else {
      final result = await DoubanService.getCategoryData(
        context,
        kind: 'movie',
        category: _selectedCategoryValue,
        type: _selectedRegionValue,
        page: _page,
        pageLimit: _pageLimit,
      );

      if (mounted) {
        // 检查当前筛选状态是否仍然与发起请求时一致
        if (requestFilterState != _getCurrentFilterState()) {
          // 筛选状态已改变，忽略这个过期的响应
          return;
        }

        setState(() {
          if (result.success && result.data != null) {
            _movies.addAll(result.data!);
            _page++;
            // 只有当返回的数据为空时才停止分页
            if (result.data!.isEmpty) {
              _hasMore = false;
            }
          } else {
            // Can show a toast or a small error indicator at the bottom
          }
          _isLoadingMore = false;
        });
      }
    }
  }

  Future<void> _refreshMoviesData() async {
    await _fetchMovies(isRefresh: true);
  }

  void _onVideoTap(VideoInfo videoInfo) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PlayerScreen(
          title: videoInfo.title,
          stype: 'movie',
          year: videoInfo.year,
        ),
      ),
    );
  }

  void _handleMenuAction(VideoInfo videoInfo, VideoMenuAction action) {
    switch (action) {
      case VideoMenuAction.play:
        _onVideoTap(videoInfo);
        break;
      case VideoMenuAction.doubanDetail:
        _launchURL('https://movie.douban.com/subject/${videoInfo.id}/');
        break;
      default:
        break;
    }
  }

  Future<void> _launchURL(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not launch $url')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StyledRefreshIndicator(
      onRefresh: _refreshMoviesData,
      refreshText: '刷新电影数据...',
      primaryColor: const Color(0xFF27AE60),
      child: SingleChildScrollView(
        controller: _scrollController,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            _buildFilterSection(),
            const SizedBox(height: 16),
            DoubanMoviesGrid(
              movies: _movies,
              isLoading: _isLoading && _movies.isEmpty,
              errorMessage: _errorMessage,
              onVideoTap: _onVideoTap,
              onGlobalMenuAction: (videoInfo, action) {
                _handleMenuAction(videoInfo, action);
              },
              contentType: 'movie',
            ),
            // 底部指示器 - 加载更多或到底提示
            if (_isLoadingMore)
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: PulsingDotsIndicator(),
              )
            else if (!_hasMore && _movies.isNotEmpty && !_isLoading)
              _buildEndOfListIndicator()
            else
              const SizedBox(height: 50), // 占位符保持间距
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '电影',
            style: FontUtils.poppins(
              fontSize: 28,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).textTheme.titleLarge?.color,
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 20, // 固定高度确保一致性
            child: Text(
              '来自豆瓣的精选内容',
              style: FontUtils.poppins(
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

  Widget _buildFilterSection() {
    final themeService = Provider.of<ThemeService>(context);
    return Container(
      width: double.infinity, // 设置为100%宽度
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
            '分类',
            _moviePrimaryOptions,
            _selectedCategoryValue,
            (newValue) {
              setState(() {
                _selectedCategoryValue = newValue;
                // 重置二级筛选为默认值
                _selectedRegionValue = '全部'; // 胶囊筛选默认值
                _selectedMovieType = 'all'; // 多级筛选默认值
                _selectedMovieRegion = 'all';
                _selectedMovieYear = 'all';
                _selectedMovieSort = 'T';
              });
              _fetchMovies(isRefresh: true);
            },
          ),
          const SizedBox(height: 16),
          // 使用固定高度的容器来避免高度跳跃
          SizedBox(
            height: 66, // 增加高度以避免Column底部溢出
            child: _selectedCategoryValue == '全部'
                ? _buildAdvancedFilterSection()
                : _buildSimpleFilterSection(),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedFilterSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '筛选',
          style: FontUtils.poppins(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).textTheme.bodyMedium?.color,
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFilterPill('类型', _movieTypeOptions, _selectedMovieType,
                    (v) {
                  setState(() => _selectedMovieType = v);
                  _fetchMovies(isRefresh: true);
                }),
                _buildFilterPill(
                    '地区', _movieRegionOptions, _selectedMovieRegion, (v) {
                  setState(() => _selectedMovieRegion = v);
                  _fetchMovies(isRefresh: true);
                }),
                _buildFilterPill('年代', _movieYearOptions, _selectedMovieYear,
                    (v) {
                  setState(() => _selectedMovieYear = v);
                  _fetchMovies(isRefresh: true);
                }),
                _buildFilterPill('排序', _movieSortOptions, _selectedMovieSort,
                    (v) {
                  setState(() => _selectedMovieSort = v);
                  _fetchMovies(isRefresh: true);
                }),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSimpleFilterSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '地区',
          style: FontUtils.poppins(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).textTheme.bodyMedium?.color,
          ),
        ),
        const SizedBox(height: 6), // 减少间距，与高级筛选保持一致
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: CapsuleTabSwitcher(
            tabs: _movieSecondaryOptions.map((e) => e.label).toList(),
            selectedTab: _movieSecondaryOptions
                .firstWhere((e) => e.value == _selectedRegionValue)
                .label,
            onTabChanged: (newLabel) {
              final newValue = _movieSecondaryOptions
                  .firstWhere((e) => e.label == newLabel)
                  .value;
              setState(() {
                _selectedRegionValue = newValue;
              });
              _fetchMovies(isRefresh: true);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildFilterPill(String title, List<SelectorOption> options,
      String selectedValue, ValueChanged<String> onSelected) {
    final selectedOption = options.firstWhere((e) => e.value == selectedValue,
        orElse: () => options.first);
    bool isDefault =
        selectedValue == 'all' || (title == '排序' && selectedValue == 'T');

    return FilterPillHover(
      isPC: DeviceUtils.isPC(),
      isDefault: isDefault,
      title: title,
      selectedOption: selectedOption,
      onTap: () {
        _showFilterOptions(context, title, options, selectedValue, onSelected);
      },
    );
  }

  void _showFilterOptions(
      BuildContext context,
      String title,
      List<SelectorOption> options,
      String selectedValue,
      ValueChanged<String> onSelected) {
    showFilterOptionsSelector(
      context: context,
      title: title,
      options: options,
      selectedValue: selectedValue,
      onSelected: onSelected,
    );
  }

  Widget _buildFilterRow(
    String title,
    List<SelectorOption> items,
    String selectedValue,
    Function(String) onItemSelected,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: FontUtils.poppins(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).textTheme.bodyMedium?.color,
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: CapsuleTabSwitcher(
            tabs: items.map((e) => e.label).toList(),
            selectedTab:
                items.firstWhere((e) => e.value == selectedValue).label,
            onTabChanged: (newLabel) {
              final newValue =
                  items.firstWhere((e) => e.label == newLabel).value;
              onItemSelected(newValue);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEndOfListIndicator() {
    final themeService = Provider.of<ThemeService>(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
          16, 8, 16, 16), // 减少顶部padding，保持底部padding与加载指示器一致
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
            style: FontUtils.poppins(
              fontSize: 14,
              color: themeService.isDarkMode
                  ? Colors.white.withOpacity(0.6)
                  : Colors.grey[600],
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '共 ${_movies.length} 部电影',
            style: FontUtils.poppins(
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
}
