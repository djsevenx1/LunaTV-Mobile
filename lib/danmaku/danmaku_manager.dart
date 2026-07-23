// lib/danmaku/danmaku_manager.dart
// 弹幕管理器 — 自动选源 + 6 源并行 + 拉单集弹幕
//
// 工作流:
//   searchByTitle(title) → 6 源并行 searchMedia → 选最匹配 + 最多集数 → 返回 DanmakuMedia
//   loadDanmaku(media, episodeOrder) → 拿分集 → 拉弹幕
//   loadByEpisodeId(source, episodeId) → 直接拉 (已知 oid/episodeId 的场景)
//
// 全局单例, 默认 5 min 缓存.

import 'package:dio/dio.dart';

import 'models/danmaku_comment.dart';
import 'models/danmaku_media.dart';
import 'sources/bilibili_danmaku.dart';
import 'sources/danmaku_source.dart';
import 'sources/iqiyi_danmaku.dart';
import 'sources/le_danmaku.dart';
import 'sources/mgtv_danmaku.dart';
import 'sources/tencent_danmaku.dart';
import 'sources/youku_danmaku.dart';

class DanmakuManager {
  DanmakuManager._();
  static final DanmakuManager instance = DanmakuManager._();

  late final Map<DanmakuSource, DanmakuSource> _sources = {
    DanmakuSource.iqiyi: IqiyiDanmaku(),
    DanmakuSource.youku: YoukuDanmaku(),
    DanmakuSource.bilibili: BilibiliDanmaku(),
    DanmakuSource.tencent: TencentDanmaku(),
    DanmakuSource.mgtv: MgtvDanmaku(),
    DanmakuSource.le: LeDanmaku(),
  };

  final Dio _sharedDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 12),
  ));

  // 用户偏好: 优先哪些源, 顺序就是优先级
  List<DanmakuSource> _preferred = const [
    DanmakuSource.bilibili,
    DanmakuSource.iqiyi,
    DanmakuSource.youku,
    DanmakuSource.tencent,
    DanmakuSource.mgtv,
    DanmakuSource.le,
  ];
  List<DanmakuSource> get preferred => List.unmodifiable(_preferred);
  set preferred(List<DanmakuSource> v) {
    if (v.isEmpty) return;
    _preferred = List.unmodifiable(v);
  }

  DanmakuSource? sourceOf(DanmakuSource s) => _sources[s]?.sourceEnum;

  /// 跨源并行搜索, 返聚合列表 (去重 + 标注源)
  Future<List<DanmakuMedia>> searchByTitle(
    String title, {
    Set<DanmakuSource>? only,
  }) async {
    final list = only ?? _preferred;
    final futures = <Future<List<DanmakuMedia>>>[];
    for (final s in list) {
      final src = _sources[s];
      if (src == null) continue;
      futures.add(_safeSearch(src, title));
    }
    final results = await Future.wait(futures, eagerError: false);
    final merged = <DanmakuMedia>[];
    final seen = <String>{};
    for (final r in results) {
      for (final m in r) {
        // 按 (source, mediaId) 去重
        final k = '${m.source.key}:${m.mediaId}';
        if (seen.add(k)) merged.add(m);
      }
    }
    return merged;
  }

  Future<List<DanmakuMedia>> _safeSearch(BaseDanmakuSource src, String kw) async {
    try {
      return await src.searchMedia(kw, dio: _sharedDio);
    } catch (_) {
      return const [];
    }
  }

  /// 拿分集
  Future<List<DanmakuEpisode>> getEpisodes(
    DanmakuSource source,
    String mediaId,
  ) async {
    final src = _sources[source];
    if (src == null) return [];
    try {
      return await src.getEpisodes(mediaId, dio: _sharedDio);
    } catch (_) {
      return [];
    }
  }

  /// 拉弹幕 — 整集
  Future<List<DanmakuComment>> loadDanmaku(
    DanmakuSource source,
    String episodeId, {
    int startSec = 0,
    int endSec = 0,
  }) async {
    final src = _sources[source];
    if (src == null) return [];
    try {
      return await src.getDanmaku(
        episodeId,
        startSec: startSec,
        endSec: endSec,
        dio: _sharedDio,
      );
    } catch (_) {
      return [];
    }
  }

  /// 自动选源: 给定标题 + (可选) 类型 (movie/tv) + (可选) 年份
  /// 6 源并行搜索, 按评分选最优
  Future<DanmakuMatch?> autoMatch({
    required String title,
    int? year,
    String? type, // 'movie' | 'tv'
  }) async {
    final kw = title.trim();
    if (kw.isEmpty) return null;
    final results = await searchByTitle(kw);
    if (results.isEmpty) return null;
    // 评分: 标题完全包含 + 年份匹配 + 类型匹配
    DanmakuMedia? best;
    int bestScore = -1;
    for (final m in results) {
      var s = 0;
      if (m.title.contains(kw) || kw.contains(m.title)) s += 10;
      if (year != null && m.year == year) s += 5;
      if (type != null && m.type == type) s += 3;
      if (s > bestScore) {
        bestScore = s;
        best = m;
      }
    }
    if (best == null) return null;
    return DanmakuMatch(media: best, score: bestScore);
  }
}

class DanmakuMatch {
  final DanmakuMedia media;
  final int score;
  const DanmakuMatch({required this.media, required this.score});
}
