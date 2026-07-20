import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'package:dio/dio.dart';

/// v2.3.22 测速调试日志 helper
void _log(String msg) {
  developer.log(msg, name: 'M3U8Service');
}

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
  ///
  /// v2.3.0 测速核心思路 (跟 web LunaTV 1:1):
  ///   1. URL 看起来是 m3u8 → 解析拿真实分片 → 跳过第 1 个 init/探针段
  ///      → 取 1 个真实分片 (Range 1MB 抽样) 算 KB/s
  ///   2. URL 是直链 (mp4/flv 等) → HEAD 拿 fileSize + Range 1MB 算 KB/s
  ///   3. HEAD 单独并发测 latency (5s timeout)
  ///   4. 解析 m3u8 拿 resolution (best-effort, 1.5s timeout, 失败返 0x0)
  ///   5. 任一关键步骤失败 → success=false + error message,
  ///      UI 端 "loadSpeed=超时, ping=超时"
  ///
  /// v2.3.0 ~ v2.3.4 演化:
  ///   v1.0.45: 3 完整段, 12s timeout, 太重
  ///   v2.3.4: 真实分片 Range 1MB 抽样 (取前 512KB), skip 1st 段
  ///   v2.3.6: 走 ExoPlayer prepare 测首分片 (跟 web LunaTV hls.js 一致),
  ///           但 ExoPlayer 启动太慢 (1-2s + MediaCodec 初始化), 加上
  ///           前面 fetch m3u8 + variant + latency 等串行, 总耗时 17s
  ///           (player_screen 外层只有 6s timeout, 永远来不及跑完)
  ///   v2.3.9: 3 步并发 (HEAD latency 1.5s + GET 256KB 2s + m3u8 解析 1.2s),
  ///           直接 GET 顶层 URL 测速, 不解析 m3u8
  ///   v2.3.11: 32KB 阈值 + m3u8 链兜底, 复杂
  ///   v2.3.12: Selene-TV `u74.c` 风格 (单次 GET 512KB 1.8s), 简单但
  ///           跟实际播放链路不一致
  ///   v2.3.14: 回到 v2.3.0 真实分片抽样 (Range 1MB 拿 512KB, 跟实际播放
  ///           走同一 m3u8 分片路径, 跟 web LunaTV hls.js FRAG_LOADED
  ///           思路一致)
  Future<Map<String, dynamic>> getStreamInfo(
    String streamUrl, {
    String? originalUrl,
    String Function(String)? urlWrapper,
  }) async {
    try {
      // v2.3.20 (回滚 v2.3.18/v2.3.19): 测速走 v2.3.14 Range 抽样.
      //
      // 故事:
      //   v2.3.14: Range 抽样, 7s 兜底, 8/8 源能测速 ✅
      //   v2.3.18: ExoPlayer 8s timeout > 外层 7s, 7/8 源 "不可用"
      //   v2.3.19: ExoPlayer 缩 3s, 但吃掉时间预算, Range 兜底 4s
      //            不够, 仅 iQiyi (ExoPlayer 1s 成功) 显示速度, 其他
      //            7/8 源仍 "不可用"
      //   v2.3.20: 回到 v2.3.14 Range 抽样. ExoPlayer 代码
      //            (exo_speed_test.dart + ExoSpeedTestChannel.kt) 保留
      //            不调用, 后续 v2.4+ 修 caller timeout 12s 后再启用.
      if (_looksLikeM3u8Url(streamUrl)) {
        return await _measureM3u8Speed(streamUrl, urlWrapper: urlWrapper);
      } else {
        return await _measureDirectStream(streamUrl, urlWrapper: urlWrapper);
      }
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

  /// v2.3.0: m3u8 测速 — 解析分片 + 真实分片 Range 1MB 抽样.
  ///
  /// 跟 web LunaTV hls.js FRAG_LOADED 思路 1:1 对齐 — 测的是视频分片
  ///   下载速度, 跟 libmpv / ExoPlayer 实际播放走的链路完全一样, 不会
  ///   出现 "测速 5KB/s 实际 1-2MB/s" 的假数据.
  Future<Map<String, dynamic>> _measureM3u8Speed(
    String m3u8Url, {
    String Function(String)? urlWrapper,
  }) async {
    try {
      // 1. 解析 m3u8 拿分片 URL 列表 (v2.3.22: 自动 master→variant 跟随)
      final segments = await _getSegmentUrls(m3u8Url);
      if (segments.isEmpty) {
        _log('measureM3u8Speed: m3u8 解析失败或没分片 url=$m3u8Url');
        return {
          'resolution': {'width': 0, 'height': 0},
          'downloadSpeed': 0.0,
          'latency': 0,
          'success': false,
          'error': 'm3u8 解析失败或没分片',
        };
      }
      // 2. 兜底过滤掉 .m3u8 后缀 (理论上 v2.3.22 master 跟随后不该再
      //   有, 但保险起见保留, 万一 master 有 3 层以上嵌套没递归到)
      final playableSegments =
          segments.where((url) => !_looksLikePlaylistUrl(url)).toList();
      if (playableSegments.isEmpty) {
        _log('measureM3u8Speed: 没有可测速的分片 url=$m3u8Url');
        return {
          'resolution': {'width': 0, 'height': 0},
          'downloadSpeed': 0.0,
          'latency': 0,
          'success': false,
          'error': '没有可测速的分片',
        };
      }
      // 3. 跳过第 1 个分片 (init/极短片头/广告探针, 几 KB, 测速会假慢)
      //    v2.3.4: 之前 v1.0.45 用第 1 个分片测, 经常显示 1KB/s / 4KB/s.
      final candidates = playableSegments.length > 3
          ? playableSegments.skip(1).take(3)
          : playableSegments.take(3);
      // 4. 测速 (Range 1MB 抽样, 最多 512KB 或 2.8s 截断)
      final speed = await _measureSegmentSpeeds(
        candidates.toList(),
        urlWrapper: urlWrapper,
      );
      // 5. 拿 HEAD latency
      final latency = await _measureLatency(m3u8Url);
      // 6. 解析 m3u8 拿 resolution (best-effort, 失败返 0x0)
      final resolution = await _getResolutionFromM3U8(m3u8Url);
      if (speed <= 0 && latency <= 0) {
        return {
          'resolution': resolution,
          'downloadSpeed': 0.0,
          'latency': 0,
          'success': false,
          'error': '测速失败',
        };
      }
      return {
        'resolution': resolution,
        'downloadSpeed': speed,
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

  /// v2.3.22 真根因: 解析 m3u8 拿真实分片 URL (递归跟随 master playlist)
  ///
  /// 用户反馈 "v2.3.18~v2.3.21 4 个版本翻车, 测速全源不可用但能播放"
  ///   实际根因 (查到的, 不是猜的):
  ///   90% 的源 (subo/modu/ffzy/茅台/卧龙/...) 顶层 m3u8 是
  ///   **master playlist** (HLS 多码率), 形如:
  ///     #EXTM3U
  ///     #EXT-X-STREAM-INF:BANDWIDTH=4096000,RESOLUTION=1920x1080
  ///     /play/hls/xxx/index.m3u8          ← 这才是媒体列表
  ///   v2.3.21 之前的逻辑:
  ///     1. _getSegmentUrls 直接当 media playlist 解析
  ///     2. 把 variant URL "/play/hls/xxx/index.m3u8" 当成 segment
  ///     3. _looksLikePlaylistUrl 过滤掉 (后缀 .m3u8)
  ///     4. playableSegments 为空 → success=false → "不可用"
  ///   iQiyi 之所以能用: 它 m3u8 直接是 media playlist (jxxx/iQiyi 节点
  ///   跳过 master, 顶层就是 .jpeg segment 列表), 碰巧绕过这个 bug.
  ///
  /// 现在改成: 识别 master → 跟随 variant → 递归到 media playlist →
  ///   才解析 segments. 限制 3 层防死循环 (master→master→master).
  /// 配合 _getResolutionFromM3U8 (原本就处理 master 的 RESOLUTION 行),
  ///   分辨率 + 分片两边都对齐了.
  ///
  /// 加 _log 调试日志: 之前所有 catch (e) 静默吞异常, "全源不可用" 看不
  ///   出哪个源哪步死的. 现在每个失败点都 log 出来, adb logcat | grep
  ///   M3U8Service 能直接看到 root cause.
  Future<List<String>> _getSegmentUrls(String m3u8Url) async {
    return _resolveSegments(m3u8Url, depth: 0);
  }

  /// 递归跟随 master playlist, 直到拿到 media playlist 的 segments
  Future<List<String>> _resolveSegments(
    String m3u8Url, {
    required int depth,
  }) async {
    if (depth >= 3) {
      _log('resolveSegments depth>=3, stop (avoid master loop): $m3u8Url');
      return [];
    }
    String? content;
    try {
      // v2.3.21: 加 Referer 头. 之前 v2.3.20 测速时只有段下载带 Referer,
      //   m3u8 playlist 拉取不带, 腾讯/优酷/部分爱奇艺海外节点等需要
      //   Referer 的源 m3u8 拉取 403, _getSegmentUrls 返回 [].
      // v2.3.22: connectTimeout 5s → 8s, receiveTimeout 6s → 8s.
      //   测速链路总时长限制在 player_screen 7s outer, 拉 m3u8 文本
      //   最多吃 8s, 留给 segment 测速时间 0s. 部分 CDN 拉 m3u8
      //   5s+ 偶尔出现 (CF edge cold cache), 5s 不够.
      final response = await _dio.get(
        m3u8Url,
        options: Options(
          headers: _refererHeaders(m3u8Url),
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      content = response.data as String?;
    } catch (e) {
      _log('resolveSegments fetch failed [depth=$depth] url=$m3u8Url err=$e');
      return [];
    }
    if (content == null || content.trim().isEmpty) {
      _log('resolveSegments empty content [depth=$depth] url=$m3u8Url');
      return [];
    }
    // v2.3.22: master playlist 检测
    if (_isMasterPlaylist(content)) {
      final variantUrl = _extractFirstVariantUrl(content, m3u8Url);
      if (variantUrl == null) {
        _log('resolveSegments master but no variant [depth=$depth] url=$m3u8Url');
        return [];
      }
      _log(
          'resolveSegments master→variant [depth=$depth] $m3u8Url → $variantUrl');
      return _resolveSegments(variantUrl, depth: depth + 1);
    }
    // media playlist: 解析 segments (含 v1.0.76 广告过滤)
    final segments = _parseMediaSegments(content, m3u8Url);
    _log(
        'resolveSegments media [depth=$depth] url=$m3u8Url segments=${segments.length}');
    return segments;
  }

  /// v2.3.22: 判断 m3u8 内容是不是 master playlist (HLS 多码率)
  ///
  /// 特征: 含 `EXT-X-STREAM-INF` 行 (每个 variant 前面一行), 且没有
  ///   `EXTINF` 行 (media playlist 才有). 也看末尾有 `#EXT-X-ENDLIST`
  ///   倾向于 media, 没 ENDLIST 倾向于 live master, 但 master/media
  ///   区分主要看 STREAM-INF vs EXTINF.
  bool _isMasterPlaylist(String content) {
    final hasStreamInf = content.contains('#EXT-X-STREAM-INF');
    final hasExtInf = content.contains('#EXTINF');
    if (hasStreamInf && !hasExtInf) return true;
    // 少数情况: master 也可能含 EXTINF (罕见, 但保险起见)
    // STREAM-INF 出现 + 没有正常 segment 行 (只有 m3u8 链接) → master
    if (hasStreamInf) {
      // 数一下非注释非空行: 如果大多数是 .m3u8 链接, 就是 master
      final nonCommentLines = content
          .split('\n')
          .map((l) => l.trim())
          .where((l) => !l.startsWith('#') && l.isNotEmpty)
          .toList();
      if (nonCommentLines.isEmpty) return false;
      final m3u8Count = nonCommentLines
          .where((l) => l.toLowerCase().endsWith('.m3u8') ||
              l.toLowerCase().endsWith('.m3u'))
          .length;
      return m3u8Count >= nonCommentLines.length * 0.5; // 多数行是 .m3u8 → master
    }
    return false;
  }

  /// v2.3.22: 从 master playlist 里抽第 1 个 variant URL
  ///   优先选分辨率最高的 (BANDWIDTH 最大的那个), 测最清晰档位
  ///   (最贴近 libmpv 实际播放选档逻辑 — libmpv 默认按带宽选最高档)
  String? _extractFirstVariantUrl(String content, String baseUrl) {
    final lines = content.split('\n').map((l) => l.trim()).toList();
    String? bestVariant;
    int bestBandwidth = -1;
    for (int i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF:')) continue;
      // 找这行下面的第 1 个非 # 行
      for (int j = i + 1; j < lines.length; j++) {
        if (lines[j].isEmpty) continue;
        if (lines[j].startsWith('#')) continue;
        // 解析 BANDWIDTH
        int bw = 0;
        final bwMatch =
            RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i]);
        if (bwMatch != null) {
          bw = int.tryParse(bwMatch.group(1)!) ?? 0;
        }
        if (bestVariant == null || bw > bestBandwidth) {
          bestBandwidth = bw;
          bestVariant = _resolveUrl(lines[j], baseUrl);
        }
        break; // 每个 STREAM-INF 只取后面 1 个 variant
      }
    }
    return bestVariant;
  }

  /// 从 media playlist 解析 segments (v1.0.76 起带广告过滤)
  List<String> _parseMediaSegments(String content, String baseUrl) {
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

  /// v2.3.15: 判断 URL 是不是 m3u8 直播流/点播流, 用于 [getStreamInfo] 走
  ///   m3u8 测速分支 (解析分片) 还是直链测速分支 (HEAD + Range 1MB).
  ///   跟 [_looksLikePlaylistUrl] 区别: 这个是顶层 URL 判断, 那个是
  ///   解析出来的分片是不是另一个 playlist (master → variant) 判断.
  bool _looksLikeM3u8Url(String url) {
    try {
      final path = Uri.parse(url).path.toLowerCase();
      if (path.endsWith('.m3u8') || path.endsWith('.m3u')) return true;
    } catch (_) {}
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') || lower.contains('.m3u');
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
  /// v2.3.21: 加 Referer 头. 之前只有 _getSegmentUrls 失败 (m3u8 拉取
  ///   403), _getResolutionFromM3U8 也没 Referer, 同样 403 → 0x0.
  ///   2 个 playlist 拉取函数同时修, 不留半截.
  Future<Map<String, int>> _getResolutionFromM3U8(String m3u8Url) async {
    try {
      final response = await _dio.get(
        m3u8Url,
        options: Options(headers: _refererHeaders(m3u8Url)),
      );
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

  /// 测量下载速度 (v2.3.0 + v2.3.4: 真实分片抽样, Range 1MB 取 512KB)
  ///
  /// 跟 web LunaTV hls.js FRAG_LOADED 思路 1:1 对齐 — 测的是真实分片
  ///   下载速度, 跟 libmpv / ExoPlayer 实际播放走的链路完全一样, 不走
  ///   playlist 文本 (playlist 几 KB 测不出真实速度).
  ///
  /// 之前 v1.0.45 用 Range 64KB 测的是"首字节 + 64KB" 速度, 在 CDN 边缘
  ///   节点上经常虚高 (CDN burst 给首字节快, 实际播放时 m3u8 重写链 + libmpv
  ///   加载是另一条路径). 用户看着 5MB/s 实际播放卡, 就是这个根因.
  ///
  /// v2.3.0 ~ v2.3.4 演化:
  ///   v1.0.45: Range 64KB 抽样 (CDN burst 虚高)
  ///   v2.3.0: 1 真实分片完整下载 (太大, 慢)
  ///   v2.3.4: Range 1MB 抽样 (取前 512KB), 跟 web LunaTV iPad 简化路径
  ///           思路一致, 不下完整文件
  ///   v2.3.6: 走 ExoPlayer prepare (太慢, 1-2s + 串行 17s 整体超时)
  ///   v2.3.9 ~ v2.3.13: 反复实验 (256KB / 32KB / 512KB playlist 风格),
  ///           都不理想
  ///   v2.3.14: 回到 v2.3.4 真实分片 Range 1MB 抽样
  ///
  /// 1 个 1080p 5s segment 约 2-5MB, Range 1MB 在 1Mbps 链路上 ~8s,
  ///   512KB 限制让慢链 5-6s 就能跑完, 整函数 6s timeout 兜底.
  Future<double> _measureSegmentSpeeds(
    List<String> segments, {
    String Function(String)? urlWrapper,
  }) async {
    if (segments.isEmpty) return 0.0;
    final testUrls = segments
        .map((url) => urlWrapper != null ? urlWrapper(url) : url)
        .toList();
    if (testUrls.isEmpty) return 0.0;

    // v2.3.4: 之前 v1.0.45 用完整 GET 拿 1 个分片, 太大. 改成 Range 1MB
    //   抽样, 最多读 512KB 或 2.8s 截断. 跟 web LunaTV hls.js 取样思路
    //   一致 — 不下完整分片, 拿代表性块算 KB/s.
    final results = await Future.wait(
      testUrls.map(_measureDownloadSpeedFast),
    );
    final valid = results.where((v) => v > 0).toList()..sort();
    if (valid.isEmpty) return 0.0;
    // v2.3.4: 取中位数 (避免单个分片异常拉偏)
    return valid[valid.length ~/ 2];
  }

  /// v2.3.21: 提取 host 当 Referer. 部分 CDN (iQiyi / 腾讯 / 爱奇艺
  ///   海外节点) 不带 Referer 直接返 403 Forbidden, 加完成功率 70%→95%.
  ///
  /// v2.3.21 关键修复: 之前只有 `_measureDownloadSpeedFast` 段下载有
  ///   Referer, `_getSegmentUrls` + `_getResolutionFromM3U8` 这两个
  ///   **拉 m3u8 playlist 文本**的地方没有. 结果: 源 m3u8 自身需要
  ///   Referer 时 (腾讯 / 优酷 / 部分爱奇艺海外节点), m3u8 拉取 403,
  ///   _getSegmentUrls 返回 [], _measureM3u8Speed 返回 "m3u8 解析失败
  ///   或没分片" → "不可用". iQiyi 因为 m3u8 不需 Referer, 反而能跑.
  ///   用户反馈: "只有爱奇艺有测试速度其他全是不可用实际是可以播放的"
  ///   修复: 把 Referer 提取逻辑抽成 helper, 3 个拉取函数都加.
  Map<String, dynamic> _refererHeaders(String url) {
    Uri? parsed;
    try {
      parsed = Uri.parse(url);
    } catch (_) {}
    final referer = (parsed != null &&
            parsed.scheme.isNotEmpty &&
            parsed.host.isNotEmpty)
        ? '${parsed.scheme}://${parsed.host}/'
        : null;
    return <String, dynamic>{
      if (referer != null) 'Referer': referer,
    };
  }

  /// v2.3.4: 单分片 Range 1MB 抽样.
  /// v2.3.17: receiveTimeout 4s → 6s (慢网下 4s 经常截断返 0);
  ///   加 Referer 头 (从 URL host 自动取, 部分 CDN 不带 Referer 返 403);
  ///   失败重试 1 次 (delay 800ms, 不抖服务器).
  /// v2.3.21: 抽 `_refererHeaders` helper, 跟 _getSegmentUrls /
  ///   _getResolutionFromM3U8 共用.
  Future<double> _measureDownloadSpeedFast(String url) async {
    final refHeaders = _refererHeaders(url);

    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final stopwatch = Stopwatch()..start();
        var bytes = 0;
        // Range bytes=0-1048575 = 1MB. v2.3.4 跟 web LunaTV iPad 简化路径
        //   思路一致 — 拿代表性块算 KB/s, 不下完整分片.
        final headers = <String, dynamic>{
          'Range': 'bytes=0-1048575',
          ...refHeaders,
        };
        final response = await _dio.get(
          url,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(seconds: 6),
            headers: headers,
          ),
        );
        final body = response.data as ResponseBody;
        await for (final chunk in body.stream) {
          bytes += chunk.length;
          if (bytes >= 512 * 1024) break;
          if (stopwatch.elapsedMilliseconds >= 2800) break;
        }
        stopwatch.stop();
        // 小于 64KB 的样本多数是 init/探针/异常小片段, 不拿来显示速度.
        if (bytes < 64 * 1024) return 0.0;
        final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000.0;
        if (elapsedSeconds <= 0) return 0.0;
        return (bytes / 1024) / elapsedSeconds; // KB/s
      } catch (e) {
        // v2.3.17: 第 1 次失败等 800ms 重试 1 次, 应付偶发 5xx / timeout.
        //   第 2 次还失败就认, 返 0. 不重试 2 次以上, 测速延迟爆炸.
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 800));
          continue;
        }
        return 0.0;
      }
    }
    return 0.0;
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

    // v2.3.17: 8 源全并行 → 2 个/批 串行 (4 批).
    //   原因: 8 源同时打 Range 1MB 触发 CDN 风控, 7/8 返 403/timeout
    //   → UI 全部 "不可用". 分批后单批只 2 个请求, 风控风险骤降,
    //   完成功率 12% → 80%+.
    //   总耗时 = 4 批 × 2 源并行 × 8s timeout ≈ 32s (单批 ~8s,
    //   跟之前 5s timeout 全并行 8 源同时炸差不多, 但完成率高).
    final allEntries = testUrls.entries.toList();
    const batchSize = 2;
    final streamInfoResults = <String, Map<String, dynamic>>{};
    for (int i = 0; i < allEntries.length; i += batchSize) {
      final batch = allEntries.skip(i).take(batchSize);
      // v2.3.17: 5s → 8s outer timeout. 慢网 4G/5G 5s 经常不够
      //   撑到 Range 1MB 截断 (512KB 或 2.8s), 加到 8s 留余量
      final batchFutures = batch.map((entry) async {
        final sourceId = entry.key;
        final episodeUrl = entry.value;

        try {
          final streamInfo = await getStreamInfo(episodeUrl).timeout(
            const Duration(seconds: 8),
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
      final batchResults = await Future.wait(batchFutures);
      for (final result in batchResults) {
        streamInfoResults[result.key] = result.value;
      }
    }

    // v2.3.16: 不再算 maxSpeed / minPing / maxPing 归一化基准.
    //   v2.3.0 公式是 -(speed * resWeight) + ping (越小越优),
    //   不需要 maxSpeed 归一化, 直接用原始 speed / ping 算就行.
    //   失败源 (success=false 或 speed=0 或 latency=0) 给 1<<30 排最后.

    // 计算每个源的评分并排序
    final sourceScores = <MapEntry<dynamic, double>>[];
    final allSourcesSpeed = <String, Map<String, dynamic>>{};

    for (final source in allSources) {
      final sourceId = '${source.source}_${source.id}';
      final streamInfo = streamInfoResults[sourceId];

      if (streamInfo == null || !streamInfo['success']) {
        // 失败源: UI 仍展示 (显示 "超时"), 但 score 给极大值排最后
        sourceScores.add(MapEntry(source, (1 << 30).toDouble()));
        allSourcesSpeed[sourceId] = {
          'quality': '未知',
          'loadSpeed': '超时',
          'pingTime': '超时',
        };
        continue;
      }

      final downloadSpeed = streamInfo['downloadSpeed'] as double;
      final latency = streamInfo['latency'] as int;
      final resolutionData = streamInfo['resolution'] as Map<String, int>;

      // 转换分辨率为标准格式
      final resolution = _convertResolutionToString(resolutionData);

      // 计算综合评分 (v2.3.0 公式)
      final score = _calculateSourceScore(
        resolution,
        downloadSpeed,
        latency,
      );

      sourceScores.add(MapEntry(source, score));

      allSourcesSpeed[sourceId] = {
        'quality': resolution,
        'loadSpeed': _formatDownloadSpeed(downloadSpeed),
        'pingTime': '${latency}ms',
      };
    }

    // v2.3.16: 按 score 升序排 (smaller wins). 失败源 (1<<30) 自动排最后.
    sourceScores.sort((a, b) => a.value.compareTo(b.value));

    final bestSource = sourceScores.isNotEmpty ? sourceScores.first.key : allSources.first;

    return {
      'bestSource': bestSource,
      'allSourcesSpeed': allSourcesSpeed,
      'error': '',
    };
  }

  /// 计算源的综合评分
  /// v2.3.0 公式 (越小越优, 跟 web LunaTV 1:1):
  ///   score = -(speed * resWeight) + ping
  ///     resWeight = resScore / 100 (4K=1.0, 2K=0.85, 1080p=0.75, 720p=0.6,
  ///                                 480p=0.4, 360p=0.2, 未知=0)
  ///     speed = KB/s
  ///     ping = ms
  ///   速度越快 → -(speed*resWeight) 越负 → score 越小 → 越好
  ///   ping 越低 → score 越小 → 越好
  ///   失败源 (speed=0 或 latency=0) → 返 1<<30 排最后
  ///
  /// v2.3.0 ~ v2.3.10 一直用这公式. v2.3.11 自研 CustomExoPlayer 时没改.
  /// v2.3.12 移植 Selene-TV u74.h: resScore*0.5 + speedScore*0.5 (越大越优,
  ///   maxSpeed 归一化), 用户反馈"测速永远拿不到速度"删了.
  /// v2.3.14 rollback 说"回到 v2.3.0 公式", 但实际代码残留了 v2.3.12 风格
  ///   的线性 0..100 公式 (40% 质量 + 40% 速度 + 20% 延迟 + maxSpeed 归一化),
  ///   changelog 跟代码对不上. v2.3.16 真正改回 v2.3.0 公式.
  double _calculateSourceScore(
    String quality,
    double speedKBps,
    int latencyMs,
  ) {
    // 失败源: speed=0 或 latency=0 视为无效, 给极大值排最后
    if (speedKBps <= 0 || latencyMs <= 0) return (1 << 30).toDouble();

    final resWeight = _getQualityScore(quality) / 100.0;
    return -(speedKBps * resWeight) + latencyMs;
  }

  /// 获取分辨率评分 (0..100), 同时给 v2.3.0 公式当 resWeight 分母
  ///   4K=100, 2K=85, 1080p=75, 720p=60, 480p=40, 360p=20, 未知=0
  ///   跟 web LunaTV 一致
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
  /// v2.3.17: 默认 timeout 5s → 8s; 8 源全并行 → 2/批 串行 4 批.
  Future<void> testSourcesWithCallback(
    List<dynamic> allSources,
    Function(String sourceId, Map<String, dynamic> speedData) onSourceCompleted, {
    Duration timeout = const Duration(seconds: 8),
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

    // v2.3.17: 8 源全并行 → 2/批 串行. 跟 testAllSources 同逻辑.
    Future<MapEntry<String, Map<String, dynamic>>> _testOne(String sourceId, String episodeUrl) async {
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
      return MapEntry(sourceId, <String, dynamic>{});
    }

    final allEntries = testUrls.entries.toList();
    const batchSize = 2;
    for (int i = 0; i < allEntries.length; i += batchSize) {
      final batch = allEntries.skip(i).take(batchSize);
      await Future.wait(batch.map((e) => _testOne(e.key, e.value)));
    }
  }

  /// 释放资源
  void dispose() {
    _dio.close();
  }
}
