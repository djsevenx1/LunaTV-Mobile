// v2.0.93: TMDB 精准识别 — 从 Selene-TV v1.4.6 mk4.java 移植
//
// 移植来源 (jadx + baksmali 反编译):
//   - mk4.c() / mk4.h() → 标题清洗 (4 个 regex) + search/multi + 过滤
//   - mk4.a()           → images 端点 + backdrop/logo 优选
//   - rb3               → 缓存 key 模式 "tmdb_ref_{apiKey}_{title}"
//
// 设计要点:
//   1. 4 个标题清洗 regex 严格按 Selene-TV 源码抄 (英中各 2 个):
//      - \s+season\s+\d+$                "Stranger Things Season 2" → "Stranger Things"
//      - \s+season\s+[ivxlcdm]+$          "Show Season IV" → "Show"
//      - \s+\d+(st|nd|rd|th)\s+season$    "2nd Season Show" → "Show"
//      - \s*第\s*[0-9一二三四五六七八九十百]+\s*[季期]$   "剧名 第3季" → "剧名"
//   2. search/multi + media_type 过滤 (movie|tv) + year 过滤 (release_date /
//      first_air_date 前 4 位) + popularity 降序 — 跟 Selene-TV 完全一致.
//   3. backdrop 优选 (w1280, iso_639_1==null 优先 + vote_average DESC):
//      - "无语言" 标签的图通常是官方横版, 跟字少图, 适合做 16:9 大背景.
//   4. logo 优选 (w500, .png 后缀, zh > en > null 优先级 + vote DESC):
//      - .png 透底, 跟大背景叠好看; zh 优先, 没中文用英文.
//   5. 缓存 7 天 (TMDB 资源稳定, 不像豆瓣 24h cookie 失效).
//   6. API 走 worker 加速 (跟 v2.0.36 README 一致), 没 worker 直连.
//
// 用法:
//   final apiKey = UserDataService.getTmdbApiKeySync();
//   if (apiKey == null) return null;  // 没配 key, 行为完全不变
//   final ref = await TmdbService.search(title: '剧名', year: 2024);
//   if (ref == null) return null;
//   final art = await TmdbService.fetchArt(id: ref.id, mediaType: ref.mediaType);
//   final backdropUrl = art?.backdropUrl;  // w1280 backdrop URL
//   final logoUrl = art?.logoUrl;          // w500 logo URL

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:luna_tv/services/user_data_service.dart';

class TmdbService {
  static const _baseUrl = 'https://api.themoviedb.org/3';
  // TMDB 官方 image CDN: https://image.tmdb.org/t/p/{size}/{file_path}
  // file_path 形如 "/abc123.jpg", 所以 _imageBase 末尾不带斜杠
  static const _imageBase = 'https://image.tmdb.org/t/p';
  // 缓存 7 天 — TMDB 元数据稳定, 反复看同一部剧 0 网络
  static const _cacheTtl = Duration(days: 7);

  // v2.0.93: 4 个标题清洗 regex — 跟 Selene-TV mk4.c 完全一致.
  // Selene-TV 行为: while-loop 反复应用, 一次只删一个, 删完从开头继续扫
  // (因为前一段删了可能暴露新的尾部可清洗段).
  static final List<RegExp> _cleanPatterns = [
    RegExp(r'\s+season\s+\d+$', caseSensitive: false),
    RegExp(r'\s+season\s+[ivxlcdm]+$', caseSensitive: false),
    RegExp(r'\s+\d+(st|nd|rd|th)\s+season$', caseSensitive: false),
    RegExp(r'\s*第\s*[0-9一二三四五六七八九十百]+\s*[季期]$'),
  ];

  /// 清洗标题 — 反复应用 4 个 regex, 一次只删一个匹配, 删完重头扫.
  ///
  /// Selene-TV 行为 (mk4.c 源码):
  ///   while (true) {
  ///     String next = stripFirst(input, p1) ?? stripFirst(input, p2) ?? ...;
  ///     if (next == null) break;
  ///     input = next;
  ///   }
  /// 这里用 firstMatch 替代, 一次只删一个 pattern, 避免 allMatches 在
  /// overlapping 时混乱.
  static String cleanTitle(String title) {
    var current = title.trim();
    var changed = true;
    while (changed) {
      changed = false;
      for (final p in _cleanPatterns) {
        final m = p.firstMatch(current);
        if (m != null) {
          current = current.substring(0, m.start).trimRight();
          changed = true;
          break;
        }
      }
    }
    return current.trim();
  }

  /// 构造 API URL — 配了 worker 走 worker 加速, 没配直连.
  /// 跟 v2.0.36 README "走 CORSAPI worker 加速" 一致.
  static String _wrapWithWorker(String fullUrl) {
    final worker = UserDataService.getCfWorkerDomainSync();
    if (worker.isNotEmpty) {
      return 'https://$worker/?url=${Uri.encodeComponent(fullUrl)}';
    }
    return fullUrl;
  }

