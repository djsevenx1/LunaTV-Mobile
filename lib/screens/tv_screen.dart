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

class TvScreen extends StatefulWidget {
  const TvScreen({super.key});

  @override
  State<TvScreen> createState() => _TvScreenState();
}

class _TvScreenState extends State<TvScreen> {
  // 电视剧一级选择器选项
  final List<SelectorOption> _tvPrimaryOptions = const [
    SelectorOption(label: '全部', value: '全部'),
    SelectorOption(label: '最近热门', value: '最近热门'),
  ];

  // 电视剧二级选择器选项
  final List<SelectorOption> _tvSecondaryOptions = const [
    SelectorOption(label: '全部', value: 'tv'),
    SelectorOption(label: '国产', value: 'tv_domestic'),
    SelectorOption(label: '欧美', value: 'tv_american'),
    SelectorOption(label: '日本', value: 'tv_japanese'),
    SelectorOption(label: '韩国', value: 'tv_korean'),
    SelectorOption(label: '动漫', value: 'tv_animation'),
    SelectorOption(label: '纪录片', value: 'tv_documentary'),
  ];

  // 新的筛选选项 - 类型
  final List<SelectorOption> _tvTypeOptions = const [
    SelectorOption(label: '全部', value: 'all'),
    SelectorOption(label: '喜剧', value: 'comedy'),
    SelectorOption(label: '爱情', value: 'romance'),
    SelectorOption(label: '悬疑', value: 'suspense'),
    SelectorOption(label: '武侠', value: 'wuxia'),
    SelectorOption(label: '古装', value: 'costume'),
    SelectorOption(label: '家庭', value: 'family'),
    SelectorOption(label: '犯罪', value: 'crime'),
    SelectorOption(label: '科幻', value: 'sci-fi'),
    SelectorOption(label: '恐怖', value: 'horror'),
    SelectorOption(label: '历史', value: 'history'),
    SelectorOption(label: '战争', value: 'war'),
    SelectorOption(label: '动作', value: 'action'),
    SelectorOption(label: '冒险', value: 'adventure'),
    SelectorOption(label: '传记', value: 'biography'),
    SelectorOption(label: '剧情', value: 'drama'),
    SelectorOption(label: '奇幻', value: 'fantasy'),
    SelectorOption(label: '惊悚', value: 'thriller'),
    SelectorOption(label: '灾难', value: 'disaster'),
    SelectorOption(label: '歌舞', value: 'musical'),
    SelectorOption(label: '音乐', value: 'music'),
  ];

  final List<SelectorOption> _tvRegionOptions = const [
    SelectorOption(label: '全部', value: 'all'),
    SelectorOption(label: '华语', value: 'chinese'),
    SelectorOption(label: '欧美', value: 'western'),
    SelectorOption(label: '国外', value: 'foreign'),
    SelectorOption(label: '韩国', value: 'korean'),
    SelectorOption(label: '日本', value: 'japanese'),
    SelectorOption(label: '中国大陆', value: 'mainland_china'),
    SelectorOption(label: '中国香港', value: 'hong_kong'),
    SelectorOption(label: '美国', value: 'usa'),
    SelectorOption(label: '英国', value: 'uk'),
    SelectorOption(label: '泰国', value: 'thailand'),
    SelectorOption(label: '中国台湾', value: 'taiwan'),
    SelectorOption(label: '意大利', value: 'italy'),
    SelectorOption(label: '法国', value: 'france'),
    SelectorOption(label: '德国', value: 'germany'),
    SelectorOption(label: '西班牙', value: 'spain'),
    SelectorOption(label: '俄罗斯', value: 'russia'),
    SelectorOption(label: '瑞典', value: 'sweden'),
    SelectorOption(label: '巴西', value: 'brazil'),
    SelectorOption(label: '丹麦', value: 'denmark'),
    SelectorOption(label: '印度', value: 'india'),
    SelectorOption(label: '加拿大', value: 'canada'),
    SelectorOption(label: '爱尔兰', value: 'ireland'),
    SelectorOption(label: '澳大利亚', value: 'australia'),
  ];

