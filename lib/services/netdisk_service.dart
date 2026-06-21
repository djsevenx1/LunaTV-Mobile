import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:luna_tv/models/netdisk_result.dart';
import 'package:luna_tv/services/user_data_service.dart';

/// 网盘搜索服务
class NetdiskService {
  /// 搜索网盘资源
  static Future<List<NetdiskResult>> search(String query) async {
    try {
      final baseUrl = await UserDataService.getServerUrl();
      final cookies = await UserDataService.getCookies();

      if (baseUrl == null || baseUrl.isEmpty) {
        return [];
      }

      final rawUrl = Uri.parse('$baseUrl/api/netdisk/search')
          .replace(queryParameters: {'q': query}).toString();
      final proxiedUrl = await UserDataService.buildProxiedUrl(rawUrl);

      final response = await http.get(
        Uri.parse(proxiedUrl),
        headers: {
          if (cookies != null && cookies.isNotEmpty) 'Cookie': cookies,
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return [];
      }

      final data = json.decode(response.body);

      if (data == null || data is! List) {
        return [];
      }

      return data
          .map((item) => NetdiskResult.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }
}
