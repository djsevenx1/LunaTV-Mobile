import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:luna_tv/models/bangumi.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/services/cf_optimizer.dart' show CfOptimizerHttpOverrides;
import 'package:luna_tv/services/douban_cache_service.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/video_proxy_log.dart';

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
        // ⚠️ api.bgm.tv v0 API 强制要求 User-Agent 是
        //    "App/Version (URL)" 格式,否则返 400!
        // 之前 v1.0.25 改成了 Chrome 标准 UA 导致整个
        // CF 代理都拉不到数据,这就是用户反馈"还是不行"的真因
        'User-Agent':
            'LunaTV-Mobile/1.0 (https://github.com/djsevenx1/LunaTV-Mobile)',
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
          final fallbackUrl = UserDataService.buildCiaoCorsUrl(apiUrl);
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
  ///
  /// v2.0.71: 走 CF Worker 时改用 SecureSocket 手动 TLS, 绕开
  ///   CfOptimizerHttpOverrides 的 SNI 污染 (跟 TMDB 同一个 bug).
  ///   HttpClient 被 hook 后 host 改优选 IP → SNI = IP → TLS 握手失败.
  ///   修法: Socket.connect(ip,443) + SecureSocket.secure(host: workerDomain).
  ///   非 worker (直连 api.bgm.tv / ciao-cors) 仍用 http.get (没 hook 污染).
  static Future<http.Response?> _fetchBangumi(
    String url,
    Map<String, String> headers,
    bool viaWorker,
  ) async {
    try {
      if (!viaWorker) {
        return await http
            .get(Uri.parse(url), headers: headers)
            .timeout(const Duration(seconds: 15));
      }
      // 走 CF Worker: 手动 TLS
      final resp = await _secureSocketGet(Uri.parse(url), headers);
      return http.Response(resp.$3, resp.$1, headers: _mapHeaders(resp.$2));
    } catch (e) {
      VideoProxyLog.append(
          '[Bangumi] 请求失败 [viaWorker=$viaWorker] url=${url.length > 120 ? url.substring(0, 120) + "..." : url} err=$e');
      return null;
    }
  }

  /// v2.0.71: 走 CF Worker 时手动 TLS GET.
  /// 返回 (statusCode, headers, body).
  static Future<(int, Map<String, String>, String)> _secureSocketGet(
      Uri uri, Map<String, String> headers) async {
    final host = uri.host;
    final port = uri.port == 0 ? 443 : uri.port;
    final pathQuery = uri.path.isEmpty
        ? '/${uri.query.isEmpty ? "" : "?${uri.query}"}'
        : (uri.query.isEmpty ? uri.path : '${uri.path}?${uri.query}');
    final preferIp = CfOptimizerHttpOverrides.getResolvedManualIp();

    late SecureSocket upstream;
    try {
      if (preferIp != null && preferIp.isNotEmpty) {
        // 优选 IP: TCP 连优选 IP, TLS SNI = host
        final tcpSocket = await Socket.connect(preferIp, port,
            timeout: const Duration(seconds: 10));
        try {
          tcpSocket.setOption(SocketOption.tcpNoDelay, true);
        } catch (_) {}
        upstream = await SecureSocket.secure(tcpSocket, host: host);
      } else {
        // 系统 DNS: SNI = host 自动
        upstream = await SecureSocket.connect(host, port,
            timeout: const Duration(seconds: 10));
        try {
          upstream.setOption(SocketOption.tcpNoDelay, true);
        } catch (_) {}
      }

      // 发 HTTP/1.1 请求
      final reqBuf = StringBuffer()
        ..write('GET $pathQuery HTTP/1.1\r\n')
        ..write('Host: $host\r\n');
      headers.forEach((k, v) => reqBuf.write('$k: $v\r\n'));
      reqBuf.write('Connection: close\r\n\r\n');
      upstream.add(utf8.encode(reqBuf.toString()));
      await upstream.flush();

      // 读响应头
      final reader = _BgmSocketReader(upstream);
      final headerLines = <String>[];
      while (true) {
        final line = await reader.readLine();
        if (line == null) break;
        if (line.isEmpty) break;
        headerLines.add(line);
      }
      if (headerLines.isEmpty) {
        return (502, {}, '');
      }
      final statusLine = headerLines.first;
      final status = int.tryParse(statusLine.split(' ').elementAtOrNull(1) ?? '') ?? 0;
      final respHeaders = <String, String>{};
      for (var i = 1; i < headerLines.length; i++) {
        final idx = headerLines[i].indexOf(':');
        if (idx > 0) {
          respHeaders[headerLines[i].substring(0, idx).trim().toLowerCase()] =
              headerLines[i].substring(idx + 1).trim();
        }
      }
      // 读 body
      final bodyBytes = await reader.readBody(
          int.tryParse(respHeaders['content-length'] ?? ''),
          (respHeaders['transfer-encoding'] ?? '').toLowerCase().contains('chunked'));
      return (status, respHeaders, utf8.decode(bodyBytes));
    } finally {
      try {
        upstream.destroy();
      } catch (_) {}
    }
  }

  static Map<String, String> _mapHeaders(Map<String, String> h) {
    // http.Response 要 List, 这里简单返回 (部分 header 可能丢失, 但 body/status 够用)
    return h;
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
        // ⚠️ api.bgm.tv v0 API 强制要求 User-Agent 是
        //    "App/Version (URL)" 格式,否则返 400
        'User-Agent':
            'LunaTV-Mobile/1.0 (https://github.com/djsevenx1/LunaTV-Mobile)',
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
          final fallbackUrl = UserDataService.buildCiaoCorsUrl(apiUrl);
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

/// v2.0.71: 封装 socket 读取 (跟 tmdb_service._SocketReader 一样).
class _BgmSocketReader {
  final Socket _socket;
  final List<int> _buf = [];
  bool _eof = false;
  late final StreamIterator<List<int>> _iter;

  _BgmSocketReader(this._socket) : _iter = StreamIterator(_socket);

  Future<String?> readLine() async {
    while (true) {
      for (var i = 0; i < _buf.length - 1; i++) {
        if (_buf[i] == 0x0D && _buf[i + 1] == 0x0A) {
          final line = utf8.decode(_buf.sublist(0, i));
          _buf.removeRange(0, i + 2);
          return line;
        }
      }
      for (var i = 0; i < _buf.length; i++) {
        if (_buf[i] == 0x0A) {
          final line = utf8.decode(_buf.sublist(0, i));
          _buf.removeRange(0, i + 1);
          return line;
        }
      }
      if (_eof) return null;
      final more = await _iter.moveNext();
      if (!more) {
        _eof = true;
        continue;
      }
      _buf.addAll(_iter.current);
    }
  }

  Future<List<int>> readN(int n) async {
    while (_buf.length < n && !_eof) {
      final more = await _iter.moveNext();
      if (!more) {
        _eof = true;
        break;
      }
      _buf.addAll(_iter.current);
    }
    final take = _buf.length < n ? _buf.length : n;
    final out = _buf.sublist(0, take);
    _buf.removeRange(0, take);
    return out;
  }

  Future<List<int>> readBody(int? contentLength, bool isChunked) async {
    if (isChunked) {
      final body = <int>[];
      while (true) {
        final sizeLine = await readLine();
        if (sizeLine == null) break;
        final sizeStr = sizeLine.split(';').first.trim();
        final size = int.tryParse(sizeStr, radix: 16);
        if (size == null || size == 0) break;
        final chunk = await readN(size);
        body.addAll(chunk);
        await readN(2);
      }
      return body;
    }
    if (contentLength != null && contentLength >= 0) {
      return await readN(contentLength);
    }
    final body = List<int>.from(_buf);
    _buf.clear();
    while (!_eof) {
      final more = await _iter.moveNext();
      if (!more) {
        _eof = true;
        break;
      }
      body.addAll(_iter.current);
    }
    return body;
  }
}


