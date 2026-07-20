// lib/services/source_browser_service.dart
// v2.3.31: 源浏览器 service
//   4 个方法对应源 API 的 4 个 ac=:
//     ac=list                  → getCategories  取分类列表
//     ac=videolist&t=X&pg=N    → getList        按分类取列表
//     ac=videolist&wd=Q&pg=N   → search         在某源内搜
//     ac=videolist&ids=ID      → getDetail      取详情
//
// 跟 DownstreamService.searchPage 同一套实现 (http package / 8s timeout /
//   GBK/UTF-8 自动检测). 不另起一套.
//
// 5 分钟 in-memory cache (key = `categories:$resourceKey` 等), 源浏览器来回
//   切分类/翻页不重复打源 API. cache 在进程内, 不进 SharedPreferences (源
//   API 可能改分类, 5 分钟 TTL 足够刷新).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:http/http.dart' as http;

import '../models/search_resource.dart';
import '../models/source_browser.dart';

/// 源浏览器 (分页) 列表结果
class SourceBrowserPage {
  final List<SourceBrowserItem> items;
  final SourceBrowserPageMeta meta;

  const SourceBrowserPage({required this.items, required this.meta});
}

class SourceBrowserService {
  // v2.3.31: 5 分钟内存缓存. key 格式: `<endpoint>:<resourceKey>[:<extra>]`.
  //   同一进程内切分类/翻页不重复打源 API. 进程退出自动清.
  static const Duration _cacheTtl = Duration(minutes: 5);
  static final Map<String, _CacheEntry<dynamic>> _cache = {};

  // v2.4.4: 跟 web source-browser routes 1:1 配置.
  //   - categories timeout: 10s (web categories/route.ts:32 = 10s)
  //   - list timeout: 15s (web list/route.ts:82 = 15s, 比之前 8s 长,
  //     解决用户反馈「分类出来后卡」— 中等速度源 8s 超时 15s 不超时)
  //   - search/detail timeout: 8s (跟 web searchWithCache downstream.ts:57 一致)
  //   - User-Agent: Chrome 147 (跟 web user-agent.ts:10,126 1:1, 之前 Chrome 122
  //     已落后 2 年多, 部分 CDN/WAF (CF Bot Mgmt) 直接 403)
  //   - SSL 验证: main.dart 全局 HttpOverrides.global 关 badCertificate
  //     (v2.4.4 加的, 之前注释撒谎说有其实没, 导致 HandshakeException 全挂)
  static const Duration _timeoutCategories = Duration(seconds: 10);
  static const Duration _timeoutList = Duration(seconds: 15);
  static const Duration _timeoutDefault = Duration(seconds: 8);
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.7727.139 Safari/537.36';

  // -------- cache helpers --------

