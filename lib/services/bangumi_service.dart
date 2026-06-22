import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:luna_tv/models/bangumi.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/services/douban_cache_service.dart';
import 'package:luna_tv/services/user_data_service.dart';

/// Bangumi 数据服务（函数级缓存，一天过期）
class BangumiService {
  static final DoubanCacheService _cache = DoubanCacheService();
  static bool _initialized = false;

  static Future<void> _initCache() async {
    if (!_initialized) {
      await _cache.init();
      _initialized = true;
    }
  }

  /// 获取当天的新番放送（根据当前星期几）
  static Future<ApiResponse<List<BangumiItem>>> getTodayCalendar(
    BuildContext context,
  ) async {
    final weekday = DateTime.now().weekday; // 1..7
    return getCalendarByWeekday(context, weekday);
  }

  /// 获取指定星期的新番放送
  static Future<ApiResponse<List<BangumiItem>>> getCalendarByWeekday(
    BuildContext context,
    int weekday, // 1..7 (Monday..Sunday)
  ) async {
    await _initCache();

    // 接口级缓存：缓存原始 API 数组，固定键，不含参数
    const cacheKey = 'bangumi_calendar_raw_v1';

    // 先尝试读取原始数组缓存
    try {
      final cachedRaw = await _cache.get<List<dynamic>>(
        cacheKey,
        (raw) => raw as List<dynamic>,
      );
      if (cachedRaw != null && cachedRaw.isNotEmpty) {
        final calendar = cachedRaw
            .map((item) => BangumiCalendarResponse.fromJson(item as Map<String, dynamic>))
            .toList();
        BangumiCalendarResponse? targetDay;
        for (final day in calendar) {
          if (day.weekday.id == weekday) {
            targetDay = day;
            break;
          }
        }
        final items = targetDay?.items ?? <BangumiItem>[];
        return ApiResponse.success(items);
      }
    } catch (_) {}

    // 未命中缓存，请求接口
    try {
      const apiUrl = 'https://api.bgm.tv/calendar';
      // CF Worker 优先，否则按用户选择走公共 CORS 代理/直连
      String requestUrl = UserDataService.buildBangumiDataUrl(apiUrl);
      // 是否是 CF Worker 走的(只要配了 worker 域名就走 worker)
      final bool isViaWorker = UserDataService.hasCfWorkerDomain();

      final headers = <String, String>{
        // 改成更标准的浏览器 UA,某些 Cloudflare 边缘节点会
        // 拦截带 "LunaTV" 字样的奇怪 UA
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
        'Accept': 'application/json',
        'Referer': 'https://bgm.tv/',
      };
      // 走 ciao-cors 时加 X-Requested-With 头
      if (requestUrl.startsWith(UserDataService.publicCorsProxyBase)) {
        headers['X-Requested-With'] = 'XMLHttpRequest';
      }

      http.Response? response =
          await _fetchBangumi(requestUrl, headers, isViaWorker);
      // CF Worker 失败 → 兜底走 ciao-cors(如果 ciao-cors 也没配就直连)
      if (response == null || response.statusCode != 200) {
        // 用户配了 worker 但 worker 挂了 → 改走 ciao-cors
        if (isViaWorker) {
          final fallbackUrl = UserDataService.publicCorsProxyBase +
              Uri.encodeComponent(apiUrl);
          final fbHeaders = Map<String, String>.from(headers);
          fbHeaders['X-Requested-With'] = 'XMLHttpRequest';
          // ignore: avoid_print
          print('Bangumi: CF Worker 失败, fallback 到 ciao-cors');
          response = await _fetchBangumi(fallbackUrl, fbHeaders, false);
        }
        if (response == null || response.statusCode != 200) {
          // 再次失败 → 直连
          if (requestUrl != apiUrl) {
            // ignore: avoid_print
            print('Bangumi: 公共 CORS 也失败, fallback 到直连');
            response = await _fetchBangumi(apiUrl, headers, false);
          }
        }
      }
      if (response == null || response.statusCode != 200) {
        return ApiResponse.error(
          '获取 Bangumi 日历失败: ${response?.statusCode ?? 'no response'}',
          statusCode: response?.statusCode ?? 0,
        );
      }

      final List<dynamic> responseData = json.decode(response.body);

      // 解析所有星期数据
      final List<BangumiCalendarResponse> calendarData = responseData
          .map((item) => BangumiCalendarResponse.fromJson(item as Map<String, dynamic>))
          .toList();

      BangumiCalendarResponse? targetDay;
      for (final day in calendarData) {
        if (day.weekday.id == weekday) {
          targetDay = day;
          break;
        }
      }

      final items = targetDay?.items ?? <BangumiItem>[];

      // 写入接口级缓存：原始数组
      try {
        await _cache.set(
          cacheKey,
          responseData,
          const Duration(days: 1),
        );
      } catch (_) {}

      return ApiResponse.success(items, statusCode: response.statusCode);
    } catch (e) {
      return ApiResponse.error('Bangumi 数据请求异常: ${e.toString()}');
    }
  }

