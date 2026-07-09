// v2.0.36: TMDB (The Movie Database) API client
//
// 核心: 通过 CF Worker CORSAPI 加速 TMDB 请求
//   原始: https://api.themoviedb.org/3/movie/popular?api_key=xxx
//   加速: https://{cf-worker}/?url=https%3A%2F%2Fapi.themoviedb.org%2F3%2Fmovie%2Fpopular%3Fapi_key%3Dxxx
//
// 为什么需要加速: TMDB 国内/某些地区访问慢, 走 CF Worker 代理后:
//   - 你设备 -> CF edge (快)
//   - CF edge -> TMDB origin (快, 走 CF 骨干网)
//   - 整条链路在国内/海外都比直连 api.themoviedb.org 快
//
// 配置要求 (v2.0.35 配):
//   1. 设置页 → 海报墙 → TMDB API Key (v3 auth, 免费)
//   2. 设置页 → 加速 → CF Worker 域名 + 开关
// 任一缺失 → 走 fallback:
//   - 无 key → TmdbException(NO_KEY)
//   - 无 CF Worker 域名 → _wrap 直接返回原 URL (走直连, 慢但能用)
//
// 缓存: 1 天本地缓存, 跟 TMDB 自己数据更新周期匹配
//   - SharedPreferences 存 JSON, key = tmdb_cache_{path}_{params_hash}
//   - 内存二级缓存避免每次都读 prefs
//
// 设计参考:
//   - 跟 CfOptimizerHttpOverrides 一样的全局静态方法模式
//   - 走 Dart HttpClient, 触发 CfOptimizerHttpOverrides 全局 hook,
//     HTTP 请求也走优选 IP (跟 v2.0.31 手动优选 IP 字段联动)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/video_proxy_log.dart';

/// v2.0.36: TMDB API 异常
class TmdbException implements Exception {
  final String message;
  final String code; // NO_KEY / INVALID_KEY / NETWORK / HTTP_xxx
  final int? httpStatus;

  const TmdbException(this.message,
      {required this.code, this.httpStatus});

  @override
  String toString() => 'TmdbException($code): $message';

  /// 翻译成中文给用户看
  String toUserMessage() {
    switch (code) {
      case 'NO_KEY':
        return '未配置 TMDB API Key. 去 设置 → 海报墙 申请并填入.';
      case 'INVALID_KEY':
        return 'TMDB API Key 无效 (401). 重新去 themoviedb.org/settings/api 复制.';
      case 'NETWORK':
        return '网络异常: $message. 检查网络 / CF Worker 域名是否配对.';
      default:
        if (httpStatus != null) {
          return 'TMDB 错误 $httpStatus: $message';
        }
        return message;
    }
  }
}

/// v2.0.36: 媒体类型
enum TmdbMediaType {
  movie('movie'),
  tv('tv'),
  person('person');

  final String value;
  const TmdbMediaType(this.value);

  static TmdbMediaType fromString(String s) {
    for (final t in TmdbMediaType.values) {
      if (t.value == s) return t;
    }
    return TmdbMediaType.movie;
  }
}

/// v2.0.36: trending 时间窗
enum TmdbTimeWindow {
  day('day'),
  week('week');

  final String value;
  const TmdbTimeWindow(this.value);
}

/// v2.0.36: 一个 TMDB 媒体条目 (movie 或 tv)
class TmdbItem {
  final int id;
  final TmdbMediaType mediaType;
  final String title; // movie: title, tv: name
  final String originalTitle;
  final String? posterPath;
  final String? backdropPath;
  final String overview;
  final double voteAverage; // 0-10
  final int voteCount;
  final String? releaseDate; // movie: release_date, tv: first_air_date
  final List<int> genreIds;

  const TmdbItem({
    required this.id,
    required this.mediaType,
    required this.title,
    required this.originalTitle,
    required this.posterPath,
    required this.backdropPath,
    required this.overview,
    required this.voteAverage,
    required this.voteCount,
    required this.releaseDate,
    required this.genreIds,
  });

