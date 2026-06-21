import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/models/short_drama.dart';

/// 短剧服务
class ShortDramaService {
  static const Duration _timeout = Duration(seconds: 30);

  /// 构建完整URL
  static Future<String> _buildUrl(String endpoint) async {
    final baseUrl = await UserDataService.getServerUrl();
    if (baseUrl == null) {
      throw Exception('服务器地址未配置，请先登录');
    }

    String cleanBaseUrl = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    String cleanEndpoint = endpoint.startsWith('/') ? endpoint : '/$endpoint';

    return '$cleanBaseUrl$cleanEndpoint';
  }

  /// 构建请求头
  static Future<Map<String, String>> _buildHeaders() async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    final cookies = await UserDataService.getCookies();
    if (cookies != null && cookies.isNotEmpty) {
      headers['Cookie'] = cookies;
    }

    return headers;
  }

  /// 获取短剧分类列表
  /// GET /api/shortdrama/categories
  /// 返回: [{type_id: number, type_name: string}]
  static Future<List<ShortDramaCategory>> getCategories() async {
    try {
      final url = await _buildUrl('/api/shortdrama/categories');
      final headers = await _buildHeaders();

      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is List) {
          return data
              .map((e) => ShortDramaCategory.fromJson(e as Map<String, dynamic>))
              .toList();
        }
        return [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// 获取分类短剧列表（分页）
  /// GET /api/shortdrama/list?categoryId={categoryId}&page={page}&size={size}
  /// 返回: {list: [...], hasMore: bool}
  static Future<ShortDramaListResponse> getList({
    required int categoryId,
    int page = 1,
    int size = 20,
  }) async {
    try {
      String url = await _buildUrl('/api/shortdrama/list');
      final queryParams = <String, String>{
        'categoryId': categoryId.toString(),
        'page': page.toString(),
        'size': size.toString(),
      };

      final uri = Uri.parse(url).replace(queryParameters: queryParams);
      final headers = await _buildHeaders();

      final response = await http
          .get(uri, headers: headers)
          .timeout(_timeout);

      // ignore: avoid_print
      print('[shortdrama/list] status=${response.statusCode} body=${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is Map<String, dynamic>) {
          // 打印 list 第一项的 keys
          if (data['list'] is List && (data['list'] as List).isNotEmpty) {
            final first = (data['list'] as List).first;
            if (first is Map<String, dynamic>) {
              // ignore: avoid_print
              print('[shortdrama/list] firstItem keys=${first.keys.toList()}');
            }
          }
          return ShortDramaListResponse.fromJson(data);
        }
      }
      return const ShortDramaListResponse(list: [], hasMore: false);
    } catch (e) {
      // ignore: avoid_print
      print('[shortdrama/list] error=$e');
      return const ShortDramaListResponse(list: [], hasMore: false);
    }
  }

  /// 搜索短剧
  /// GET /api/shortdrama/search?query={query}&page={page}&size={size}
  /// 返回: {list: [...], hasMore: bool}
  static Future<ShortDramaListResponse> search(
    String query, {
    int page = 1,
    int size = 20,
  }) async {
    try {
      String url = await _buildUrl('/api/shortdrama/search');
      final queryParams = <String, String>{
        'query': query,
        'page': page.toString(),
        'size': size.toString(),
      };

      final uri = Uri.parse(url).replace(queryParameters: queryParams);
      final headers = await _buildHeaders();

      final response = await http
          .get(uri, headers: headers)
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is Map<String, dynamic>) {
          return ShortDramaListResponse.fromJson(data);
        }
      }
      return const ShortDramaListResponse(list: [], hasMore: false);
    } catch (e) {
      return const ShortDramaListResponse(list: [], hasMore: false);
    }
  }

  /// 获取短剧详情
  /// GET /api/shortdrama/detail?id={id}
  /// 返回: {id, title, poster, episodes, episodes_titles, source, ...}
  /// 或后端可能用 episode_count / episode_list 字段
  static Future<ShortDramaDetail?> getDetail(String id) async {
    // ignore: avoid_print
    print('[shortdrama/detail] id=$id');
    try {
      String url = await _buildUrl('/api/shortdrama/detail');
      final uri = Uri.parse(url).replace(queryParameters: {
        'id': id,
      });
      final headers = await _buildHeaders();

      // ignore: avoid_print
      print('[shortdrama/detail] GET $uri');

      final response = await http
          .get(uri, headers: headers)
          .timeout(_timeout);

      // ignore: avoid_print
      print('[shortdrama/detail] status=${response.statusCode} body=${response.body}');

      if (response.statusCode == 200) {
        final body = response.body;
        if (body.isEmpty) return null;
        final data = json.decode(body);
        if (data is Map<String, dynamic>) {
          // 打印实际 keys 方便排查字段名
          // ignore: avoid_print
          print('[shortdrama/detail] keys=${data.keys.toList()}');
          return ShortDramaDetail.fromJson(data);
        }
        return null;
      }
      return null;
    } catch (e) {
      // ignore: avoid_print
      print('[shortdrama/detail] error=$e');
      return null;
    }
  }

  /// 解析短剧集数获取播放地址
  /// GET /api/shortdrama/parse?id={id}&episode={episode}&proxy=true
  /// 返回: {code, msg, data: {videoId, videoName, currentEpisode, totalEpisodes, parsedUrl, ...}}
  /// proxy=true 失败时自动重试 proxy=false
  static Future<ShortDramaParseResult> parseEpisode({
    required int id,
    required int episode,
    String? name,
    bool useProxy = true,
  }) async {
    // ignore: avoid_print
    print('[shortdrama/parse] id=$id episode=$episode name=$name useProxy=$useProxy');
    final result = await _parseEpisodeOnce(
      id: id,
      episode: episode,
      name: name,
      useProxy: useProxy,
    );
    // ignore: avoid_print
    print('[shortdrama/parse] code=${result.code} msg=${result.msg} url=${result.data?.parsedUrl} proxyUrl=${result.data?.proxyUrl}');
    // proxy 失败时回退到直连
    if (result.code != 0 && useProxy) {
      // ignore: avoid_print
      print('[shortdrama/parse] proxy failed, retry without proxy');
      final fallback = await _parseEpisodeOnce(
        id: id,
        episode: episode,
        name: name,
        useProxy: false,
      );
      // ignore: avoid_print
      print('[shortdrama/parse] fallback code=${fallback.code} msg=${fallback.msg} url=${fallback.data?.parsedUrl}');
      return fallback;
    }
    return result;
  }

  static Future<ShortDramaParseResult> _parseEpisodeOnce({
    required int id,
    required int episode,
    String? name,
    required bool useProxy,
  }) async {
    try {
      String url = await _buildUrl('/api/shortdrama/parse');
      final queryParams = <String, String>{
        'id': id.toString(),
        'episode': episode.toString(),
      };
      if (useProxy) {
        queryParams['proxy'] = 'true';
      }
      if (name != null && name.isNotEmpty) {
        queryParams['name'] = name;
      }

      final uri = Uri.parse(url).replace(queryParameters: queryParams);
      final headers = await _buildHeaders();

      // ignore: avoid_print
      print('[shortdrama/parse] GET $uri');

      final response = await http
          .get(uri, headers: headers)
          .timeout(_timeout);

      // ignore: avoid_print
      print('[shortdrama/parse] status=${response.statusCode} body=${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is Map<String, dynamic>) {
          return ShortDramaParseResult.fromJson(data);
        }
        final bodyPreview = response.body.length > 200
            ? '${response.body.substring(0, 200)}...'
            : response.body;
        return ShortDramaParseResult(
            code: -1, msg: '响应非 JSON: $bodyPreview');
      }
      final bodyPreview = response.body.length > 200
          ? '${response.body.substring(0, 200)}...'
          : response.body;
      return ShortDramaParseResult(
          code: -1, msg: 'HTTP ${response.statusCode}: $bodyPreview');
    } catch (e) {
      return ShortDramaParseResult(code: -1, msg: '网络错误: $e');
    }
  }

  /// 获取推荐短剧
  /// GET /api/shortdrama/recommend?category={category}&size={size}
  /// 返回: [ShortDrama, ...]
  static Future<List<ShortDrama>> getRecommend({
    int? category,
    int size = 10,
  }) async {
    try {
      String url = await _buildUrl('/api/shortdrama/recommend');
      final queryParams = <String, String>{
        'size': size.toString(),
      };
      if (category != null) {
        queryParams['category'] = category.toString();
      }

      final uri = Uri.parse(url).replace(queryParameters: queryParams);
      final headers = await _buildHeaders();

      final response = await http
          .get(uri, headers: headers)
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is List) {
          return data
              .map((e) => ShortDrama.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      }
      return [];
    } catch (e) {
      return [];
    }
  }
}
