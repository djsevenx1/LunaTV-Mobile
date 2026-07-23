// lib/danmaku/models/danmaku_media.dart
// 剧集搜索结果 — 对应 SeleneTV DanmakuMedia(source, mediaId, title, type, year, poster, episodeCount)

enum DanmakuSource { iqiyi, youku, bilibili, tencent, mgtv, le }

extension DanmakuSourceName on DanmakuSource {
  String get key {
    switch (this) {
      case DanmakuSource.iqiyi:    return 'iqiyi';
      case DanmakuSource.youku:    return 'youku';
      case DanmakuSource.bilibili: return 'bilibili';
      case DanmakuSource.tencent:  return 'tencent';
      case DanmakuSource.mgtv:     return 'mgtv';
      case DanmakuSource.le:       return 'le';
    }
  }

  String get displayName {
    switch (this) {
      case DanmakuSource.iqiyi:    return '爱奇艺';
      case DanmakuSource.youku:    return '优酷';
      case DanmakuSource.bilibili: return 'B站';
      case DanmakuSource.tencent:  return '腾讯视频';
      case DanmakuSource.mgtv:     return '芒果TV';
      case DanmakuSource.le:       return '乐视';
    }
  }
}

class DanmakuMedia {
  final DanmakuSource source;
  final String mediaId;          // 剧 ID (给 getEpisodes)
  final String title;
  final String type;             // "movie" | "tv"
  final int? year;
  final String? poster;
  final int episodeCount;        // 默认 80 (从 SeleneTV)

  const DanmakuMedia({
    required this.source,
    required this.mediaId,
    required this.title,
    required this.type,
    this.year,
    this.poster,
    this.episodeCount = 80,
  });

  bool get isMovie => type == 'movie';
}

class DanmakuEpisode {
  final DanmakuSource source;
  final String episodeId;        // 集 ID (给 getDanmaku)
  final int order;
  final String title;

  const DanmakuEpisode({
    required this.source,
    required this.episodeId,
    required this.order,
    required this.title,
  });
}
