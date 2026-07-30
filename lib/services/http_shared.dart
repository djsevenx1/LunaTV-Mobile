// lib/services/http_shared.dart
// v2.4.5: 公共 HTTP helper, 让 SourceBrowserService / DownstreamService /
//   SearchService 共用同一套 UA / timeout / URL 构建 / 响应解码.
//
// 之前 v2.4.4 只修了 source_browser_service.dart 一个文件, downstream_service
//   和 search_service 仍是 Chrome 122 + 8s timeout + 直接拼 URL + .endsWith('.m3u8')
//   过滤, 导致「源浏览器能开但搜索/点开视频没集数」「同一个源不同入口行为不一致」.
//
// 这套 helper 跟 web 配置 1:1:
//   - UA: Chrome 147 (web user-agent.ts:10,126)
//   - timeout: categories 10s / list 15s / search/detail 8s (web categories/list/search routes)
//   - URL 构建: 检查 api 是否已带 `?` (web 也没检查, 但用户配置的某些源 api 带 ?from=xxx)
//   - 响应解码: GBK / UTF-8 自动检测 (跟 web downstream.ts 1:1)
//   - SSL 验证: main.dart 全局 HttpOverrides.global 信任所有证书 (v2.4.4 加的)
//
// v2.4.6: 加 isServerMode + getViaServer, 服务器模式走服务端代理
//   /api/source-browser/* + /api/detail (跟 web 1:1). mobile 直连源 API 在
//   中国大陆常被 DNS 污染 / GFW 拦截, 服务端代理能正常访问.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:http/http.dart' as http;

import 'user_data_service.dart';

/// v2.4.5: 公共 HTTP 配置 + helper, 3 个 service 共用.
class HttpShared {
  HttpShared._();

  /// 跟 web user-agent.ts:10,126 1:1.
  ///   之前 mobile 是 Chrome 122 (2024-03 发布), 落后 web 2 年多,
  ///   CF Bot Management 把这种旧 UA 当机器人流量返 403/503/challenge.
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/147.0.7727.139 Safari/537.36';

  /// 跟 web source-browser routes 1:1.
  ///   - categories 10s (web categories/route.ts:32)
  ///   - list 15s (web list/route.ts:82, 解决「分类出来后卡」— 中等速度源 8s 超时 15s 不超时)
  ///   - search/detail 8s (web searchWithCache downstream.ts:57)
  static const Duration timeoutCategories = Duration(seconds: 10);
  static const Duration timeoutList = Duration(seconds: 15);
  static const Duration timeoutDefault = Duration(seconds: 8);

  /// 标准 HTTP headers, 3 个 service 共用.
  static Map<String, String> jsonHeaders() => {
        'User-Agent': userAgent,
        'Accept': 'application/json',
      };

  static Map<String, String> htmlHeaders() => {
        'User-Agent': userAgent,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      };

  /// v2.4.4 / v2.4.5: URL 构建检查 api 是否已带 `?`.
  ///   之前直接 `$api?ac=list`, 如果 api 是 `https://x/api.php?from=xxx`
  ///   会拼出破损的 `?from=xxx?ac=list`. 现在检查 api 是否含 `?`,
  ///   含则用 `&` 拼接, 不含则用 `?` 拼接. 同时 trim api.
  static String buildUrl(String api, String query) {
    final trimmed = api.trim();
    if (trimmed.isEmpty) return '';
    final sep = trimmed.contains('?') ? '&' : '?';
    return '$trimmed$sep$query';
  }

  /// 解码 HTTP body, GBK / UTF-8 自动检测.
  ///   跟 DownstreamService.searchPage / SourceBrowserService._decodeBody 同一套:
  ///   1. 读 content-type charset
  ///   2. 没 charset 试 UTF-8, 失败再试 GBK
  ///   3. 都失败用原 body (拿到乱码)
  ///   返回 String (可能乱码), 调用方自己 json.decode.
  static String decodeBody(http.Response response) {
    String? charset;
    final contentType = response.headers['content-type'];
    if (contentType != null) {
      final m = RegExp(r'charset=([^;]+)').firstMatch(contentType);
      if (m != null) charset = m.group(1)?.toLowerCase().trim();
    }
    if (charset == 'gbk' || charset == 'gb2312') {
      try {
        return gbk.decode(response.bodyBytes);
      } catch (_) {
        return utf8.decode(response.bodyBytes, allowMalformed: true);
      }
    }
    try {
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    } catch (_) {
      try {
        return gbk.decode(response.bodyBytes);
      } catch (_) {
        if (kDebugMode) {
          debugPrint(
              '[HttpShared] decode failed, first 200 chars: ${response.body.substring(0, response.body.length > 200 ? 200 : response.body.length)}');
        }
        return response.body;
      }
    }
  }

