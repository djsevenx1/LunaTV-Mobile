import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/models/release_item.dart';

/// 发布日历服务
class ReleaseCalendarService {
  static const Duration _timeout = Duration(seconds: 30);

  /// 获取发布日历数据
  /// [type] 可选筛选类型: movie/tv/anime
  static Future<List<ReleaseItem>> getReleaseCalendar({String? type}) async {
    try {
      final baseUrl = await UserDataService.getServerUrl();
      if (baseUrl == null) {
        return [];
      }

      final cookies = await UserDataService.getCookies();

      // 构建请求URL
      String url = '$baseUrl/api/release-calendar';
      if (type != null && type.isNotEmpty) {
        url += '?type=$type';
      }

      final headers = <String, String>{
        'Accept': 'application/json',
      };
      if (cookies != null && cookies.isNotEmpty) {
        headers['Cookie'] = cookies;
      }

      final response = await http
          .get(
            Uri.parse(url),
            headers: headers,
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        return data
            .map((item) => ReleaseItem.fromJson(item as Map<String, dynamic>))
            .toList();
      }

      return [];
    } catch (e) {
      return [];
    }
  }
}
