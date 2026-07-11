import 'package:luna_tv/models/play_record.dart';

/// 视频信息数据模型，用于VideoCard展示
class VideoInfo {
  final String id;
  final String source; // 来源标识
  final String title;
  final String sourceName;
  final String year;
  final String cover;
  final int index;
  final int totalEpisodes;
  final int playTime;
  final int totalTime;
  final int saveTime;
  final String searchTitle;
  final String? doubanId; // 豆瓣ID，用于豆瓣模式
  final int? bangumiId; // Bangumi ID，用于Bangumi模式
  final String? rate; // 评分，用于豆瓣模式
  // v2.0.84: 16:9 横版 cover_url (l_cover 1280x720). 详情页大头部用,
  //   比竖版海报 (l_ratio_poster 600x900) 在平板/横屏清晰
  final String? coverUrl;

  VideoInfo({
    required this.id,
    required this.source,
    required this.title,
    required this.sourceName,
    required this.year,
    required this.cover,
    required this.index,
    required this.totalEpisodes,
    required this.playTime,
    required this.totalTime,
    required this.saveTime,
    required this.searchTitle,
    this.doubanId,
    this.bangumiId,
    this.rate,
    this.coverUrl,
  });

  /// 从PlayRecord创建VideoInfo
  factory VideoInfo.fromPlayRecord(PlayRecord playRecord, {
    String? doubanId,
    int? bangumiId,
    String? rate,
    String? coverUrl,
  }) {
    return VideoInfo(
      id: playRecord.id,
      source: playRecord.source,
      title: playRecord.title,
      sourceName: playRecord.sourceName,
      year: playRecord.year,
      cover: playRecord.cover,
      index: playRecord.index,
      totalEpisodes: playRecord.totalEpisodes,
      playTime: playRecord.playTime,
      totalTime: playRecord.totalTime,
      saveTime: playRecord.saveTime,
      searchTitle: playRecord.searchTitle,
      doubanId: doubanId,
      bangumiId: bangumiId,
      rate: rate,
      coverUrl: coverUrl,
    );
  }

  /// 从JSON创建VideoInfo
  factory VideoInfo.fromJson(String key, Map<String, dynamic> json) {
    // 从key中分离source和id，格式为 "source+id"
    final parts = key.split('+');
    final source = parts.length > 1 ? parts[0] : '';
    final id = parts.length > 1 ? parts[1] : key;

    return VideoInfo(
      id: id,
      source: source,
      title: json['title'] ?? '',
      sourceName: json['source_name'] ?? '',
      year: json['year'] ?? '',
      cover: json['cover'] ?? '',
      index: json['index'] ?? 0,
      totalEpisodes: json['total_episodes'] ?? 0,
      playTime: json['play_time'] ?? 0,
      totalTime: json['total_time'] ?? 0,
      saveTime: json['save_time'] ?? 0,
      searchTitle: json['search_title'] ?? '',
      doubanId: json['douban_id'],
      bangumiId: json['bangumi_id'],
      rate: json['rate'],
      coverUrl: json['cover_url'],
    );
  }

  /// 转换为JSON
  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'source_name': sourceName,
      'year': year,
      'cover': cover,
      'cover_url': coverUrl,
      'index': index,
      'total_episodes': totalEpisodes,
      'play_time': playTime,
      'total_time': totalTime,
      'save_time': saveTime,
      'search_title': searchTitle,
      'douban_id': doubanId,
      'bangumi_id': bangumiId,
      'rate': rate,
    };
  }

  /// 获取播放进度百分比
  double get progressPercentage {
    if (totalTime <= 0) return 0.0;
    return (playTime / totalTime).clamp(0.0, 1.0);
  }

  /// 格式化播放时间
  String get formattedPlayTime {
    final hours = playTime ~/ 3600;
    final minutes = (playTime % 3600) ~/ 60;
    final seconds = playTime % 60;
    
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
  }

  /// 格式化总时间
  String get formattedTotalTime {
    final hours = totalTime ~/ 3600;
    final minutes = (totalTime % 3600) ~/ 60;
    final seconds = totalTime % 60;
    
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
  }
}
