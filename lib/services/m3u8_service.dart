import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';

/// M3U8 解析和测速服务
class M3U8Service {
  final Dio _dio = Dio();

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
  Future<Map<String, dynamic>> getStreamInfo(
    String streamUrl, {
    String? originalUrl,
    String Function(String)? urlWrapper,
  }) async {
    try {
      // 1) GET M3U8 manifest 一次, 同时解析 segments 和 resolution
      //    v2.3.0: 视频加速删了, originalUrl 不需要了, 传 null 走 streamUrl.
      //    即便上游还传 originalUrl (老 player_screen 调法), 也不影响解析
      //    (原 m3u8 manifest 里的相对路径用 upstream base / worker base
      //     解析都行, 段是 absolute URL 走 _parseSegmentsFromContent 二次
      //     检查, 没解析对会 fallback 到 upstream base 重新拼).
      final m3u8Content = await _fetchM3U8Content(streamUrl);
      if (m3u8Content == null) {
        // 不是 M3U8, 走直链测速
        return await _measureDirectStream(streamUrl, urlWrapper: urlWrapper);
      }
      final baseForSegments = originalUrl ?? streamUrl;
      final segments = _parseSegmentsFromContent(m3u8Content, baseForSegments);
      final resolution = _parseResolutionFromContent(m3u8Content);
      if (segments.isEmpty) {
        // M3U8 但没解析到 segment (罕见, 比如只有 master playlist 没有 variant)
        return await _measureDirectStream(streamUrl, urlWrapper: urlWrapper);
      }

      // 2) 并发: HEAD 测延迟 + Range 测速 (都用第 1 个 segment, 反正测的是同一条线路)
      //    v2.3.0: 视频加速删了, urlWrapper 不需要, 走 firstSegment 直连 CDN.
      final firstSegment = segments.first;
      final testUrl = urlWrapper != null ? urlWrapper(firstSegment) : firstSegment;
      final futures = await Future.wait([
        _measureLatency(testUrl),
        _measureDownloadSpeedFast(testUrl),
      ]);
      final latency = futures[0] as int;
      final downloadSpeedKBps = futures[1] as double;

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
  Future<double> _measureDownloadSpeedFast(String url) async {
    try {
      final stopwatch = Stopwatch()..start();
      // 不带 Range, 完整下载第 1 个 segment. 跟 web LunaTV 的 hls.js
      //   FRAG_LOADED 等价 — 真实分片下载速度.
      final response = await _dio.get(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          // v2.1.26: 8s -> 12s. 完整 segment 在慢链上 10s 都有可能,
          //   12s 给慢网留余量. web LunaTV 用 9000ms timeout, 跟这同量级.
          receiveTimeout: const Duration(seconds: 12),
        ),
      );
      stopwatch.stop();
      final bytes = (response.data as Uint8List).length;
      if (bytes == 0) return 0.0;
      // 兼容服务端不返回 206 而是直接 200 全量, 也兼容 206 部分内容
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

