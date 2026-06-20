import 'package:flutter/material.dart';
import 'package:luna_tv/models/bangumi.dart';
import 'package:luna_tv/models/play_record.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/services/bangumi_service.dart';
import 'package:luna_tv/widgets/recommendation_section.dart';
import 'package:luna_tv/widgets/section_title.dart';
import 'package:luna_tv/widgets/video_menu_bottom_sheet.dart';

/// 新番放送组件
class BangumiSection extends StatefulWidget {
  final Function(PlayRecord)? onBangumiTap;
  final VoidCallback? onMoreTap;
  final Function(VideoInfo, VideoMenuAction)? onGlobalMenuAction; // 全局菜单操作回调

  const BangumiSection({
    super.key,
    this.onBangumiTap,
    this.onMoreTap,
    this.onGlobalMenuAction,
  });

  @override
  State<BangumiSection> createState() => _BangumiSectionState();

  /// 静态方法：刷新新番放送数据
  static Future<void> refreshBangumiCalendar() async {
    await _BangumiSectionState._currentInstance?._loadBangumiCalendar();
  }
}

class _BangumiSectionState extends State<BangumiSection> {
  List<BangumiItem> _bangumiItems = [];
  bool _isLoading = true;
  bool _hasError = false;

  // 静态变量存储当前实例
  static _BangumiSectionState? _currentInstance;

  @override
  void initState() {
    super.initState();
    // 设置当前实例
    _currentInstance = this;
    _loadBangumiCalendar();
  }

  /// 加载新番放送数据
  Future<void> _loadBangumiCalendar() async {
    if (!mounted) return;

    try {
      setState(() {
        _isLoading = true;
        _hasError = false;
      });

      // 直接调用 BangumiService（内部函数级缓存）
      final result = await BangumiService.getTodayCalendar(context);
      if (!mounted) return;

      if (result.success && result.data != null) {
        setState(() {
          _bangumiItems = result.data!;
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
    return _bangumiItems.map((item) => item.toVideoInfo()).toList();
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
    // 创建评分映射
    final rateMap = <String, String>{};
    for (final item in _bangumiItems) {
      if (item.rating.score > 0) {
        // 如果是整数则添加.0，否则保留一位小数
        final score = item.rating.score;
        final formattedScore = score == score.toInt()
            ? '${score.toInt()}.0'
            : score.toStringAsFixed(1);
        rateMap[item.id.toString()] = formattedScore;
      }
    }

    return RecommendationSection(
      title: '新番放送',
      subtitle: '本季新番',
      icon: Icons.auto_awesome,
      sectionColor: SectionColor.pink,
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
        widget.onBangumiTap?.call(playRecord);
      },
      onGlobalMenuAction: widget.onGlobalMenuAction,
      isLoading: _isLoading,
      hasError: _hasError,
      onRetry: _loadBangumiCalendar,
      cardCount: 2.75,
    );
  }
}
