import 'package:flutter/material.dart';
import 'package:luna_tv/models/play_record.dart';
import 'package:luna_tv/models/short_drama.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/services/short_drama_service.dart';
import 'package:luna_tv/widgets/video_menu_bottom_sheet.dart';
import 'package:luna_tv/widgets/recommendation_section.dart';
import 'package:luna_tv/widgets/section_title.dart';

/// 热门短剧组件
class HotShortDramaSection extends StatefulWidget {
  final Function(PlayRecord)? onDramaTap;
  final VoidCallback? onMoreTap;
  final Function(VideoInfo, VideoMenuAction)? onGlobalMenuAction;

  const HotShortDramaSection({
    super.key,
    this.onDramaTap,
    this.onMoreTap,
    this.onGlobalMenuAction,
  });

  @override
  State<HotShortDramaSection> createState() => _HotShortDramaSectionState();

  /// 静态方法：刷新热门短剧数据
  static Future<void> refreshHotShortDramas() async {
    await _HotShortDramaSectionState._currentInstance?._loadHotDramas();
  }
}

class _HotShortDramaSectionState extends State<HotShortDramaSection> {
  List<ShortDrama> _dramas = [];
  bool _isLoading = true;
  bool _hasError = false;

  static _HotShortDramaSectionState? _currentInstance;

  @override
  void initState() {
    super.initState();
    _currentInstance = this;
    _loadHotDramas();
  }

  /// 加载热门短剧（取第一个分类的第一页数据）
  Future<void> _loadHotDramas() async {
    if (!mounted) return;

    try {
      setState(() {
        _isLoading = true;
        _hasError = false;
      });

      final categories = await ShortDramaService.getCategories();
      if (!mounted) return;

      if (categories.isEmpty) {
        setState(() {
          _hasError = true;
          _isLoading = false;
        });
        return;
      }

      final result = await ShortDramaService.getList(
        categoryId: categories.first.typeId,
        page: 1,
        size: 12,
      );
      if (!mounted) return;

      if (result.list.isNotEmpty) {
        setState(() {
          _dramas = result.list;
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
    return _dramas.map((drama) {
      final cover = drama.backdrop.isNotEmpty ? drama.backdrop : drama.cover;
      return VideoInfo(
        id: drama.id.toString(),
        source: '',
        title: drama.name,
        sourceName: '',
        year: '',
        cover: cover,
        index: 0,
        totalEpisodes: drama.episodeCount,
        playTime: 0,
        totalTime: 0,
        saveTime: 0,
        searchTitle: drama.name,
        rate: drama.score > 0 ? drama.score.toStringAsFixed(1) : null,
      );
    }).toList();
  }

  @override
  void dispose() {
    if (_currentInstance == this) {
      _currentInstance = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RecommendationSection(
      title: '热门短剧',
      subtitle: '精彩短剧',
      icon: Icons.movie,
      sectionColor: SectionColor.red,
      moreText: '查看更多',
      onMoreTap: widget.onMoreTap,
      videoInfos: _convertToVideoInfos(),
      onItemTap: (videoInfo) {
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
        widget.onDramaTap?.call(playRecord);
      },
      onGlobalMenuAction: widget.onGlobalMenuAction,
      isLoading: _isLoading,
      hasError: _hasError,
      onRetry: _loadHotDramas,
      cardCount: 2.75,
    );
  }
}
