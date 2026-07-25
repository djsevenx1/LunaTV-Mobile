// lib/danmaku/danmaku_manager.dart
// 弹幕管理器 — 自动选源 + 6 源并行 + 拉单集弹幕
//
// 工作流:
//   searchByTitle(title) → 6 源并行 searchMedia → 选最匹配 + 最多集数 → 返回 DanmakuMedia
//   loadDanmaku(media, episodeOrder) → 拿分集 → 拉弹幕
//   loadByEpisodeId(source, episodeId) → 直接拉 (已知 oid/episodeId 的场景)
//
// 全局单例, 默认 5 min 缓存.

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../services/diary_service.dart';
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

  late final Map<DanmakuSource, BaseDanmakuSource> _sources = {
    DanmakuSource.iqiyi: IqiyiDanmaku(),
    DanmakuSource.youku: YoukuDanmaku(),
    DanmakuSource.bilibili: BilibiliDanmaku(),
    DanmakuSource.tencent: TencentDanmaku(),
    DanmakuSource.mgtv: MgtvDanmaku(),
    DanmakuSource.le: LeDanmaku(),
  };

  /// 共享 Dio — 所有源共用. 必须带浏览器 UA, 否则多数弹幕 API 会拒绝.
  /// 各源在 getDanmaku 等方法里可通过 Options(headers: ...) 追加源专属头.
  static const String kDefaultUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  final Dio _sharedDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 12),
    // ★ responseType 必须是 plain: 默认 json 会导致 Dio 自动解码 JSON 为 Map,
    //   源码里 json.decode(r.data!) 会因 r.data 已是 Map 而崩溃.
    //   plain 保证 r.data 始终是 String, 由各源自行 json.decode.
    responseType: ResponseType.plain,
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    },
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
    await DiaryService.add('[弹幕] 搜索: "$title" (${list.length}源并行)');
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
    await DiaryService.add('[弹幕] 搜索完成: ${merged.length}条结果');
    return merged;
  }

  Future<List<DanmakuMedia>> _safeSearch(BaseDanmakuSource src, String kw) async {
    try {
      final r = await src.searchMedia(kw, dio: _sharedDio)
          .timeout(const Duration(seconds: 10), onTimeout: () => []);
      await DiaryService.add('[弹幕] ${src.sourceEnum.displayName} 搜索: ${r.length}条'
          '${r.isEmpty ? " (空/超时)" : ""}');
      return r;
    } catch (e) {
      await DiaryService.add('[弹幕] ${src.sourceEnum.displayName} 搜索异常: $e');
      return const [];
    }
  }

  /// 搜索单个源 — 供弹幕面板逐源检查用 (10s 超时)
  Future<List<DanmakuMedia>> searchSingleSource(
    DanmakuSource source,
    String title,
  ) async {
    final src = _sources[source];
    if (src == null) return [];
    try {
      return await src.searchMedia(title, dio: _sharedDio)
          .timeout(const Duration(seconds: 10), onTimeout: () => []);
    } catch (_) {
      return const [];
    }
  }

  /// 拿分集 (10s 超时)
  Future<List<DanmakuEpisode>> getEpisodes(
    DanmakuSource source,
    String mediaId,
  ) async {
    final src = _sources[source];
    if (src == null) return [];
    try {
      final eps = await src.getEpisodes(mediaId, dio: _sharedDio)
          .timeout(const Duration(seconds: 10), onTimeout: () => []);
      await DiaryService.add('[弹幕] ${source.displayName} 分集: ${eps.length}集'
          '${eps.isEmpty ? " (空/超时)" : ""}');
      return eps;
    } catch (e) {
      await DiaryService.add('[弹幕] ${source.displayName} 分集异常: $e');
      return [];
    }
  }

  /// 拉弹幕 — 整集
  /// ★ v2.5.52: 8s 超时, 超时返回空 (调用方自动试下一个源)
  ///   旧问题: Completer + partial 方案中 partial 永远为空 (getDanmaku 一次性返回),
  ///           超时后返回空列表 = 跟没加一样. 改为直接 timeout, 8s 更短,
  ///           配合调用方依次尝试 3 个源, 总耗时最多 24s.
  Future<List<DanmakuComment>> loadDanmaku(
    DanmakuSource source,
    String episodeId, {
    int startSec = 0,
    int endSec = 0,
  }) async {
    final src = _sources[source];
    if (src == null) return [];
    debugPrint('[DanmakuManager] loadDanmaku: source=${source.key} '
        'episodeId=$episodeId startSec=$startSec endSec=$endSec');
    await DiaryService.add('[弹幕] ${source.displayName} 开始拉取: eid=$episodeId');
    try {
      final result = await src.getDanmaku(
        episodeId,
        startSec: startSec,
        endSec: endSec,
        dio: _sharedDio,
      ).timeout(const Duration(seconds: 8), onTimeout: () {
        debugPrint('[DanmakuManager] loadDanmaku TIMEOUT (8s): ${source.key}');
        return <DanmakuComment>[];
      });
      debugPrint('[DanmakuManager] loadDanmaku result: ${source.key} → ${result.length}');
      await DiaryService.add('[弹幕] ${source.displayName} 拉取完成: ${result.length}条'
          '${result.isEmpty ? " (空/超时)" : ""}');
      return result;
    } catch (e) {
      debugPrint('[DanmakuManager] loadDanmaku error: ${source.key} → $e');
      await DiaryService.add('[弹幕] ${source.displayName} 拉取异常: $e');
      return [];
    }
  }

  /// v2.5.52: 并行试多个源拉弹幕, 用第一个非空结果
  ///   解决"等半天没弹幕": 不再串行试 3 个源 (每个 8s = 24s),
  ///   而是同时发 3 个请求, 谁先返回非空就用谁, 总耗时 ≤ 8s.
  ///   [candidates] = [(source, episodeId), ...] 已按评分排序
  Future<({DanmakuSource source, List<DanmakuComment> comments})?>
  loadDanmakuParallel(
    List<(DanmakuSource, String)> candidates,
  ) async {
    if (candidates.isEmpty) return null;
    await DiaryService.add('[弹幕] 并行加载: ${candidates.length}个候选源');
    final completer =
        Completer<({DanmakuSource source, List<DanmakuComment> comments})?>();
    var remaining = candidates.length;

    for (final (source, episodeId) in candidates) {
      loadDanmaku(source, episodeId).then((list) {
        if (!completer.isCompleted && list.isNotEmpty) {
          completer.complete((source: source, comments: list));
        } else {
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        }
      }).catchError((e) {
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      });
    }

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        debugPrint('[DanmakuManager] loadDanmakuParallel TIMEOUT (10s)');
        return null;
      },
    );
  }

  /// 自动选源: 给定标题 + (可选) 类型 (movie/tv) + (可选) 年份
  /// ★ v2.5.51: 移植 SeleneTV ph0.java 评分算法
  ///   - 标题归一化 + Levenshtein 编辑距离
  ///   - 季数提取与匹配
  ///   - 黑名单过滤 (NCOP/NCED/OVA/ED/SP/特典/预告/广告/花絮/速看/PV/番外)
  ///   - 多级评分: 完全相等 > 去季号相同+季数匹配 > 子串包含+季数匹配 > 相似度≥85%+季数匹配
  Future<DanmakuMatch?> autoMatch({
    required String title,
    int? year,
    String? type, // 'movie' | 'tv'
  }) async {
    final kw = title.trim();
    if (kw.isEmpty) return null;
    final results = await searchByTitle(kw);
    if (results.isEmpty) return null;
    final scored = DanmakuScorer.score(kw, results, year: year, type: type);
    if (scored.isEmpty) return null;
    await DiaryService.add('[弹幕] 自动匹配: 最优=${scored.first.media.source.displayName} '
        '"${scored.first.media.title}" score=${scored.first.score}');
    return DanmakuMatch(media: scored.first.media, score: scored.first.score);
  }
}

