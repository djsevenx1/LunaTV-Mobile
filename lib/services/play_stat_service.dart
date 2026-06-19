import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/models/play_stat.dart';

/// 播放统计服务
class PlayStatService {
  static const Duration _timeout = Duration(seconds: 30);

  /// 获取播放统计数据
  /// 从现有的 /api/playrecords 接口获取数据，解析为统计格式
  static Future<List<PlayStat>> getPlayStats() async {
    try {
      final baseUrl = await UserDataService.getServerUrl();
      if (baseUrl == null) {
        return [];
      }

      final cookies = await UserDataService.getCookies();

      final headers = <String, String>{
        'Accept': 'application/json',
      };
      if (cookies != null && cookies.isNotEmpty) {
        headers['Cookie'] = cookies;
      }

      final response = await http
          .get(
            Uri.parse('$baseUrl/api/playrecords'),
            headers: headers,
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        final List<PlayStat> stats = [];

        data.forEach((key, itemData) {
          final record = itemData as Map<String, dynamic>;
          stats.add(PlayStat.fromJson(key, {
            'title': record['title'] ?? '',
            'cover': record['cover'] ?? '',
            'play_count': 1,
            'total_duration': record['play_time'] ?? 0,
            'last_play_time': record['save_time']?.toString() ?? '',
            'type': record['type'] ?? '',
          }));
        });

        // 按播放次数降序排列
        stats.sort((a, b) => b.playCount.compareTo(a.playCount));

        return stats;
      }

      return [];
    } catch (e) {
      return [];
    }
  }

  /// 获取播放汇总数据
  /// 计算总播放次数、总时长、最常看的类型等
  static Future<Map<String, dynamic>> getPlaySummary() async {
    try {
      final stats = await getPlayStats();

      int totalPlayCount = 0;
      int totalDuration = 0;
      final Map<String, int> typeCount = {};

      for (final stat in stats) {
        totalPlayCount += stat.playCount;
        totalDuration += stat.totalDuration;
        if (stat.type.isNotEmpty) {
          typeCount[stat.type] = (typeCount[stat.type] ?? 0) + stat.playCount;
        }
      }

      // 找出最常看的类型
      String mostWatchedType = '';
      int maxCount = 0;
      typeCount.forEach((type, count) {
        if (count > maxCount) {
          maxCount = count;
          mostWatchedType = type;
        }
      });

      // 获取类型显示名称
      String mostWatchedTypeDisplay = '';
      switch (mostWatchedType) {
        case 'movie':
          mostWatchedTypeDisplay = '电影';
          break;
        case 'tv':
          mostWatchedTypeDisplay = '电视剧';
          break;
        case 'anime':
          mostWatchedTypeDisplay = '动漫';
          break;
        case 'show':
          mostWatchedTypeDisplay = '综艺';
          break;
        default:
          mostWatchedTypeDisplay = mostWatchedType;
      }

      return {
        'totalPlayCount': totalPlayCount,
        'totalDuration': totalDuration,
        'totalItems': stats.length,
        'mostWatchedType': mostWatchedTypeDisplay,
        'typeDistribution': typeCount,
      };
    } catch (e) {
      return {
        'totalPlayCount': 0,
        'totalDuration': 0,
        'totalItems': 0,
        'mostWatchedType': '',
        'typeDistribution': <String, int>{},
      };
    }
  }
}
