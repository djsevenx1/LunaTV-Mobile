import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/screens/login_screen.dart';
import 'package:luna_tv/services/local_search_cache_service.dart';
import 'package:luna_tv/models/favorite_item.dart';
import 'package:luna_tv/models/search_result.dart';
import 'package:luna_tv/models/play_record.dart';
import 'package:luna_tv/models/search_resource.dart';
import 'package:luna_tv/models/search_suggestion.dart';

/// API响应结果类
class ApiResponse<T> {
  final bool success;
  final T? data;
  final String? message;
  final int? statusCode;

  ApiResponse({
    required this.success,
    this.data,
    this.message,
    this.statusCode,
  });

  factory ApiResponse.success(T data, {int? statusCode}) {
    return ApiResponse<T>(
      success: true,
      data: data,
      statusCode: statusCode,
    );
  }

  factory ApiResponse.error(String message, {int? statusCode}) {
    return ApiResponse<T>(
      success: false,
      message: message,
      statusCode: statusCode,
    );
  }
}

/// 通用API请求服务
class ApiService {
  // v2.5.26: 复用 HTTP 客户端, 启用 keep-alive 连接池.
  //   之前每次 http.get/post 都新建 IOClient → 新 TLS 握手 (200-1000ms/次).
  //   复用后同 host 的请求走同一个连接池, 省掉 TLS 握手开销.
  static final http.Client _httpClient = http.Client();

  // v2.5.25: 分场景超时 — 之前全部 30s, 列表/搜索卡住时用户等太久.
  //   - 普通 GET/POST (列表/收藏/历史): 15s
  //   - 搜索 (fetchSourcesData): 20s (后端聚合多源, 需要更久)
  //   - 登录/autoLogin: 10s (快速失败, 让用户早看到错误)
  static const Duration _timeoutDefault = Duration(seconds: 15);
  static const Duration _timeoutSearch = Duration(seconds: 20);
  static const Duration _timeoutAuth = Duration(seconds: 10);

  /// 获取基础URL (优先同步内存缓存, fallback async)
  static Future<String?> _getBaseUrl() async {
    // v2.5.25: warmup 后走同步内存读, 避免每次请求都 async/await
    final cached = UserDataService.getServerUrlSync();
    if (cached != null) return cached;
    return await UserDataService.getServerUrl();
  }

  /// 获取认证cookies (优先同步内存缓存, fallback async)
  static Future<String?> _getCookies() async {
    final cached = UserDataService.getCookiesSync();
    if (cached != null) return cached;
    return await UserDataService.getCookies();
  }

  /// 构建完整URL
  static Future<String> _buildUrl(String endpoint) async {
    final baseUrl = await _getBaseUrl();
    if (baseUrl == null) {
      throw Exception('服务器地址未配置，请先登录');
    }

    // 确保baseUrl不以/结尾，endpoint以/开头
    String cleanBaseUrl = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    String cleanEndpoint = endpoint.startsWith('/') ? endpoint : '/$endpoint';

    return '$cleanBaseUrl$cleanEndpoint';
  }

  /// 构建请求头
  static Future<Map<String, String>> _buildHeaders({
    Map<String, String>? additionalHeaders,
    bool includeAuth = true,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    // 添加认证cookies
    if (includeAuth) {
      final cookies = await _getCookies();
      if (cookies != null && cookies.isNotEmpty) {
        headers['Cookie'] = cookies;
      }
    }

    // 添加额外头部
    if (additionalHeaders != null) {
      headers.addAll(additionalHeaders);
    }

    return headers;
  }

  /// 处理响应
  static Future<ApiResponse<T>> _handleResponse<T>(
    http.Response response,
    T Function(dynamic)? fromJson,
    BuildContext? context,
  ) async {
    // 处理401未授权
    if (response.statusCode == 401) {
      // 清除用户数据
      await UserDataService.clearUserData();

      // 跳转到登录页
      if (context != null && context.mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const LoginScreen()),
          (route) => false,
        );
      }

      return ApiResponse.error(
        '登录已过期，请重新登录',
        statusCode: 401,
      );
    }

