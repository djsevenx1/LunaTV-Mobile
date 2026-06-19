import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:luna_tv/models/douban_movie.dart';
import 'package:luna_tv/utils/device_utils.dart';
import 'package:luna_tv/widgets/video_card.dart';
import 'package:luna_tv/widgets/video_menu_bottom_sheet.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/utils/font_utils.dart';
import 'package:luna_tv/widgets/shimmer_effect.dart';

class DoubanMoviesGrid extends StatefulWidget {
  final List<DoubanMovie>? movies;
  final bool isLoading;
  final String? errorMessage;
  final Function(VideoInfo) onVideoTap;
  final Function(VideoInfo, VideoMenuAction)? onGlobalMenuAction;
  final String contentType; // 'movie' 或 'tv'

  const DoubanMoviesGrid({
    super.key,
    this.movies,
    this.isLoading = false,
    this.errorMessage,
    required this.onVideoTap,
    this.onGlobalMenuAction,
    this.contentType = 'movie', // 默认为电影
  });

  @override
  State<DoubanMoviesGrid> createState() => _DoubanMoviesGridState();
}

class _DoubanMoviesGridState extends State<DoubanMoviesGrid> {
  @override
  Widget build(BuildContext context) {
    if (widget.isLoading && (widget.movies == null || widget.movies!.isEmpty)) {
      return _buildLoadingState();
    }

    if (widget.errorMessage != null) {
      return _buildErrorState();
    }

    if (widget.movies == null || widget.movies!.isEmpty) {
      return _buildEmptyState();
    }

    return _buildMoviesGrid();
  }

  Widget _buildLoadingState() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 平板模式根据宽度动态展示6～9列，手机模式3列
        final int crossAxisCount = DeviceUtils.getTabletColumnCount(context);
        final isTablet = DeviceUtils.isTablet(context);

        final double screenWidth = constraints.maxWidth;
        const double padding = 16.0;
        const double spacing = 12.0;
        final double availableWidth = screenWidth - (padding * 2) - (spacing * (crossAxisCount - 1));
        const double minItemWidth = 80.0;
        final double calculatedItemWidth = availableWidth / crossAxisCount;
        final double itemWidth = math.max(calculatedItemWidth, minItemWidth);
        final double itemHeight = itemWidth * 2.0;

        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: itemWidth / itemHeight,
            crossAxisSpacing: spacing,
            mainAxisSpacing: isTablet ? 0 : 6,
          ),
          itemCount: isTablet ? crossAxisCount * 2 : 6, // 平板显示2行，手机显示6个骨架卡片
          itemBuilder: (context, index) {
            return _buildSkeletonCard(itemWidth);
          },
        );
      },
    );
  }

  /// 构建骨架卡片
  Widget _buildSkeletonCard(double width) {
    final double height = width * 1.5;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 封面骨架
        ShimmerEffect(
          width: width,
          height: height,
          borderRadius: BorderRadius.circular(8),
        ),
        const SizedBox(height: 4),
        // 标题骨架
        Center(
          child: ShimmerEffect(
            width: width * 0.8,
            height: 12,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.error_outline,
            size: 80,
            color: Color(0xFFbdc3c7),
          ),
          const SizedBox(height: 24),
          Text(
            '加载失败',
            style: FontUtils.poppins(context,
                            fontSize: 18,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF7f8c8d),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            widget.errorMessage ?? '未知错误',
            style: FontUtils.poppins(context,
                            fontSize: 14,
              color: const Color(0xFF95a5a6),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final bool isMovie = widget.contentType == 'movie';
    final String contentName = isMovie ? '电影' : '剧集';

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isMovie ? Icons.movie_filter_outlined : Icons.tv_outlined,
            size: 80,
            color: const Color(0xFFbdc3c7),
          ),
          const SizedBox(height: 24),
          Text(
            '暂无$contentName',
            style: FontUtils.poppins(context,
                            fontSize: 18,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF7f8c8d),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '当前分类下没有$contentName',
            style: FontUtils.poppins(context,
                            fontSize: 14,
              color: const Color(0xFF95a5a6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMoviesGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 平板模式根据宽度动态展示6～9列，手机模式3列
        final int crossAxisCount = DeviceUtils.getTabletColumnCount(context);
        final isTablet = DeviceUtils.isTablet(context);

        final double screenWidth = constraints.maxWidth;
        const double padding = 16.0;
        const double spacing = 12.0;
        final double availableWidth = screenWidth - (padding * 2) - (spacing * (crossAxisCount - 1));
        const double minItemWidth = 80.0;
        final double calculatedItemWidth = availableWidth / crossAxisCount;
        final double itemWidth = math.max(calculatedItemWidth, minItemWidth);
        final double itemHeight = itemWidth * 2.0;

        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: itemWidth / itemHeight,
            crossAxisSpacing: spacing,
            mainAxisSpacing: isTablet ? 0 : 6,
          ),
          itemCount: widget.movies!.length,
          itemBuilder: (context, index) {
            final movie = widget.movies![index];
            final videoInfo = movie.toVideoInfo();

            return VideoCard(
              videoInfo: videoInfo,
              onTap: () => widget.onVideoTap(videoInfo),
              from: 'douban',
              cardWidth: itemWidth,
              onGlobalMenuAction: widget.onGlobalMenuAction != null ? (action) => widget.onGlobalMenuAction!(videoInfo, action) : null,
              isFavorited: false,
            );
          },
        );
      },
    );
  }
}
