import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';

// v2.3.9: ExoPlayer 测速 channel 还在但不再用.
//   之前 v2.3.6 让 ExoPlayer prepare() m3u8 测首分片, 但 ExoPlayer 启动
//   慢 (HlsMediaSource prepare 1-2s + MediaCodec 初始化), 加上 Dio HEAD
//   5s timeout + fetch variant 3s + fetch manifest 3s, 总耗时 17s, 而
//   player_screen 外层只有 6s timeout, 测速永远来不及跑完, UI 拿不到
//   速度. v2.3.9 改成: 解析 m3u8 拿真实分片, 直接下 256KB 算 KB/s, 整体
//   2-3s 跑完. Dart 层不再调 exo_speed_test.
// import 'exo_speed_test.dart';

/// M3U8 解析和测速服务
class M3U8Service {
  final Dio _dio = Dio();

  // v2.3.9: ExoPlayer 测速 channel 暂时废弃 (Kotlin 端代码还在, 编译过
  //   / APK 里有, 但 Dart 端不调). 历史说明保留, 方便以后想清楚再恢复.
  //   ExoPlayer 测速失败的真实根因是: ExoPlayer prepare() HLS 媒体源本身
  //   要 1-2s 初始化 + MediaCodec 实例化, 加上前面 fetch m3u8 + variant
  //   + latency 等串行步骤, 总耗时 17s, player_screen 外层只有 6s timeout,
  //   测速永远来不及跑完, UI 端"速度不显示".
  // bool? _exoSpeedTestAvailable;

