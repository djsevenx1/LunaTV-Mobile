// lib/services/source_browser_service.dart
// v2.3.31: 源浏览器 service
//   4 个方法对应源 API 的 4 个 ac=:
//     ac=list                  → getCategories  取分类列表
//     ac=videolist&t=X&pg=N    → getList        按分类取列表
//     ac=videolist&wd=Q&pg=N   → search         在某源内搜
//     ac=videolist&ids=ID      → getDetail      取详情
//
// v2.4.6: 服务器模式走服务端代理 (跟 web /api/source-browser/* 1:1).
//   v2.4.5 之前 mobile 全部直连源 API, 但用户手机在中国大陆直连 iqiyizyapi.com
//   等源常被 DNS 污染 / GFW 拦截 / CDN 不友好 → _getJson 抛异常返 null →
//   UI 显示「加载分类失败」. web 端 /api/source-browser/* route 是服务端代理
//   (服务端部署在海外, 能正常访问), 所以 web 正常 mobile 失败.
//   修: 服务器模式下 mobile 也走服务端代理; 本地模式 (无服务端) fallback 直连.
//   这就是用户反馈「v2.4.5 还是很多不行」的真凶 — 不是 UA/timeout/SSL,
//   而是手机网络直连源 API 被拦.
//
// v2.4.5: 改用 HttpShared 公共 helper (UA / timeout / buildUrl / decodeBody).
//   v2.4.4 把传输层配置 (Chrome 147 / 15s timeout / _buildUrl) 写死在本文件,
//   导致 downstream_service 和 search_service 仍是 Chrome 122 + 8s + 直接拼 URL.
//   抽到 HttpShared 后 3 个 service 共用, 以后改一处全链路生效.
//   同时修 class 字段 cast 安全 (json['class'] is! List 时返空, 不抛 TypeError).
//
// 5 分钟 in-memory cache (key = `categories:$resourceKey` 等), 源浏览器来回
//   切分类/翻页不重复打源 API. cache 在进程内, 不进 SharedPreferences (源
//   API 可能改分类, 5 分钟 TTL 足够刷新).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/search_resource.dart';
import '../models/source_browser.dart';
import 'http_shared.dart';

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
  ///
  /// v2.4.6: 服务器模式走服务端代理 `/api/source-browser/categories?source=K`
  ///   (跟 web categories/route.ts 1:1). 本地模式 / 服务端代理失败 → fallback 直连.
  static Future<List<SourceCategory>?> getCategories(
      SearchResource resource) async {
    final key = 'categories:${resource.key}';
    final cached = _getCached<List<SourceCategory>>(key);
    if (cached != null) return cached;

    // v2.4.6: 服务器模式优先走服务端代理
    if (await HttpShared.isServerMode()) {
      final data = await HttpShared.getViaServer(
          '/api/source-browser/categories?source=${Uri.encodeComponent(resource.key)}',
          timeout: HttpShared.timeoutCategories);
      if (data != null) {
        final catsRaw = data['categories'];
        if (catsRaw is List) {
          final list = catsRaw
              .whereType<Map<String, dynamic>>()
              .map(SourceCategory.fromJson)
              .where((c) => c.typeId > 0 && c.typeName.isNotEmpty)
              .toList();
          _setCached(key, list);
          return list;
        }
        // 服务端返了但 categories 不是 List → 空 (跟 web Array.isArray 1:1)
        _setCached(key, const <SourceCategory>[]);
        return const <SourceCategory>[];
      }
      // 服务端代理失败 → fallback 直连源 API
    }

    // 本地模式 / 服务端代理失败 fallback: 直连源 API
    final url = HttpShared.buildUrl(resource.api, 'ac=list');
    final json = await _getJson(url, timeout: HttpShared.timeoutCategories);
    if (json == null) return null;

    // v2.4.5: class 字段 cast 安全. 某些源返 `class: ""` / `class: "电影,电视剧"`
    // (字符串而非数组), `as List?` 会抛 TypeError, `?? const []` 接不住.
    // 跟 web categories/route.ts:53-54 `Array.isArray(data.class) ? data.class : []` 1:1.
    // v2.6.43: fallback 兼容自维护源 — lunatv-sources 的 HTML→maccms 转换代理
    //   (kan555.php / kkys.php 等) ?ac=list 不返 class, 改返 list 字段,
    //   结构跟 class 一样 [{type_id, type_name}]. 标准 maccms 的 list 是视频
    //   列表, 但这些代理源的 list 在 ac=list 模式下返的是分类列表 (code:1 +
    //   total:5 + list:[{type_id,type_name}]). 先取 class, 没有再取 list.
    List? classRaw = json['class'] is List ? json['class'] as List : null;
    classRaw ??= json['list'] is List ? json['list'] as List : null;
    if (classRaw == null) {
      _setCached(key, const <SourceCategory>[]);
      return const <SourceCategory>[];
    }
    final list = classRaw
        .whereType<Map<String, dynamic>>()
        .map(SourceCategory.fromJson)
        .where((c) => c.typeId > 0 && c.typeName.isNotEmpty)
        .toList();
    _setCached(key, list);
    return list;
  }

  /// 按分类取列表 (源 API `?ac=videolist&t=X&pg=N`)
  /// 失败返 null, page 从 1 开始.
  ///
  /// v2.4.6: 服务器模式走服务端代理 `/api/source-browser/list?source=K&type_id=T&page=N`
  ///   (跟 web list/route.ts 1:1). 本地模式 / 服务端代理失败 → fallback 直连.
  static Future<SourceBrowserPage?> getList(
    SearchResource resource, {
    required int typeId,
    required int page,
  }) async {
    final cacheKey = 'list:$typeId:$page';

    // v2.4.6: 服务器模式优先走服务端代理
    if (await HttpShared.isServerMode()) {
      final endpoint =
          '/api/source-browser/list?source=${Uri.encodeComponent(resource.key)}&type_id=$typeId&page=$page';
      final result = await _fetchPageViaServer(endpoint, cacheKey,
          timeout: HttpShared.timeoutList);
      if (result != null) return result;
      // 服务端代理失败 → fallback 直连源 API
    }

    final url = HttpShared.buildUrl(resource.api, 'ac=videolist&t=$typeId&pg=$page');
    return _fetchPage(url, cacheKey, timeout: HttpShared.timeoutList);
  }

  /// 搜索 (源 API `?ac=videolist&wd=Q&pg=N`)
  /// 不传 typeId 全源搜; 传 typeId 在某分类下搜.
  ///
  /// v2.4.6: 服务器模式走服务端代理 `/api/source-browser/search?source=K&q=Q&page=N`
  ///   (跟 web search/route.ts 1:1). 本地模式 / 服务端代理失败 → fallback 直连.
  static Future<SourceBrowserPage?> search(
    SearchResource resource, {
    required String query,
    int? typeId,
    required int page,
  }) async {
    final encoded = Uri.encodeComponent(query);
    final tParam = typeId != null ? '&t=$typeId' : '';
    final cacheKey = 'search:$query:$typeId:$page';

    // v2.4.6: 服务器模式优先走服务端代理
    if (await HttpShared.isServerMode()) {
      final endpoint =
          '/api/source-browser/search?source=${Uri.encodeComponent(resource.key)}&q=$encoded&page=$page';
      final result = await _fetchPageViaServer(endpoint, cacheKey,
          timeout: HttpShared.timeoutDefault);
      if (result != null) return result;
      // 服务端代理失败 → fallback 直连源 API
    }

    final url = HttpShared.buildUrl(
        resource.api, 'ac=videolist&wd=$encoded$tParam&pg=$page');
    return _fetchPage(url, cacheKey, timeout: HttpShared.timeoutDefault);
  }

  /// 取详情 (源 API `?ac=videolist&ids=ID`)
  /// 返回 SourceBrowserDetail, 失败返 null.
  /// 跟 web detail API 行为一致, 用 `?ac=videolist&ids=` 而不是 `?ac=detail&ids=`.
  static Future<SourceBrowserDetail?> getDetail(
    SearchResource resource, {
    required String id,
  }) async {
    final url = HttpShared.buildUrl(resource.api, 'ac=videolist&ids=$id');
    final json = await _getJson(url, timeout: HttpShared.timeoutDefault);
    if (json == null) return null;
    if (json['list'] is! List) return null;
    final list = (json['list'] as List).whereType<Map<String, dynamic>>();
    if (list.isEmpty) return null;
    final first = list.first;
    final episodes =
        HttpShared.parseVodPlayUrl((first['vod_play_url'] ?? '').toString())
            .map((e) => SourceBrowserEpisode(name: e.name, url: e.url))
            .toList();
    return SourceBrowserDetail.fromJson(first, episodes);
  }

  // -------- private helpers --------

  /// v2.4.6: 走服务端代理取分页 (web list/search route 返 `{items, meta}` 格式).
  ///   跟 _fetchPage 区别: _fetchPage 解析 AppleCMS 原始格式 `{list, page, pagecount...}`,
  ///   _fetchPageViaServer 解析 web route 包装格式 `{items: [...], meta: {...}}`.
  ///   web route 已经做了字段标准化 (vod_id→id / vod_name→title 等),
  ///   SourceBrowserItem.fromJson 有 fallback 兼容两种字段名.
  static Future<SourceBrowserPage?> _fetchPageViaServer(
      String endpoint, String cacheKey,
      {required Duration timeout}) async {
    final key = 'page:$cacheKey';
    final cached = _getCached<SourceBrowserPage>(key);
    if (cached != null) return cached;

    final data = await HttpShared.getViaServer(endpoint, timeout: timeout);
    if (data == null) return null;

    final itemsRaw = data['items'];
    if (itemsRaw is! List) return null;
    final items = itemsRaw
        .whereType<Map<String, dynamic>>()
        .map(SourceBrowserItem.fromJson)
        .where((it) => it.id.isNotEmpty && it.title.isNotEmpty)
        .toList();
    final metaJson = data['meta'] as Map<String, dynamic>? ?? const {};
    final meta = SourceBrowserPageMeta(
      page: (metaJson['page'] as num?)?.toInt() ?? 1,
      pageCount: (metaJson['pagecount'] as num?)?.toInt() ?? 1,
      total: (metaJson['total'] as num?)?.toInt() ?? items.length,
      limit: (metaJson['limit'] as num?)?.toInt() ?? 20,
    );
    final page = SourceBrowserPage(items: items, meta: meta);
    _setCached(key, page);
    return page;
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

    if (json['list'] is! List) return null;
    final items = (json['list'] as List)
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

  /// GET 拿 JSON, 失败返 null.
  ///   v2.4.5: 改用 HttpShared.jsonHeaders + HttpShared.decodeBody + HttpShared.parseJson.
  static Future<Map<String, dynamic>?> _getJson(String url,
      {required Duration timeout}) async {
    if (url.isEmpty) return null;
    try {
      final response = await http
          .get(Uri.parse(url), headers: HttpShared.jsonHeaders())
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (kDebugMode) {
          debugPrint(
              '[SourceBrowser] HTTP ${response.statusCode} url=$url');
        }
        return null;
      }
      final decoded = HttpShared.parseJson(HttpShared.decodeBody(response));
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
}

class _CacheEntry<T> {
  final T value;
  final DateTime at;
  _CacheEntry(this.value, this.at);
}