  final List<SelectorOption> _tvYearOptions = const [
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

  final List<SelectorOption> _tvPlatformOptions = const [
    SelectorOption(label: '全部', value: 'all'),
    SelectorOption(label: '腾讯视频', value: 'tencent'),
    SelectorOption(label: '爱奇艺', value: 'iqiyi'),
    SelectorOption(label: '优酷', value: 'youku'),
    SelectorOption(label: '湖南卫视', value: 'hunan_tv'),
    SelectorOption(label: 'Netflix', value: 'netflix'),
    SelectorOption(label: 'HBO', value: 'hbo'),
    SelectorOption(label: 'BBC', value: 'bbc'),
    SelectorOption(label: 'NHK', value: 'nhk'),
    SelectorOption(label: 'CBS', value: 'cbs'),
    SelectorOption(label: 'NBC', value: 'nbc'),
    SelectorOption(label: 'tvN', value: 'tvn'),
  ];

  final List<SelectorOption> _tvSortOptions = const [
    SelectorOption(label: '综合排序', value: 'T'),
    SelectorOption(label: '近期热度', value: 'U'),
    SelectorOption(label: '首播时间', value: 'R'),
    SelectorOption(label: '高分优先', value: 'S'),
  ];

  String _selectedCategoryValue = '最近热门'; // 默认选中最近热门
  String _selectedRegionValue = 'tv'; // 二级筛选默认选中全部

  // 新版筛选状态
  String _selectedTvType = 'all';
  String _selectedTvRegion = 'all';
  String _selectedTvYear = 'all';
  String _selectedTvPlatform = 'all';
  String _selectedTvSort = 'T';

  final ScrollController _scrollController = ScrollController();
  final List<DoubanMovie> _tvShows = [];
  int _page = 0;
  final int _pageLimit = 25;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String? _errorMessage;

  /// 获取当前筛选状态
  String _getCurrentFilterState() {
    return '$_selectedCategoryValue|$_selectedRegionValue|$_selectedTvType|$_selectedTvRegion|$_selectedTvYear|$_selectedTvPlatform|$_selectedTvSort';
  }

  @override
  void initState() {
    super.initState();
    _fetchTvShows(isRefresh: true);
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
        if (_hasMore && !_isLoading && !_isLoadingMore && _tvShows.isNotEmpty) {
          _loadMoreTvShows();
        }
        return;
      }

      // 正常滚动情况：当滚动到距离底部50像素内时触发加载
      const double threshold = 50.0;
      if (position.pixels >= position.maxScrollExtent - threshold) {
        _loadMoreTvShows();
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
    if (position.maxScrollExtent <= 0 && _tvShows.isNotEmpty) {
      _loadMoreTvShows();
    }
  }

  Future<void> _fetchTvShows({bool isRefresh = false}) async {
    // 记录发起请求时的筛选状态
    final requestFilterState = _getCurrentFilterState();

    setState(() {
      _isLoading = true;
      if (isRefresh) {
        _tvShows.clear();
        _page = 0;
        _hasMore = true;
      }
      _errorMessage = null;
    });

    if (_selectedCategoryValue == '全部') {
      // 将界面选项转换为豆瓣API参数
      String categoryValue = _selectedTvType;
      String regionValue = _selectedTvRegion;
      String yearValue = _selectedTvYear;
      String platformValue = _selectedTvPlatform;

      // 转换地区参数为中文标签
      if (regionValue != 'all') {
        regionValue =
            _tvRegionOptions.firstWhere((e) => e.value == regionValue).label;
      }

      // 转换年代参数为中文标签
      if (yearValue != 'all') {
        yearValue =
            _tvYearOptions.firstWhere((e) => e.value == yearValue).label;
      }

      // 转换类型参数为中文标签
      if (categoryValue != 'all') {
        categoryValue =
            _tvTypeOptions.firstWhere((e) => e.value == categoryValue).label;
      }
      // 转换平台参数为中文标签
      if (platformValue != 'all') {
        platformValue = _tvPlatformOptions
            .firstWhere((e) => e.value == platformValue)
            .label;
      }

      final params = DoubanRecommendsParams(
        kind: 'tv',
        category: categoryValue,
        format: '电视剧',
        region: regionValue,
        year: yearValue,
        platform: platformValue,
        sort: _selectedTvSort,
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
            _tvShows.addAll(result.data!);
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
        kind: 'tv',
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
            _tvShows.addAll(result.data!);
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

  Future<void> _loadMoreTvShows() async {
    if (_isLoading || _isLoadingMore || !_hasMore) return;

    // 记录发起请求时的筛选状态
    final requestFilterState = _getCurrentFilterState();

    setState(() {
      _isLoadingMore = true;
    });

    if (_selectedCategoryValue == '全部') {
      // 将界面选项转换为豆瓣API参数
      String categoryValue = _selectedTvType;
      String regionValue = _selectedTvRegion;
      String yearValue = _selectedTvYear;
      String platformValue = _selectedTvPlatform;

      // 转换地区参数为中文标签
      if (regionValue != 'all') {
        regionValue =
            _tvRegionOptions.firstWhere((e) => e.value == regionValue).label;
      }

      // 转换年代参数为中文标签
      if (yearValue != 'all') {
        yearValue =
            _tvYearOptions.firstWhere((e) => e.value == yearValue).label;
      }

      // 转换类型参数为中文标签
      if (categoryValue != 'all') {
        categoryValue =
            _tvTypeOptions.firstWhere((e) => e.value == categoryValue).label;
      }
      // 转换平台参数为中文标签
      if (platformValue != 'all') {
        platformValue = _tvPlatformOptions
            .firstWhere((e) => e.value == platformValue)
            .label;
      }

      final params = DoubanRecommendsParams(
        kind: 'tv',
        category: categoryValue,
        format: '电视剧',
        region: regionValue,
        year: yearValue,
        platform: platformValue,
        sort: _selectedTvSort,
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
            _tvShows.addAll(result.data!);
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
        kind: 'tv',
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
            _tvShows.addAll(result.data!);
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

  Future<void> _refreshTvShowsData() async {
    await _fetchTvShows(isRefresh: true);
  }

  void _onVideoTap(VideoInfo videoInfo) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PlayerScreen(
          title: videoInfo.title,
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
      onRefresh: _refreshTvShowsData,
      refreshText: '刷新电视剧数据...',
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
              movies: _tvShows,
              isLoading: _isLoading && _tvShows.isEmpty,
              errorMessage: _errorMessage,
              onVideoTap: _onVideoTap,
              onGlobalMenuAction: (videoInfo, action) {
                _handleMenuAction(videoInfo, action);
              },
              contentType: 'tv',
            ),
            // 底部指示器 - 加载更多或到底提示
            if (_isLoadingMore)
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: PulsingDotsIndicator(),
              )
            else if (!_hasMore && _tvShows.isNotEmpty && !_isLoading)
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
            '电视剧',
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
            _tvPrimaryOptions,
            _selectedCategoryValue,
            (newValue) {
              setState(() {
                _selectedCategoryValue = newValue;
                // 重置二级筛选为默认值
                _selectedRegionValue = 'tv'; // 胶囊筛选默认值
                _selectedTvType = 'all'; // 多级筛选默认值
                _selectedTvRegion = 'all';
                _selectedTvYear = 'all';
                _selectedTvPlatform = 'all';
                _selectedTvSort = 'T';
              });
              _fetchTvShows(isRefresh: true);
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
                _buildFilterPill('类型', _tvTypeOptions, _selectedTvType, (v) {
                  setState(() => _selectedTvType = v);
                  _fetchTvShows(isRefresh: true);
                }),
                _buildFilterPill('地区', _tvRegionOptions, _selectedTvRegion,
                    (v) {
                  setState(() => _selectedTvRegion = v);
                  _fetchTvShows(isRefresh: true);
                }),
                _buildFilterPill('年代', _tvYearOptions, _selectedTvYear, (v) {
                  setState(() => _selectedTvYear = v);
                  _fetchTvShows(isRefresh: true);
                }),
                _buildFilterPill('平台', _tvPlatformOptions, _selectedTvPlatform,
                    (v) {
                  setState(() => _selectedTvPlatform = v);
                  _fetchTvShows(isRefresh: true);
                }),
                _buildFilterPill('排序', _tvSortOptions, _selectedTvSort, (v) {
                  setState(() => _selectedTvSort = v);
                  _fetchTvShows(isRefresh: true);
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
          '类型',
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
            tabs: _tvSecondaryOptions.map((e) => e.label).toList(),
            selectedTab: _tvSecondaryOptions
                .firstWhere((e) => e.value == _selectedRegionValue)
                .label,
            onTabChanged: (newLabel) {
              final newValue = _tvSecondaryOptions
                  .firstWhere((e) => e.label == newLabel)
                  .value;
              setState(() {
                _selectedRegionValue = newValue;
              });
              _fetchTvShows(isRefresh: true);
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
            '共 ${_tvShows.length} 部电视剧',
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