  /// search/multi 拿精准 (mediaType, id).
  ///
  /// 严格按 Selene-TV mk4.h 行为:
  ///   1. include_adult=false
  ///   2. media_type in ["movie", "tv"]
  ///   3. year 过滤: release_date / first_air_date 前 4 位 == year
  ///   4. 选 popularity 最大的
  ///   5. 没结果返 null
  ///
  /// 缓存 key: "tmdb_ref_{cleanedTitle}_{year}" — 跟 Selene-TV rb3 一致
  /// (他们用 apiKey 是为了多账号, 我们只有 1 个所以用 title 即可).
  static Future<({String mediaType, int id})?> search({
    required String title,
    int? year,
  }) async {
    final cleaned = cleanTitle(title);
    if (cleaned.isEmpty) return null;

    final apiKey = UserDataService.getTmdbApiKeySync();
    if (apiKey == null || apiKey.isEmpty) return null;

    // 1) 缓存查
    final cacheKey = 'tmdb_ref_${cleaned}_${year ?? ""}';
    final cached = await _readRefCache(cacheKey);
    if (cached != null) return cached;

    // 2) search/multi 请求
    final params = <String, String>{
      'api_key': apiKey,
      'query': cleaned,
      'include_adult': 'false',
      'page': '1',
    };
    if (year != null) params['year'] = year.toString();
    final query =
        params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    final url = _wrapWithWorker('$_baseUrl/search/multi?$query');

    final http.Response resp;
    try {
      resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
    if (resp.statusCode != 200) return null;

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final results = (json['results'] as List?) ?? [];

    String? bestMediaType;
    int? bestId;
    double bestPopularity = -1;
    for (final r in results) {
      if (r is! Map) continue;
      final mediaType = r['media_type'] as String?;
      if (mediaType != 'movie' && mediaType != 'tv') continue;

      // year 过滤 — release_date / first_air_date 前 4 位
      if (year != null) {
        final dateField = mediaType == 'movie' ? 'release_date' : 'first_air_date';
        final date = r[dateField] as String?;
        if (date == null || !date.startsWith(year.toString())) continue;
      }

      final popularity = (r['popularity'] as num?)?.toDouble() ?? 0;
      if (popularity > bestPopularity) {
        bestPopularity = popularity;
        bestMediaType = mediaType;
        bestId = r['id'] as int?;
      }
    }

    if (bestMediaType == null || bestId == null) return null;

    final result = (mediaType: bestMediaType, id: bestId);
    await _writeRefCache(cacheKey, result);
    return result;
  }

  /// images 端点拿 backdrop + logo 优选.
  ///
  /// 跟 Selene-TV mk4.a 行为:
  ///   1. backdrop 优选 w1280, iso_639_1==null 优先, vote_average DESC
  ///   2. logo 优选 w500, .png 后缀, zh > en > null 优先级, vote DESC
  ///   3. 两次请求 (无语言 + zh-CN), 合并去重, 按上面规则选
  ///
  /// 缓存 key: "tmdb_art_{mediaType}_{id}"
  static Future<TmdbArt?> fetchArt({
    required int id,
    required String mediaType,
  }) async {
    final apiKey = UserDataService.getTmdbApiKeySync();
    if (apiKey == null || apiKey.isEmpty) return null;

    // 缓存查
    final cacheKey = 'tmdb_art_${mediaType}_$id';
    final cached = await _readArtCache(cacheKey);
    if (cached != null) return cached;

    // 1) 无语言版本 (backdrop 优选无语言, 跟 v2.0.43 风格一致)
    // 2) zh-CN 版本 (logo 优选中文, 跟 v2.0.43 风格一致)
    final noLangUrl = _wrapWithWorker(
        '$_baseUrl/$mediaType/$id/images?api_key=$apiKey');
    final zhUrl = _wrapWithWorker(
        '$_baseUrl/$mediaType/$id/images?api_key=$apiKey&language=zh-CN');

    final List<http.Response> responses;
    try {
      responses = await Future.wait([
        http.get(Uri.parse(noLangUrl)).timeout(const Duration(seconds: 10)),
        http.get(Uri.parse(zhUrl)).timeout(const Duration(seconds: 10)),
      ]);
    } catch (_) {
      return null;
    }
    if (responses[0].statusCode != 200) return null;

    Map<String, dynamic> noLang;
    Map<String, dynamic> zh;
    try {
      noLang = jsonDecode(responses[0].body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    if (responses[1].statusCode == 200) {
      try {
        zh = jsonDecode(responses[1].body) as Map<String, dynamic>;
      } catch (_) {
        zh = <String, dynamic>{};
      }
    } else {
      zh = <String, dynamic>{};
    }

    // backdrop 优选: w1280, iso_639_1==null 优先, vote_average DESC
    final backdrops = <Map<String, dynamic>>[
      ...((noLang['backdrops'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>()),
      ...((zh['backdrops'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>()),
    ];
    String? bestBackdropPath;
    double bestBackdropVote = -1;
    var bestBackdropIsNullLang = false;
    for (final b in backdrops) {
      final path = b['file_path'] as String?;
      if (path == null || path.isEmpty) continue;
      final vote = (b['vote_average'] as num?)?.toDouble() ?? 0;
      final isNullLang = b['iso_639_1'] == null;
      // 优选规则: null lang 优先 (isNullLang=true 比 false 大), 同 lang 选 vote 大
      if (isNullLang && !bestBackdropIsNullLang) {
        bestBackdropPath = path;
        bestBackdropVote = vote;
        bestBackdropIsNullLang = true;
      } else if (isNullLang == bestBackdropIsNullLang && vote > bestBackdropVote) {
        bestBackdropPath = path;
        bestBackdropVote = vote;
        bestBackdropIsNullLang = isNullLang;
      }
    }
    final backdropUrl = bestBackdropPath != null
        ? '$_imageBase/w1280/${bestBackdropPath.startsWith('/') ? bestBackdropPath.substring(1) : bestBackdropPath}'
        : null;

    // logo 优选: w500, .png 后缀, zh > en > null 优先级, vote DESC
    final logos = <Map<String, dynamic>>[
      ...((zh['logos'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>()),
      ...((noLang['logos'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>()),
    ];
    String? bestLogoPath;
    var bestLogoLangPriority = -1;
    double bestLogoVote = -1;
    for (final l in logos) {
      final path = l['file_path'] as String?;
      if (path == null || path.isEmpty) continue;
      if (!path.toLowerCase().endsWith('.png')) continue;
      final iso = l['iso_639_1'] as String?;
      final langPriority = iso == 'zh' ? 2 : (iso == 'en' ? 1 : 0);
      final vote = (l['vote_average'] as num?)?.toDouble() ?? 0;
      if (langPriority > bestLogoLangPriority ||
          (langPriority == bestLogoLangPriority && vote > bestLogoVote)) {
        bestLogoPath = path;
        bestLogoLangPriority = langPriority;
        bestLogoVote = vote;
      }
    }
    final logoUrl = bestLogoPath != null
        ? '$_imageBase/w500/${bestLogoPath.startsWith('/') ? bestLogoPath.substring(1) : bestLogoPath}'
        : null;

    final art = TmdbArt(backdropUrl: backdropUrl, logoUrl: logoUrl);
    await _writeArtCache(cacheKey, art);
    return art;
  }

  /// 清空所有 TMDB 缓存 (切换 key 后调一次, 避免老 key 的结果污染)
  static Future<void> clearAllCache() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('tmdb_')).toList();
    for (final k in keys) {
      await prefs.remove(k);
    }
  }

  // ===== 缓存层 (SharedPreferences 简单实现, 跟 doubanCacheService 不同 —
  //   这里每个键独立, 不需要统一目录) =====

  static Future<({String mediaType, int id})?> _readRefCache(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final ts = json['ts'] as int? ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - ts > _cacheTtl.inMilliseconds) {
        return null;
      }
      final mediaType = json['mediaType'] as String?;
      final id = json['id'] as int?;
      if (mediaType == null || id == null) return null;
      return (mediaType: mediaType, id: id);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeRefCache(
      String key, ({String mediaType, int id}) data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode({
      'ts': DateTime.now().millisecondsSinceEpoch,
      'mediaType': data.mediaType,
      'id': data.id,
    }));
  }

  static Future<TmdbArt?> _readArtCache(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final ts = json['ts'] as int? ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - ts > _cacheTtl.inMilliseconds) {
        return null;
      }
      return TmdbArt(
        backdropUrl: json['backdrop'] as String?,
        logoUrl: json['logo'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeArtCache(String key, TmdbArt data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode({
      'ts': DateTime.now().millisecondsSinceEpoch,
      'backdrop': data.backdropUrl,
      'logo': data.logoUrl,
    }));
  }
}

/// TMDB art 数据 — 详情页大头部用
class TmdbArt {
  final String? backdropUrl; // w1280 16:9 横版
  final String? logoUrl;     // w500 透底 logo (跟背景叠好看)
  const TmdbArt({this.backdropUrl, this.logoUrl});

  bool get isEmpty => backdropUrl == null && logoUrl == null;
  bool get isNotEmpty => !isEmpty;
}
