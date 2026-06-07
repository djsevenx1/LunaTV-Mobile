import 'package:flutter/material.dart';
import 'package:luna_tv/models/douban_movie.dart';
import 'package:luna_tv/models/play_record.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/services/douban_service.dart';
import 'package:luna_tv/widgets/video_menu_bottom_sheet.dart';
import 'package:luna_tv/recommendation_section.dart';

/// 热门综艺组件
class HotShowSection extends StatefulWidget {
  final Function(PlayRecord)? onShowTap;
  final VoidCallback? onMoreTap;
  final Function(VideoInfo, VideoMenuAction)? onGlobalMenuAction;

  const HotShowSection({
    super.key,
    this.onShowTap,
    this.onMoreTap,
    this.onGlobalMenuAction,
  });

  @override
  State<HotShowSection> createState() => _HotShowSectionState();

  /// 静态方法：刷新热门综艺数据
  static Future<void> refreshHotShows() async {
    await _HotShowSectionState._currentInstance?._loadHotShows();
  }
}

class _HotShowSectionState extends State<HotShowSection> {
  List<DoubanMovie> _shows = [];
  bool _isLoading = true;
  bool _hasError = false;
  
  
  // 静态变量存储当前实例
  static _HotShowSectionState? _currentInstance;

  @override
  void initState() {
    super.initState();
    // 设置当前实例
    _currentInstance = this;
    _loadHotShows();
  }

  /// 加载热门综艺
  Future<void> _loadHotShows() async {
    if (!mounted) return;

    try {
      setState(() {
        _isLoading = true;
        _hasError = false;
      });

      // 直接调用 DoubanService（内部已做函数级缓存）
      final result = await DoubanService.getHotShows(context);
      if (!mounted) return;

      if (result.success && result.data != null && result.data!.isNotEmpty) {
        setState(() {
          _shows = result.data!;
          _isLoading = false;
        });
      } else {
        setState(() {
          _hasError = true;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _isLoading = false;
      });
    }
  }

  /// 转换为VideoInfo列表
  List<VideoInfo> _convertToVideoInfos() {
    return _shows.map((show) => show.toVideoInfo()).toList();
  }

  @override
  void dispose() {
    // 清除当前实例引用
    if (_currentInstance == this) {
      _currentInstance = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RecommendationSection(
      title: '热门综艺',
      moreText: '查看更多 >',
      onMoreTap: widget.onMoreTap,
      videoInfos: _convertToVideoInfos(),
      onItemTap: (videoInfo) {
        // 转换为PlayRecord用于回调
        final playRecord = PlayRecord(
          id: videoInfo.id,
          source: videoInfo.source,
          title: videoInfo.title,
          sourceName: videoInfo.sourceName,
          year: videoInfo.year,
          cover: videoInfo.cover,
          index: videoInfo.index,
          totalEpisodes: videoInfo.totalEpisodes,
          playTime: videoInfo.playTime,
          totalTime: videoInfo.totalTime,
          saveTime: videoInfo.saveTime,
          searchTitle: videoInfo.searchTitle,
        );
        widget.onShowTap?.call(playRecord);
      },
      onGlobalMenuAction: widget.onGlobalMenuAction,
      isLoading: _isLoading,
      hasError: _hasError,
      onRetry: _loadHotShows,
      cardCount: 2.75,
    );
  }
}