  /// 单次 Bangumi HTTP 请求,失败返 null
  static Future<http.Response?> _fetchBangumi(
    String url,
    Map<String, String> headers,
    bool viaWorker,
  ) async {
    try {
      return await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      // ignore: avoid_print
      print('Bangumi 请求失败 [viaWorker=$viaWorker] url=$url err=$e');
      return null;
    }
  }

  /// 获取 Bangumi 详情数据
  /// 
  /// 参数说明：
  /// - bangumiId: Bangumi ID
  static Future<ApiResponse<BangumiDetails>> getBangumiDetails(
    BuildContext context, {
    required String bangumiId,
  }) async {
    await _initCache();

    // 生成缓存键
    final cacheKey = _cache.generateBangumiDetailsCacheKey(
      bangumiId: bangumiId,
    );

    // 尝试从缓存获取数据
    try {
      final cachedData = await _cache.get<BangumiDetails>(
        cacheKey,
        (raw) {
          if (raw is! Map<String, dynamic>) {
            throw FormatException('Bangumi 缓存数据格式错误: ${raw.runtimeType}');
          }
          return BangumiDetails.fromJson(raw);
        },
      );

      if (cachedData != null) {
        return ApiResponse.success(cachedData);
      }
    } catch (e) {
      // 缓存读取失败，清理可能损坏的缓存，继续执行网络请求
      try {
        // 清理这个特定的缓存项
        await _cache.set(cacheKey, null, Duration.zero);
      } catch (_) {}
    }

    try {
      final apiUrl = 'https://api.bgm.tv/v0/subjects/$bangumiId';
      // CF Worker 优先，否则按用户选择走公共 CORS 代理/直连
      String requestUrl = UserDataService.buildBangumiDataUrl(apiUrl);
      final bool isViaWorker = UserDataService.hasCfWorkerDomain();

      final headers = <String, String>{
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
        'Accept': 'application/json',
        'Referer': 'https://bgm.tv/',
      };
      if (requestUrl.startsWith(UserDataService.publicCorsProxyBase)) {
        headers['X-Requested-With'] = 'XMLHttpRequest';
      }

      http.Response? response =
          await _fetchBangumi(requestUrl, headers, isViaWorker);
      if (response == null || response.statusCode != 200) {
        if (isViaWorker) {
          final fallbackUrl = UserDataService.publicCorsProxyBase +
              Uri.encodeComponent(apiUrl);
          final fbHeaders = Map<String, String>.from(headers);
          fbHeaders['X-Requested-With'] = 'XMLHttpRequest';
          // ignore: avoid_print
          print('Bangumi 详情: CF Worker 失败, fallback 到 ciao-cors');
          response = await _fetchBangumi(fallbackUrl, fbHeaders, false);
        }
        if (response == null || response.statusCode != 200) {
          if (requestUrl != apiUrl) {
            // ignore: avoid_print
            print('Bangumi 详情: 公共 CORS 也失败, fallback 到直连');
            response = await _fetchBangumi(apiUrl, headers, false);
          }
        }
      }
      if (response == null || response.statusCode != 200) {
        return ApiResponse.error(
          '获取 Bangumi 详情数据失败: ${response?.statusCode ?? 'no response'}',
          statusCode: response?.statusCode ?? 0,
        );
      }

      try {
        final Map<String, dynamic> data = json.decode(response.body);
        final details = BangumiDetails.fromJson(data);

        // 缓存成功的结果，缓存时间为24小时
        try {
          await _cache.set(
            cacheKey,
            details.toJson(),
            const Duration(days: 3),
          );
        } catch (cacheError) {
          // 静默处理缓存错误
        }

        return ApiResponse.success(details, statusCode: response.statusCode);
      } catch (parseError) {
        return ApiResponse.error('Bangumi 详情数据解析失败: ${parseError.toString()}');
      }
    } catch (e) {
      return ApiResponse.error('Bangumi 详情数据请求异常: ${e.toString()}');
    }
  }
}