// ─── SeleneTV ph0.java 评分算法移植 (v2.5.51) ───────────────────────────
//   评分逻辑:
//     1. 黑名单过滤: 剔除标题含 NCOP/NCED/OVA/ED/SP/特典/预告/广告/花絮/速看/PV/番外
//     2. 标题归一化: 去符号转小写
//     3. 季数提取: 正则识别 Season N / 第N季 / 第N部 / 罗马数字等
//     4. Levenshtein 编辑距离 → 相似度百分比
//     5. 评分:
//        - 归一化后完全相等 → 10000
//        - 去季号后相同 + 季数一致 → similarity + 5000
//        - 子串包含 (≥4字) + 季数一致 → similarity + 3000
//        - 相似度 ≥85% + 季数一致 → similarity
//        - 其他 → 0 (丢弃)
class DanmakuScorer {
  // 中文黑名单 — 完整词汇匹配, 不会误杀正常标题
  static final RegExp _cnBlacklist = RegExp(
    r'特典|预告片|广告|花絮|速看|番外篇|彩蛋',
  );
  // 英文黑名单 — 只匹配明确的番外缩写, 加词边界防止误杀
  // ★ v2.5.52: 修复 OP/ED/SP/PV/MV/CM 误杀英文标题 (如 Operation, Red, Spider)
  //   只保留足够特殊的复合词 NCOP/NCED/OVA/OAD, 短词加 \b 词边界
  static final RegExp _enBlacklist = RegExp(
    r'\bNCOP\b|\bNCED\b|\bOVA\b|\bOAD\b|\bOP版\b|\bED版\b|\bPV版\b|\bopening\b|\bending\b',
    caseSensitive: false,
  );

