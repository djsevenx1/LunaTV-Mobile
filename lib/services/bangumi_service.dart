import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:luna_tv/models/bangumi.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/douban_cache_service.dart';
import 'package:luna_tv/services/user_data_service.dart';

/// Bangumi 数据服务 (函数级缓存, 一天过期)
///
/// v2.1.42 改: 加 'bangumi_proxy' 加速 — Bangumi 数据源选 worker 加速且
///   配了 worker URL 时, api.bgm.tv URL 走 [UserDataService.buildBangumiDataUrl]
///   wrap 成 `${workerUrl}/bangumi/...` (path-based). 跟 v2.1.40 之前
///   CF Worker 套娃 (`?url=`) 不一样: path-based worker 不需要 URL encode,
///   日志 / 日记 / Cache-Control 都干净. 没配 worker URL 或数据源选 'direct'
///   → 1:1 走直连, 跟 v2.1.40 行为一致.
/// v2.1.40 改: 删 CF Worker (CORSAPI 套娃) / ciao-cors 公共代理加速,
///   一律直连 api.bgm.tv. 删了 _fetchBangumi / _secureSocketGet /
///   _BgmSocketReader / dart:io 依赖 / cf_optimizer 引用.
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
    // v2.1.40 改: 删 CF Worker / ciao-cors 兜底, 一律直连 api.bgm.tv
    // v2.1.42 改: 加 'bangumi_proxy' 分支 — Bangumi 数据源选 worker
    //   加速时, buildBangumiDataUrl 内部 wrap 成 `${workerUrl}/bangumi/...`
    //   (path-based). 选 'direct' / 没配 worker URL → 1:1 返原 URL.
    // v2.1.43 改: 加详细 DiaryService 日记, 方便排查「数据源选
    //   bangumi_proxy 但还是直连」类问题 — 之前 v2.1.42 没记日记,
    //   看到日历失败只能猜.
    try {
      const apiUrl = 'https://api.bgm.tv/calendar';
      // v2.1.42: wrap URL via buildBangumiDataUrl (1:1 返 / 走 worker)
      final proxiedUrl = UserDataService.buildBangumiDataUrl(apiUrl);
      DiaryService.add(
          '[Bangumi] getCalendarByWeekday begin: weekday=$weekday');
      DiaryService.add(
          '[Bangumi] URL build: apiUrl=$apiUrl proxiedUrl=$proxiedUrl (source=${UserDataService.getBangumiDataSourceKeySync()}, worker=${UserDataService.getTmdbProxyDomainSync()})');

      const headers = <String, String>{
        // ⚠️ api.bgm.tv v0 API 强制要求 User-Agent 是
        //    "App/Version (URL)" 格式,否则返 400!
        // 之前 v1.0.25 改成了 Chrome 标准 UA 导致整个
        // CF 代理都拉不到数据,这就是用户反馈"还是不行"的真因
        'User-Agent':
            'LunaTV-Mobile/1.0 (https://github.com/djsevenx1/LunaTV-Mobile)',
        'Accept': 'application/json',
        'Referer': 'https://bgm.tv/',
      };

      // v2.1.40: 网络/握手/超时错 retry 1 次 (救国内出口路由抖),
      //   没了 worker / ciao-cors 多级 fallback.
      // v2.1.43: 记起止时间 + 响应大小, 方便排查 慢 / 空 body.
      final sw = Stopwatch()..start();
      final http.Response? response = await _httpGetWithRetry(proxiedUrl, headers);
      sw.stop();
      DiaryService.add(
          '[Bangumi] getCalendarByWeekday http done: statusCode=${response?.statusCode}, ${sw.elapsedMilliseconds}ms, bodyLen=${response?.body.length ?? 0}');
      if (response == null || response.statusCode != 200) {
        // v2.1.43: 失败时把 body 前 200 字符也记进去, BGM 偶发
        //   返 503 / 502 啥的, 看不到 body 没法定位是限流还是
        //   upstream 挂了. body 截断避免日记爆炸.
        final bodyPreview = response?.body.substring(
                0, response.body.length > 200 ? 200 : response.body.length) ??
            '';
        DiaryService.add(
            '[Bangumi] getCalendarByWeekday FAIL: statusCode=${response?.statusCode ?? 'null'} body="$bodyPreview"');
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
      // v2.1.43: 整 try 块异常 (json.decode 挂 / 别的)
      DiaryService.add(
          '[Bangumi] getCalendarByWeekday except: $e');
      return ApiResponse.error('Bangumi 数据请求异常: ${e.toString()}');
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

    // v2.1.40 改: 删 CF Worker / ciao-cors 兜底, 一律直连
    // v2.1.42 改 (有 bug): 想 wrap URL 走 worker, 但只改了 getCalendarByWeekday
    //   没改这里, line 用的是 `apiUrl` 不是 `proxiedUrl`, 等于 1:1 走直连.
    //   用户反馈「TMDB 加速可用 Bangumi 加速不行」的真因之一
    //   (新番日历能拿到, 详情页用同 worker URL 但直连 fallback 到 api.bgm.tv).
    // v2.1.43 改: 跟 getCalendarByWeekday 对齐, 调 buildBangumiDataUrl
    //   拿 proxiedUrl, 用 proxiedUrl 发请求. 同时加详细 DiaryService 日记
    //   方便后续排查.
    try {
      final apiUrl = 'https://api.bgm.tv/v0/subjects/$bangumiId';
      // v2.1.43: 修 v2.1.42 bug — 之前用 `apiUrl` 直接调, 走不到 worker.
      //   跟 getCalendarByWeekday 一样 wrap 一次.
      final proxiedUrl = UserDataService.buildBangumiDataUrl(apiUrl);
      DiaryService.add('[Bangumi] getBangumiDetails begin: id=$bangumiId');
      DiaryService.add(
          '[Bangumi] URL build: apiUrl=$apiUrl proxiedUrl=$proxiedUrl (source=${UserDataService.getBangumiDataSourceKeySync()}, worker=${UserDataService.getTmdbProxyDomainSync()})');

      const headers = <String, String>{
        // ⚠️ api.bgm.tv v0 API 强制要求 User-Agent 是
        //    "App/Version (URL)" 格式,否则返 400
        'User-Agent':
            'LunaTV-Mobile/1.0 (https://github.com/djsevenx1/LunaTV-Mobile)',
        'Accept': 'application/json',
        'Referer': 'https://bgm.tv/',
      };

      // v2.1.43: 修 v2.1.42 的 wrap URL bug — 用 proxiedUrl 而不是 apiUrl.
      //   加 Stopwatch 计时, 跟 getCalendarByWeekday 行为对齐.
      final sw = Stopwatch()..start();
      final http.Response? response = await _httpGetWithRetry(proxiedUrl, headers);
      sw.stop();
      DiaryService.add(
          '[Bangumi] getBangumiDetails http done: statusCode=${response?.statusCode}, ${sw.elapsedMilliseconds}ms, bodyLen=${response?.body.length ?? 0}');
      if (response == null || response.statusCode != 200) {
        // v2.1.43: 失败 body 前 200 字符进日记
        final bodyPreview = response?.body.substring(
                0, response.body.length > 200 ? 200 : response.body.length) ??
            '';
        DiaryService.add(
            '[Bangumi] getBangumiDetails FAIL: statusCode=${response?.statusCode ?? 'null'} body="$bodyPreview"');
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
        // v2.1.43: 解析错也记日记
        DiaryService.add(
            '[Bangumi] getBangumiDetails parse err: $parseError');
        return ApiResponse.error('Bangumi 详情数据解析失败: ${parseError.toString()}');
      }
    } catch (e) {
      // v2.1.43: 整 try 块异常 (网络挂 / retry 都挂 / 别的)
      DiaryService.add(
          '[Bangumi] getBangumiDetails except: $e');
      return ApiResponse.error('Bangumi 详情数据请求异常: ${e.toString()}');
    }
  }

  /// v2.1.40: http.get + 1 层 retry (网络/握手/超时错 retry 1 次).
  ///
  /// 删 _fetchBangumi / _secureSocketGet / _BgmSocketReader /
  /// dart:io / cf_optimizer 之后, 统一用 http.get, 行为跟 v2.1.22
  /// 之前的 tmdb_service 直连模式一致.
  static Future<http.Response?> _httpGetWithRetry(
    String url,
    Map<String, String> headers, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      return await http.get(Uri.parse(url), headers: headers).timeout(timeout);
    } catch (e) {
      try {
        return await http.get(Uri.parse(url), headers: headers).timeout(timeout);
      } catch (_) {
        return null;
      }
    }
  }
}