  static T? _getCached<T>(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.at) > _cacheTtl) {
      _cache.remove(key);
      return null;
    }
    return entry.value as T;
  }

  static void _setCached(String key, dynamic value) {
    _cache[key] = _CacheEntry<dynamic>(value, DateTime.now());
  }

  /// 清空所有缓存 (源 API 改了 / 切账号 / 用户手动刷新时调)
  static void clearCache() => _cache.clear();

  // -------- public API --------

  /// 取源分类 (源 API `?ac=list`)
  /// 返回 List<SourceCategory>, 失败返 null.
  static Future<List<SourceCategory>?> getCategories(
      SearchResource resource) async {
    final key = 'categories:${resource.key}';
    final cached = _getCached<List<SourceCategory>>(key);
    if (cached != null) return cached;

    // v2.4.4: URL 构建检查 api 是否已带 `?`, 跟 web 1:1 (web 也没检查,
    //   但用户配置的某些源 api 带 ?from=xxx, 直接拼 ?ac=list 会破损)
    final url = _buildUrl(resource.api, 'ac=list');
    final json = await _getJson(url, timeout: _timeoutCategories);
    if (json == null) return null;

    final list = (json['class'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SourceCategory.fromJson)
        .where((c) => c.typeId > 0 && c.typeName.isNotEmpty)
        .toList();
    _setCached(key, list);
    return list;
  }

  /// 按分类取列表 (源 API `?ac=videolist&t=X&pg=N`)
  /// 失败返 null, page 从 1 开始.
  static Future<SourceBrowserPage?> getList(
    SearchResource resource, {
    required int typeId,
    required int page,
  }) async {
    final url =
        _buildUrl(resource.api, 'ac=videolist&t=$typeId&pg=$page');
    return _fetchPage(url, 'list:$typeId:$page', timeout: _timeoutList);
  }

  /// 搜索 (源 API `?ac=videolist&wd=Q&pg=N`)
  /// 不传 typeId 全源搜; 传 typeId 在某分类下搜.
  static Future<SourceBrowserPage?> search(
    SearchResource resource, {
    required String query,
    int? typeId,
    required int page,
  }) async {
    final encoded = Uri.encodeComponent(query);
    final tParam = typeId != null ? '&t=$typeId' : '';
    final url = _buildUrl(resource.api, 'ac=videolist&wd=$encoded$tParam&pg=$page');
    return _fetchPage(url, 'search:$query:$typeId:$page',
        timeout: _timeoutDefault);
  }

  /// 取详情 (源 API `?ac=videolist&ids=ID`)
  /// 返回 SourceBrowserDetail, 失败返 null.
  /// 跟 web detail API 行为一致, 用 `?ac=videolist&ids=` 而不是 `?ac=detail&ids=`.
  static Future<SourceBrowserDetail?> getDetail(
    SearchResource resource, {
    required String id,
  }) async {
    final url = _buildUrl(resource.api, 'ac=videolist&ids=$id');
    final json = await _getJson(url, timeout: _timeoutDefault);
    if (json == null) return null;
    final list = (json['list'] as List? ?? const [])
        .whereType<Map<String, dynamic>>();
    if (list.isEmpty) return null;
    final first = list.first;
    final episodes =
        _parsePlayUrl((first['vod_play_url'] ?? '').toString());
    return SourceBrowserDetail.fromJson(first, episodes);
  }

  // -------- private helpers --------

  /// v2.4.4: URL 构建检查 api 是否已带 `?`.
  ///   之前直接 `${api}?ac=list`, 如果 api 是 `https://x/api.php?from=xxx`
  ///   会拼出破损的 `?from=xxx?ac=list`. 现在检查 api 是否含 `?`,
  ///   含则用 `&` 拼接, 不含则用 `?` 拼接.
  ///   同时 trim api 字段去除前后空格.
  static String _buildUrl(String api, String query) {
    final trimmed = api.trim();
    if (trimmed.isEmpty) return '';
    final sep = trimmed.contains('?') ? '&' : '?';
    return '$trimmed$sep$query';
  }

  static Future<SourceBrowserPage?> _fetchPage(
      String url, String cacheKey,
      {required Duration timeout}) async {
    if (url.isEmpty) return null;
    final key = 'page:$cacheKey';
    final cached = _getCached<SourceBrowserPage>(key);
    if (cached != null) return cached;

    final json = await _getJson(url, timeout: timeout);
    if (json == null) return null;

    final items = (json['list'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SourceBrowserItem.fromJson)
        .where((it) => it.id.isNotEmpty && it.title.isNotEmpty)
        .toList();
    final meta = SourceBrowserPageMeta(
      page: (json['page'] as num?)?.toInt() ?? 1,
      pageCount: (json['pagecount'] as num?)?.toInt() ?? 1,
      total: (json['total'] as num?)?.toInt() ?? items.length,
      limit: (json['limit'] as num?)?.toInt() ?? 20,
    );
    final page = SourceBrowserPage(items: items, meta: meta);
    _setCached(key, page);
    return page;
  }

  /// GET 拿 JSON, 失败返 null. GBK / UTF-8 自动检测.
  ///   跟 DownstreamService.searchPage 同一套: 读 content-type charset, 失败
  ///   试 GBK, 失败再试 UTF-8 allowMalformed.
  ///   v2.4.4: timeout 改成参数 (categories 10s / list 15s / search 8s / detail 8s),
  ///     跟 web source-browser routes 1:1.
  static Future<Map<String, dynamic>?> _getJson(String url,
      {required Duration timeout}) async {
    if (url.isEmpty) return null;
    try {
      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              'User-Agent': _userAgent,
              'Accept': 'application/json',
            },
          )
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (kDebugMode) {
          debugPrint(
              '[SourceBrowser] HTTP ${response.statusCode} url=$url');
        }
        return null;
      }
      final decoded = _decodeBody(response);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } on TimeoutException {
      if (kDebugMode) debugPrint('[SourceBrowser] timeout url=$url');
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[SourceBrowser] err url=$url e=$e');
      return null;
    }
  }

  /// 解码 HTTP body, 跟 DownstreamService.searchPage 同一套:
  ///   1. 读 content-type charset
  ///   2. 没 charset 试 UTF-8, 失败再试 GBK
  ///   3. 都失败用原 body (拿到乱码)
  static dynamic _decodeBody(http.Response response) {
    String? charset;
    final contentType = response.headers['content-type'];
    if (contentType != null) {
      final m = RegExp(r'charset=([^;]+)').firstMatch(contentType);
      if (m != null) charset = m.group(1)?.toLowerCase().trim();
    }
    if (charset == 'gbk' || charset == 'gb2312') {
      try {
        return json.decode(gbk.decode(response.bodyBytes));
      } catch (_) {
        return json
            .decode(utf8.decode(response.bodyBytes, allowMalformed: true));
      }
    }
    // 默认 utf-8 → utf-8 失败试 gbk
    try {
      return json.decode(utf8.decode(response.bodyBytes, allowMalformed: true));
    } catch (_) {
      try {
        return json.decode(gbk.decode(response.bodyBytes));
      } catch (_) {
        if (kDebugMode) {
          debugPrint(
              '[SourceBrowser] decode failed, first 200 chars: ${response.body.substring(0, response.body.length > 200 ? 200 : response.body.length)}');
        }
        return null;
      }
    }
  }

  /// 解析 vod_play_url 格式 "第01集\$url#第02集\$url#..."
  ///   跟 DownstreamService.searchPage._parseVodPlayUrl 同款, 但产出
  ///   List<SourceBrowserEpisode> 而不是 String.
  /// 兼容格式:
  ///   "第01集\$https://...m3u8#第02集\$https://...m3u8"      标准
  ///   "kTaImPSY#第14集\$https://...#第15集\$https://..."   前置 hash
  ///   "https://...m3u8#https://...m3u8"                  单行全 URL
  ///   "第01集\$url\$\$\$第01集\$url"                      多源 (只取第一个 $)
  static List<SourceBrowserEpisode> _parsePlayUrl(String playUrl) {
    if (playUrl.isEmpty) return const [];
    // 多源分隔 $$$ → 取第一个
    final firstSource = playUrl.split(r'$$$').first;
    final episodes = <SourceBrowserEpisode>[];
    // 按 # 切 (选集分隔)
    for (final seg in firstSource.split('#')) {
      final t = seg.trim();
      if (t.isEmpty) continue;
      // 标准 "集名\$url"
      final dollarIdx = t.indexOf(r'$');
      if (dollarIdx > 0) {
        final name = t.substring(0, dollarIdx).trim();
        final url = t.substring(dollarIdx + 1).trim();
        if (url.startsWith('http')) {
          episodes.add(SourceBrowserEpisode(name: name, url: url));
          continue;
        }
      }
      // 整段是 URL (没集名前缀)
      if (t.startsWith('http')) {
        episodes.add(SourceBrowserEpisode(name: '播放', url: t));
      }
    }
    return episodes;
  }
}

class _CacheEntry<T> {
  final T value;
  final DateTime at;
  _CacheEntry(this.value, this.at);
}
