import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/utils/image_url.dart';
import 'package:provider/provider.dart';

/// Hero Banner 轮播项数据模型
class HeroBannerItem {
  final String id;
  final String title;
  final String subtitle;
  final String imageUrl;
  final String type; // movie/tv/anime/show
  final String source;
  final String id_; // 用于跳转播放
  final String? year;
  final String? rate;
  final String? description;

  const HeroBannerItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.type,
    required this.source,
    required this.id_,
    this.year,
    this.rate,
    this.description,
  });

  String get typeLabel {
    switch (type) {
      case 'movie':
        return '电影';
      case 'tv':
        return '剧集';
      case 'anime':
        return '动漫';
      case 'show':
        return '综艺';
      case 'short':
        return '短剧';
      default:
        return type;
    }
  }
}

/// Hero Banner 轮播组件 - LunaTV 风格
/// 全屏背景图 + 渐变遮罩 + 大标题 + CTA 按钮
class HeroBanner extends StatefulWidget {
  final List<HeroBannerItem> items;
  final void Function(HeroBannerItem item)? onTap;

  const HeroBanner({
    super.key,
    required this.items,
    this.onTap,
  });

  @override
  State<HeroBanner> createState() => _HeroBannerState();
}

class _HeroBannerState extends State<HeroBanner> {
  late PageController _pageController;
  Timer? _autoScrollTimer;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _startAutoScroll();
  }

  @override
  void didUpdateWidget(covariant HeroBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) {
      _currentPage = 0;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
      _startAutoScroll();
    }
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _startAutoScroll() {
    _autoScrollTimer?.cancel();
    if (widget.items.length <= 1) return;
    _autoScrollTimer = Timer.periodic(const Duration(seconds: 8), (timer) {
      if (!mounted || !_pageController.hasClients) return;
      final next = (_currentPage + 1) % widget.items.length;
      _pageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 1000),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        final isDarkMode = themeService.isDarkMode;
        return LayoutBuilder(
          builder: (context, constraints) {
            // 响应式高度 - 调小降低源图 600×900 被强拉到 banner 宽度的放大倍率
            // 平板上原来 42~45vh 现在 32vh, 放大倍率从 6.7x 降到 3x 以内
            // v1.0.48: 重新加高 (32~45vh, clamp 240~520), 配合 v1.0.39 raw 图升级
            // 1~2x 放大倍率不会糊, 平板看着更舒展
            final screenWidth = constraints.maxWidth;
            final screenHeight = MediaQuery.of(context).size.height;
            double bannerHeight;
            if (screenWidth < 640) {
              bannerHeight = screenHeight * 0.32; // 移动端 32vh
            } else if (screenWidth < 768) {
              bannerHeight = screenHeight * 0.38; // sm 38vh
            } else if (screenWidth < 1024) {
              bannerHeight = screenHeight * 0.42; // md 42vh
            } else {
              bannerHeight = screenHeight * 0.45; // lg+ 45vh
            }
            bannerHeight = bannerHeight.clamp(240.0, 520.0);

            // banner 实际宽度 (去掉左右 12 边距), 给 CachedNetworkImage 算解码尺寸
            final bannerWidth = screenWidth - 24;

            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  width: double.infinity,
                  height: bannerHeight,
                  child: Stack(
                    children: [
                      // 背景图轮播
                      PageView.builder(
                        controller: _pageController,
                        itemCount: widget.items.length,
                        onPageChanged: (index) {
                          setState(() {
                            _currentPage = index;
                          });
                        },
                        itemBuilder: (context, index) {
                          return _buildBannerItem(
                              widget.items[index], isDarkMode, bannerWidth);
                        },
                      ),

                      // 左右切换按钮
                      if (widget.items.length > 1) ...[
                        Positioned(
                          left: 8,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: _buildNavButton(
                              Icons.chevron_left,
                              () {
                                if (_pageController.hasClients) {
                                  _pageController.previousPage(
                                    duration: const Duration(milliseconds: 500),
                                    curve: Curves.easeInOut,
                                  );
                                }
                              },
                            ),
                          ),
                        ),
                        Positioned(
                          right: 8,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: _buildNavButton(
                              Icons.chevron_right,
                              () {
                                if (_pageController.hasClients) {
                                  _pageController.nextPage(
                                    duration: const Duration(milliseconds: 500),
                                    curve: Curves.easeInOut,
                                  );
                                }
                              },
                            ),
                          ),
                        ),
                      ],

                      // 底部指示器
                      Positioned(
                        bottom: 8,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: List.generate(
                              widget.items.length,
                              (index) => AnimatedContainer(
                                duration: const Duration(milliseconds: 300),
                                margin: const EdgeInsets.symmetric(horizontal: 3),
                                width: index == _currentPage ? 20 : 5,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: index == _currentPage
                                      ? Colors.white
                                      : Colors.white.withOpacity(0.5),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBannerItem(HeroBannerItem item, bool isDarkMode, double bannerWidth) {
    return GestureDetector(
      onTap: () => widget.onTap?.call(item),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 背景图
          FutureBuilder<String>(
            future: getImageUrl(item.imageUrl, item.source,
                upgradeDouban: true),
            builder: (context, snapshot) {
              final imageUrl = snapshot.data ?? item.imageUrl;
              final headers = getImageRequestHeaders(imageUrl, item.source);
              // 按 banner 实际显示尺寸 (build 时计算的 bannerWidth) × devicePixelRatio 解码,
              // 平板上 banner 跨满屏,源图被放大到 2~3 倍很常见,
              // 必须用 FilterQuality.high 做高质量重采样,否则马赛克很明显
              final dpr = MediaQuery.of(context).devicePixelRatio;
              final bannerPx = (bannerWidth * dpr).round();
              return CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
                httpHeaders: headers,
                memCacheWidth: bannerPx,
                placeholder: (context, url) => Container(
                  color: isDarkMode ? Colors.black : Colors.grey[300],
                ),
                errorWidget: (context, url, error) => Container(
                  color: isDarkMode ? Colors.black : Colors.grey[300],
                  child: const Icon(Icons.movie, color: Colors.white, size: 64),
                ),
              );
            },
          ),
          // 底部柔和渐变遮罩 - 让图片更通透
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withOpacity(0.25),
                  Colors.black.withOpacity(0.55),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
          // 左侧柔和渐变 - 保护标题可读性
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.black.withOpacity(0.35),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.6],
              ),
            ),
          ),
          // 内容
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标签行
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      // 类型
                      _buildPill(item.typeLabel, withBg: false),
                      // 年份
                      if (item.year != null && item.year!.isNotEmpty)
                        _buildPill(item.year!, withBg: false),
                      // 评分
                      if (item.rate != null && item.rate!.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.ratingAmber.withOpacity(0.85),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.star,
                                  size: 11, color: Colors.white),
                              const SizedBox(width: 2),
                              Text(
                                item.rate!,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 标题
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      height: 1.2,
                      shadows: [
                        Shadow(
                          color: Colors.black54,
                          offset: Offset(0, 1),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  // 按钮
                  Row(
                    children: [
                      // 立即播放
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: () => widget.onTap?.call(item),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 6),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.play_arrow,
                                      color: Colors.black, size: 18),
                                  SizedBox(width: 4),
                                  Text(
                                    '立即播放',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.black,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPill(String text, {bool withBg = true}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: withBg ? Colors.white.withOpacity(0.15) : Colors.transparent,
        border: Border.all(
          color: Colors.white.withOpacity(withBg ? 0.0 : 0.3),
          width: 0.5,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildNavButton(IconData icon, VoidCallback onPressed) {
    return Material(
      color: Colors.black.withOpacity(0.3),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}
