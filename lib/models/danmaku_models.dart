// v2.3.12: 弹幕数据模型.
//   1:1 移植自 Selene-TV org.moontechlab.selenetv.model.DanmakuComment +
//   org.moontechlab.selenenetv.service.danmaku.DanmakuEpisode +
//   org.moontechlab.selenetv.service.danmaku.DanmakuMedia.
//
// Dart 没有 `Long` 类型, 64 位整型用 int (Dart int 在 64-bit VM 是 64-bit).
// B站 弹幕用 protobuf 编码, 之前 Selene-TV 走 raw HTTP + 正则解 XML (老接口),
// 我们也跟 Selene-TV 走 XML 老接口, 不依赖 protobuf 库.

/// 单条弹幕.
///
/// 字段语义跟 Selene-TV 完全一致:
///   - [timeMs]: 弹幕出现时间 (毫秒), 从视频开头算
///   - [mode]: 1=滚动 (scroll), 3=底部 (bottom), 5=顶部 (top)
///   - [color]: RGB 整数 (e.g. 0xFFFFFF = 白色)
///   - [text]: 弹幕内容, 已经是 HTML 反转义后的纯文本
class DanmakuComment {
  final int timeMs;
  final int mode; // 1=scroll, 3=bottom, 5=top
  final int color; // RGB int, 跟 B站协议一致
  final String text;

  /// v2.3.12: 内部状态 (UI 端轨道分配用, 不参与 equals / hashCode).
  ///   - [_trackIndex] 滚动弹幕分配的轨道 (-1 = 未分配)
  ///   - [_estimatedWidth] 估算文字宽度, 算滚动进度用
  int _trackIndex;
  double _estimatedWidth;

  DanmakuComment({
    required this.timeMs,
    required this.mode,
    required this.color,
    required this.text,
    int trackIndex = -1,
    double estimatedWidth = 0.0,
  })  : _trackIndex = trackIndex,
        _estimatedWidth = estimatedWidth;

  /// 滚动 (right-to-left) 弹幕 — mode 1
  bool get isScroll => mode == 1;

  /// 底部固定弹幕 — mode 3
  bool get isBottom => mode == 3 || mode == 4;

  /// 顶部固定弹幕 — mode 5
  bool get isTop => mode == 5 || mode == 6;

  /// v2.3.12: UI 端 (danmaku_overlay.dart) 用, 设轨道 / 估算宽度.
  set trackIndex(int v) => _trackIndex = v;
  int get trackIndex => _trackIndex;

  set estimatedWidth(double v) => _estimatedWidth = v;
  double get estimatedWidth => _estimatedWidth;

  @override
  String toString() =>
      'DanmakuComment(timeMs=$timeMs, mode=$mode, color=$color, text="$text")';
}

/// 剧集列表中的一项 (跟 Selene-TV `DanmakuEpisode` 对齐).
///
/// [provider] 标识源, e.g. "bilibili" / "tencent" / "youku" / "iqiyi" /
///             "mgtv" / "letv".
/// [episodeId] 该源内部的剧集 id, e.g. B站 oid (cid).
/// [title] 剧集标题.
/// [episodeIndex] 1-based 集数 (跟 player_screen episode index 一致).
class DanmakuEpisode {
  final String provider;
  final String episodeId;
  final String title;
  final int episodeIndex;

  const DanmakuEpisode({
    required this.provider,
    required this.episodeId,
    required this.title,
    required this.episodeIndex,
  });

  @override
  String toString() =>
      'DanmakuEpisode(provider=$provider, episodeId=$episodeId, title=$title, episodeIndex=$episodeIndex)';
}

/// 媒体条目 (跟 Selene-TV `DanmakuMedia` 对齐).
///
/// [provider] 源标识, e.g. "bilibili".
/// [mediaId] 该源内部的 media id, e.g. B站 `ss12345` 或 `BV1xx` 形式.
/// [title] 媒体标题 (剧名).
/// [type] "tvseries" / "movie" / "anime" 等, 跟 Selene-TV 默认 "tvseries" 一致.
/// [season] 第几季 (nullable, B站 ss id 才有意义).
/// [year] 上映年份 (nullable).
/// [episodeCount] 总集数 (nullable, 用于展示).
class DanmakuMedia {
  final String provider;
  final String mediaId;
  final String title;
  final String type;
  final int? season;
  final int? year;
  final int? episodeCount;

  const DanmakuMedia({
    required this.provider,
    required this.mediaId,
    required this.title,
    this.type = 'tvseries',
    this.season,
    this.year,
    this.episodeCount,
  });

  @override
  String toString() =>
      'DanmakuMedia(provider=$provider, mediaId=$mediaId, title=$title, type=$type, season=$season, year=$year, episodeCount=$episodeCount)';
}
