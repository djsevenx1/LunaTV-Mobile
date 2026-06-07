import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:luna_tv/models/play_record.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/widgets/video_card.dart';
import 'package:luna_tv/services/page_cache_service.dart';
import 'package:luna_tv/utils/device_utils.dart';
import 'package:luna_tv/utils/font_utils.dart';
import 'package:luna_tv/widgets/video_menu_bottom_sheet.dart';
import 'package:luna_tv/shimmer_effect.dart';

class HistoryGrid extends StatefulWidget {
  final Function(PlayRecord) onVideoTap;
  final Function(PlayRecord, VideoMenuAction)? onGlobalMenuAction;

  const HistoryGrid({
    super.key,
    required this.onVideoTap,
    this.onGlobalMenuAction,
  });

  @override
  State<HistoryGrid> createState() => _HistoryGridState();

  /// 静态方法：刷新播放历史数据
  static Future<void> refreshHistory() async {
    await _HistoryGridState._currentInstance?._refreshDataInBackground();
  }

  /// 静态方法：从UI中移除指定的播放记录
  static void removeHistoryFromUI(String source, String id) {
    _HistoryGridState._currentInstance?.removeHistoryFromUI(source, id);
  }
}

class _HistoryGridState extends State<HistoryGrid>
    with TickerProviderStateMixin {
  List<PlayRecord> _playRecords = [];
  bool _isLoading = true;
  String? _errorMessage;
  final PageCacheService _cacheService = PageCacheService();

  // 静态变量存储当前实例
  static _HistoryGridState? _currentInstance;

  @override
  void initState() {
    super.initState();

    // 设置当前实例
    _currentInstance = this;

    _loadData();
  }

  @override
  void dispose() {
    // 清除当前实例引用
    if (_currentInstance == this) {
      _currentInstance = null;
    }
    super.dispose();
  }

  Future<void> _loadData() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _loadPlayRecords();
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  /// 后台刷新数据
  Future<void> _refreshDataInBackground() async {
    try {
      await _refreshPlayRecords();
    } catch (e) {
      // 后台刷新失败，静默处理，保持原有数据
    }
  }

  /// 刷新播放记录数据
  Future<void> _refreshPlayRecords() async {
    try {
      if (!mounted) return;
      final cachedRecordsResult =
          await _cacheService.getPlayRecordsDirect(context);
      if (!mounted) return;
      if (cachedRecordsResult.success && cachedRecordsResult.data != null) {
        final cachedRecords = cachedRecordsResult.data!;
        setState(() {
          _playRecords = cachedRecords;
        });
      }
    } catch (e) {
      // 静默处理错误，保持原有数据
    }
  }

  /// 从UI中移除指定的播放记录（供外部调用）
  void removeHistoryFromUI(String source, String id) {
    if (!mounted) return;

    setState(() {
      _playRecords
          .removeWhere((record) => record.source == source && record.id == id);
    });
  }

  Future<void> _loadPlayRecords() async {
    try {
      if (!mounted) return;
      // 使用缓存服务获取数据
      final result = await _cacheService.getPlayRecords(context);
      if (!mounted) return;

      if (result.success && result.data != null) {
        setState(() {
          _playRecords = result.data!;
        });
      } else {
        throw Exception(result.errorMessage ?? '获取播放记录失败');
      }
    } catch (e) {
      throw Exception('获取播放记录失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return _buildLoadingState();
    }

    if (_errorMessage != null) {
      return _buildErrorState();
    }

    if (_playRecords.isEmpty) {
      return _buildEmptyState();
    }

    return _buildHistoryGrid();
  }

  Widget _buildLoadingState() {
    return RefreshIndicator(
      onRefresh: _loadData,
      color: const Color(0xFF27ae60),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 平板模式根据宽度动态展示6～9列，手机模式3列
          final int crossAxisCount = DeviceUtils.getTabletColumnCount(context);
          final isTablet = DeviceUtils.isTablet(context);

          // 计算每列的宽度
          final double screenWidth = constraints.maxWidth;
          const double padding = 16.0;
          const double spacing = 12.0;
          final double availableWidth =
              screenWidth - (padding * 2) - (spacing * (crossAxisCount - 1));
          const double minItemWidth = 80.0;
          final double calculatedItemWidth = availableWidth / crossAxisCount;
          final double itemWidth = math.max(calculatedItemWidth, minItemWidth);
          final double itemHeight = itemWidth * 2.0;

          return GridView.builder(
            padding: const EdgeInsets.all(16),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              childAspectRatio: itemWidth / itemHeight,
              crossAxisSpacing: spacing,
              mainAxisSpacing: isTablet ? 0 : 16,
            ),
            itemCount: isTablet ? crossAxisCount * 2 : 6,
            itemBuilder: (context, index) {
              return _buildSkeletonCard(itemWidth);
            },
          );
        },
      ),
    );
  }

  /// 构建骨架卡片
  Widget _buildSkeletonCard(double width) {
    final double height = width * 1.4;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ShimmerEffect(
          width: width,
          height: height,
          borderRadius: BorderRadius.circular(8),
        ),
        const SizedBox(height: 4),
        Center(
          child: ShimmerEffect(
            width: width * 0.8,
            height: 12,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(height: 2),
        Center(
          child: ShimmerEffect(
            width: width * 0.6,
            height: 8,
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
            style: FontUtils.poppins(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF7f8c8d),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _errorMessage ?? '未知错误',
            style: FontUtils.poppins(
              fontSize: 14,
              color: const Color(0xFF95a5a6),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _loadPlayRecords,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF27ae60),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Text(
              '重试',
              style: FontUtils.poppins(
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 120.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.history,
              size: 80,
              color: Color(0xFFbdc3c7),
            ),
            const SizedBox(height: 24),
            Text(
              '暂无播放历史',
              style: FontUtils.poppins(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF7f8c8d),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '您观看过的视频将显示在这里',
              style: FontUtils.poppins(
                fontSize: 14,
                color: const Color(0xFF95a5a6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryGrid() {
    return RefreshIndicator(
      onRefresh: _loadPlayRecords,
      color: const Color(0xFF27ae60),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 平板模式根据宽度动态展示6～9列，手机模式3列
          final int crossAxisCount = DeviceUtils.getTabletColumnCount(context);
          final isTablet = DeviceUtils.isTablet(context);

          // 计算每列的宽度
          final double screenWidth = constraints.maxWidth;
          const double padding = 16.0;
          const double spacing = 12.0;
          final double availableWidth =
              screenWidth - (padding * 2) - (spacing * (crossAxisCount - 1));
          const double minItemWidth = 80.0;
          final double calculatedItemWidth = availableWidth / crossAxisCount;
          final double itemWidth = math.max(calculatedItemWidth, minItemWidth);
          final double itemHeight = itemWidth * 2.0;

          return GridView.builder(
            padding: const EdgeInsets.all(16),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              childAspectRatio: itemWidth / itemHeight,
              crossAxisSpacing: spacing,
              mainAxisSpacing: isTablet ? 0 : 16,
            ),
            itemCount: _playRecords.length,
            itemBuilder: (context, index) {
              final playRecord = _playRecords[index];

              return VideoCard(
                videoInfo: VideoInfo.fromPlayRecord(playRecord),
                onTap: () => widget.onVideoTap(playRecord),
                from: 'playrecord',
                cardWidth: itemWidth,
                onGlobalMenuAction: widget.onGlobalMenuAction != null
                    ? (action) => widget.onGlobalMenuAction!(playRecord, action)
                    : null,
                isFavorited: _cacheService.isFavoritedSync(
                    playRecord.source, playRecord.id),
              );
            },
          );
        },
      ),
    );
  }
}