  // 标题归一化: 去掉 《》「」[]()·:：-—_~!？,. 空格等, 转小写
  static final RegExp _normalizeRe = RegExp(
    r'[《》「」\[\]\(\)·:：\-—_~！？,.\s/\\|]',
  );

  // 季数提取正则 (SeleneTV ph0.d)
  static final List<RegExp> _seasonPatterns = [
    RegExp(r'(?:S|Season)\s*(\d+)', caseSensitive: false),
    RegExp(r'第([一二三四五六七八九十])[季部幕]'),
    RegExp(r'第(\d+)[季部幕]'),
    RegExp(r'([ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫ])'),
    RegExp(r'(IV|XL|CD|IX|VI|VII|VIII|XI|XII)', caseSensitive: false),
  ];

  /// 对搜索结果评分排序
  static List<DanmakuMatch> score(
    String queryTitle,
    List<DanmakuMedia> results, {
    int? year,
    String? type,
  }) {
    final out = <DanmakuMatch>[];

    // 1) 黑名单过滤
    final filtered = results.where((m) {
      final t = m.title;
      if (_cnBlacklist.hasMatch(t) || _enBlacklist.hasMatch(t)) return false;
      return true;
    }).toList();

    // 2) 评分
    final normQuery = normalize(queryTitle);
    final seasonQuery = extractSeason(queryTitle);

    for (final m in filtered) {
      final normCandidate = normalize(m.title);
      final seasonCandidate = extractSeason(m.title);
      final seasonMatch = seasonQuery == seasonCandidate;

      int score = 0;

      if (normQuery == normCandidate) {
        // 完全相等 → 满分
        score = 10000;
      } else {
        final baseQuery = stripSeason(normQuery);
        final baseCandidate = stripSeason(normCandidate);

        if (baseQuery == baseCandidate) {
          // 去季号后相同
          if (seasonMatch) {
            score = similarity(normQuery, normCandidate) + 5000;
          }
        } else if (baseQuery.length >= 4 &&
            baseCandidate.contains(baseQuery) &&
            seasonMatch) {
          // 子串包含
          score = similarity(baseQuery, baseCandidate) + 3000;
        } else if (baseCandidate.length >= 4 &&
            baseQuery.contains(baseCandidate) &&
            seasonMatch) {
          score = similarity(baseQuery, baseCandidate) + 3000;
        } else {
          // Levenshtein 相似度
          final sim = similarity(baseQuery, baseCandidate);
          if (sim >= 85 && seasonMatch) {
            score = sim;
          }
        }
      }

      // 年份/类型加分 (LunaTV 扩展, SeleneTV 无此逻辑)
      if (score > 0) {
        if (year != null && m.year == year) score += 5;
        if (type != null && m.type == type) score += 3;
      }

      if (score > 0) {
        out.add(DanmakuMatch(media: m, score: score));
      }
    }

    // 3) 按分数降序
    out.sort((a, b) => b.score - a.score);
    return out;
  }

