import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/utils/device_utils.dart';
import 'package:luna_tv/utils/font_utils.dart';

/// Hero Banner 轮播项数据模型
class HeroBannerItem {
  final String id;
  final String title;
  final String subtitle;
  final String imageUrl;
  final String type; // movie/tv/anime/show
  final String source;
  final String id_; // 用于跳转播放

  const HeroBannerItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.type,
    required this.source,
    required this.id_,
  });

  /// 根据 type 返回中文标签
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
      default:
        return type;
    }
  }
}

/// Hero Banner 轮播组件，用于首页顶部展示热门内容
class HeroBanner extends StatefulWidget {
  final List<HeroBannerItem> items;
  final void Function(HeroBannerItem item)? onTap;
  final double height;

  const HeroBanner({
    super.key,
    required this.items,
    this.onTap,
    this.height = 200,
  });

  @override
  State<HeroBanner> createState() => _HeroBannerState();
}

class _HeroBannerState extends State<HeroBanner> {
  late PageController _pageController;
  Timer? _autoScrollTimer;
  int _currentPage = 0;
  bool _isUserInteracting = false;

  // PC 端 hover 状态
  bool _isHovered = false;
  bool _isPlayButtonHovered = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _startAutoScroll();
  }

  @override
  void didUpdateWidget(covariant HeroBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表变化时重置
    if (oldWidget.items.length != widget.items.length) {
      _currentPage = 0;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
    }
  }

  @override
  void dispose() {
    _stopAutoScroll();
    _pageController.dispose();
    super.dispose();
  }

  /// 启动自动轮播
  void _startAutoScroll() {
    _stopAutoScroll();
    _autoScrollTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!_isUserInteracting && widget.items.length > 1 && mounted) {
        _nextPage();
      }
    });
  }

  /// 停止自动轮播
  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  /// 切换到下一页
  void _nextPage() {
    if (!mounted || ! _pageController.hasClients) return;
    _currentPage = (_currentPage + 1) % widget.items.length;
    _pageController.animateToPage(
      _currentPage,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  /// 用户开始拖拽
  void _onPageDragStart() {
    _isUserInteracting = true;
    _stopAutoScroll();
  }

  /// 用户结束拖拽
  void _onPageDragEnd() {
    _isUserInteracting = false;
    _startAutoScroll();
  }

  /// 处理 banner 点击
  void _onBannerTap(HeroBannerItem item) {
    widget.onTap?.call(item);
  }

  @override
  Widget build(BuildContext context) {
    // 空列表时不显示
    if (widget.items.isEmpty) {
      return const SizedBox.shrink();
    }

    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Banner 主体
            SizedBox(
              height: widget.height,
              child: _buildBannerContent(themeService),
            ),
            // 底部指示器
            const SizedBox(height: 8),
            _buildIndicator(themeService),
          ],
        );
      },
    );
  }

  /// 构建 Banner 内容
  Widget _buildBannerContent(ThemeService themeService) {
    final bool isPC = DeviceUtils.isPC();

    if (isPC) {
      return MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) {
          setState(() {
            _isHovered = false;
            _isPlayButtonHovered = false;
          });
        },
        child: GestureDetector(
          onTap: () => _onBannerTap(widget.items[_currentPage]),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                // PageView
                _buildPageView(themeService),
                // PC 端 hover 播放按钮叠加层
                _buildPCPlayOverlay(),
              ],
            ),
          ),
        ),
      );
    }

    // 移动端
    return GestureDetector(
      onTap: () => _onBannerTap(widget.items[_currentPage]),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: _buildPageView(themeService),
      ),
    );
  }

  /// 构建 PageView
  Widget _buildPageView(ThemeService themeService) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          _onPageDragStart();
        } else if (notification is ScrollEndNotification) {
          _onPageDragEnd();
        }
        return false;
      },
      child: PageView.builder(
        controller: _pageController,
        itemCount: widget.items.length,
        onPageChanged: (index) {
          setState(() {
            _currentPage = index;
          });
        },
        itemBuilder: (context, index) {
          return _buildBannerItem(widget.items[index], themeService);
        },
      ),
    );
  }

  /// 构建单个 Banner 项
  Widget _buildBannerItem(HeroBannerItem item, ThemeService themeService) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 背景大图
        CachedNetworkImage(
          imageUrl: item.imageUrl,
          fit: BoxFit.cover,
          cacheKey: item.imageUrl,
          placeholder: (context, url) => Container(
            color: themeService.isDarkMode
                ? const Color(0xFF333333)
                : Colors.grey[300],
          ),
          errorWidget: (context, url, error) => Container(
            color: themeService.isDarkMode
                ? const Color(0xFF333333)
                : Colors.grey[300],
            child: const Icon(
              Icons.movie,
              color: Color(0xFF666666),
              size: 40,
            ),
          ),
          fadeInDuration: const Duration(milliseconds: 300),
          fadeOutDuration: const Duration(milliseconds: 100),
        ),

        // 底部渐变遮罩（从透明到黑色）
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            height: widget.height * 0.7,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withOpacity(0.85),
                ],
                stops: const [0.0, 1.0],
              ),
            ),
          ),
        ),

        // 文字内容区域
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 类型标签
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF27ae60),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  item.typeLabel,
                  style: FontUtils.poppins(context,
                                        fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              // 标题
              Text(
                item.title,
                style: FontUtils.poppins(context,
                                    fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              // 副标题/描述
              Text(
                item.subtitle,
                style: FontUtils.poppins(context,
                                    fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: Colors.white.withOpacity(0.7),
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// PC 端 hover 播放按钮叠加层
  Widget _buildPCPlayOverlay() {
    return AnimatedOpacity(
      opacity: _isHovered ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.3),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: MouseRegion(
            onEnter: (_) => setState(() => _isPlayButtonHovered = true),
            onExit: (_) => setState(() => _isPlayButtonHovered = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isPlayButtonHovered
                    ? const Color(0xFF27ae60)
                    : Colors.white.withOpacity(0.9),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                Icons.play_arrow,
                color: _isPlayButtonHovered
                    ? Colors.white
                    : const Color(0xFF27ae60),
                size: 36,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 构建底部指示器
  Widget _buildIndicator(ThemeService themeService) {
    if (widget.items.length <= 1) {
      return const SizedBox.shrink();
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(widget.items.length, (index) {
        final bool isActive = index == _currentPage;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: isActive ? 18 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: isActive
                ? const Color(0xFF27ae60)
                : (themeService.isDarkMode
                    ? Colors.white.withOpacity(0.3)
                    : const Color(0xFF2c3e50).withOpacity(0.3)),
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}
