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
  static Future<List<String>> getCategories() async {
    try {
      final url = await _buildUrl('/api/shortdrama/categories');
      final headers = await _buildHeaders();

      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is List) {
          return data.map((e) => e.toString()).toList();
        }
        return [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// 获取短剧列表
  static Future<List<ShortDrama>> getList({
    String? category,
    int page = 1,
  }) async {
    try {
      String url = await _buildUrl('/api/shortdrama/list');
      final queryParams = <String, String>{};

      if (category != null && category.isNotEmpty) {
        queryParams['category'] = category;
      }
      queryParams['page'] = page.toString();

      final uri = Uri.parse(url).replace(queryParameters: queryParams);
      final headers = await _buildHeaders();

      final response = await http
          .get(uri, headers: headers)
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is List) {
          return data
              .map((e) =>
                  ShortDrama.fromJson(e as Map<String, dynamic>))
              .toList();
        }
        return [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// 搜索短剧
  static Future<List<ShortDrama>> search(String query) async {
    try {
      String url = await _buildUrl('/api/shortdrama/search');
      final uri = Uri.parse(url).replace(queryParameters: {
        'q': query,
      });
      final headers = await _buildHeaders();

      final response = await http
          .get(uri, headers: headers)
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is List) {
          return data
              .map((e) =>
                  ShortDrama.fromJson(e as Map<String, dynamic>))
              .toList();
        }
        return [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// 获取短剧详情
  static Future<ShortDrama> getDetail(String id) async {
    try {
      String url = await _buildUrl('/api/shortdrama/detail');
      final uri = Uri.parse(url).replace(queryParameters: {
        'id': id,
      });
      final headers = await _buildHeaders();

      final response = await http
          .get(uri, headers: headers)
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return ShortDrama.fromJson(data as Map<String, dynamic>);
      }
      throw Exception('获取短剧详情失败');
    } catch (e) {
      rethrow;
    }
  }

  /// 获取推荐短剧
  static Future<List<ShortDrama>> getRecommend() async {
    try {
      final url = await _buildUrl('/api/shortdrama/recommend');
      final headers = await _buildHeaders();

      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is List) {
          return data
              .map((e) =>
                  ShortDrama.fromJson(e as Map<String, dynamic>))
              .toList();
        }
        return [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }
}
