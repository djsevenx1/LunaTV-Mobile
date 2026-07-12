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
//   final backdropUrl = art?.backdropUrl;  // w1280 backdrop URL (走 worker 加速, v2.0.94)
//   final logoUrl = art?.logoUrl;          // w500 logo URL (走 worker 加速, v2.0.94)

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:luna_tv/services/diary_service.dart';
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
    // v2.0.96: 第 5 个 — 清洗剧名末尾的年份 (1900-2099).
    //   跟 Season 清洗一个模式, 一次只删一个, while-loop.
    //   用途: 豆瓣/番剧源常在 title 末尾加年份 (e.g. "痴迷 2025" / "Avatar 2009"),
    //     TMDB search 内部按 "title starts with query" 匹配, 末尾年份
    //     经常干扰, 清洗后命中率高很多. Selene-TV mk4 没这 regex,
    //     我们 LunaTV-Mobile 加上 (跟 Season 清洗复用同一套机制).
    RegExp(r'\s+(19|20)\d{2}$'),
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

  /// v2.0.97: 构造 API / image URL — 根据 TMDB 数据源 3 选 1 选路径
  ///
  /// - 'cf_worker' (默认, 跟 v2.0.94 ~ v2.0.96 一致): 配 worker 域名时
  ///   wrap `https://$worker/?url=<encoded fullUrl>`, 没配 worker 域名
  ///   时直连 fullUrl. CF Worker 加速跟豆瓣/番剧图一个模式.
  /// - 'direct': 强制直连 fullUrl, 不走 worker. 给用户在国内 worker 域名
  ///   被墙 / 想用真直连的时用.
  /// - 'off': 配了 TMDB key 也强制不走 TMDB. search / fetchArt 调用方
  ///   开头判 `source == 'off'` 直接 return null, 不调 _buildTmdbApiUrl.
  ///
  /// 跟 Bangumi 数据源 (cf_worker / direct / cors_proxy) 风格一致, 3 选 1.
  /// TMDB 跟 Bangumi 一样用 worker 加速, 不需要 cors_proxy 第三方代理
  /// (Zwei 的 cors-proxy 是给豆瓣做的, 跨服务不可靠).
  static String _buildTmdbApiUrl(String fullUrl, String source) {
    switch (source) {
      case 'direct':
        return fullUrl;
      case 'cf_worker':
      default:
        final worker = UserDataService.getCfWorkerDomainSync();
        if (worker.isNotEmpty) {
          return 'https://$worker/?url=${Uri.encodeComponent(fullUrl)}';
        }
        return fullUrl;
    }
  }

  /// search/multi 拿精准 (mediaType, id).
  ///
  /// 跟 Selene-TV mk4.h 行为 (1:1 移植) + v2.0.96 改进:
  ///
  /// v2.0.96: search URL **不传 year 参数** (v2.0.93 传了, 命中很差).
  ///   - TMDB 内部按 popularity DESC 排序, year 只是 hint, 传了反而
  ///     经常 0 结果 (中文剧名 + year 太严). 改不传让 TMDB 用自己的
  ///     ranking 自由匹配, 命中率明显高.
  ///   - year 过滤从「硬 continue」(v2.0.93) 改「soft bonus」(v2.0.96):
  ///     year 匹配的 +1000 popularity bonus, 不匹配 0, 然后 popularity
  ///     (含 bonus) 排序. 这样 year 匹配优先, 但 year 不匹配时仍能选
  ///     popularity 最大的, 跟 v2.0.93 year 硬过滤的"无结果"相比宽容
  ///     很多. v2.0.93 行为: "痴迷 2025" → 0 result → SnackBar 弹错;
  ///     v2.0.96 行为: "痴迷 2025" → 清洗 "痴迷" + 软 year bonus, 仍
  ///     可能选到非 2025 的同名剧 (rare) 或 2025 真正的剧.
  ///
  /// v2.0.93 行为 (保留注释, 备查):
  ///   1. include_adult=false
  ///   2. media_type in ["movie", "tv"]
  ///   3. year 过滤: release_date / first_air_date 前 4 位 == year (硬 continue)
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
    if (cleaned.isEmpty) {
      DiaryService.add('[TMDB] search skip: cleanTitle 空 (原 title="$title")');
      return null;
    }

    final apiKey = UserDataService.getTmdbApiKeySync();
    if (apiKey == null || apiKey.isEmpty) {
      DiaryService.add('[TMDB] search skip: apiKey 空');
      return null;
    }

    // v2.0.97: 配了 key 但数据源 = 'off' → 强制不走 TMDB, 走豆瓣兜底
    final source = UserDataService.getTmdbDataSourceSync();
    if (source == 'off') {
      DiaryService.add('[TMDB] search skip: source=off');
      return null;
    }
    DiaryService.add(
        '[TMDB] search begin: cleaned="$cleaned" year=$year source=$source');

    // 1) 缓存查
    final cacheKey = 'tmdb_ref_${cleaned}_${year ?? ""}';
    final cached = await _readRefCache(cacheKey);
    if (cached != null) {
      DiaryService.add(
          '[TMDB] cache hit: ${cached.mediaType}#${cached.id} (key=$cacheKey)');
      return cached;
    }

    // 2) search/multi 请求 — v2.0.96 不传 year 给 TMDB (命中率更高)
    final params = <String, String>{
      'api_key': apiKey,
      'query': cleaned,
      'include_adult': 'false',
      'page': '1',
    };
    // v2.0.96: 删 year from URL — TMDB 内部按 popularity DESC 排, year
    //   只是 hint, 传了经常 0 结果. 改用 soft bonus 在 result 上过滤.
    // if (year != null) params['year'] = year.toString();
    final query =
        params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    final url = _buildTmdbApiUrl('$_baseUrl/search/multi?$query', source);
    DiaryService.add('[TMDB] network req: $url');

    final http.Response resp;
    try {
      resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
    } catch (e) {
      // v2.0.99.2: 网络错也写进日记, 用户排查 "TMDB 大背景没出来为啥"
      DiaryService.add('[TMDB] network err: $e (timeout=10s)');
      return null;
    }
    if (resp.statusCode != 200) {
      // v2.0.99.2: HTTP 错 (401 key 失效 / 429 限流 / 5xx) 写进日记
      DiaryService.add(
          '[TMDB] network err: statusCode=${resp.statusCode} (401=key 失效 / 429=限流 / 5xx=服务异常)');
      return null;
    }

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      DiaryService.add('[TMDB] parse err: $e');
      return null;
    }
    final results = (json['results'] as List?) ?? [];
    if (results.isEmpty) {
      DiaryService.add('[TMDB] network ok 但 0 results (TMDB 真没这剧)');
      return null;
    }
    DiaryService.add('[TMDB] network ok: ${results.length} results');

    String? bestMediaType;
    int? bestId;
    double bestScore = -1; // v2.0.96: 软 year bonus 后的综合分
    String? bestDate;
    for (final r in results) {
      if (r is! Map) continue;
      final mediaType = r['media_type'] as String?;
      if (mediaType != 'movie' && mediaType != 'tv') continue;

      // v2.0.96: year 过滤从硬 continue 改 soft bonus
      //   - year 匹配: score = popularity + 1000 (优先选)
      //   - year 不匹配: score = popularity + 0 (跟 year 匹配的一样参与排序)
      //   - year 为空: score = popularity + 0
      // 这样 year 匹配的剧优先, 但 year 不匹配时仍能选 popularity 最大的.
      double score = (r['popularity'] as num?)?.toDouble() ?? 0;
      double bonus = 0;
      if (year != null) {
        final dateField = mediaType == 'movie' ? 'release_date' : 'first_air_date';
        final date = r[dateField] as String?;
        if (date != null && date.startsWith(year.toString())) {
          bonus = 1000.0;
          score += 1000.0;
        }
      }

      if (score > bestScore) {
        bestScore = score;
        bestMediaType = mediaType;
        bestId = r['id'] as int?;
        bestDate = r[mediaType == 'movie' ? 'release_date' : 'first_air_date']
            as String?;
      }
    }

    if (bestMediaType == null || bestId == null) {
      DiaryService.add(
          '[TMDB] filter 后无候选 (movie/tv 类型都被过滤掉, 罕见)');
      return null;
    }
    // v2.0.99.2: 选 best 写日记, 方便用户/开发者看为啥选了这个
    final bonusStr = (year != null && bestDate != null && bestDate.startsWith(year.toString()))
        ? '+1000 year bonus'
        : '0 (year 不匹配)';
    DiaryService.add(
        '[TMDB] best pick: $bestMediaType#$bestId score=$bestScore (popularity=${bestScore - (bonusStr.contains('+1000') ? 1000 : 0)}, bonus=$bonusStr, date=$bestDate)');

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
    if (apiKey == null || apiKey.isEmpty) {
      DiaryService.add('[TMDB] fetchArt skip: apiKey 空');
      return null;
    }

    // v2.0.97: 配了 key 但数据源 = 'off' → 强制不走 TMDB
    final source = UserDataService.getTmdbDataSourceSync();
    if (source == 'off') {
      DiaryService.add('[TMDB] fetchArt skip: source=off');
      return null;
    }
    DiaryService.add(
        '[TMDB] fetchArt begin: $mediaType#$id source=$source');

    // 缓存查
    final cacheKey = 'tmdb_art_${mediaType}_$id';
    final cached = await _readArtCache(cacheKey);
    if (cached != null) {
      DiaryService.add(
          '[TMDB] cache hit art: backdrop=${cached.backdropUrl != null}, logo=${cached.logoUrl != null}');
      return cached;
    }

    // 1) 无语言版本 (backdrop 优选无语言, 跟 v2.0.43 风格一致)
    // 2) zh-CN 版本 (logo 优选中文, 跟 v2.0.43 风格一致)
    final noLangUrl = _buildTmdbApiUrl(
        '$_baseUrl/$mediaType/$id/images?api_key=$apiKey', source);
    final zhUrl = _buildTmdbApiUrl(
        '$_baseUrl/$mediaType/$id/images?api_key=$apiKey&language=zh-CN', source);

    final List<http.Response> responses;
    try {
      responses = await Future.wait([
        http.get(Uri.parse(noLangUrl)).timeout(const Duration(seconds: 10)),
        http.get(Uri.parse(zhUrl)).timeout(const Duration(seconds: 10)),
      ]);
    } catch (e) {
      DiaryService.add('[TMDB] fetchArt network err: $e');
      return null;
    }
    if (responses[0].statusCode != 200) {
      DiaryService.add(
          '[TMDB] fetchArt noLang statusCode=${responses[0].statusCode}');
      return null;
    }

    Map<String, dynamic> noLang;
    Map<String, dynamic> zh;
    try {
      noLang = jsonDecode(responses[0].body) as Map<String, dynamic>;
    } catch (e) {
      DiaryService.add('[TMDB] fetchArt parse err: $e');
      return null;
    }
    if (responses[1].statusCode == 200) {
      try {
        zh = jsonDecode(responses[1].body) as Map<String, dynamic>;
      } catch (e) {
        DiaryService.add('[TMDB] fetchArt zh parse err: $e');
        zh = <String, dynamic>{};
      }
    } else {
      DiaryService.add(
          '[TMDB] fetchArt zh statusCode=${responses[1].statusCode} (用空 {} 兜底)');
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
        ? _buildTmdbApiUrl(
            '$_imageBase/w1280/${bestBackdropPath.startsWith('/') ? bestBackdropPath.substring(1) : bestBackdropPath}',
            source)
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
        ? _buildTmdbApiUrl(
            '$_imageBase/w500/${bestLogoPath.startsWith('/') ? bestLogoPath.substring(1) : bestLogoPath}',
            source)
        : null;

    final art = TmdbArt(backdropUrl: backdropUrl, logoUrl: logoUrl);
    DiaryService.add(
        '[TMDB] fetchArt done: backdrop=${backdropUrl != null}, logo=${logoUrl != null} (backdrops 候选 ${backdrops.length}, logos 候选 ${logos.length})');
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