  /// 从 TMDB JSON 解析. 兼容 movie / tv / trending 混合响应.
  factory TmdbItem.fromJson(Map<String, dynamic> json) {
    final type = json['media_type'] != null
        ? TmdbMediaType.fromString(json['media_type'] as String)
        : (json['title'] != null
            ? TmdbMediaType.movie
            : TmdbMediaType.tv);
    final title = (type == TmdbMediaType.movie
            ? json['title']
            : json['name']) as String? ??
        '';
    final original = (type == TmdbMediaType.movie
            ? json['original_title']
            : json['original_name']) as String? ??
        '';
    final date = (type == TmdbMediaType.movie
            ? json['release_date']
            : json['first_air_date']) as String?;
    final genres = (json['genre_ids'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        const [];
    final vote = (json['vote_average'] as num?)?.toDouble() ?? 0;
    final votes = (json['vote_count'] as num?)?.toInt() ?? 0;

    return TmdbItem(
      id: (json['id'] as num).toInt(),
      mediaType: type,
      title: title,
      originalTitle: original,
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      overview: (json['overview'] as String?) ?? '',
      voteAverage: vote,
      voteCount: votes,
      releaseDate: date,
      genreIds: genres,
    );
  }

  /// 年份 (从 release_date 截前 4 字符)
  int? get year {
    if (releaseDate == null || releaseDate!.length < 4) return null;
    return int.tryParse(releaseDate!.substring(0, 4));
  }

  /// 评分百分比 (0-100)
  int get votePercent => (voteAverage * 10).round();
}

/// v2.0.36: 分页结果
class TmdbPagedResult<T> {
  final int page;
  final List<T> results;
  final int totalPages;
  final int totalResults;

  const TmdbPagedResult({
    required this.page,
    required this.results,
    required this.totalPages,
    required this.totalResults,
  });

  factory TmdbPagedResult.fromJson(Map<String, dynamic> json,
      T Function(Map<String, dynamic>) parseItem) {
    final results = (json['results'] as List?)
            ?.map((e) => parseItem(e as Map<String, dynamic>))
            .toList() ??
        const [];
    return TmdbPagedResult(
      page: (json['page'] as num?)?.toInt() ?? 1,
      results: results,
      totalPages: (json['total_pages'] as num?)?.toInt() ?? 0,
      totalResults: (json['total_results'] as num?)?.toInt() ?? 0,
    );
  }
}

/// v2.0.36: TMDB 配置 (含图片 CDN base url)
class TmdbConfiguration {
  final String imageBaseUrl; // e.g. https://image.tmdb.org/t/p/
  final List<String> posterSizes;
  final List<String> backdropSizes;

  const TmdbConfiguration({
    required this.imageBaseUrl,
    required this.posterSizes,
    required this.backdropSizes,
  });

  /// 海报图完整 URL
  ///   size: 'w92' / 'w154' / 'w185' / 'w342' / 'w500' / 'w780' / 'original'
  String posterUrl(String? path, {String size = 'w500'}) {
    if (path == null || path.isEmpty) return '';
    return '$imageBaseUrl$size$path';
  }

  String backdropUrl(String? path, {String size = 'w1280'}) {
    if (path == null || path.isEmpty) return '';
    return '$imageBaseUrl$size$path';
  }

  factory TmdbConfiguration.fromJson(Map<String, dynamic> json) {
    final images = json['images'] as Map<String, dynamic>?;
    final baseUrl = (images?['secure_base_url'] as String?) ??
        (images?['base_url'] as String?) ??
        'https://image.tmdb.org/t/p/';
    final poster = (images?['poster_sizes'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const ['w185', 'w500', 'original'];
    final backdrop = (images?['backdrop_sizes'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const ['w1280', 'original'];
    return TmdbConfiguration(
      imageBaseUrl: baseUrl,
      posterSizes: poster,
      backdropSizes: backdrop,
    );
  }
}

/// v2.0.36: 缓存条目
class _CacheEntry {
  final DateTime savedAt;
  final dynamic data;
  const _CacheEntry(this.savedAt, this.data);
}

class TmdbService {
  TmdbService._();

  static const String _baseUrl = 'https://api.themoviedb.org/3';
  // v2.0.45: 改成中文资源. TMDB 支持 language 参数指定返回字段的语言,
  //   zh-CN 返回简体中文标题/简介; region=CN 让海报/人气榜单偏向国内观众.
  //   之前没传 → 英文标题 + 英文 overview, 跟"海报墙"墙不匹配.
  static const String _language = 'zh-CN';
  static const String _region = 'CN';
  static const Duration _cacheTtl = Duration(days: 1);
  // TMDB free API: 40 req/10s, 1 天缓存命中率应该 90%+, 压力很小

  // 内存缓存 (path + params 序列化 -> entry)
  static final Map<String, _CacheEntry> _memoryCache = {};

  // ===== 公共 API =====

  /// v2.0.36: 拿 TMDB 配置 (含图片 CDN base url)
  ///
  /// 这个调用频次很低 (App 启动一次, 或 key 变了一次), 1 天缓存
  static Future<TmdbConfiguration> getConfiguration() async {
    final json = await _httpGet('/configuration',
        {'language': _language}, useCache: true);
    return TmdbConfiguration.fromJson(json as Map<String, dynamic>);
  }

  /// v2.0.36: 热门 (按 type 分)
  ///
  /// [type] 限定 movie 或 tv, person 不接
  /// [page] 默认 1
  static Future<TmdbPagedResult<TmdbItem>> getPopular({
    required TmdbMediaType type,
    int page = 1,
  }) async {
    assert(type == TmdbMediaType.movie || type == TmdbMediaType.tv,
        'getPopular only supports movie/tv');
    final json = await _httpGet(
      '/${type.value}/popular',
      {
        'page': '$page',
        'language': _language,
        'region': _region,
      },
      useCache: true,
    );
    return TmdbPagedResult.fromJson(
        json as Map<String, dynamic>, TmdbItem.fromJson);
  }

  /// v2.0.36: 趋势 (今日/本周), 不分 movie/tv 混合返回
  static Future<TmdbPagedResult<TmdbItem>> getTrending({
    required TmdbMediaType type,
    TmdbTimeWindow window = TmdbTimeWindow.day,
    int page = 1,
  }) async {
    final json = await _httpGet(
      '/trending/${type.value}/${window.value}',
      {
        'page': '$page',
        'language': _language,
      },
      useCache: true,
    );
    return TmdbPagedResult.fromJson(
        json as Map<String, dynamic>, TmdbItem.fromJson);
  }

  /// v2.0.36: 搜剧 (剧名 + 年份可选)
  static Future<TmdbPagedResult<TmdbItem>> search({
    required TmdbMediaType type,
    required String query,
    int? year,
    int page = 1,
  }) async {
    final params = <String, String>{
      'query': query,
      'page': '$page',
      'language': _language,
    };
    if (year != null) {
      params[type == TmdbMediaType.movie ? 'year' : 'first_air_date_year'] =
          '$year';
    }
    final json = await _httpGet(
      '/search/${type.value}',
      params,
      useCache: true,
    );
    return TmdbPagedResult.fromJson(
        json as Map<String, dynamic>, TmdbItem.fromJson);
  }

  /// v2.0.36: 详情 (movie 或 tv)
  static Future<TmdbItem?> getDetails({
    required TmdbMediaType type,
    required int id,
  }) async {
    try {
      final json = await _httpGet(
        '/${type.value}/$id',
        {'language': _language},
        useCache: true,
      );
      // 详情返回不带 media_type, 根据 type 字段缺失推断
      final map = json as Map<String, dynamic>;
      map['media_type'] ??= type.value;
      return TmdbItem.fromJson(map);
    } on TmdbException catch (e) {
      if (e.httpStatus == 404) return null;
      rethrow;
    }
  }

  /// v2.0.36: 清缓存 (测试用, 或用户主动重置)
  static Future<void> clearCache() async {
    _memoryCache.clear();
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('tmdb_cache_'));
    for (final k in keys) {
      await prefs.remove(k);
    }
  }

  // ===== 内部 =====

  /// v2.0.45: 拼 URL + 走 CORSAPI 包装
  ///
  ///   tmdb_url -> https://{cf-worker}/?url={encoded(tmdb_url)}
  ///   如果 CF Worker 不可用 (没配域名 / 用户选直连) -> 返回原 URL (直连)
  ///
  /// 跟 [UserDataService.buildProxiedUrlAsync] 不同: 多了"用户选的 TMDB 数据源"
  /// 判断 — 用户选"直连"时强制走原 URL, 选"CF Worker 加速"时走 buildProxiedUrl.
  /// 跟豆瓣/Bangumi 的数据源选择器对齐 (v2.0.45).
  static Future<String> _wrap(String tmdbUrl) async {
    // v2.0.45: 走 UserDataService.buildTmdbDataUrl (同步)
    //   - 用户选"直连" → 原 URL
    //   - 用户选"CF Worker 加速" + 域名配了 → 走 worker
    //   - 用户选"CF Worker 加速" + 域名没配 → 退化成直连
    // buildTmdbDataUrl 内部读 _tmdbDataSourceCache (warmupCfWorkerConfig 时初始化),
    //   这里 await 一次保证 cache 已就绪.
    await UserDataService.getTmdbDataSourceKey();
    return UserDataService.buildTmdbDataUrl(tmdbUrl);
  }

  /// v2.0.36: HTTP GET + 1 天本地缓存
  ///
  /// useCache: false 用于调试 (强制走网络)
  /// v2.0.55: 加 [TMDB] 日记, 玩家屏幕"日记"按钮能看 — 用户反馈
  ///   "tmdb 获取有问题, 只有历史里面能获取海报", 没法判断是 cache miss
  ///   / 网络 / CF Worker / TMDB rate limit. 详细日记能看清:
  ///   缓存命中? 走的 CF Worker 还是直连? HTTP 状态码? body? 异常?
  static Future<dynamic> _httpGet(
    String path,
    Map<String, String> params, {
    bool useCache = true,
  }) async {
    final key = await UserDataService.getTmdbApiKey();
    if (key == null || key.isEmpty) {
      // ignore: avoid_print
      VideoProxyLog.append('[TMDB] 未配置 API Key — 去设置填');
      throw const TmdbException('未配置 TMDB API Key', code: 'NO_KEY');
    }

    // 拼 query string, 保留原始顺序方便缓存命中
    final orderedParams = <String, String>{'api_key': key, ...params};
    final qs = orderedParams.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final cacheKey = useCache ? _cacheKey(path, qs) : null;
    // ignore: avoid_print
    VideoProxyLog.append('[TMDB] 准备 GET $path (cacheKey=$cacheKey)');

    // 1) 内存缓存
    if (cacheKey != null) {
      final mem = _memoryCache[cacheKey];
      if (mem != null &&
          DateTime.now().difference(mem.savedAt) < _cacheTtl) {
        final ageMin = DateTime.now().difference(mem.savedAt).inMinutes;
        // ignore: avoid_print
        VideoProxyLog.append('[TMDB] 命中内存缓存 (${ageMin} 分钟前存)');
        return mem.data;
      }
    }
    // 2) SharedPreferences 缓存
    if (cacheKey != null) {
      final cached = await _readFromPrefs(cacheKey);
      if (cached != null) {
        // ignore: avoid_print
        VideoProxyLog.append('[TMDB] 命中 SharedPreferences 缓存');
        // 写回内存缓存
        _memoryCache[cacheKey] = _CacheEntry(DateTime.now(), cached);
        return cached;
      }
    }
    // ignore: avoid_print
    VideoProxyLog.append('[TMDB] 缓存 miss, 准备真发请求');

    // 3) 真发请求
    final tmdbUrl = '$_baseUrl$path?$qs';
    final url = await _wrap(tmdbUrl);
    // ignore: avoid_print
    VideoProxyLog.append(
        '[TMDB] 实际 URL: ${url.substring(0, url.length > 160 ? 160 : url.length)}${url.length > 160 ? "..." : ""}');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('Accept', 'application/json');
      req.headers.set('User-Agent', 'LunaTV-Mobile/2.0.36');
      final resp = await req.close();
      final status = resp.statusCode;
      final ct = resp.headers.value('content-type') ?? '?';
      // ignore: avoid_print
      VideoProxyLog.append('[TMDB] 响应 HTTP $status content-type=$ct');

      if (status == 401) {
        // ignore: avoid_print
        VideoProxyLog.append(
            '[TMDB] 401 鉴权失败 — API Key 无效或被 TMDB 撤销, 去 themoviedb.org/settings/api 重新复制');
        throw const TmdbException(
          'TMDB API Key 无效 (401). 去 themoviedb.org/settings/api 重新复制.',
          code: 'INVALID_KEY',
          httpStatus: 401,
        );
      }
      if (status == 404) {
        // ignore: avoid_print
        VideoProxyLog.append('[TMDB] 404 资源不存在');
        throw const TmdbException(
          'TMDB 资源不存在 (404)',
          code: 'HTTP_404',
          httpStatus: 404,
        );
      }
      if (status == 429) {
        // ignore: avoid_print
        VideoProxyLog.append(
            '[TMDB] 429 rate limit — TMDB 限流 40 req/10s, 等会儿再试或减并发');
        throw const TmdbException(
          'TMDB 限流 (429). 40 req/10s, 等 10 秒再试.',
          code: 'RATE_LIMIT',
          httpStatus: 429,
        );
      }

      final body = await resp.transform(utf8.decoder).join();
      if (status >= 400) {
        // ignore: avoid_print
        VideoProxyLog.append(
            '[TMDB] HTTP $status 错误, body 前 200: ${body.substring(0, body.length > 200 ? 200 : body.length)}');
        throw TmdbException(
          'TMDB HTTP $status: ${body.substring(0, body.length > 200 ? 200 : body.length)}',
          code: 'HTTP_$status',
          httpStatus: status,
        );
      }
      // ignore: avoid_print
      VideoProxyLog.append(
          '[TMDB] 响应 body ${body.length} bytes, 前 120: ${body.length > 120 ? body.substring(0, 120) + "..." : body}');

      final dynamic json = jsonDecode(body);

      // 写缓存
      if (cacheKey != null) {
        _memoryCache[cacheKey] = _CacheEntry(DateTime.now(), json);
        await _saveToPrefs(cacheKey, json);
        // ignore: avoid_print
        VideoProxyLog.append('[TMDB] 写入缓存 (1 天 TTL)');
      }

      return json;
    } on SocketException catch (e) {
      // ignore: avoid_print
      VideoProxyLog.append(
          '[TMDB] Socket 异常: ${e.message} (host=${e.address?.host} port=${e.port}) — 检查网络 / CF Worker 域名');
      throw TmdbException('Socket: ${e.message}', code: 'NETWORK');
    } on HttpException catch (e) {
      // ignore: avoid_print
      VideoProxyLog.append('[TMDB] HTTP 异常: ${e.message}');
      throw TmdbException('HTTP: ${e.message}', code: 'NETWORK');
    } on HandshakeException catch (e) {
      // ignore: avoid_print
      VideoProxyLog.append(
          '[TMDB] TLS 握手异常: ${e.message} — 大概率 CF Worker 代理证书错 / 优选 IP 拨上但 SNI cert 不对 / 网络 TLS 被劫持');
      throw TmdbException('TLS: ${e.message}', code: 'TLS');
    } on TimeoutException {
      // ignore: avoid_print
      VideoProxyLog.append(
          '[TMDB] 请求超时 (10s) — 网络慢 / CF Worker 慢 / TMDB rate limit / 优选 IP 不通');
      throw const TmdbException('请求超时 (10s)', code: 'NETWORK');
    } catch (e) {
      // ignore: avoid_print
      VideoProxyLog.append('[TMDB] 其它异常: $e');
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// v2.0.36: 缓存 key (path + queryString 的 base64 摘要, 取前 16 字符)
  ///
  /// 不用 crypto 包, 走 dart:convert.base64Url 自带.
  /// 16 字符 base64 足够避免冲突 (1M 缓存 key 碰撞概率 ~10^-7).
  static String _cacheKey(String path, String queryString) {
    final full = '$path?$queryString';
    final b64 = base64Url.encode(utf8.encode(full));
    final digest = b64.length > 16 ? b64.substring(0, 16) : b64;
    return 'tmdb_cache_${path.replaceAll('/', '_')}_$digest';
  }

  /// v2.0.36: 从 SharedPreferences 读缓存
  static Future<dynamic> _readFromPrefs(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final ts = (map['ts'] as num?)?.toInt() ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - ts > _cacheTtl.inMilliseconds) {
        // 过期
        await prefs.remove(key);
        return null;
      }
      return map['data'];
    } catch (_) {
      return null;
    }
  }

  /// v2.0.36: 写 SharedPreferences 缓存
  static Future<void> _saveToPrefs(String key, dynamic data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode({
        'ts': DateTime.now().millisecondsSinceEpoch,
        'data': data,
      });
      await prefs.setString(key, raw);
    } catch (_) {
      // 缓存失败无所谓, 反正能 fallback 网络
    }
  }
}