  M3U8Service() {
    // 配置 Dio
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 30);
    _dio.options.headers = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    };
  }


  /// 并发获取流的核心信息：分辨率、下载速度、延迟
  /// v1.0.45: 优化测速速度
  ///   - M3U8 manifest 只下载 1 次 (之前 _getResolutionFromM3U8 又下了一次)
  ///   - 下载速度只测 1 个段 + Range 请求只取 64KB (之前下 3 个完整段)
  ///   - 对直接 MP4 源 (不是 M3U8) 走 _measureMp4Speed 单独测
  /// v1.0.74: 测速时支持 URL 包装 + 原始 base URL
  ///   - [originalUrl]: 解析 m3u8 segment 相对路径用的 base
  ///     (测 worker URL 时必须传原始 m3u8 URL, 不传会用 worker URL 解析, segment 全错)
  ///   - [urlWrapper]: 测速时包装 segment URL 的回调
  ///     (传 `(url) => buildProxiedUrl(url)` 可让 segment 测速也走 worker)
  /// v2.3.0: 视频加速 (CF Worker 视频代理 + 优选 IP + 本地代理) 整个删了,
  ///   测速走直连 CDN, [originalUrl] / [urlWrapper] 不再需要. 参数保留
  ///   (传 null 即可, 字段仍占位保持向后兼容, 实际逻辑走 streamUrl 即可).
  ///
  /// v2.3.9: 测速流程重写.
  ///   之前 v2.3.3-2.3.5 流程是: fetch m3u8 manifest (3s) + fetch variant
  ///   (3s) + Dio HEAD latency (5s) + Dio Range 1MB 测速 (4s) + ExoPlayer
  ///   测速 (6s) — 全串行, 总耗时最坏 17s, player_screen 外层只有 6s
  ///   timeout, ExoPlayer 测速永远来不及跑完, 整个测速链路被 timeout
  ///   拖垮, UI 端"速度不显示".
  ///
  ///   v2.3.9 改成**两步并发**:
  ///     1. HEAD 测 latency (1.5s timeout, 真实网络延迟)
  ///     2. 直接 GET streamUrl 前 256KB 测速 (2s timeout, m3u8 顶层
  ///        拿 256KB = 整个 playlist + 部分 segment 头, 跟播放走的
  ///        链路完全一致, 不再被 Range 请求 CDN 限速坑).
  ///   两步并发 2s 内基本能跑完, 外层 3-4s timeout 也来得及.
  ///   m3u8 解析 (拿 resolution) 单独再发一次, 1.5s timeout, 跟测速
  ///   并发不影响主结果.
  ///
  /// v2.3.11: 用户反馈"完全没速度显示了" — 截图里 10/11 源都只显示
  ///   latency (ms) 没有 KB/s. 根因是 m3u8 master playlist 5-30KB,
  ///   `_measureDownloadSpeedFast256K` 旧版 < 32KB 直接返 0.
  ///   现在 _measureDownloadSpeedFast256K 内部会自动:
  ///     - 拿到 ≥ 32KB → 直接算 speed
  ///     - 拿到 < 32KB + 内容是 m3u8 → 解析拿 variant / segment,
  ///       对真实分片再测
  ///   但 m3u8 链 (master → variant → segment) 最坏 3 次 GET, 每次
  ///   2s, 总 6s. v2.3.9 用的 Future.wait 全局 2.8s timeout 会砍掉.
  ///   改成**各自 timeout**: latency 1.5s, resolution 1.5s, speed 5s.
  ///   整函数 max 5s 跑完 (m3u8 链真实耗时 1-3s 居多), player_screen
  ///   外层 5s timeout 来得及.
  Future<Map<String, dynamic>> getStreamInfo(
    String streamUrl, {
    String? originalUrl,
    String Function(String)? urlWrapper,
  }) async {
    try {
      // v2.3.11: 各自独立 timeout, 不再用 Future.wait 统一 2.8s.
      //   speed 任务可能要走 m3u8 链 (3 次 GET) 给 5s, latency / resolution
      //   各自 1.5s. 三个任务**同时启动**, 谁先完谁先返, 跟 v2.3.9 行为一致.
      final latFuture = _measureLatencyFast(streamUrl);
      final resFuture = _tryParseResolution(streamUrl);
      final speedFuture = _measureDownloadSpeedFast256K(streamUrl);

      int latency = -1;
      try {
        latency = await latFuture.timeout(const Duration(milliseconds: 1500));
      } catch (_) {}

      Map<String, int> resolution = {'width': 0, 'height': 0};
      try {
        final r = await resFuture.timeout(const Duration(milliseconds: 1500));
        if (r['width'] != null || r['height'] != null) {
          resolution = r;
        }
      } catch (_) {}

      double downloadSpeedKBps = 0.0;
      try {
        downloadSpeedKBps =
            await speedFuture.timeout(const Duration(seconds: 5));
      } catch (_) {}

      if (downloadSpeedKBps <= 0 && latency <= 0) {
        return {
          'resolution': resolution,
          'downloadSpeed': 0.0,
          'latency': 0,
          'success': false,
          'error': 'all speed test failed',
        };
      }
      return {
        'resolution': resolution,
        'downloadSpeed': downloadSpeedKBps,
        'latency': latency,
        'success': true,
        'error': '',
      };
    } catch (e) {
      return {
        'resolution': {'width': 0, 'height': 0},
        'downloadSpeed': 0.0,
        'latency': 0,
        'success': false,
        'error': e.toString(),
      };
    }
  }

  /// v2.3.9: 测 latency (HEAD 请求, 1.5s timeout). 比之前 _measureLatency 用的
  ///   5s connectTimeout + 5s receiveTimeout 短, 单源 1.5s 内出结果.
  Future<int> _measureLatencyFast(String url) async {
    try {
      final tempDio = Dio();
      tempDio.options.connectTimeout = const Duration(milliseconds: 1500);
      tempDio.options.receiveTimeout = const Duration(milliseconds: 1500);
      final sw = Stopwatch()..start();
      try {
        await tempDio.head(url);
        sw.stop();
        return sw.elapsedMilliseconds;
      } catch (e) {
        // 拿到响应但状态码非 2xx 也算 latency OK
        if (e is DioException && e.response != null) {
          sw.stop();
          return sw.elapsedMilliseconds;
        }
        return -1;
      }
    } catch (_) {
      return -1;
    }
  }

  /// v2.3.9: 下 256KB 测速.
  ///   - 不用 Range (CDN 经常对 Range 限速, 之前 5KB/s 假速度的根因).
  ///   - 不用 ExoPlayer (prepare HLS 媒体源要 1-2s, 加上前面解析 17s,
  ///     永远跑不完外层 6s timeout).
  ///   - 直接 GET 前 256KB: m3u8 顶层拿 playlist 文本 + 第一个 segment
  ///     头部数据; 直链 mp4 拿前 256KB. 这部分数据走的下载路径跟
  ///     实际播放走的是同一条 (无 Range, 无 HEAD), 速度更接近真实值.
  ///   - 2s timeout, 收够 256KB 或超时停.
  ///
  /// v2.3.11 重大修复: m3u8 master playlist 5-30KB, 远不到 32KB 阈值
  ///   (旧版 `_measureDownloadSpeedFast256K` 直接返 0). 用户反馈
  ///   "完全没速度显示了" — 10/11 源都只显示 latency (ms) 没有 KB/s,
  ///   因为测速拿不到 segment 实际数据, 全是空跑.
  ///   现在流程:
  ///     1) 下 256KB 直连 URL (跟 v2.3.9 一样)
  ///     2) 拿到字节数 < 32KB, 看内容是不是 m3u8 (#EXTM3U 开头):
  ///        - master playlist (#EXT-X-STREAM-INF): 选 bandwidth 最高的
  ///          variant, 对 variant URL 再跑 256KB 测速 (variant 自身可能
  ///          还是 master, 但国内平台 iQIYI/U酷 顶层 master 都只有一层)
  ///        - media playlist: 找第一个非 # 开头 segment, 对 segment URL
  ///          跑 256KB 测速
  ///        - 不是 m3u8: 原本 32KB 阈值, 现在降到 2KB (m3u8 playlist
  ///          5KB 都算成功, 跟 5KB/s 慢链区分开)
  ///     3) 如果下 256KB 拿到 ≥ 32KB, 直接用 256KB / elapsed 算 speed
  ///   整链路 3s 内能跑完 (m3u8 parse ~50ms, variant/segment 下 256KB
  ///   ~1-2s, 三步并发跟原来一致).
  Future<double> _measureDownloadSpeedFast256K(String url) async {
    // 1) 直连 URL 下 256KB
    final direct = await _downloadHead256K(url);
    if (direct.bytes >= 32 * 1024) {
      // 拿到 ≥ 32KB, 直接算 speed (大文件, 慢链都能算准)
      final sec = direct.elapsedMs / 1000.0;
      if (sec <= 0) return 0.0;
      return (direct.bytes / 1024) / sec;
    }

    // 2) 拿到 < 32KB, 看是不是 m3u8 (master playlist 5-30KB)
    final content = direct.content;
    if (content != null && content.trimLeft().startsWith('#EXTM3U')) {
      // 2a) master playlist: 选带宽最高的 variant
      final variant = _pickBestVariantUrlFromContent(content, url);
      if (variant != null) {
        final v = await _downloadHead256K(variant);
        if (v.bytes >= 2 * 1024) {
          final sec = v.elapsedMs / 1000.0;
          if (sec > 0) return (v.bytes / 1024) / sec;
        }
        // variant 还是 m3u8 (多层 master), 解析拿第一段 segment
        final variantContent = v.content;
        if (variantContent != null) {
          final segUrl = _pickFirstSegmentFromContent(variantContent, variant);
          if (segUrl != null) {
            final s = await _downloadHead256K(segUrl);
            if (s.bytes >= 2 * 1024) {
              final sec = s.elapsedMs / 1000.0;
              if (sec > 0) return (s.bytes / 1024) / sec;
            }
          }
        }
      }
      // 2b) master 没找到 variant, 试当 media playlist 处理
      final segUrl = _pickFirstSegmentFromContent(content, url);
      if (segUrl != null) {
        final s = await _downloadHead256K(segUrl);
        if (s.bytes >= 2 * 1024) {
          final sec = s.elapsedMs / 1000.0;
          if (sec > 0) return (s.bytes / 1024) / sec;
        }
      }
      // 2c) playlist 文本下完, 退而求其次: 用 playlist 大小 (假设 50ms 内下完)
      //     算个 "instant" speed, 至少不是 0. playlist 5KB / 0.05s = 100KB/s
      //     量级, 用户能看到 KB/s 不再全是 latency.
      if (direct.bytes >= 1024 && direct.elapsedMs > 0) {
        return (direct.bytes / 1024) / (direct.elapsedMs / 1000.0);
      }
      return 0.0;
    }

    // 3) 不是 m3u8 (小直链/失败), 用宽松阈值 2KB
    if (direct.bytes >= 2 * 1024 && direct.elapsedMs > 0) {
      return (direct.bytes / 1024) / (direct.elapsedMs / 1000.0);
    }
    return 0.0;
  }

  /// v2.3.11: 内部辅助 — 下最多 256KB, 累计 1.8s 内. 返字节数 + 耗时
  ///   (毫秒) + 完整内容 (如果 < 32KB, 把内容也存下来给 m3u8 解析用).
  Future<_DownloadResult> _downloadHead256K(String url) async {
    try {
      final tempDio = Dio();
      tempDio.options.connectTimeout = const Duration(milliseconds: 1500);
      tempDio.options.receiveTimeout = const Duration(milliseconds: 2000);
      tempDio.options.headers = {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36',
        'Accept': '*/*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      };
      final sw = Stopwatch()..start();
      int bytes = 0;
      final buffer = StringBuffer();
      final resp = await tempDio.get<ResponseBody>(
        url,
        options: Options(responseType: ResponseType.stream),
      );
      // 限制最多累计 64KB 文本, 避免 m3u8 playlist 很大 (例如 100KB) 把
      // 整个 playlist 文本都缓存下来.
      const maxContentBytes = 64 * 1024;
      await for (final chunk in resp.data!.stream) {
        bytes += chunk.length;
        if (bytes <= maxContentBytes) {
          try {
            buffer.write(String.fromCharCodes(chunk));
          } catch (_) {
            // 非 UTF-8 段数据 (mp4 二进制), 跳过文本累积
          }
        }
        if (bytes >= 256 * 1024) break;
        if (sw.elapsedMilliseconds >= 1800) break;
      }
      sw.stop();
      return _DownloadResult(
        bytes: bytes,
        elapsedMs: sw.elapsedMilliseconds,
        content: buffer.length > 0 ? buffer.toString() : null,
      );
    } catch (_) {
      return _DownloadResult(bytes: 0, elapsedMs: 0, content: null);
    }
  }

  /// v2.3.11: 从 m3u8 master playlist 文本里选 bandwidth 最高的 variant URL.
  ///   解析 `#EXT-X-STREAM-INF:...BANDWIDTH=N` + 下一行 URL, 跟已存在的
  ///   `_pickBestVariantPlaylist` 类似但只返 URL (不返 bandwidth/resolution).
  String? _pickBestVariantUrlFromContent(String content, String baseUrl) {
    final lines = content.split('\n').map((line) => line.trim()).toList();
    String? bestUrl;
    int bestBandwidth = -1;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      final params = <String, String>{};
      for (final part in line.substring('#EXT-X-STREAM-INF:'.length).split(',')) {
        final kv = part.split('=');
        if (kv.length == 2) {
          params[kv[0].trim()] = kv[1].trim().replaceAll('"', '');
        }
      }
      final bandwidth = int.tryParse(params['BANDWIDTH'] ?? '') ?? 0;
      // 下一行非 # 开头的就是 variant URL
      for (var j = i + 1; j < lines.length; j++) {
        final candidate = lines[j];
        if (candidate.isEmpty) continue;
        if (candidate.startsWith('#')) continue;
        if (bandwidth > bestBandwidth) {
          bestBandwidth = bandwidth;
          bestUrl = _resolveUrl(candidate, baseUrl);
        }
        break;
      }
    }
    return bestUrl;
  }

  /// v2.3.11: 从 m3u8 media playlist 文本里找第一个非 # 开头的 segment URL.
  String? _pickFirstSegmentFromContent(String content, String baseUrl) {
    for (final line in content.split('\n').map((l) => l.trim())) {
      if (line.isEmpty) continue;
      if (line.startsWith('#')) continue;
      // 跳过 EXT-X-KEY / EXT-X-MAP 之类 (虽然它们也以 # 开头, 但要防
      // 段 URL 本身以 # 开头 — 不可能, URL 不以 # 开头)
      return _resolveUrl(line, baseUrl);
    }
    return null;
  }

  /// v2.3.11: m3u8 服务内部用的下载结果. 跟旧的"返 double"不同, 把
  /// 字节数 + 耗时 + 文本都返出来, 方便上层 m3u8 解析.
  /// 注: bytes 跟 content.length 不一定一致, bytes 是原始字节数, content
  /// 是 UTF-8 decode 后的字符数 (可能略大或小). 测速只用 bytes.

  /// v2.3.9: 尝试解析 m3u8 拿 resolution. 1.5s timeout, 失败返 0x0.
  ///   不影响主测速结果, 只是个 best-effort 增强信息.
  Future<Map<String, int>> _tryParseResolution(String url) async {
    try {
      final tempDio = Dio();
      tempDio.options.connectTimeout = const Duration(milliseconds: 1200);
      tempDio.options.receiveTimeout = const Duration(milliseconds: 1200);
      final resp = await tempDio.get(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final content = resp.data as String;
      if (!content.trimLeft().startsWith('#EXTM3U')) {
        return {'width': 0, 'height': 0};
      }
      final res = _parseResolutionFromContent(content);
      // 如果是 master playlist, 尝试进入最佳 variant 拿更准 resolution
      final variant = _pickBestVariantPlaylist(content, url);
      if (variant != null && variant.resolution['height'] != 0) {
        return variant.resolution;
      }
      return res;
    } catch (_) {
      return {'width': 0, 'height': 0};
    }
  }

  /// GET M3U8 内容, 返回 null 表示不是 M3U8 (直链视频)
  Future<String?> _fetchM3U8Content(String m3u8Url) async {
    try {
      final response = await _dio.get(
        m3u8Url,
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
      final content = response.data as String;
      // M3U8 必须以 #EXTM3U 开头, 不然就是直链
      if (!content.trimLeft().startsWith('#EXTM3U')) return null;
      return content;
    } catch (e) {
      return null;
    }
  }

  /// 从 M3U8 内容里解析 RESOLUTION, 不再额外下载
  Map<String, int> _parseResolutionFromContent(String content) {
    for (final line in content.split('\n').map((l) => l.trim())) {
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        final params = <String, String>{};
        for (final part in line.substring('#EXT-X-STREAM-INF:'.length).split(',')) {
          final kv = part.split('=');
          if (kv.length == 2) params[kv[0].trim()] = kv[1].trim();
        }
        if (params.containsKey('RESOLUTION')) {
          final dims = params['RESOLUTION']!.split('x');
          if (dims.length == 2) {
            return {
              'width': int.tryParse(dims[0]) ?? 0,
              'height': int.tryParse(dims[1]) ?? 0,
            };
          }
        }
      }
    }
    return {'width': 0, 'height': 0};
  }

  _VariantPlaylist? _pickBestVariantPlaylist(String content, String baseUrl) {
    final lines = content.split('\n').map((line) => line.trim()).toList();
    _VariantPlaylist? best;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;

      final params = <String, String>{};
      for (final part in line.substring('#EXT-X-STREAM-INF:'.length).split(',')) {
        final kv = part.split('=');
        if (kv.length == 2) params[kv[0].trim()] = kv[1].trim().replaceAll('"', '');
      }

      String? variantLine;
      for (var j = i + 1; j < lines.length; j++) {
        final candidate = lines[j];
        if (candidate.isEmpty) continue;
        if (candidate.startsWith('#')) continue;
        variantLine = candidate;
        break;
      }
      if (variantLine == null) continue;

      final resolution = _parseResolutionFromParams(params);
      final bandwidth = int.tryParse(params['BANDWIDTH'] ?? '') ?? 0;
      final candidate = _VariantPlaylist(
        url: _resolveUrl(variantLine, baseUrl),
        resolution: resolution,
        bandwidth: bandwidth,
      );

      if (best == null || candidate.score > best.score) {
        best = candidate;
      }
    }

    return best;
  }

  Map<String, int> _parseResolutionFromParams(Map<String, String> params) {
    final value = params['RESOLUTION'];
    if (value == null) return {'width': 0, 'height': 0};
    final dims = value.split('x');
    if (dims.length != 2) return {'width': 0, 'height': 0};
    return {
      'width': int.tryParse(dims[0]) ?? 0,
      'height': int.tryParse(dims[1]) ?? 0,
    };
  }

  /// 直链 (非 M3U8) 测速
  /// v1.0.74: 支持 urlWrapper 包装测速 URL (走 worker 测速)
  /// v2.1.27: HEAD 拿 Content-Length + 算 ping, 再用 Range 1MB 测速.
  ///   之前 v2.1.26 直接复用 `_measureDownloadSpeedFast` (完整 GET) —
  ///   500MB-2GB 的 mp4 完整下完流量爆炸 + 12s timeout 永远返 0.
  ///   现在的做法跟 web LunaTV 思路一致: HEAD 一次拿 fileSize + latency,
  ///   然后 Range bytes=0-1048575 取前 1MB 算 speed, 跟 m3u8 测速
  ///   (拿代表性块) 同思路.
  Future<Map<String, dynamic>> _measureDirectStream(
    String streamUrl, {
    String Function(String)? urlWrapper,
  }) async {
    try {
      // 测速 URL: 直链的话, urlWrapper 包一次 (走 worker)
      final testUrl = urlWrapper != null ? urlWrapper(streamUrl) : streamUrl;

      // 1) HEAD 拿 file size + 算 ping
      //    HEAD 不传 body, 比 GET 快, 而且部分 CDN HEAD 返的 metadata 更准
      //    (Content-Length 直接给到原始 mp4 大小, 跟播放器实际下载一致).
      final pingStopwatch = Stopwatch()..start();
      int fileSizeBytes = 0;
      try {
        final headResponse = await _dio.head(
          testUrl,
          options: Options(
            receiveTimeout: const Duration(seconds: 5),
            // 某些 CDN HEAD 不带 Content-Length, 强制 receive response headers
            followRedirects: true,
            validateStatus: (s) => s != null && s < 500,
          ),
        );
        fileSizeBytes = int.tryParse(
              headResponse.headers.value('content-length') ?? '',
            ) ??
            0;
      } catch (_) {
        // HEAD 失败不影响主流程, fileSize 留 0
      }
      pingStopwatch.stop();
      final latency = pingStopwatch.elapsedMilliseconds;

      // 2) Range 1MB 测速 (跟 web LunaTV 思路对齐)
      final speed = await _measureRangeDownloadSpeed(testUrl);

      return {
        'resolution': {'width': 0, 'height': 0}, // 直链没法从 M3U8 拿分辨率
        'downloadSpeed': speed,
        'latency': latency,
        'fileSize': fileSizeBytes,
        'success': true,
        'error': '',
      };
    } catch (e) {
      return {
        'resolution': {'width': 0, 'height': 0},
        'downloadSpeed': 0.0,
        'latency': 0,
        'fileSize': 0,
        'success': false,
        'error': e.toString(),
      };
    }
  }



  /// 获取M3U8流的片段URL列表
  Future<List<String>> _getSegmentUrls(String m3u8Url) async {
    try {
      final response = await _dio.get(m3u8Url);
      final content = response.data as String;
      return _parseSegmentsFromContent(content, m3u8Url);
    } catch (e) {
      return [];
    }
  }

  /// 从M3U8内容中解析片段URL
  /// v1.0.76: 跳过明显广告段 (URL host 跟 baseUrl 不同 + 含广告关键词)
  ///
  /// 用户反馈"播放到广告位置会重头播放" — 根因是视频源 m3u8 在广告位置插入
  /// 跨域广告 m3u8 segment, 加载失败 (跨域 / CORS / worker 转发不了) →
  /// libmpv HLS demuxer 触发内部 reload → state.position 跳 0.
  /// v1.0.75 position jump recovery 在这种场景下会死循环 (广告位置 → 0 →
  /// seek 回去 → 又到广告位置 → 又 0 → ...), 改成"每集只 seek 一次" 兜底
  /// (在 player_screen.dart 加 _recoverySeekedThisEpisode 锁).
  ///
  /// 本函数这边也加一个轻量过滤: 解析时跳过明显广告 segment, 测速选第一个
  /// 非广告段测. 这不影响实际播放 (播放还是 libmpv 主导), 但能让测速不被
  /// 广告段失败干扰 (之前 v1.0.74 修的 segment URL 解析错位类似, 都是
  /// 测速链路被广告段污染).
  List<String> _parseSegmentsFromContent(String content, String baseUrl) {
    final lines = content.split('\n').map((line) => line.trim()).toList();
    final segments = <String>[];

    // v1.0.76: 提取 baseUrl 的 host, 跨域 = 可能是广告段
    String? baseHost;
    try {
      baseHost = Uri.parse(baseUrl).host.toLowerCase();
    } catch (_) {}

    for (final line in lines) {
      // 跳过注释和空行
      if (line.startsWith('#') || line.isEmpty) {
        continue;
      }

      final absoluteUrl = _resolveUrl(line, baseUrl);

      // v1.0.76: 跳过明显广告段
      if (_looksLikeAdSegment(absoluteUrl, baseHost)) {
        continue;
      }

      segments.add(absoluteUrl);
    }

    return segments;
  }

  /// v1.0.76: 判断一个 segment URL 是不是"明显广告段"
  ///
  /// 启发式规则 (按可靠性排序):
  ///   1. URL 含广告关键词: \`/ad/\`, \`/ads/\`, \`/advert/\`, \`doubleclick\`,
  ///      \`googlevideo\` (部分广告走 googlevideo CDN), \`imasdk\`, \`adnxs\`
  ///   2. URL host 跟 baseUrl host 不一致 (跨域)
  ///      - 主 m3u8 在 \`cdn.example.com\`, 广告 m3u8 在 \`ads.example.org\`
  ///      - 例外: 同一域名的不同子域不算跨域 (\`a.cdn.com\` vs \`b.cdn.com\`
  ///        都属于 `cdn.com`)
  ///   3. URL path 含 `/ad/` 形式 (`/ad/seg.ts`, `/ads/seg.ts`)
  ///
  /// 注意: 这只是**轻量启发式**, 不会漏掉所有广告也不会误伤所有正片.
  /// 真要彻底跳过广告需要在 worker 端改 m3u8 内容 (识别 EXT-X-DISCONTINUITY
  /// 标签 + 重写 playlist), 不是 app 层能 100% 解决的事.
  /// 这里只解决"测速被广告段污染" 的次要问题, 主要问题 (v1.0.76 加的 episode
  /// 锁防死循环) 在 player_screen.dart.

  /// v1.0.76 + v2.1.4: 判断一个 segment URL 是不是"明显广告段"
  ///
  /// 启发式规则 (按可靠性排序):
  ///   1. URL 含广告关键词: `/ad/`, `/ads/`, `/advert/`, `doubleclick`,
  ///      `googlevideo` (部分广告走 googlevideo CDN), `imasdk`, `adnxs`,
  ///      `admarvel`, `pubmatic` — v1.0.76 加
  ///      + v2.1.4 加赌博站特征: 澳门/葡京/威尼斯/凯发/bbin/365/666/7899 等
  ///      (URL-encoded 形式 `%E6%BE%B3%E9%97%A8` 等, 实际 segment 出现时已
  ///      URL-encode; 部分赌博站用纯数字 host 66588/8800/6666/9999/7899
  ///      不走 path, 走 host 识别)
  ///   2. URL host 跟 baseUrl host 不一致 (跨域)
  ///      - 主 m3u8 在 `cdn.example.com`, 广告 m3u8 在 `ads.example.org`
  ///      - 例外: 同一域名的不同子域不算跨域 (`a.cdn.com` vs `b.cdn.com`
  ///        都属于 `cdn.com`)
  ///   3. URL path 含 `/ad/` 形式 (`/ad/seg.ts`, `/ads/seg.ts`)
  ///   4. **v2.1.4 新增**: 段 URL host 本身是赌博站特征 (4-5 位纯数字
  ///      host + .co/.org/.cc/.top/.vip/.cyou 冷门 TLD, e.g. 66588.co,
  ///      7899.cc, 8800.top, 6666.vip, 9999.cyou) — 主片 CDN 不会这样.
  ///      赌博站常用这种 pattern 绕封, 主流片源 CDN 都是 `cdn.example.com`
  ///      / `xxx.bilivideo.com` / `xxx.aliyuncs.com` 这种.
  ///
  /// 注意: 这只是**轻量启发式**, 不会漏掉所有广告也不会误伤所有正片.
  /// 真要彻底跳过广告需要在 worker 端改 m3u8 内容 (识别 EXT-X-DISCONTINUITY
  /// 标签 + 重写 playlist), 不是 app 层能 100% 解决的事.
  /// 这里只解决"测速被广告段污染" 的次要问题, 主要问题 (v1.0.76 加的 episode
  /// 锁防死循环) 在 player_screen.dart.
  static const List<String> _adKeywords = [
    '/ad/',
    '/ads/',
    '/advert/',
    'doubleclick',
    'googlevideo',
    'imasdk',
    'adnxs',
    'admarvel',
    'pubmatic',
    // v2.1.4: 赌博站特征 (URL-encoded 中文, 因 segment URL 在 m3u8
    //   里都是 encoded 形式)
    // 葡京 / 澳门葡京 / 威尼斯人 / 凯发 / 永利 / 银河 / 太阳城
    '%E8%91%A1%E4%BA%AC',     // 葡京
    '%E6%BE%B3%E9%97%A8',     // 澳门
    '%E5%87%AF%E5%8F%91',     // 凯发
    '%E9%93%AD%E6%B2%B3',     // 银河
    'bbin',                    // bbin 博彩平台
    'ag88',
    '365sb',
    '6668',
    '7899',
    '9999',
    '8800',
    '66588',                   // 66588.co 赌博站
  ];

  // v2.1.4: 赌博站 host TLD 冷门后缀. 主片 CDN 不会用这些.
  static const List<String> _gamblingTlds = [
    '.top',
    '.cc',
    '.vip',
    '.cyou',
    '.xyz',
    '.click',
    '.loan',
    '.work',
    '.kim',
    '.rest',
    '.support',
  ];

  // v2.1.4: 赌博站 host 模式: 4-5 位纯数字 (e.g. 66588, 7899, 8800, 9999).
  //   主片 CDN host 不会是纯数字, 都是 `xxx.com` / `cdn.xxx.com`.
  static bool _isGamblingHost(String host) {
    if (host.isEmpty) return false;
    // 纯数字 4-5 位 (66588, 7899, 8800, 6666, 9999)
    final isAllDigits = RegExp(r'^\d{4,5}$').hasMatch(host);
    if (isAllDigits) return true;
    // 冷门 TLD (top/cc/vip/cyou/xyz 等赌博站常用)
    for (final tld in _gamblingTlds) {
      if (host.endsWith(tld)) {
        // 二次确认: 域名没有 "cdn" / "static" / "media" / "video" / "img" / "vod" 字样
        //   (主片 CDN 常含这些). 不过赌博站也可能用 cdn 字样伪装, 这里宽松处理.
        //   主片用 top/cc/vip 等 TLD 几乎不存在, 判赌博够用.
        return true;
      }
    }
    return false;
  }

  bool _looksLikeAdSegment(String url, String? baseHost) {
    final lower = url.toLowerCase();

    // 规则 1: URL 关键词匹配
    for (final kw in _adKeywords) {
      if (lower.contains(kw)) return true;
    }

    // 规则 2: 跨域 (跟 baseUrl host 不同)
    String? segHost;
    if (baseHost != null && baseHost.isNotEmpty) {
      try {
        segHost = Uri.parse(url).host.toLowerCase();
        if (segHost.isNotEmpty && segHost != baseHost) {
          // 例外: 同一二级域名 (e.g. a.cdn.example.com vs b.cdn.example.com
          // 都属于 cdn.example.com, 不算广告)
          final baseParts = baseHost.split('.');
          final segParts = segHost.split('.');
          if (baseParts.length >= 2 && segParts.length >= 2) {
            final baseApex = baseParts.sublist(baseParts.length - 2).join('.');
            final segApex = segParts.sublist(segParts.length - 2).join('.');
            if (baseApex != segApex) {
              return true; // 二级域名不同, 算跨域广告
            }
          } else {
            return true; // host 解析不出来, 当跨域处理
          }
        }
      } catch (_) {}
    }

    // 规则 3 (v2.1.4): 段 URL host 是赌博站特征 (4-5 位纯数字 host 或
    //   冷门 TLD). 即便 host 跟 baseHost 一致 (同源 CDN 套了赌博域),
    //   也能识别.
    if (segHost == null) {
      try {
        segHost = Uri.parse(url).host.toLowerCase();
      } catch (_) {}
    }
    if (segHost != null && segHost.isNotEmpty && _isGamblingHost(segHost)) {
      return true;
    }

    return false;
  }

  bool _looksLikePlaylistUrl(String url) {
    try {
      final path = Uri.parse(url).path.toLowerCase();
      return path.endsWith('.m3u8') || path.endsWith('.m3u');
    } catch (_) {
      final lower = url.toLowerCase();
      return lower.contains('.m3u8') || lower.contains('.m3u');
    }
  }

  /// 解析相对 URL 为绝对 URL
  String _resolveUrl(String url, String baseUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    
    final baseUri = Uri.parse(baseUrl);
    if (url.startsWith('/')) {
      // 绝对路径
      return '${baseUri.scheme}://${baseUri.host}${baseUri.hasPort ? ':${baseUri.port}' : ''}$url';
    } else {
      // 相对路径
      final basePath = baseUri.path.substring(0, baseUri.path.lastIndexOf('/') + 1);
      return '${baseUri.scheme}://${baseUri.host}${baseUri.hasPort ? ':${baseUri.port}' : ''}$basePath$url';
    }
  }

  /// 测量网络延迟（RTT - Round Trip Time）
  Future<int> _measureLatency(String url) async {
    try {
      // 创建临时的 Dio 实例用于延迟测量
      final tempDio = Dio();
      tempDio.options.connectTimeout = const Duration(seconds: 5);
      tempDio.options.receiveTimeout = const Duration(seconds: 5);
      tempDio.options.headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Accept': '*/*',
      };
      
      // 使用 HEAD 请求测量延迟，减少数据传输
      final stopwatch = Stopwatch()..start();
      
      try {
        await tempDio.head(url);
        stopwatch.stop();
        final latency = stopwatch.elapsedMilliseconds;
        return latency;
      } on DioException catch (dioError) {
        // 对于 DioException，检查是否收到了服务器响应
        if (dioError.response != null) {
          // 有响应，说明网络连接成功，只是状态码不是 2xx
          stopwatch.stop();
          final latency = stopwatch.elapsedMilliseconds;
          return latency;
        } else {
          // 没有响应，说明连接失败
          return -1;
        }
      }
      
    } catch (e) {
      return -1; // 返回 -1 表示测量失败
    }
  }


  /// 从 M3U8 文件获取分辨率
  Future<Map<String, int>> _getResolutionFromM3U8(String m3u8Url) async {
    try {
      final response = await _dio.get(m3u8Url);
      final content = response.data as String;
      final lines = content.split('\n').map((line) => line.trim()).toList();
      
      for (final line in lines) {
        if (line.startsWith('#EXT-X-STREAM-INF:')) {
          final params = <String, String>{};
          final parts = line.substring('#EXT-X-STREAM-INF:'.length).split(',');
          
          for (final part in parts) {
            final keyValue = part.split('=');
            if (keyValue.length == 2) {
              params[keyValue[0].trim()] = keyValue[1].trim();
            }
          }
          
          if (params.containsKey('RESOLUTION')) {
            final resolution = params['RESOLUTION']!;
            final dimensions = resolution.split('x');
            if (dimensions.length == 2) {
              return {
                'width': int.tryParse(dimensions[0]) ?? 0,
                'height': int.tryParse(dimensions[1]) ?? 0,
              };
            }
          }
        }
      }
      
      return {'width': 0, 'height': 0};
    } catch (e) {
      return {'width': 0, 'height': 0};
    }
  }

  /// 测量下载速度 (v2.1.26: 改成下完整第 1 个 segment, 跟 web LunaTV 的
  ///   hls.js FRAG_LOADED 思路一致 — 测的是真实分片下载速度, 跟 libmpv
  ///   实际播放走的链路完全一样, 比之前的 Range 64KB 准)
  ///
  /// 之前 v1.0.45 用的 Range 64KB 测的是"首字节 + 64KB" 速度, 在 CDN 边缘
  /// 节点上经常虚高 (CDN burst 给首字节快, 实际播放时 m3u8 重写链 + libmpv
  /// 加载是另一条路径). 用户看着 5MB/s 实际播放卡, 就是这个根因.
  ///
  /// 现在的做法: 拿 m3u8 解析后, 取第 1 个 segment (非广告段), 走
  /// urlWrapper 包装 (跟播放同一条 m3u8 重写链), 完整 GET 拿数据,
  /// 用实际 size/time 算. 跟 web LunaTV hls.js 的 FRAG_LOADED 事件
  /// (size / loadTime) 等价. 测的就是 libmpv 实际播放走的链路速度.
  ///
  /// 1 个 1080p 5s segment 约 2-5MB, 慢链 (500KB/s) 10s 内能下完.
  /// 12s timeout 兜底, 跟 web 版 9000ms 同量级, 防止卡死.
  Future<double> _measureSegmentSpeeds(
    List<String> segments, {
    String Function(String)? urlWrapper,
  }) async {
    final playableSegments =
        segments.where((url) => !_looksLikePlaylistUrl(url)).toList();
    // v2.3.4: 第 1 个分片经常是 init.mp4 / 极短片头 / 广告探针, 只有几 KB,
    //   拿它算速度会显示 1KB/s / 4KB/s。优先跳过第 1 个, 后面不够再退回全量。
    final candidates = playableSegments.length > 3
        ? playableSegments.skip(1).take(3)
        : playableSegments.take(3);
    final testUrls = candidates
        .map((url) => urlWrapper != null ? urlWrapper(url) : url)
        .toList();
    if (testUrls.isEmpty) return 0.0;

    final results = await Future.wait(
      testUrls.map(_measureDownloadSpeedFast),
    );
    final valid = results.where((v) => v > 0).toList()..sort();
    if (valid.isEmpty) return 0.0;
    return valid[valid.length ~/ 2];
  }

  Future<double> _measureDownloadSpeedFast(String url) async {
    try {
      final stopwatch = Stopwatch()..start();
      var bytes = 0;
      // v2.3.4: 不再完整下载分片。完整 segment 在后台 6 源并发测速时太重,
      //   6 秒外层 timeout 很容易触发, 最后掉到只有延迟的 fallback。
      //   改成真实分片抽样: Range 取前 1MB, 流式读取到 512KB 或 2.8s
      //   就停止。这样测的是视频分片链路, 不是 playlist 文本, 也不会拖垮并发。
      final response = await _dio.get(
        url,
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: const Duration(seconds: 4),
          headers: const {'Range': 'bytes=0-1048575'},
        ),
      );
      final body = response.data as ResponseBody;
      await for (final chunk in body.stream) {
        bytes += chunk.length;
        if (bytes >= 512 * 1024) break;
        if (stopwatch.elapsedMilliseconds >= 2800) break;
      }
      stopwatch.stop();
      // 小于 64KB 的样本多数是 init/探针/异常小片段, 不拿来显示速度。
      if (bytes < 64 * 1024) return 0.0;
      final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000.0;
      if (elapsedSeconds <= 0) return 0.0;
      return (bytes / 1024) / elapsedSeconds; // KB/s
    } catch (e) {
      return 0.0;
    }
  }

  /// 测量下载速度 (v2.1.27: Range 1MB, 跟 web LunaTV 思路对齐)
  ///
  /// 用在 `_measureDirectStream`: 直链 (非 m3u8) mp4 等大文件测速.
  /// 之前 v2.1.26 用 `_measureDownloadSpeedFast` (完整 GET) 测直链,
  /// 500MB-2GB 的 mp4 完整 GET 会下完整个文件 → 流量爆炸 + 12s timeout
  /// 永远返 0.
  ///
  /// 现在的做法: Range bytes=0-1048575 只取前 1MB, 算 speed = 1MB / elapsed.
  /// 跟 web LunaTV iPad 简化路径思路一致 — 不下完整文件, 拿代表性块.
  /// m3u8 测速用 `_measureDownloadSpeedFast` (完整 segment), 直链用这个 (Range 1MB).
  ///
  /// 1MB 在 1Mbps 链路上 ~8s 传完, 慢链 12s timeout 兜底.
  /// 跟 m3u8 测速一样的"拿代表性块"思路, 跟 web LunaTV 对齐.
  Future<double> _measureRangeDownloadSpeed(String url) async {
    try {
      final stopwatch = Stopwatch()..start();
      // Range bytes=0-1048575 = 1MB. 跟 web LunaTV 思路一致.
      final response = await _dio.get(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          // v2.1.27: 跟 m3u8 测速一样 12s. 1MB 在 1Mbps 链路上 ~8s,
          //   慢链给 12s 留余量.
          receiveTimeout: const Duration(seconds: 12),
          headers: const {'Range': 'bytes=0-1048575'},
        ),
      );
      stopwatch.stop();
      final bytes = (response.data as Uint8List).length;
      if (bytes == 0) return 0.0;
      // 兼容服务端不返回 206 而是直接 200 全量 (少数 CDN 不支持 Range,
      //   会返完整文件, bytes 会是完整 size; 我们用实际 elapsed 算
      //   真实速度, 不强制 1MB)
      final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000.0;
      if (elapsedSeconds <= 0) return 0.0;
      return (bytes / 1024) / elapsedSeconds; // KB/s
    } catch (e) {
      return 0.0;
    }
  }

  /// 测量下载速度 (旧版: 3 完整段, 保留以防新方法在某些 CDN 失败)
  Future<double> _measureDownloadSpeed(List<String> segments) async {
    try {
      // 使用前3个片段进行测速
      final segmentsToTest = segments.take(3).toList();

      final stopwatch = Stopwatch()..start();
      int totalBytes = 0;
      int successfulDownloads = 0;

      // 并发下载片段
      final futures = segmentsToTest.map((segmentUrl) async {
        try {
          final response = await _dio.get(
            segmentUrl,
            options: Options(
              responseType: ResponseType.bytes,
              receiveTimeout: const Duration(seconds: 5),
            ),
          );

          final bytes = (response.data as Uint8List).length;
          totalBytes += bytes;
          successfulDownloads++;
        } catch (e) {
          // 忽略下载失败的片段
        }
      });
      
      await Future.wait(futures);
      stopwatch.stop();
      
      if (successfulDownloads == 0 || totalBytes == 0) {
        return 0.0;
      }
      
      // 计算下载速度 (KB/s)
      final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000.0;
      final downloadSpeed = (totalBytes / 1024) / elapsedSeconds;
      
      return downloadSpeed;
    } catch (e) {
      return 0.0;
    }
  }

  /// 批量获取所有源的流信息并选择最佳源
  Future<Map<String, dynamic>> preferBestSource(List<dynamic> allSources) async {
    if (allSources.isEmpty) {
      return {
        'bestSource': null,
        'allSourcesSpeed': <String, Map<String, dynamic>>{},
        'error': '没有可用的源',
      };
    }
    
    if (allSources.length == 1) {
      return {
        'bestSource': allSources.first,
        'allSourcesSpeed': <String, Map<String, dynamic>>{},
        'error': '',
      };
    }
    
    // 为每个源选择要测试的集数链接
    final testUrls = <String, String>{}; // sourceId -> episodeUrl
    
    for (final source in allSources) {
      final sourceId = '${source.source}_${source.id}';
      String episodeUrl;
      
      // 选择第二集链接，如果没有第二集则选择第一集
      if (source.episodes.length >= 2) {
        episodeUrl = source.episodes[1]; // 第二集
      } else if (source.episodes.isNotEmpty) {
        episodeUrl = source.episodes[0]; // 第一集
      } else {
        continue; // 跳过没有集数的源
      }
      
      testUrls[sourceId] = episodeUrl;
    }
    
    // 并发获取所有源的流信息
    final futures = testUrls.entries.map((entry) async {
      final sourceId = entry.key;
      final episodeUrl = entry.value;
      
      try {
        final streamInfo = await getStreamInfo(episodeUrl).timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            return {
              'resolution': {'width': 0, 'height': 0},
              'downloadSpeed': 0.0,
              'latency': 0,
              'success': false,
              'error': '获取流信息超时',
            };
          },
        );
        return MapEntry(sourceId, streamInfo);
      } catch (e) {
        return MapEntry(sourceId, {
          'resolution': {'width': 0, 'height': 0},
          'downloadSpeed': 0.0,
          'latency': 0,
          'success': false,
          'error': e.toString(),
        });
      }
    });
    
    // 等待所有流信息获取完成
    final results = await Future.wait(futures);
    final streamInfoResults = <String, Map<String, dynamic>>{};
    for (final result in results) {
      streamInfoResults[result.key] = result.value;
    }
    
    // 找出所有有效速度的最大值，用于线性映射
    final validSpeeds = <double>[];
    final validPings = <int>[];
    
    for (final source in allSources) {
      final sourceId = '${source.source}_${source.id}';
      final streamInfo = streamInfoResults[sourceId];
      
      if (streamInfo != null && streamInfo['success']) {
        final downloadSpeed = streamInfo['downloadSpeed'] as double;
        final latency = streamInfo['latency'] as int;
        
        if (downloadSpeed > 0) {
          validSpeeds.add(downloadSpeed);
        }
        if (latency > 0) {
          validPings.add(latency);
        }
      }
    }
    
    // 计算基准值
    final maxSpeed = validSpeeds.isNotEmpty ? validSpeeds.reduce((a, b) => a > b ? a : b) : 1024.0; // 默认1MB/s作为基准
    final minPing = validPings.isNotEmpty ? validPings.reduce((a, b) => a < b ? a : b) : 50;
    final maxPing = validPings.isNotEmpty ? validPings.reduce((a, b) => a > b ? a : b) : 1000;
    
    // 计算每个源的评分并排序
    final sourceScores = <MapEntry<dynamic, double>>[];
    final allSourcesSpeed = <String, Map<String, dynamic>>{};
    
    for (final source in allSources) {
      final sourceId = '${source.source}_${source.id}';
      final streamInfo = streamInfoResults[sourceId];
      
      if (streamInfo == null || !streamInfo['success']) {
        continue; // 跳过获取失败的源
      }
      
      final downloadSpeed = streamInfo['downloadSpeed'] as double;
      final latency = streamInfo['latency'] as int;
      final resolutionData = streamInfo['resolution'] as Map<String, int>;
      
      // 转换分辨率为标准格式
      final resolution = _convertResolutionToString(resolutionData);
      
      // 计算综合评分
      final score = _calculateSourceScore(
        resolution,
        downloadSpeed,
        latency,
        maxSpeed,
        minPing,
        maxPing,
      );
      
      sourceScores.add(MapEntry(source, score));
      
      allSourcesSpeed[sourceId] = {
        'quality': resolution,
        'loadSpeed': _formatDownloadSpeed(downloadSpeed),
        'pingTime': '${latency}ms',
      };
    }
    
    // 按综合评分排序，选择最佳播放源
    sourceScores.sort((a, b) => b.value.compareTo(a.value));
    
    final bestSource = sourceScores.isNotEmpty ? sourceScores.first.key : allSources.first;
    
    return {
      'bestSource': bestSource,
      'allSourcesSpeed': allSourcesSpeed,
      'error': '',
    };
  }

  /// 计算源的综合评分
  /// 使用线性映射算法，基于实际测速结果动态调整评分范围
  /// 包含分辨率、下载速度和网络延迟三个维度的评分
  double _calculateSourceScore(
    String quality,
    double speedKBps,
    int latencyMs,
    double maxSpeed,
    int minPing,
    int maxPing,
  ) {
    double score = 0;

    // 分辨率评分 (40% 权重)
    final qualityScore = _getQualityScore(quality);
    score += qualityScore * 0.4;

    // 下载速度评分 (40% 权重) - 基于最大速度线性映射
    final speedScore = _getSpeedScore(speedKBps, maxSpeed);
    score += speedScore * 0.4;

    // 网络延迟评分 (20% 权重) - 基于延迟范围线性映射
    final pingScore = _getPingScore(latencyMs, minPing, maxPing);
    score += pingScore * 0.2;

    return (score * 100).round() / 100.0; // 保留两位小数
  }

  /// 获取分辨率评分
  double _getQualityScore(String quality) {
    switch (quality.toLowerCase()) {
      case '4k':
      case '2160p':
        return 100;
      case '2k':
      case '1440p':
        return 85;
      case '1080p':
        return 75;
      case '720p':
        return 60;
      case '480p':
        return 40;
      case 'sd':
      case '360p':
        return 20;
      default:
        return 0;
    }
  }

  /// 获取下载速度评分
  double _getSpeedScore(double speedKBps, double maxSpeed) {
    if (speedKBps <= 0) return 30; // 无效速度给默认分
    
    // 基于最大速度线性映射，最高100分
    final speedRatio = speedKBps / maxSpeed;
    return (speedRatio * 100).clamp(0.0, 100.0);
  }

  /// 获取网络延迟评分
  double _getPingScore(int latencyMs, int minPing, int maxPing) {
    if (latencyMs <= 0) return 0; // 无效延迟给0分
    
    // 如果所有延迟都相同，给满分
    if (maxPing == minPing) return 100;
    
    // 线性映射：最低延迟=100分，最高延迟=0分
    final pingRatio = (maxPing - latencyMs) / (maxPing - minPing);
    return (pingRatio * 100).clamp(0.0, 100.0);
  }

  /// 将分辨率数据转换为标准字符串格式
  String _convertResolutionToString(Map<String, int> resolutionData) {
    final width = resolutionData['width'] ?? 0;
    final height = resolutionData['height'] ?? 0;
    
    if (width == 0 || height == 0) return '未知';
    
    // 根据经典宽度判断分辨率
    if (width >= 3840) return '4K';      // 4K: 3840x2160
    if (width >= 2560) return '2K';      // 2K: 2560x1440
    if (width >= 1920) return '1080p';   // 1080p: 1920x1080
    if (width >= 1280) return '720p';    // 720p: 1280x720
    if (width >= 854) return '480p';     // 480p: 854x480
    if (width >= 640) return '360p';     // 360p: 640x360
    
    return 'SD';
  }

  /// 格式化下载速度为字符串
  String _formatDownloadSpeed(double speedKBps) {
    if (speedKBps <= 0) return '超时';
    
    if (speedKBps >= 1024) {
      // 大于等于1MB/s，显示为MB/s
      final speedMBps = speedKBps / 1024;
      return '${speedMBps.toStringAsFixed(1)}MB/s';
    } else {
      // 小于1MB/s，显示为KB/s
      return '${speedKBps.toStringAsFixed(1)}KB/s';
    }
  }


  /// 并发测速所有源并实时回调结果
  Future<void> testSourcesWithCallback(
    List<dynamic> allSources,
    Function(String sourceId, Map<String, dynamic> speedData) onSourceCompleted, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (allSources.isEmpty) return;
    
    // 为每个源选择要测试的集数链接
    final testUrls = <String, String>{}; // sourceId -> episodeUrl
    
    for (final source in allSources) {
      final sourceId = '${source.source}_${source.id}';
      String episodeUrl;
      
      // 选择第二集链接，如果没有第二集则选择第一集
      if (source.episodes.length >= 2) {
        episodeUrl = source.episodes[1]; // 第二集
      } else if (source.episodes.isNotEmpty) {
        episodeUrl = source.episodes[0]; // 第一集
      } else {
        continue; // 跳过没有集数的源
      }
      
      testUrls[sourceId] = episodeUrl;
    }
    
    // 创建并发测速任务
    final futures = testUrls.entries.map((entry) async {
      final sourceId = entry.key;
      final episodeUrl = entry.value;
      
      try {
        final streamInfo = await getStreamInfo(episodeUrl).timeout(
          timeout,
          onTimeout: () {
            return {
              'resolution': {'width': 0, 'height': 0},
              'downloadSpeed': 0.0,
              'latency': 0,
              'success': false,
              'error': '获取流信息超时',
            };
          },
        );
        
        if (streamInfo['success']) {
          final downloadSpeed = streamInfo['downloadSpeed'] as double;
          final latency = streamInfo['latency'] as int;
          final resolutionData = streamInfo['resolution'] as Map<String, int>;
          
          // 转换分辨率为标准格式
          final resolution = _convertResolutionToString(resolutionData);
          
          final speedData = {
            'quality': resolution,
            'loadSpeed': _formatDownloadSpeed(downloadSpeed),
            'pingTime': '${latency}ms',
          };
          
          // 实时回调结果
          onSourceCompleted(sourceId, speedData);
        } else {
          // 测速失败的情况
          final speedData = {
            'quality': '未知',
            'loadSpeed': '超时',
            'pingTime': '超时',
          };
          onSourceCompleted(sourceId, speedData);
        }
      } catch (e) {
        // 异常情况
        final speedData = {
          'quality': '未知',
          'loadSpeed': '超时',
          'pingTime': '超时',
        };
        onSourceCompleted(sourceId, speedData);
      }
    });
    
    // 并发执行所有测速任务，每个任务完成后会立即触发回调
    await Future.wait(futures);
  }

  /// 释放资源
  void dispose() {
    _dio.close();
  }
}

class _VariantPlaylist {
  final String url;
  final Map<String, int> resolution;
  final int bandwidth;

  const _VariantPlaylist({
    required this.url,
    required this.resolution,
    required this.bandwidth,
  });

  int get score {
    final height = resolution['height'] ?? 0;
    if (height > 0) return height * 1000000 + bandwidth;
    return bandwidth;
  }
}

/// v2.3.11: _downloadHead256K 的返回值. 跟 _VariantPlaylist 平行放在
///   m3u8_service.dart 文件底部, 跟其他私有 class 一起.
class _DownloadResult {
  final int bytes;
  final int elapsedMs;
  final String? content;

  const _DownloadResult({
    required this.bytes,
    required this.elapsedMs,
    required this.content,
  });
}