    // 处理其他错误状态码
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String errorMessage = '请求失败';
      try {
        final errorData = json.decode(response.body);
        errorMessage =
            errorData['message'] ?? errorData['error'] ?? errorMessage;
      } catch (e) {
        // 如果解析失败，使用默认错误信息
        switch (response.statusCode) {
          case 400:
            errorMessage = '请求参数错误';
            break;
          case 403:
            errorMessage = '没有权限访问';
            break;
          case 404:
            errorMessage = '请求的资源不存在';
            break;
          case 500:
            errorMessage = '服务器内部错误';
            break;
          default:
            errorMessage = '网络请求失败 (${response.statusCode})';
        }
      }

      return ApiResponse.error(
        errorMessage,
        statusCode: response.statusCode,
      );
    }

    // 处理成功响应
    try {
      // 兼容空响应 (如 POST /api/playrecords 有些后端返回 200 + 空 body)
      if (response.body.isEmpty) {
        return ApiResponse.success(null as T, statusCode: response.statusCode);
      }
      final responseData = json.decode(response.body);

      if (fromJson != null) {
        final data = fromJson(responseData);
        return ApiResponse.success(data, statusCode: response.statusCode);
      } else {
        return ApiResponse.success(responseData as T,
            statusCode: response.statusCode);
      }
    } catch (e) {
      return ApiResponse.error(
        '响应数据解析失败: ${e.toString()}',
        statusCode: response.statusCode,
      );
    }
  }

  /// GET请求
  static Future<ApiResponse<T>> get<T>(
    String endpoint, {
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
    T Function(dynamic)? fromJson,
    BuildContext? context,
    Duration? timeout,
  }) async {
    try {
      // v2.5.25: 并行构建 URL 和 headers (之前串行 await 2 次)
      final results = await Future.wait([
        _buildUrl(endpoint),
        _buildHeaders(additionalHeaders: headers),
      ]);
      String url = results[0] as String;
      final requestHeaders = results[1] as Map<String, String>;

      // 添加查询参数
      if (queryParameters != null && queryParameters.isNotEmpty) {
        final uri = Uri.parse(url);
        final newUri = uri.replace(queryParameters: queryParameters);
        url = newUri.toString();
      }

      final response = await _httpClient
          .get(
            Uri.parse(url),
            headers: requestHeaders,
          )
          .timeout(timeout ?? _timeoutDefault);

      return await _handleResponse(response, fromJson, context);
    } catch (e) {
      return ApiResponse.error('网络请求异常: ${e.toString()}');
    }
  }

  /// POST请求
  static Future<ApiResponse<T>> post<T>(
    String endpoint, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    T Function(dynamic)? fromJson,
    BuildContext? context,
    Duration? timeout,
  }) async {
    try {
      // v2.5.25: 并行构建 URL 和 headers
      final results = await Future.wait([
        _buildUrl(endpoint),
        _buildHeaders(additionalHeaders: headers),
      ]);
      final url = results[0] as String;
      final requestHeaders = results[1] as Map<String, String>;

      final response = await _httpClient
          .post(
            Uri.parse(url),
            headers: requestHeaders,
            body: body != null ? json.encode(body) : null,
          )
          .timeout(timeout ?? _timeoutDefault);

      return await _handleResponse(response, fromJson, context);
    } catch (e) {
      return ApiResponse.error('网络请求异常: ${e.toString()}');
    }
  }

  /// PUT请求
  static Future<ApiResponse<T>> put<T>(
    String endpoint, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    T Function(dynamic)? fromJson,
    BuildContext? context,
    Duration? timeout,
  }) async {
    try {
      // v2.5.25: 并行构建 URL 和 headers
      final results = await Future.wait([
        _buildUrl(endpoint),
        _buildHeaders(additionalHeaders: headers),
      ]);
      final url = results[0] as String;
      final requestHeaders = results[1] as Map<String, String>;

      final response = await http
          .put(
            Uri.parse(url),
            headers: requestHeaders,
            body: body != null ? json.encode(body) : null,
          )
          .timeout(timeout ?? _timeoutDefault);

      return await _handleResponse(response, fromJson, context);
    } catch (e) {
      return ApiResponse.error('网络请求异常: ${e.toString()}');
    }
  }

  /// DELETE请求
  static Future<ApiResponse<T>> delete<T>(
    String endpoint, {
    Map<String, String>? headers,
    T Function(dynamic)? fromJson,
    BuildContext? context,
    Duration? timeout,
  }) async {
    try {
      // v2.5.25: 并行构建 URL 和 headers
      final results = await Future.wait([
        _buildUrl(endpoint),
        _buildHeaders(additionalHeaders: headers),
      ]);
      final url = results[0] as String;
      final requestHeaders = results[1] as Map<String, String>;

      final response = await http
          .delete(
            Uri.parse(url),
            headers: requestHeaders,
          )
          .timeout(timeout ?? _timeoutDefault);

      return await _handleResponse(response, fromJson, context);
    } catch (e) {
      return ApiResponse.error('网络请求异常: ${e.toString()}');
    }
  }

  /// 上传文件请求
  static Future<ApiResponse<T>> uploadFile<T>(
    String endpoint,
    String filePath, {
    Map<String, String>? fields,
    Map<String, String>? headers,
    T Function(dynamic)? fromJson,
    BuildContext? context,
  }) async {
    try {
      final url = await _buildUrl(endpoint);
      final requestHeaders = await _buildHeaders(
        additionalHeaders: headers,
        includeAuth: true,
      );

      // 移除Content-Type，让http包自动设置multipart的Content-Type
      requestHeaders.remove('Content-Type');

      final request = http.MultipartRequest('POST', Uri.parse(url));
      request.headers.addAll(requestHeaders);

      // 添加文件
      request.files.add(await http.MultipartFile.fromPath('file', filePath));

      // 添加其他字段
      if (fields != null) {
        request.fields.addAll(fields);
      }

      final streamedResponse = await request.send().timeout(_timeoutDefault);
      final response = await http.Response.fromStream(streamedResponse);

      return await _handleResponse(response, fromJson, context);
    } catch (e) {
      return ApiResponse.error('文件上传异常: ${e.toString()}');
    }
  }

  /// 获取收藏夹列表
  static Future<ApiResponse<List<FavoriteItem>>> getFavorites(
      BuildContext context) async {
    try {
      final baseUrl = await _getBaseUrl();
      if (baseUrl == null) {
        return ApiResponse.error('服务器地址未配置');
      }

      final cookies = await _getCookies();
      if (cookies == null) {
        return ApiResponse.error('用户未登录');
      }

      final response = await _httpClient.get(
        Uri.parse('$baseUrl/api/favorites'),
        headers: {
          'Accept': 'application/json',
          'Cookie': cookies,
        },
      ).timeout(_timeoutDefault);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        final List<FavoriteItem> favorites = [];

        // 将Map转换为List并按save_time降序排序
        data.forEach((id, itemData) {
          favorites.add(FavoriteItem.fromJson(id, itemData));
        });

        // 按save_time降序排序
        favorites.sort((a, b) => b.saveTime.compareTo(a.saveTime));

        return ApiResponse.success(favorites, statusCode: response.statusCode);
      } else if (response.statusCode == 401) {
        // 未授权，跳转到登录页面
        if (context.mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (context) => const LoginScreen()),
          );
        }
        return ApiResponse.error('登录已过期，请重新登录',
            statusCode: response.statusCode);
      } else {
        return ApiResponse.error('获取收藏夹失败: ${response.statusCode}',
            statusCode: response.statusCode);
      }
    } catch (e) {
      return ApiResponse.error('获取收藏夹异常: ${e.toString()}');
    }
  }

  /// 获取搜索历史
  static Future<ApiResponse<List<String>>> getSearchHistory(
      BuildContext context) async {
    try {
      final response = await get<List<String>>(
        '/api/searchhistory',
        context: context,
        fromJson: (data) => (data as List).cast<String>(),
      );

      if (response.success && response.data != null) {
        return ApiResponse.success(response.data!,
            statusCode: response.statusCode);
      } else {
        return ApiResponse.error(response.message ?? '获取搜索历史失败');
      }
    } catch (e) {
      return ApiResponse.error('获取搜索历史异常: ${e.toString()}');
    }
  }

  /// 添加搜索历史
  static Future<ApiResponse<void>> addSearchHistory(
      String query, BuildContext context) async {
    try {
      final response = await post<void>(
        '/api/searchhistory',
        context: context,
        body: {'keyword': query},
      );

      return response;
    } catch (e) {
      return ApiResponse.error('添加搜索历史异常: ${e.toString()}');
    }
  }

  /// 清空搜索历史
  static Future<ApiResponse<void>> clearSearchHistory(
      BuildContext context) async {
    try {
      final response = await delete<void>(
        '/api/searchhistory',
        context: context,
      );

      return response;
    } catch (e) {
      return ApiResponse.error('清空搜索历史异常: ${e.toString()}');
    }
  }

  /// 删除单个搜索历史
  static Future<ApiResponse<void>> deleteSearchHistory(
      String query, BuildContext context) async {
    try {
      final encodedQuery = Uri.encodeComponent(query);
      final response = await delete<void>(
        '/api/searchhistory?keyword=$encodedQuery',
        context: context,
      );

      return response;
    } catch (e) {
      return ApiResponse.error('删除搜索历史异常: ${e.toString()}');
    }
  }

  /// 保存播放记录
  static Future<ApiResponse<void>> savePlayRecord(
      PlayRecord playRecord, BuildContext context) async {
    try {
      // 构建正确的请求体格式
      final key = '${playRecord.source}+${playRecord.id}';
      final body = {
        'key': key,
        'record': playRecord.toJson(),
      };
      // ignore: avoid_print
      print('[playrecords] POST key=$key');

      final response = await post<void>(
        '/api/playrecords',
        body: body,
        context: context,
      );

      // ignore: avoid_print
      print('[playrecords] POST resp code=${response.statusCode} ok=${response.success} msg=${response.message}');
      return response;
    } catch (e) {
      // ignore: avoid_print
      print('[playrecords] POST 异常: $e');
      return ApiResponse.error('保存播放记录异常: ${e.toString()}');
    }
  }

  /// 删除播放记录
  static Future<ApiResponse<void>> deletePlayRecord(
      String source, String id, BuildContext context) async {
    try {
      final key = '$source+$id';
      final encodedKey = Uri.encodeComponent(key);
      final response = await delete<void>(
        '/api/playrecords?key=$encodedKey',
        context: context,
      );

      return response;
    } catch (e) {
      return ApiResponse.error('删除播放记录异常: ${e.toString()}');
    }
  }

  /// 清空播放记录
  static Future<ApiResponse<void>> clearPlayRecord(BuildContext context) async {
    try {
      final response = await delete<void>(
        '/api/playrecords',
        context: context,
      );

      return response;
    } catch (e) {
      return ApiResponse.error('清空播放记录异常: ${e.toString()}');
    }
  }

  /// 添加收藏
  static Future<ApiResponse<void>> favorite(String source, String id,
      Map<String, dynamic> favoriteData, BuildContext context) async {
    try {
      final key = '$source+$id';
      final body = {
        'key': key,
        'favorite': favoriteData,
      };

      final response = await post<void>(
        '/api/favorites',
        body: body,
        context: context,
      );

      return response;
    } catch (e) {
      return ApiResponse.error('收藏异常: ${e.toString()}');
    }
  }

  /// 取消收藏
  static Future<ApiResponse<void>> unfavorite(
      String source, String id, BuildContext context) async {
    try {
      final key = '$source+$id';
      final encodedKey = Uri.encodeComponent(key);
      final response = await delete<void>(
        '/api/favorites?key=$encodedKey',
        context: context,
      );

      return response;
    } catch (e) {
      return ApiResponse.error('取消收藏异常: ${e.toString()}');
    }
  }

  /// 检查网络连接状态
  static Future<bool> checkConnection() async {
    try {
      final baseUrl = await _getBaseUrl();
      if (baseUrl == null) return false;

      final response = await _httpClient.get(
        Uri.parse('$baseUrl/api/health'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 5));

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// 自动登录方法
  static Future<ApiResponse<String>> autoLogin() async {
    try {
      // 获取用户数据
      final serverUrl = await UserDataService.getServerUrl();
      final username = await UserDataService.getUsername();
      final password = await UserDataService.getPassword();

      if (serverUrl == null || username == null || password == null) {
        return ApiResponse.error('缺少登录信息');
      }

      // 处理 URL
      String baseUrl = serverUrl.trim();
      if (baseUrl.endsWith('/')) {
        baseUrl = baseUrl.substring(0, baseUrl.length - 1);
      }
      String loginUrl = '$baseUrl/api/login';

      // 发送登录请求
      final response = await _httpClient
          .post(
            Uri.parse(loginUrl),
            headers: {
              'Content-Type': 'application/json',
            },
            body: json.encode({
              'username': username,
              'password': password,
            }),
          )
          .timeout(_timeoutAuth);

      if (response.statusCode == 200) {
        // 解析并保存 cookies
        String cookies = _parseCookies(response);

        // 更新 cookies
        await UserDataService.saveUserData(
          serverUrl: baseUrl,
          username: username,
          password: password,
          cookies: cookies,
        );

        return ApiResponse.success('自动登录成功', statusCode: response.statusCode);
      } else {
        return ApiResponse.error(
          '自动登录失败: ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
    } catch (e) {
      return ApiResponse.error('自动登录异常: ${e.toString()}');
    }
  }

  /// 获取视频详情
  static Future<List<SearchResult>> fetchSourceDetail(
      String source, String id) async {
    try {
      final response = await get<SearchResult>(
        '/api/detail',
        queryParameters: {
          'source': source,
          'id': id,
        },
        fromJson: (data) => SearchResult.fromJson(data as Map<String, dynamic>),
      );

      if (response.success && response.data != null) {
        return [response.data!];
      } else {
        print('获取视频详情失败: ${response.message}');
        return [];
      }
    } catch (e) {
      print('获取视频详情失败: $e');
      return [];
    }
  }

  /// 搜索视频源数据
  /// 同一 source key 出现多次时,只保留集数最多的那一条
  /// (修复后端注册多个同 key 资源导致前端显示重复源的问题)
  ///
  /// v2.5.26: 接入 LocalSearchCacheService 10 分钟 TTL 缓存.
  ///   - 重复搜索同关键词直接命中内存, 零网络延迟.
  ///   - 缓存存的是已去重的 List<SearchResult>, 避免重复解析 JSON.
  ///   - sourceKey 用 'server_aggregated' 表示这是后端聚合结果.
  static Future<List<SearchResult>> fetchSourcesData(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    // v2.5.26: 缓存命中直接返回, 跳过网络请求
    const sourceKey = 'server_aggregated';
    final cache = LocalSearchCacheService();
    final cached = cache.getCachedSearchPage(sourceKey, trimmed, 1);
    if (cached != null && cached.status == CachedPageStatus.ok) {
      // 缓存里存的就是 List<SearchResult>, 直接 cast 返回
      try {
        return (cached.data as List).cast<SearchResult>();
      } catch (_) {
        // cast 失败说明缓存类型异常, 走网络重写
      }
    }

    try {
      final response = await get<Map<String, dynamic>>(
        '/api/search',
        queryParameters: {
          'q': trimmed,
        },
        fromJson: (data) => data as Map<String, dynamic>,
        timeout: _timeoutSearch,
      );

      if (response.success && response.data != null) {
        final data = response.data!;
        final results = data['results'] as List<dynamic>? ?? [];

        // 解析 + 按 source key 去重
        final parsed = results
            .map((item) => SearchResult.fromJson(item as Map<String, dynamic>))
            .toList();
        final deduped = _dedupeBySourceKey(parsed);

        // v2.5.26: 命中网络后写缓存 (只缓存非空结果, 避免空结果被缓存 10 分钟)
        if (deduped.isNotEmpty) {
          cache.setCachedSearchPage(
            sourceKey,
            trimmed,
            1,
            CachedPageStatus.ok,
            deduped,
          );
        }
        return deduped;
      } else {
        print('搜索失败: ${response.message}');
        return [];
      }
    } catch (e) {
      print('搜索失败: $e');
      return [];
    }
  }

  /// 按 source key 去重,同一 key 保留集数最多的;空 key 不参与去重
  static List<SearchResult> _dedupeBySourceKey(List<SearchResult> results) {
    final deduped = <String, SearchResult>{};
    for (final r in results) {
      if (r.source.isEmpty) {
        deduped['__nokey_${deduped.length}'] = r;
        continue;
      }
      final existing = deduped[r.source];
      if (existing == null) {
        deduped[r.source] = r;
      } else if (r.episodes.length > existing.episodes.length) {
        deduped[r.source] = r;
      }
    }
    return deduped.values.toList();
  }

  /// 获取搜索资源列表
  static Future<List<SearchResource>> getSearchResources() async {
    try {
      final response = await get<List<SearchResource>>(
        '/api/search/resources',
        fromJson: (data) {
          final list = data as List<dynamic>;
          return list
              .map((item) =>
                  SearchResource.fromJson(item as Map<String, dynamic>))
              .toList();
        },
      );

      if (response.success && response.data != null) {
        return response.data!;
      } else {
        print('获取搜索源失败: ${response.message}');
        return [];
      }
    } catch (e) {
      print('获取搜索源失败: $e');
      return [];
    }
  }

  /// 获取搜索建议
  static Future<List<String>> getSearchSuggestions(String query) async {
    try {
      final response = await get<List<SearchSuggestion>>(
        '/api/search/suggestions',
        queryParameters: {'q': query.trim()},
        fromJson: (data) {
          final responseData = data as Map<String, dynamic>;
          final list = responseData['suggestions'] as List<dynamic>;
          return list
              .map((item) =>
                  SearchSuggestion.fromJson(item as Map<String, dynamic>))
              .toList();
        },
      );

      if (response.success && response.data != null) {
        // 提取建议文本列表
        return response.data!.map((suggestion) => suggestion.text).toList();
      } else {
        print('获取搜索建议失败: ${response.message}');
        return [];
      }
    } catch (e) {
      print('获取搜索建议失败: $e');
      return [];
    }
  }

  /// 解析 Set-Cookie 头部
  static String _parseCookies(http.Response response) {
    List<String> cookies = [];

    // 获取所有 Set-Cookie 头部
    final setCookieHeaders = response.headers['set-cookie'];
    if (setCookieHeaders != null) {
      // HTTP 头部通常是 String 类型
      final cookieParts = setCookieHeaders.split(';');
      if (cookieParts.isNotEmpty) {
        cookies.add(cookieParts[0].trim());
      }
    }

    return cookies.join('; ');
  }
}
