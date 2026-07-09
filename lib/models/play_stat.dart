/// 播放统计数据模型
class PlayStat {
  final String source;
  final String id;
  final String title;
  final String cover;
  final int playCount; // 播放次数
  final int totalDuration; // 总观看时长(秒)
  final String lastPlayTime; // 最后播放时间
  final String type; // movie/tv/anime/show

  PlayStat({
    required this.source,
    required this.id,
    required this.title,
    required this.cover,
    required this.playCount,
    required this.totalDuration,
    required this.lastPlayTime,
    required this.type,
  });

  /// 从JSON创建PlayStat
  factory PlayStat.fromJson(String key, Map<String, dynamic> json) {
    // 从key中分离source和id，格式为 "source+id"
    final parts = key.split('+');
    final source = parts.length > 1 ? parts[0] : '';
    final id = parts.length > 1 ? parts[1] : key;

    return PlayStat(
      source: source,
      id: id,
      title: json['title'] ?? '',
      cover: json['cover'] ?? '',
      playCount: json['play_count'] ?? 0,
      totalDuration: json['total_duration'] ?? 0,
      lastPlayTime: json['last_play_time'] ?? '',
      type: json['type'] ?? '',
    );
  }

  /// 转换为JSON
  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'cover': cover,
      'play_count': playCount,
      'total_duration': totalDuration,
      'last_play_time': lastPlayTime,
      'type': type,
    };
  }

  /// 格式化总观看时长
  String get formattedDuration {
    final hours = totalDuration ~/ 3600;
    final minutes = (totalDuration % 3600) ~/ 60;

    if (hours > 0) {
      return '$hours小时${minutes}分钟';
    } else {
      return '$minutes分钟';
    }
  }

  /// 获取类型显示名称
  String get typeDisplayName {
    switch (type) {
      case 'movie':
        return '电影';
      case 'tv':
        return '电视剧';
      case 'anime':
        return '动漫';
      case 'show':
        return '综艺';
      default:
        return type;
    }
  }
}
