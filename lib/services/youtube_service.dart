import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/models/youtube_video.dart';

/// YouTube 数据服务
class YouTubeService {
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

  /// 搜索 YouTube 视频
  static Future<List<YouTubeVideo>> search(String query) async {
    try {
      String url = await _buildUrl('/api/youtube/search');
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
              .map((e) => YouTubeVideo.fromJson(e as Map<String, dynamic>))
              .toList();
        }
        return [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// 获取热门 YouTube 视频
  static Future<List<YouTubeVideo>> getPopular({String? region}) async {
    try {
      String url = await _buildUrl('/api/youtube/popular');
      final queryParams = <String, String>{};

      if (region != null && region.isNotEmpty) {
        queryParams['region'] = region;
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
              .map((e) => YouTubeVideo.fromJson(e as Map<String, dynamic>))
              .toList();
        }
        return [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// 获取支持的地区列表
  static Future<List<String>> getRegions() async {
    try {
      final url = await _buildUrl('/api/youtube/regions');
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
}
