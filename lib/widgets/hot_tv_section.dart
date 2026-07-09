import 'package:flutter/material.dart';
import 'package:luna_tv/models/douban_movie.dart';
import 'package:luna_tv/models/play_record.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/services/douban_service.dart';
import 'package:luna_tv/widgets/video_menu_bottom_sheet.dart';
import 'package:luna_tv/widgets/recommendation_section.dart';
import 'package:luna_tv/widgets/section_title.dart';

/// 热门剧集组件
class HotTvSection extends StatefulWidget {
  final Function(PlayRecord)? onTvTap;
  final VoidCallback? onMoreTap;
  final Function(VideoInfo, VideoMenuAction)? onGlobalMenuAction;

  const HotTvSection({
    super.key,
    this.onTvTap,
    this.onMoreTap,
    this.onGlobalMenuAction,
  });

  @override
  State<HotTvSection> createState() => _HotTvSectionState();

  /// 静态方法：刷新热门剧集数据
  static Future<void> refreshHotTvShows() async {
    await _HotTvSectionState._currentInstance?._loadHotTvShows();
  }
}

class _HotTvSectionState extends State<HotTvSection> {
  List<DoubanMovie> _tvShows = [];
  bool _isLoading = true;
  bool _hasError = false;
  
  
  // 静态变量存储当前实例
  static _HotTvSectionState? _currentInstance;

  @override
  void initState() {
    super.initState();
    // 设置当前实例
    _currentInstance = this;
    _loadHotTvShows();
  }

  /// 加载热门剧集
  Future<void> _loadHotTvShows() async {
    if (!mounted) return;

    try {
      setState(() {
        _isLoading = true;
        _hasError = false;
      });

      // 直接调用 DoubanService（内部已做函数级缓存）
      final result = await DoubanService.getHotTvShows(context);
      if (!mounted) return;

      if (result.success && result.data != null) {
        setState(() {
          _tvShows = result.data!;
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
    return _tvShows.map((tvShow) => tvShow.toVideoInfo()).toList();
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
      title: '热门剧集',
      subtitle: '热播剧集',
      icon: Icons.tv,
      sectionColor: SectionColor.blue,
      moreText: '查看更多',
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
        widget.onTvTap?.call(playRecord);
      },
      onGlobalMenuAction: widget.onGlobalMenuAction,
      isLoading: _isLoading,
      hasError: _hasError,
      onRetry: _loadHotTvShows,
      cardCount: 2.75,
    );
  }
}
