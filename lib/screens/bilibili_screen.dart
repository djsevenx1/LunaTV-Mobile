import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:luna_tv/models/bilibili_video.dart';
import 'package:luna_tv/services/bilibili_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/widgets/pulsing_dots_indicator.dart';
import 'package:luna_tv/utils/font_utils.dart';

/// Bilibili 页面
class BilibiliScreen extends StatefulWidget {
  const BilibiliScreen({super.key});

  @override
  State<BilibiliScreen> createState() => _BilibiliScreenState();
}

class _BilibiliScreenState extends State<BilibiliScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _searchFocusNode = FocusNode();

  // 热门视频数据
  final List<BilibiliVideo> _popularVideos = [];
  bool _isLoadingPopular = false;

  // 搜索数据
  final List<BilibiliVideo> _searchResults = [];
  bool _isSearching = false;
  bool _hasSearched = false;

  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchPopularVideos();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// 获取热门视频
  Future<void> _fetchPopularVideos() async {
    if (!mounted) return;

    setState(() {
      _isLoadingPopular = true;
      _errorMessage = null;
    });

    final result = await BilibiliService.getPopular();

    if (!mounted) return;

    setState(() {
      _popularVideos.addAll(result);
      _isLoadingPopular = false;
    });
  }

  /// 执行搜索
  Future<void> _performSearch(String query) async {
    if (query.trim().isEmpty) return;
    if (!mounted) return;

    setState(() {
      _isSearching = true;
      _hasSearched = true;
      _searchResults.clear();
      _errorMessage = null;
    });

    final result = await BilibiliService.search(query.trim());

    if (!mounted) return;

    setState(() {
      _searchResults.addAll(result);
      _isSearching = false;
    });
  }

  /// 打开外部浏览器播放 Bilibili 视频
  Future<void> _launchBilibiliVideo(BilibiliVideo video) async {
    final uri = Uri.parse('https://www.bilibili.com/video/${video.id}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开链接')),
      );
    }
  }

  /// 格式化播放量
  String _formatPlayCount(int count) {
    if (count >= 10000) {
      return '${(count / 10000).toStringAsFixed(1)}万';
    }
    return count.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return RefreshIndicator(
          onRefresh: _fetchPopularVideos,
          color: const Color(0xFF27ae60),
          child: CustomScrollView(
            controller: _scrollController,
            slivers: [
              // 顶部标题
              SliverToBoxAdapter(
                child: _buildHeader(themeService),
              ),
              // 搜索框
              SliverToBoxAdapter(
                child: _buildSearchBar(themeService),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),

              // 搜索结果区域
              if (_hasSearched) ...[
                if (_isSearching)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: PulsingDotsIndicator(),
                    ),
                  )
                else if (_searchResults.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _buildSearchEmptyState(themeService),
                  )
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        return _buildSearchResultItem(
                          _searchResults[index],
                          themeService,
                        );
                      },
                      childCount: _searchResults.length,
                    ),
                  ),
              ] else ...[
                // 热门视频区域
                if (_isLoadingPopular && _popularVideos.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: PulsingDotsIndicator(),
                    ),
                  )
                else if (_popularVideos.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _buildEmptyState(themeService),
                  )
                else ...[
                  SliverToBoxAdapter(
                    child: _buildSectionTitle('热门视频', themeService),
                  ),
                  SliverToBoxAdapter(
                    child: _buildPopularVideoGrid(themeService),
                  ),
                ],
              ],

              // 底部间距
              const SliverToBoxAdapter(child: SizedBox(height: 50)),
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
            'Bilibili',
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
              '发现热门视频内容',
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

  /// 构建搜索框
  Widget _buildSearchBar(ThemeService themeService) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: themeService.isDarkMode
              ? Colors.white.withOpacity(0.1)
              : Colors.grey[200],
          borderRadius: BorderRadius.circular(12),
        ),
        child: TextField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          style: FontUtils.poppins(context,
            fontSize: 14,
            color: themeService.isDarkMode
                ? const Color(0xFFffffff)
                : const Color(0xFF2c3e50),
          ),
          decoration: InputDecoration(
            hintText: '搜索 Bilibili 视频...',
            hintStyle: FontUtils.poppins(context,
              fontSize: 14,
              color: themeService.isDarkMode
                  ? const Color(0xFFb0b0b0)
                  : const Color(0xFF7f8c8d),
            ),
            prefixIcon: Icon(
              Icons.search,
              color: themeService.isDarkMode
                  ? const Color(0xFFb0b0b0)
                  : const Color(0xFF7f8c8d),
            ),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: Icon(
                      Icons.clear,
                      color: themeService.isDarkMode
                          ? const Color(0xFFb0b0b0)
                          : const Color(0xFF7f8c8d),
                    ),
                    onPressed: () {
                      _searchController.clear();
                      _searchFocusNode.unfocus();
                      setState(() {
                        _hasSearched = false;
                        _searchResults.clear();
                      });
                    },
                  )
                : null,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: (query) {
            _searchFocusNode.unfocus();
            _performSearch(query);
          },
          onChanged: (value) {
            setState(() {});
          },
        ),
      ),
    );
  }

  /// 构建区域标题
  Widget _buildSectionTitle(String title, ThemeService themeService) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 12),
      child: Text(
        title,
        style: FontUtils.poppins(context,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: themeService.isDarkMode
              ? const Color(0xFFffffff)
              : const Color(0xFF2c3e50),
        ),
      ),
    );
  }

  /// 构建热门视频2列网格
  Widget _buildPopularVideoGrid(ThemeService themeService) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final double horizontalPadding = 16;
    final double gridWidth = screenWidth - horizontalPadding * 2;
    final double spacing = 10.0;
    final double cardWidth = (gridWidth - spacing) / 2;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: spacing,
          childAspectRatio: cardWidth / (cardWidth * 1.35),
        ),
        itemCount: _popularVideos.length,
        itemBuilder: (context, index) {
          return _buildPopularVideoCard(
            _popularVideos[index],
            themeService,
          );
        },
      ),
    );
  }

  /// 构建单个热门视频卡片
  Widget _buildPopularVideoCard(
      BilibiliVideo video, ThemeService themeService) {
    return GestureDetector(
      onTap: () => _launchBilibiliVideo(video),
      child: Container(
        decoration: BoxDecoration(
          color: themeService.isDarkMode
              ? Colors.white.withOpacity(0.08)
              : Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 缩略图
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
              child: Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Image.network(
                      video.thumbnail,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: themeService.isDarkMode
                            ? const Color(0xFF333333)
                            : Colors.grey[300],
                        child: const Center(
                          child: Icon(
                            Icons.video_library,
                            color: Color(0xFF27ae60),
                            size: 32,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 时长标签
                  if (video.duration.isNotEmpty)
                    Positioned(
                      bottom: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          video.duration,
                          style: FontUtils.sourceCodePro(context,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // 标题和信息
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    style: FontUtils.poppins(context,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: themeService.isDarkMode
                          ? const Color(0xFFffffff)
                          : const Color(0xFF2c3e50),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    video.author,
                    style: FontUtils.poppins(context,
                      fontSize: 11,
                      color: themeService.isDarkMode
                          ? const Color(0xFFb0b0b0)
                          : const Color(0xFF7f8c8d),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_formatPlayCount(video.playCount)} 播放',
                    style: FontUtils.poppins(context,
                      fontSize: 11,
                      color: themeService.isDarkMode
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
    );
  }

  /// 构建搜索结果列表项
  Widget _buildSearchResultItem(
      BilibiliVideo video, ThemeService themeService) {
    return GestureDetector(
      onTap: () => _launchBilibiliVideo(video),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: themeService.isDarkMode
              ? Colors.white.withOpacity(0.05)
              : Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 缩略图
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                children: [
                  Image.network(
                    video.thumbnail,
                    width: 160,
                    height: 90,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 160,
                      height: 90,
                      color: themeService.isDarkMode
                          ? const Color(0xFF333333)
                          : Colors.grey[300],
                      child: const Icon(
                        Icons.video_library,
                        color: Color(0xFF27ae60),
                        size: 32,
                      ),
                    ),
                  ),
                  // 时长标签
                  if (video.duration.isNotEmpty)
                    Positioned(
                      bottom: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          video.duration,
                          style: FontUtils.sourceCodePro(context,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // 视频信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text(
                    video.title,
                    style: FontUtils.poppins(context,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: themeService.isDarkMode
                          ? const Color(0xFFffffff)
                          : const Color(0xFF2c3e50),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    video.author,
                    style: FontUtils.poppins(context,
                      fontSize: 12,
                      color: themeService.isDarkMode
                          ? const Color(0xFFb0b0b0)
                          : const Color(0xFF7f8c8d),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        '${_formatPlayCount(video.playCount)} 播放',
                        style: FontUtils.poppins(context,
                          fontSize: 12,
                          color: themeService.isDarkMode
                              ? const Color(0xFFb0b0b0)
                              : const Color(0xFF7f8c8d),
                        ),
                      ),
                      if (video.publishedAt.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          video.publishedAt,
                          style: FontUtils.poppins(context,
                            fontSize: 12,
                            color: themeService.isDarkMode
                                ? const Color(0xFFb0b0b0)
                                : const Color(0xFF7f8c8d),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
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
            Icons.ondemand_video_outlined,
            size: 64,
            color: themeService.isDarkMode
                ? Colors.white.withOpacity(0.3)
                : Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            '暂无热门视频',
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

  /// 构建搜索空状态
  Widget _buildSearchEmptyState(ThemeService themeService) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off_outlined,
            size: 64,
            color: themeService.isDarkMode
                ? Colors.white.withOpacity(0.3)
                : Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            '未找到相关视频',
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
            '换个关键词试试',
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
}