  /// 标题归一化 (SeleneTV ph0.a)
  static String normalize(String s) {
    return s.replaceAll(_normalizeRe, '').toLowerCase();
  }

  /// 季数提取 (SeleneTV ph0.d) — 提取季数用于匹配
  /// 返回 null 表示无法识别季数 (视为 "无季号", 匹配时视作一致)
  static int? extractSeason(String s) {
    // 中文数字映射
    const cnMap = {
      '一': 1, '二': 2, '三': 3, '四': 4, '五': 5,
      '六': 6, '七': 7, '八': 8, '九': 9, '十': 10,
    };
    const romanMap = {
      'Ⅰ': 1, 'Ⅱ': 2, 'Ⅲ': 3, 'Ⅳ': 4, 'Ⅴ': 5,
      'Ⅵ': 6, 'Ⅶ': 7, 'Ⅷ': 8, 'Ⅸ': 9, 'Ⅹ': 10, 'Ⅺ': 11, 'Ⅻ': 12,
    };

    for (final re in _seasonPatterns) {
      final m = re.firstMatch(s);
      if (m != null) {
        final g = m.group(1)!;
        // 中文数字
        if (cnMap.containsKey(g)) return cnMap[g];
        // 罗马数字 (Unicode)
        if (romanMap.containsKey(g)) return romanMap[g];
        // 罗马数字 (ASCII)
        final roman = _parseRoman(g);
        if (roman != null) return roman;
        // 阿拉伯数字
        final n = int.tryParse(g);
        if (n != null) return n;
      }
    }
    return null;
  }

  static int? _parseRoman(String s) {
    const vals = {'I': 1, 'V': 5, 'X': 10, 'L': 50, 'C': 100, 'D': 500, 'M': 1000};
    final up = s.toUpperCase();
    if (!up.split('').every((c) => vals.containsKey(c))) return null;
    int result = 0;
    for (var i = 0; i < up.length; i++) {
      final v = vals[up[i]]!;
      if (i + 1 < up.length && v < vals[up[i + 1]]!) {
        result -= v;
      } else {
        result += v;
      }
    }
    return result > 0 ? result : null;
  }

  /// 去掉季号后缀 (SeleneTV ph0.f) — 用于主干标题比较
  static final RegExp _stripSeasonRe = RegExp(
    r'(?:第[一二三四五六七八九十\d]+[季部幕])|(?:S\s*\d+)|(?:Season\s*\d+)|([ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫ])|(?:第\d+季)|(?:之章)',
    caseSensitive: false,
  );
  static String stripSeason(String s) {
    return s.replaceAll(_stripSeasonRe, '');
  }

  /// Levenshtein 编辑距离 → 相似度百分比 (SeleneTV ph0.c)
  /// 返回 0-100
  static int similarity(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 100;
    if (a.isEmpty || b.isEmpty) return 0;
    final maxLen = a.length > b.length ? a.length : b.length;
    if (maxLen == 0) return 100;
    final dist = _levenshtein(a, b);
    return ((1 - dist / maxLen) * 100).round().clamp(0, 100);
  }

  static int _levenshtein(String s1, String s2) {
    final l1 = s1.length;
    final l2 = s2.length;
    if (l1 == 0) return l2;
    if (l2 == 0) return l1;

    // 滚动数组优化
    var prev = List<int>.generate(l2 + 1, (i) => i);
    var curr = List<int>.filled(l2 + 1, 0);

    for (var i = 1; i <= l1; i++) {
      curr[0] = i;
      for (var j = 1; j <= l2; j++) {
        final cost = s1[i - 1] == s2[j - 1] ? 0 : 1;
        curr[j] = [
          prev[j] + 1,     // 删除
          curr[j - 1] + 1, // 插入
          prev[j - 1] + cost, // 替换
        ].reduce((a, b) => a < b ? a : b);
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[l2];
  }
}

class DanmakuMatch {
  final DanmakuMedia media;
  final int score;
  const DanmakuMatch({required this.media, required this.score});
}
