import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:luna_tv/models/short_drama.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/utils/font_utils.dart';
import 'package:luna_tv/utils/device_utils.dart';

/// 短剧卡片组件
class ShortDramaCard extends StatefulWidget {
  final ShortDrama drama;
  final VoidCallback? onTap;
  final double? cardWidth;

  const ShortDramaCard({
    super.key,
    required this.drama,
    this.onTap,
    this.cardWidth,
  });

  @override
  State<ShortDramaCard> createState() => _ShortDramaCardState();
}

class _ShortDramaCardState extends State<ShortDramaCard> {
  bool _isHovered = false;
  bool _isPlayButtonHovered = false;

  @override
  Widget build(BuildContext context) {
    final bool isPC = DeviceUtils.isPC();

    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        final double width = widget.cardWidth ?? 120.0;
        final double height = width * 1.4;

        final cardContent = SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 封面图片
              Stack(
                children: [
                  Container(
                    width: width,
                    height: height,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CachedNetworkImage(
                        imageUrl: widget.drama.cover,
                        fit: BoxFit.cover,
                        cacheKey: widget.drama.cover,
                        memCacheWidth: (width *
                                MediaQuery.of(context).devicePixelRatio)
                            .round(),
                        memCacheHeight: (height *
                                MediaQuery.of(context).devicePixelRatio)
                            .round(),
                        placeholder: (context, url) => Container(
                          width: width,
                          height: height,
                          decoration: BoxDecoration(
                            color: themeService.isDarkMode
                                ? const Color(0xFF333333)
                                : Colors.grey[300],
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        errorWidget: (context, url, error) => Container(
                          width: width,
                          height: height,
                          decoration: BoxDecoration(
                            color: themeService.isDarkMode
                                ? const Color(0xFF333333)
                                : Colors.grey[300],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.movie,
                            color: themeService.isDarkMode
                                ? const Color(0xFF666666)
                                : Colors.grey,
                            size: 40,
                          ),
                        ),
                        fadeInDuration: const Duration(milliseconds: 200),
                        fadeOutDuration: const Duration(milliseconds: 100),
                      ),
                    ),
                  ),
                  // 底部渐变遮罩
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      height: height * 0.45,
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(8),
                          bottomRight: Radius.circular(8),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withOpacity(0.7),
                          ],
                          stops: const [0.0, 1.0],
                        ),
                      ),
                    ),
                  ),
                  // 集数标签
                  if (widget.drama.episodeCount > 0)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF27ae60),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          '共${widget.drama.episodeCount}集',
                          style: FontUtils.poppins(context,
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  // 底部标题（在渐变遮罩上）
                  Positioned(
                    bottom: 6,
                    left: 6,
                    right: 6,
                    child: Text(
                      widget.drama.title,
                      style: FontUtils.poppins(context,
                        color: Colors.white,
                        fontSize: width < 100 ? 12 : 13,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Hover 渐变蒙层（PC平台）
                  if (isPC)
                    AnimatedOpacity(
                      opacity: _isHovered ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        width: width,
                        height: height,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withOpacity(0.6),
                            ],
                            stops: const [0.5, 1.0],
                          ),
                        ),
                      ),
                    ),
                  // 中心播放按钮（PC平台）
                  if (isPC)
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: widget.onTap,
                        child: Center(
                          child: AnimatedOpacity(
                            opacity: _isHovered ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 200),
                            child: MouseRegion(
                              onEnter: (_) => setState(
                                  () => _isPlayButtonHovered = true),
                              onExit: (_) => setState(
                                  () => _isPlayButtonHovered = false),
                              child: AnimatedScale(
                                scale: _isPlayButtonHovered ? 1.1 : 1.0,
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeInOut,
                                child: AnimatedContainer(
                                  duration:
                                      const Duration(milliseconds: 200),
                                  width: 50,
                                  height: 50,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _isPlayButtonHovered
                                        ? const Color(0xFF27ae60)
                                        : Colors.transparent,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2.5,
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.play_arrow,
                                    color: Colors.white,
                                    size: 28,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );

        // PC平台：添加hover效果
        if (isPC) {
          return GestureDetector(
            onTap: widget.onTap,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _isHovered = true),
              onExit: (_) => setState(() => _isHovered = false),
              child: AnimatedScale(
                scale: _isHovered ? 1.05 : 1.0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: cardContent,
              ),
            ),
          );
        }

        // 非PC平台
        return GestureDetector(
          onTap: widget.onTap,
          child: cardContent,
        );
      },
    );
  }
}