  /// 尝试把解码后的 String 解析成 JSON. 失败返 null.
  ///   调用方: `final json = HttpShared.parseJson(decoded); if (json == null) return null;`
  static dynamic parseJson(String body) {
    try {
      return json.decode(body);
    } catch (_) {
      return null;
    }
  }

  /// v2.4.5: 兼容解析 vod_play_url, 跟 web downstream.ts:115-129 1:1.
  ///   之前 downstream_service / search_service 用 `.endsWith('.m3u8')` 过滤,
  ///   把 `.mp4` 直链 / `https://x.m3u8?token=xxx&expires=yyy` 带鉴权参数的 URL
  ///   全部过滤掉了 → 搜索结果为空 / 点开视频没集数.
  ///   改成 `startsWith('http')`, 跟 source_browser_service.dart:280,286 一致.
  ///
  /// 返回 (episodeName, episodeUrl) 列表. 多源 (`$$$` 分隔) 取集数最多的一组.
  static List<({String name, String url})> parseVodPlayUrl(String playUrl) {
    if (playUrl.isEmpty) return const [];
    final firstSource = playUrl.split(r'$$$').first;
    final episodes = <({String name, String url})>[];
    for (final seg in firstSource.split('#')) {
      final t = seg.trim();
      if (t.isEmpty) continue;
      final dollarIdx = t.indexOf(r'$');
      if (dollarIdx > 0) {
        final name = t.substring(0, dollarIdx).trim();
        final url = t.substring(dollarIdx + 1).trim();
        if (url.startsWith('http')) {
          episodes.add((name: name, url: url));
          continue;
        }
      }
      if (t.startsWith('http')) {
        episodes.add((name: '播放', url: t));
      }
    }
    return episodes;
  }

  // -------- v2.4.6: 服务器模式服务端代理 helpers --------

  /// 服务器模式 = 非本地模式 (有 serverUrl + cookies).
  ///   服务器模式走服务端代理 /api/source-browser/* + /api/detail (跟 web 1:1),
  ///   本地模式 fallback 直连源 API.
  ///   mobile 直连源 API 在中国大陆常被 DNS 污染 / GFW 拦截 / CDN 不友好,
  ///   服务端 (部署在海外) 能正常访问 → 服务器模式必须走服务端代理.
  static Future<bool> isServerMode() async {
    return !await UserDataService.getIsLocalMode();
  }

  /// 走服务端代理 GET 拿 JSON.
  ///   endpoint 形如 `/api/source-browser/categories?source=xxx`
  ///   或 `/api/detail?source=K&id=ID`.
  ///   携带登录 cookie (authInfo), 服务端 route 用 cookie 鉴权.
  ///   失败返 null (让上层 fallback 直连源 API).
  static Future<Map<String, dynamic>?> getViaServer(String endpoint,
      {Duration? timeout}) async {
    try {
      // v2.5.25: 优先同步内存读, 避免每次都 async SharedPreferences
      final baseUrl = UserDataService.getServerUrlSync();
      if (baseUrl == null || baseUrl.isEmpty) return null;
      final cleanBase = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
      final cleanEndpoint =
          endpoint.startsWith('/') ? endpoint : '/$endpoint';
      final url = '$cleanBase$cleanEndpoint';

      final cookies = UserDataService.getCookiesSync();
      final headers = <String, String>{
        'Accept': 'application/json',
        if (cookies != null && cookies.isNotEmpty) 'Cookie': cookies,
      };

      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(timeout ?? timeoutCategories);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (kDebugMode) {
          debugPrint(
              '[HttpShared] getViaServer HTTP ${response.statusCode} url=$url');
        }
        return null;
      }
      final decoded = parseJson(decodeBody(response));
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } on TimeoutException {
      if (kDebugMode) debugPrint('[HttpShared] getViaServer timeout: $endpoint');
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[HttpShared] getViaServer err: $e');
      return null;
    }
  }
}
