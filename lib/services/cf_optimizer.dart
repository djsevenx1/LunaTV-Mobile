import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data'; // v2.0.83: Uint8List (SecureSocket chunk 类型)

import 'package:shared_preferences/shared_preferences.dart';

import 'package:luna_tv/services/user_data_service.dart'; // v2.0.82: saveManualBestIp 调用 saveCfBestIp

/// CF 优选测速服务
///
/// v2.0.11: 新增,客户端纯 override DNS 解析
///
/// 原理:
///   - CF 公开 ~17 段 Anycast IP, 默认 DNS 给的可能不是国内访问最快的
///   - 我们跑 TCP 443 握手测速, 选 Top N IP
///   - 存到 SharedPreferences, HTTP 请求时通过 [CfOptimizerHttpOverrides]
///     强制把 worker 域名解析到优选 IP
///
/// 兼容性:
///   - CF Worker (CORSAPI) 代码**不用改**, worker 自己不知道客户端走的是优选 IP
///   - 用户在 LunaTV 配的 "CF Worker 加速源域名" (自定义域名) 不需要变
///   - 优选只对**自定义域名**有效 (CNAME 到 .workers.dev),
///     *.workers.dev 原域名走 CF 自己的 CDN, override 容易被忽略
///
/// 触发条件:
///   - 用户配了 CF Worker 域名 (没配 = 整个优选没意义, 走系统 DNS)
///   - 用户打开 "优选 IP 启用" 开关 ([UserDataService.getCfWorkerEnabled],
///     v2.0.76 后语义是"对所有资源用优选 IP" — 不再是 CF Worker 总开关)
///   - 用户可以单独关 "CF 优选测速" 开关 (默认开)
///   - 启动时如果 7 天没测过 → 后台跑
///   - 用户菜单里可以手动 "立即优选测速"
///
/// v2.0.76 起, CF Worker 代理本身没有总开关 — 域名配了就生效, 关掉"优选 IP
/// 启用" 仍会走 worker 域名, 但 worker 域名按系统 DNS 解析 (不一定是最快的 IP).
class CfOptimizer {
  // CF 公开 IPv4 段 (https://www.cloudflare.com/ips/)
  // v4: 173.245.48.0/20, 103.21.244.0/22, 103.22.200.0/22,
  //     103.31.4.0/22, 141.101.64.0/18, 108.162.192.0/18,
  //     190.93.240.0/20, 188.114.96.0/20, 197.234.240.0/22,
  //     198.41.128.0/17, 162.158.0.0/15, 104.16.0.0/13,
  //     104.24.0.0/14, 172.64.0.0/13, 131.0.72.0/22
  // 从每段抽 1-2 个代表性 IP (这些是社区测速公认比较稳的)
  static const List<String> _candidateIps = [
    // 1.0.0.0/24 段 (APNIC, 离国内近)
    '1.0.0.1', '1.1.1.1',
    // 1.1.0.0/16 段
    '1.1.1.0', '1.0.0.0',
    // 104.16.0.0/13 大段
    '104.16.0.1', '104.16.16.1', '104.16.32.1', '104.16.48.1',
    '104.16.64.1', '104.16.80.1', '104.16.96.1', '104.16.112.1',
    '104.17.0.1', '104.17.32.1', '104.17.64.1', '104.17.96.1',
    '104.18.0.1', '104.18.32.1', '104.18.64.1', '104.18.96.1',
    '104.19.0.1', '104.19.32.1', '104.19.64.1', '104.19.96.1',
    '104.20.0.1', '104.20.16.1', '104.20.32.1', '104.20.48.1',
    // 172.64.0.0/13 段
    '172.64.0.1', '172.64.16.1', '172.64.32.1', '172.64.48.1',
    '172.64.64.1', '172.64.80.1', '172.64.96.1', '172.64.112.1',
    '172.65.0.1', '172.65.16.1', '172.65.32.1', '172.65.48.1',
    '172.66.0.1', '172.66.16.1', '172.66.32.1', '172.66.48.1',
    '172.67.0.1', '172.67.16.1', '172.67.32.1', '172.67.48.1',
    '172.68.0.1', '172.68.16.1', '172.68.32.1', '172.68.48.1',
    '172.69.0.1', '172.69.16.1', '172.69.32.1', '172.69.48.1',
    '172.70.0.1', '172.70.16.1', '172.70.32.1', '172.70.48.1',
    '172.71.0.1', '172.71.16.1', '172.71.32.1', '172.71.48.1',
    // 162.158.0.0/15 段
    '162.158.0.1', '162.158.16.1', '162.158.32.1', '162.158.48.1',
    '162.158.64.1', '162.158.80.1', '162.158.96.1', '162.158.112.1',
    '162.159.0.1', '162.159.16.1', '162.159.32.1', '162.159.48.1',
    // 198.41.128.0/17 段
    '198.41.128.1', '198.41.192.1', '198.41.224.1',
    // 188.114.96.0/20 段
    '188.114.96.1', '188.114.97.1', '188.114.98.1', '188.114.99.1',
    '188.114.100.1', '188.114.101.1', '188.114.102.1', '188.114.103.1',
    // 190.93.240.0/20 段
    '190.93.240.1', '190.93.241.1', '190.93.242.1', '190.93.243.1',
    '190.93.244.1', '190.93.245.1', '190.93.246.1', '190.93.247.1',
    // 141.101.64.0/18 段
    '141.101.64.1', '141.101.65.1', '141.101.66.1', '141.101.67.1',
    '141.101.68.1', '141.101.69.1', '141.101.70.1', '141.101.71.1',
    // 108.162.192.0/18 段
    '108.162.192.1', '108.162.193.1', '108.162.194.1', '108.162.195.1',
    // 173.245.48.0/20 段
    '173.245.48.1', '173.245.49.1', '173.245.50.1', '173.245.51.1',
    '173.245.52.1', '173.245.53.1', '173.245.54.1', '173.245.55.1',
  ];

  // 优选 IP 数量 (存 Top N, fallback 用)
  static const int _topN = 3;

  // 测速超时 (单个 IP)
  static const Duration _probeTimeout = Duration(milliseconds: 1500);

  // TCP 测速并发数
  static const int _concurrency = 10;

  // 重测周期 (7 天)
  static const Duration _retestInterval = Duration(days: 7);

  // SharedPreferences key
  static const String _kEnabled = 'cf_optimizer_enabled';
  static const String _kIps = 'cf_best_ips';
  static const String _kLastTest = 'cf_optimizer_last_test';
  static const String _kTargetDomain = 'cf_optimizer_target_domain';

  /// 优选测速结果
  static Future<List<({String ip, int latencyMs})>> _probeAll({
    int concurrency = _concurrency,
    Duration timeout = _probeTimeout,
    void Function(int done, int total)? onProgress,
  }) async {
    final results = <MapEntry<String, int>>[];
    final queue = List<String>.from(_candidateIps);
    int done = 0;
    int total = queue.length;

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final ip = queue.removeAt(0);
        final lat = await _probeOne(ip, timeout);
        done++;
        if (lat >= 0) {
          results.add(MapEntry(ip, lat));
        }
        onProgress?.call(done, total);
      }
    }

    final workers = <Future<void>>[];
    for (int i = 0; i < concurrency; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);

    // 按延迟升序排序
    results.sort((a, b) => a.value.compareTo(b.value));
    return results
        .take(_topN)
        .map((e) => (ip: e.key, latencyMs: e.value))
        .toList();
  }

  /// TCP 443 握手测速, 返回毫秒延迟 (-1 = 失败/超时)
  static Future<int> _probeOne(String ip, Duration timeout) async {
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(ip, 443,
              timeout: timeout)
          .timeout(timeout, onTimeout: () {
        throw TimeoutException('probe $ip timeout');
      });
      stopwatch.stop();
      socket.destroy();
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      stopwatch.stop();
      return -1;
    }
  }

  // ============== 对外 API ==============

  /// 跑一次完整优选测速
  /// 返回 Top N IP 列表 (按延迟升序)
  /// 测完自动存到 SharedPreferences
  ///
  /// [targetDomain] 是 worker 自定义域名, 用来标记这组优选 IP 是给哪个域名的
  /// 如果换域名, 旧的优选 IP 失效, 需要重测
  static Future<List<String>> runOptimization({
    required String targetDomain,
    void Function(int done, int total)? onProgress,
  }) async {
    if (targetDomain.isEmpty) {
      return [];
    }
    final results = await _probeAll(onProgress: onProgress);
    final ips = results.map((e) => e.ip).toList();

    // 存
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kIps, ips);
    await prefs.setInt(_kLastTest, DateTime.now().millisecondsSinceEpoch);
    await prefs.setString(_kTargetDomain, targetDomain);
    return ips;
  }

  /// 是否启用 CF 优选 (默认 true)
  static Future<bool> getEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kEnabled) ?? true;
  }

  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, enabled);
  }

  /// 当前缓存的优选 IP 列表 (按延迟排序)
  static Future<List<String>> getBestIps() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kIps) ?? const [];
  }

  /// 当前优选 IP 关联的 worker 域名
  static Future<String> getTargetDomain() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kTargetDomain) ?? '';
  }

  /// 上次测速时间 (millisSinceEpoch), 0 = 从未测过
  static Future<int> getLastTest() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kLastTest) ?? 0;
  }

  /// 是否需要重测 (7 天过期 或 没测过 或 域名变了)
  static Future<bool> needsRetest({required String currentDomain}) async {
    if (currentDomain.isEmpty) return false;
    final last = await getLastTest();
    if (last == 0) return true;
    final stored = await getTargetDomain();
    if (stored != currentDomain) return true;
    final elapsed = DateTime.now().millisecondsSinceEpoch - last;
    return elapsed > _retestInterval.inMilliseconds;
  }

  /// 清空优选缓存
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kIps);
    await prefs.remove(_kLastTest);
    await prefs.remove(_kTargetDomain);
  }

  // ============== v2.0.82: IP 优选测速 (返回全量结果, 让用户点选存) ==============
  //
  // 跟 [runOptimization] 不同:
  //   - runOptimization: 按延迟取 Top 3 自动存, 后台用
  //   - runSpeedTest: 测所有 IP 的延迟 + 下载速度, 列表展示, 用户手动点存
  //
  // 测速方法: HttpClient + addHostEntry 强制 host → ip 映射, GET worker
  //   /speed?size=1 端点 (v2.0.84 一次性 Uint8Array, 不流式). 同时拿到
  //   延迟 (HTTP 响应开始到第一字节 ≈ TCP+TLS 握手时间) 和下载速度.
  //
  // 限制: 默认测前 30 个 IP, 避免 100 个 IP × 1MB = 100MB 流量.

  /// IP 优选测速结果 (供 UI 展示)
  ///   - latencyMs: HTTP 响应延迟 (ms), -1 = 失败
  ///   - mbPerSec: 下载速度 (MB/s), 0 = 失败
  ///   - httpCode: HTTP 状态码, 0 = 连接失败, -1 = 超时
  static Future<List<({String ip, int latencyMs, double mbPerSec, int httpCode})>>
      runSpeedTest({
    required String targetDomain,
    int testMB = 1,
    int maxIps = 30,
    int concurrency = 6,
    Duration timeout = const Duration(seconds: 10),
    void Function(int done, int total)? onProgress,
  }) async {
    if (targetDomain.isEmpty) return const [];
    final cleanDomain = targetDomain
        .replaceFirst(RegExp(r'^https?://'), '')
        .split('/').first
        .trim();

    final ips = _candidateIps.take(maxIps).toList();
    final results = <({String ip, int latencyMs, double mbPerSec, int httpCode})>[];
    final queue = List<String>.from(ips);
    int done = 0;
    int total = queue.length;

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final ip = queue.removeAt(0);
        final r = await _probeOneWithSpeed(
          ip: ip,
          host: cleanDomain,
          testMB: testMB,
          timeout: timeout,
        );
        results.add(r);
        done++;
        onProgress?.call(done, total);
      }
    }

    final workers = <Future<void>>[];
    for (int i = 0; i < concurrency; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);

    // 按速度降序排序, 失败的 (mbPerSec=0) 排最后
    results.sort((a, b) {
      if (a.mbPerSec == 0 && b.mbPerSec == 0) return 0;
      if (a.mbPerSec == 0) return 1;
      if (b.mbPerSec == 0) return -1;
      return b.mbPerSec.compareTo(a.mbPerSec);
    });
    return results;
  }

  /// 单 IP 测速: Socket.connect(ip) + SecureSocket.secure(host=worker 域名)
  ///   手动写 HTTP/1.1 GET, 读 body 算速度
  /// 返回 (ip, latencyMs, mbPerSec, httpCode)
  ///   - latencyMs: 拿到第一个 body byte 的时间 (ms), 反映 TCP+TLS 握手延迟
  ///   - mbPerSec: 下载完 testMB 的平均速度
  ///   - httpCode: HTTP 状态码, 0/-1/-2/-3 = 连接/超时/TLS/其他错误
  ///
  /// v2.0.82b: 改 raw socket 方案. 之前用 HttpClient + URL.host=IP 时,
  ///   CF edge 在 SNI=IP 阶段直接断连 ("Connection terminated during
  ///   handshake", 不是证书问题). 改用 SecureSocket.secure(socket,
  ///   host: workerDomain) 显式把 SNI 设为 worker 域名 + 连接目标 IP.
  ///   onBadCertificate=true 跳过证书验证 (worker CF edge 返回的是
  ///   workers.dev 通用证书, 跟 client 期望的 worker 域名不匹配,
  ///   但握手成功就行, 测速 client 不需要严格验证证书).
  static Future<({String ip, int latencyMs, double mbPerSec, int httpCode})>
      _probeOneWithSpeed({
    required String ip,
    required String host,
    required int testMB,
    required Duration timeout,
  }) async {
    final sw = Stopwatch()..start();
    Socket? rawSocket;
    try {
      // 1. TCP 连 IP:443
      rawSocket = await Socket.connect(ip, 443, timeout: timeout);
      // 2. TLS 升级, SNI=worker 域名
      //    v2.0.83d: SecureSocket.secure 没有 named `timeout` 参数
      //      (之前 v2.0.83c 编译错 No named parameter with the name 'timeout')
      //      超时用外层 .timeout() 包裹, SSL 阶段也算进 timeout
      final secureSocket = await SecureSocket.secure(
        rawSocket,
        host: host,
      ).timeout(timeout);
      // 3. 写 HTTP/1.1 GET
      final request = 'GET /speed?size=$testMB HTTP/1.1\r\n'
          'Host: $host\r\n'
          'User-Agent: LunaTV-CfSpeedTest/1.0\r\n'
          'Connection: close\r\n'
          '\r\n';
      secureSocket.write(request);
      await secureSocket.flush();

      // 4. 收完整 response (Connection: close 让 server 关连接 = stream 结束)
      //    v2.0.83c: 改用 await for + 字节累加, 不在 listen 闭包内解析
      //      headers (避免闭包变量捕获 / StreamSubscription 类型问题)
      //    v2.0.83d: 收 response 也包 .timeout, 万一 server 不关连接会卡死
      int firstByteMs = -1;
      int bytes = 0;
      final buf = <int>[];
      await for (final Uint8List chunk in secureSocket.timeout(timeout)) {
        if (firstByteMs < 0) {
          firstByteMs = sw.elapsedMilliseconds;
        }
        bytes += chunk.length;
        buf.addAll(chunk);
      }
      sw.stop();
      // 5. 解析 response
      final responseStr = utf8.decode(buf, allowMalformed: true);
      final statusMatch =
          RegExp(r'HTTP/\S+\s+(\d+)').firstMatch(responseStr);
      final httpCode =
          statusMatch != null ? int.parse(statusMatch.group(1)!) : 0;
      if (httpCode == 0) {
        return (ip: ip, latencyMs: -1, mbPerSec: 0.0, httpCode: -3);
      }
      if (httpCode != 200) {
        return (ip: ip, latencyMs: -1, mbPerSec: 0.0, httpCode: httpCode);
      }
      // 算 body bytes (减去 header 段)
      final headerEnd = responseStr.indexOf('\r\n\r\n');
      final bodyBytes = headerEnd < 0 ? bytes : bytes - (headerEnd + 4);
      if (bodyBytes <= 0) {
        return (ip: ip, latencyMs: -1, mbPerSec: 0.0, httpCode: -3);
      }
      final secs = sw.elapsedMilliseconds / 1000.0;
      final mb = bodyBytes / 1024.0 / 1024.0;
      final mbps = secs > 0 ? mb / secs : 0.0;
      return (
        ip: ip,
        latencyMs: firstByteMs < 0 ? sw.elapsedMilliseconds : firstByteMs,
        mbPerSec: mbps,
        httpCode: 200,
      );
    } on TimeoutException {
      sw.stop();
      return (ip: ip, latencyMs: -1, mbPerSec: 0.0, httpCode: -1);
    } on SocketException {
      sw.stop();
      return (ip: ip, latencyMs: -1, mbPerSec: 0.0, httpCode: 0);
    } on HandshakeException {
      sw.stop();
      return (ip: ip, latencyMs: -1, mbPerSec: 0.0, httpCode: -2);
    } catch (e) {
      sw.stop();
      return (ip: ip, latencyMs: -1, mbPerSec: 0.0, httpCode: -3);
    } finally {
      try {
        rawSocket?.destroy();
      } catch (_) {}
    }
  }

  /// 把选中的 IP 存为优选 (单 IP 形式, 给 [UserDataService.saveCfBestIp])
  /// 同时也存到 [_kIps] 列表 (给 [CfOptimizerHttpOverrides] 用)
  static Future<void> saveManualBestIp(String ip) async {
    if (ip.isEmpty) return;
    await UserDataService.saveCfBestIp(ip);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kIps, [ip]);
    await prefs.setInt(_kLastTest, DateTime.now().millisecondsSinceEpoch);
    await prefs.setString(_kTargetDomain, '');
    // 立即推到 HTTP overrides
    CfOptimizerHttpOverrides.setManualPreferredIp(ip);
  }

  /// 格式化最后测速时间 (人类可读)
  static Future<String> lastTestHuman() async {
    final last = await getLastTest();
    if (last == 0) return '从未测速';
    final dt = DateTime.fromMillisecondsSinceEpoch(last);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
  }
}

/// HTTP overrides: 强制把 worker 域名解析到优选 IP
///
/// 触发条件: CF Worker 加速开关 + CF 优选开关都打开 + 优选 IP 缓存非空
///
/// 实现: 继承 [HttpOverrides], 在 [HttpClient.createDefaultHttpClient] 返回的
/// HttpClient 里 hook 一下, 让 DNS 解析直接返回优选 IP
///
/// ⚠️ Flutter 的 CachedNetworkImage / http package 走 [HttpClient],
///    所以这个 override 会影响图片加载 + 普通 HTTP 请求
/// ⚠️ libmpv 视频播放走原生 libmpv (C 库), 不受 Dart HttpClient 影响,
///    所以视频流不会走优选 IP, 这是已知限制 (v2.0.11)
class CfOptimizerHttpOverrides extends HttpOverrides {
  static bool _globalInstalled = false;

  // 优选 IP 静态缓存 (跨 _OptimizingHttpClient 实例共享)
  static List<String>? _bestIpsCache;
  static String? _targetDomainCache;
  static bool _featureEnabled = false;
  // v2.0.31: 用户手动填的优选 IP. 优先级最高, 不依赖测速, 不依赖开关.
  // 一旦设置, 所有指向 targetDomain 的 Dart HTTP 请求都强制用这个 IP.
  // v2.0.32: 接受 IP 或优选域名 (cf.877774.xyz 这类 CF 智能调度域名).
  //   - IPv4: 直接用
  //   - 域名: 启动时 / 5min 周期 DNS 解析取第一个 A 记录, 缓存到 [_resolvedManualIp]
  static String? _manualPreferredIp;
  // v2.0.32: 域名解析后的实际 IP (IP 模式下跟 _manualPreferredIp 一样)
  static String? _resolvedManualIp;
  // v2.0.32: 解析时间戳 (millisSinceEpoch), 0 = 从未解析过
  static int _resolvedAt = 0;
  // v2.0.32: 解析失败时的错误信息 (UI 显示用)
  static String? _resolveError;
  // v2.0.32: 域名解析 TTL (5 分钟, 过期重新解析)
  static const Duration _resolveTtl = Duration(minutes: 5);

  // v2.0.46: 视频代理目标 host 的 DNS 解析结果缓存 (host → [IPv4...])
  //   跟 [getTopNIpsForVideoProxy] 配合: race 候选优先用 host DNS 解析的 IP
  //   (跟 SNI 匹配的 CF edge IP), 而不是手动优选 IP (可能是任意 CF IP, 跟
  //   SNI 不在同一个 zone → TLS 失败 → 0KB 死链). 用户 v2.0.45 反馈:
  //   「ip优选播放不了0kb 优选ip 问题已确认」, logcat 显示 162.159.158.162
  //   TCP 拨上 15ms 但 TLS 失败, race 永远返这个 IP.
  static final Map<String, List<String>> _hostResolvedIpsCache = {};
  static final Map<String, int> _hostResolvedIpsAt = {};
  static const Duration _hostResolveTtl = Duration(minutes: 5);
  // 避免同一个 host 短时间多次并发解析
  static final Set<String> _hostResolving = {};

  /// v2.0.32: 拿到手动优选实际生效的 IP (null = 没配 / 解析失败)
  static String? getResolvedManualIp() => _resolvedManualIp;

  /// v2.1.40: 拿到用户原始输入 (IP 或域名), 跟 [getResolvedManualIp] 区别
  ///   在于这是没解析的原文, 给日记/UI 显示 "用户填的啥"
  static String getManualPreferredIpForUi() => _manualPreferredIp ?? '';

  /// v2.1.33: 给 [LunaImageHttp] (MethodChannel + OkHttp 路径) 用 —
  ///   拿到当前 targetDomain (worker 域名), null = 没配
  static String? getTargetDomain() => _targetDomainCache;

  /// v2.1.33: 给 [LunaImageHttp] 用 — 优选开关是否启用
  static bool isFeatureEnabled() => _featureEnabled;

  /// v2.1.33: 给 [LunaImageHttp] 用 — 测速结果 (按延迟升序, 第一名最快)
  static List<String>? getBestIps() => _bestIpsCache;

  /// v2.0.32: 上次解析时间 (人类可读, UI 显示用)
  static String getResolvedAtHuman() {
    if (_resolvedAt == 0) return '从未解析';
    final dt = DateTime.fromMillisecondsSinceEpoch(_resolvedAt);
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
  }

  /// v2.0.32: 上次解析错误 (null = 无错)
  static String? getResolveError() => _resolveError;

  /// app 启动时 warmup 缓存 (主线程读 SharedPreferences 后调用)
  static void warmup({
    required List<String> bestIps,
    required String targetDomain,
    required bool featureEnabled,
    String? manualPreferredIp,
  }) {
    _bestIpsCache = bestIps;
    _targetDomainCache = targetDomain;
    _featureEnabled = featureEnabled;
    _manualPreferredIp = manualPreferredIp;
    // v2.0.32: 启动时清掉旧解析结果, 让后台 re-resolve
    _resolvedManualIp = null;
    _resolvedAt = 0;
    _resolveError = null;
  }

  /// 刷新缓存 (优选测速完后调用)
  static void refresh({
    required List<String> bestIps,
    required String targetDomain,
  }) {
    _bestIpsCache = bestIps;
    _targetDomainCache = targetDomain;
  }

  /// v2.0.31: 用户在设置页改了手动优选 IP / 域名, 立即生效 (不用重启 App)
  /// v2.0.32: 接受 IP 或优选域名
  static void setManualPreferredIp(String? input) {
    if (input == null || input.isEmpty) {
      _manualPreferredIp = null;
      _resolvedManualIp = null;
      _resolvedAt = 0;
      _resolveError = null;
      return;
    }
    _manualPreferredIp = input;
    // v2.0.32: 如果是 IPv4, 立即生效; 域名要等 resolveManualPreferred
    if (_isIpv4(input)) {
      _resolvedManualIp = input;
      _resolvedAt = DateTime.now().millisecondsSinceEpoch;
      _resolveError = null;
    } else {
      _resolvedManualIp = null;
      _resolvedAt = 0;
      _resolveError = '待解析';
    }
  }

  /// v2.0.32: 解析手动优选 (域名 → IP). 立即返回, 异步执行.
  /// - IPv4: 直接用
  /// - 域名: DNS lookup, 取第一个 IPv4 结果
  /// - 失败: 保持旧值, 设置 _resolveError
  ///
  /// 使用方式:
  ///   - App 启动 warmup 后调用一次
  ///   - 用户改了手动优选后调用一次
  ///   - 5 分钟周期 Timer 调用一次
  static Future<void> resolveManualPreferred() async {
    final input = _manualPreferredIp;
    if (input == null || input.isEmpty) {
      _resolvedManualIp = null;
      _resolvedAt = 0;
      _resolveError = null;
      return;
    }
    if (_isIpv4(input)) {
      _resolvedManualIp = input;
      _resolvedAt = DateTime.now().millisecondsSinceEpoch;
      _resolveError = null;
      return;
    }
    // 域名解析
    try {
      final addrs = await InternetAddress.lookup(input,
              type: InternetAddressType.IPv4)
          .timeout(const Duration(seconds: 5));
      if (addrs.isNotEmpty) {
        _resolvedManualIp = addrs.first.address;
        _resolvedAt = DateTime.now().millisecondsSinceEpoch;
        _resolveError = null;
      } else {
        _resolveError = '解析无结果';
        // 保留旧 IP (避免因为一次失败就断流)
      }
    } catch (e) {
      _resolveError = '解析失败: $e';
      // 保留旧 IP
    }
  }

  /// v2.0.32: 是否需要重新解析 (过期 / 从未解析 / 是域名)
  static bool needsResolve() {
    final input = _manualPreferredIp;
    if (input == null || input.isEmpty) return false;
    if (_isIpv4(input)) return false; // IPv4 永不重解析
    if (_resolvedAt == 0) return true; // 从未解析
    final elapsed = DateTime.now().millisecondsSinceEpoch - _resolvedAt;
    return elapsed > _resolveTtl.inMilliseconds;
  }

  /// v2.0.46: 同步读 host DNS 解析缓存 (没缓存返 null)
  static List<String>? getHostResolvedIps(String host) {
    if (host.isEmpty) return null;
    final cached = _hostResolvedIpsCache[host];
    final cachedAt = _hostResolvedIpsAt[host] ?? 0;
    if (cached == null) return null;
    final elapsed = DateTime.now().millisecondsSinceEpoch - cachedAt;
    if (elapsed > _hostResolveTtl.inMilliseconds) return null; // 过期
    return cached;
  }

  /// v2.0.46: 异步解析 host 的 DNS, 写进 [_hostResolvedIpsCache].
  ///
  /// 调用方 fire-and-forget: getTopNIpsForVideoProxy 第一次看到 manual IP
  /// 但 host DNS 没缓存时调一次, 之后 _connectRace 就能用上 host DNS IP.
  ///
  /// 不会重复解析: [_hostResolving] Set 守门.
  /// 失败静默: 解析失败时缓存空 list, 等 5 分钟 TTL 过期再试.
  /// 已经被禁了: 如果一个 host 已经解析失败过, [_hostResolving] 也会
  ///   short-circuit, 避免 spam 解析.
  static Future<void> resolveHostEagerly(String host) async {
    if (host.isEmpty) return;
    if (_hostResolving.contains(host)) return;
    _hostResolving.add(host);
    try {
      // 用系统 DNS 解析, 5 秒超时
      final addrs = await InternetAddress.lookup(host,
              type: InternetAddressType.IPv4)
          .timeout(const Duration(seconds: 5));
      final ips = addrs.map((a) => a.address).toList();
      _hostResolvedIpsCache[host] = ips;
      _hostResolvedIpsAt[host] = DateTime.now().millisecondsSinceEpoch;
    } catch (_) {
      // 解析失败, 写空 list (避免下次再触发)
      _hostResolvedIpsCache[host] = const [];
      _hostResolvedIpsAt[host] = DateTime.now().millisecondsSinceEpoch;
    } finally {
      _hostResolving.remove(host);
    }
  }

  /// v2.0.46: 视频代理请求 host 时调用, fire-and-forget 触发 host DNS 解析
  ///
  /// 比 [resolveHostEagerly] 多一层"已经解析过就跳过"的守门, 避免
  /// 视频代理每秒 N 次请求时重复触发 DNS 解析. 但仍然 fire-and-forget,
  /// 调用方不用 await, 后续 race 拿候选时 DNS 可能还在解析中, 走
  /// [getTopNIpsForVideoProxy] 的 fallback 路径 (返 [manual, host]).
  static void maybeResolveHostEagerly(String host) {
    if (host.isEmpty) return;
    // 缓存命中就跳过 (5 分钟 TTL 内)
    final cached = getHostResolvedIps(host);
    if (cached != null) return;
    // 正在解析就跳过
    if (_hostResolving.contains(host)) return;
    // ignore: unawaited_futures
    resolveHostEagerly(host);
  }

  /// v2.0.32: IPv4 校验
  static bool _isIpv4(String s) {
    final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(s);
    if (m == null) return false;
    for (var i = 1; i <= 4; i++) {
      final n = int.parse(m.group(i)!);
      if (n < 0 || n > 255) return false;
    }
    return true;
  }

  /// 关闭优选 (开关关了 / 优选 IP 清空)
  static void disable() {
    _bestIpsCache = null;
    _targetDomainCache = null;
    _featureEnabled = false;
    // 注意: 不清 _manualPreferredIp, 手动 IP 不受 featureEnabled 控制
  }

  /// v2.0.16: 给本地视频代理用的查表
  ///
  /// 输入: 任意域名
  /// 返回: 该域名对应的"最可能最快 IP" (round-robin 在 bestIps 数组里轮)
  ///   - domain 不等于 targetDomain (不是优选测速的那个 worker 域名) → null
  ///   - _featureEnabled == false (开关关了) → null
  ///   - _bestIpsCache 为空 (没测速) → null
  ///   - 一切就绪 → 返回下一个 IP (轮询, 避免都打第一个)
  ///
  /// 视频代理 (video_proxy_server.dart) 用这个方法决定 CONNECT 时连哪个 IP
  static String? pickBestIpForDomain(String domain) {
    if (!_featureEnabled) return null;
    final ips = _bestIpsCache;
    final target = _targetDomainCache;
    if (ips == null || ips.isEmpty || target == null || target.isEmpty) {
      return null;
    }
    if (domain.toLowerCase() != target.toLowerCase()) return null;
    final idx = _ipRoundRobin % ips.length;
    _ipRoundRobin++;
    return ips[idx];
  }

  static int _ipRoundRobin = 0;

  /// v2.0.19: 取前 N 个优选 IP (按延迟升序, 不打乱顺序)
  /// 给本地代理并发拨号用 — 借鉴 cmliu/edgetunnel 的 "预加载竞速拨号"
  ///
  /// 跟 [pickBestIpForDomain] 的区别:
  ///   - pickBestIpForDomain: 单 IP + round-robin (多请求时分散流量)
  ///   - getTopNIpsForDomain: 多个 IP 按时延排, 给并发拨号用
  ///     (单请求要最快, 不在乎 round-robin)
  ///
  /// 返回空 list = 没配 / 没测过, 调用方应该 fallback 到原 host
  ///
  /// v2.0.25 改: 不再检查 domain == targetDomain
  ///   CF Anycast IP 对所有 CF 后面的域名都有效 (同一个 edge IP).
  ///   旧代码只对 worker 域名返回优选 IP, 视频源域名 != worker 域名
  ///   → 返回空 → 代理 fallback 直连 → 优选 IP 白配了, 没有加速效果.
  /// v2.0.25: 不再检查 domain == targetDomain, 对所有域名都返回优选 IP
  ///   - 视频源在 CF 后面 → 优选 IP 连 CF edge → SNI 匹配 → 加速 ✓
  ///   - 视频源不在 CF 后面 → 优选 IP 连 CF edge → SNI 不匹配 →
  ///     TLS 失败 → backend 关闭 TCP → onDone: closeAll → libmpv 报错
  ///   后者的问题由 _connectRace 的 fallback 兜底 (TCP 连接失败才 fallback,
  ///   TLS 失败不 fallback). 暂时接受这个风险, 大部分视频源在 CF 后面.
  static List<String> getTopNIpsForDomain(String domain, int n) {
    if (!_featureEnabled) return const [];
    final ips = _bestIpsCache;
    if (ips == null || ips.isEmpty) return const [];
    // v2.0.25: 不再检查 domain == targetDomain, 对所有域名都返回优选 IP
    if (n <= 0) return const [];
    if (n >= ips.length) return List<String>.from(ips);
    return ips.sublist(0, n);
  }

  /// v2.0.34: 视频代理 (VideoProxyServer) 拿优选 IP 用的查表
  ///
  /// 跟 [getTopNIpsForDomain] 的区别:
  ///   - 手动优选 IP (_resolvedManualIp) **优先级最高**:
  ///     - 不依赖 featureEnabled (v2.0.32 起手动 IP 不受优选测速开关控制)
  ///     - 不依赖 _bestIpsCache (不需要先跑优选测速)
  ///   - 手动优选只有 1 个 IP; 测速优选有 N 个 (N 由调用方传)
  ///   - 测速优选作为 fallback (需要 featureEnabled + _bestIpsCache)
  ///
  /// 这个差异让 [VideoProxyServer.tryStart] 的门可以独立于优选测速开关:
  ///   - 用户只要在 CF 加速页填了手动 IP (v2.0.31+) 或优选域名 (v2.0.32+)
  ///   - 视频代理就能起, 不用先跑"优选测速"那个 v2.0.30 砍掉的功能
  ///   - 这正是用户反馈"worker 不走优选, 速度不快"的修复点
  ///
  /// 返回空 list = 啥都没配, 调用方应该不启代理
  ///
  /// 注意: 手动优选只有 1 个 IP, _connectRace 单 IP 拨号失败时
  /// fallback 到原 host. 不像 3 IP 并发那么稳, 但 v2.0.32 域名模式下
  /// 域名自带多 IP 调度, 也算补偿了.
  ///
  /// v2.0.45: 把原 host 加进候选. 解决"单 IP 优选 0KB"问题 —
  ///   用户配的 IP 跟目标 host 不在同一个 CF zone / IP 已下线 →
  ///   TLS 握手失败 → libmpv 0KB 死. 把原 host 加进 race, 至少能让
  ///   系统 DNS 解析的 IP 跟 TLS SNI 走同一个 CF edge (CF anycast
  ///   按 SNI 路由证书). 缺点: 多一次 DNS lookup, 多个并发 socket.
  ///   实测 162.159.x.x 这种通用 CF IP, 拨上后 TLS 还是 0KB,
  ///   必须 fallback 到 host 让系统 DNS 选一个跟 SNI 匹配的 edge.
  ///
  /// v2.0.46: 跟 _resolvedManualIp 一样, 提前把 host DNS 解析缓存起来.
  ///   race 候选 **优先用 host DNS 解析的 IP** (跟 SNI 匹配的 CF edge IP),
  ///   手动 IP 排最后. 没缓存时 fire-and-forget 触发一次解析, 下次
  ///   getTopNIpsForVideoProxy 调用就用上. 用户场景:
  ///   配 `162.159.158.162` 静态 IP, target host `api.xx.workers.dev` →
  ///   系统 DNS 解析 host 返回 `104.x.x.x` (跟 SNI 匹配的 edge IP, 跟
  ///   手动 IP 不同的 zone) → race 候选 [104.x.x.x, 162.159.158.162] →
  ///   104.x.x.x TCP 拨上 ~30ms, 162.159.158.162 TCP 拨上 ~15ms, race
  ///   选 162.159.158.162 (15ms 优先) → 还是 0KB. 真的稳的修法见
  ///   [resolveHostEagerly] 调用点的注释.
  ///
  /// v2.0.48: 跟 v2.0.46 反过来 — race 选最快是错的, 改成 **host 永远第一**.
  ///   v2.0.46 顺序拨号 [host_ips..., manual] 已经正确, 但 _handleConnect
  ///   同步部分 fire-and-forget 触发 DNS, 同步调 getTopNIpsForVideoProxy
  ///   时 cache 是空的 → 返 [manual, host] (manual 在前) → 顺序拨号 manual
  ///   第一个 TCP 连上 → 返给 libmpv → libmpv TLS 失败 → 0KB.
  ///   改法: cache 空时返 [host, manual] (host 在前), 第一个 TCP 连上
  ///   的就是 host (系统 DNS 给的 IP, 跟 SNI 匹配), TLS 必然成功.
  ///   手动 IP 永远 fallback — 慢 1 个 IP 的拨号时间 (几十 ms), 但消除了
  ///   0KB 风险. 用户场景 (配 `172.64.229.44` 优选 IP, target
  ///   `api.xx.workers.dev`): 系统 DNS 给 `104.x.x.x` (有 cert 的 edge),
  ///   顺序拨号先拨 `104.x.x.x` (TLS 成功) → 视频 OK, `172.64.229.44`
  ///   完全用不到.
  static List<String> getTopNIpsForVideoProxy(String host, int n) {
    // 手动优选优先 (v2.0.32+: 可能是 IP, 也可能是已 resolve 的域名)
    final manual = _resolvedManualIp;
    if (manual != null && manual.isNotEmpty) {
      // v2.0.46: 先看 host DNS 缓存, 优先用 host IP (跟 SNI 匹配)
      final hostIps = getHostResolvedIps(host);
      if (hostIps != null && hostIps.isNotEmpty) {
        // host IPs 排前面 (跟 SNI 匹配的 CF edge IP),
        // 手动 IP 排最后 (兜底 — race 不选它时用户可能看到 fallback 原 host)
        final result = <String>[];
        for (final ip in hostIps) {
          if (ip != manual) result.add(ip);
        }
        result.add(manual);
        return result;
      }
      // v2.0.48: 缓存没值 (第一次或解析失败) — **顺序倒过来**,
      //   从 v2.0.46 的 [manual, host] 改成 [host, manual].
      //   根因: 手动 IP (从 cf.877774.xyz 这类优选 IP 服务拿的 fast CF IP)
      //   跟目标 host (e.g. api.xx.workers.dev) **不在同一个 CF zone**,
      //   TCP 拨上 (CF anycast 接受所有 IP) 但 TLS 失败 (edge 没那个
      //   SNI 的 cert). race / 顺序拨号都救不了 — 第一个 TCP 连上的
      //   IP 就被返给 libmpv, 后面 libmpv 做 TLS 才挂, 0KB 死链.
      //   解法: **host 优先**, 让 Socket.connect(host, port) 走系统
      //   DNS 解析 — 系统 DNS 给的 IP 是 CF "有 cert 的 edge", 必然
      //   TLS 成功. 手动 IP 当 fallback — 慢 1 个 IP 的拨号时间
      //   (几十 ms), 但消除了 0KB 风险.
      //
      //   触发后, resolveHostEagerly 仍 fire-and-forget 跑, 下次
      //   调用就走缓存路径 [host_ips..., manual] (跟当前正确路径一致).
      // ignore: unawaited_futures
      resolveHostEagerly(host);
      return [host, manual];
    }
    // fallback: 测速优选
    return getTopNIpsForDomain(host, n);
  }

  /// 安装全局 override (app 启动时调用)
  static Future<void> install() async {
    if (_globalInstalled) return;
    HttpOverrides.global = CfOptimizerHttpOverrides();
    _globalInstalled = true;
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // v2.1.32: **绝不要** new SecurityContext() 替换 context.
    //   之前 v2.1.30/31 我加了 `context ?? SecurityContext()` 想用 SecurityContext
    //   配 TLS 1.2 cipher, 但 `SecurityContext()` 默认**不信任任何证书**, 导致
    //   所有 https 请求 TLS 验证失败 (HandshakeException), 登录 API 跟 image 加载
    //   全部挂. v2.1.25 时直接 `super.createHttpClient(context)` 没问题, 修回这个.
    //
    //   影响范围: 只影响 Dart HttpClient (package:http / CachedNetworkImage /
    //     video_proxy_server / TMDB API / Douban / Bangumi / 登录 API / m3u8 测速).
    //   **视频 m3u8 播放走原生 libmpv (C 库), 完全不受 Dart 端影响.**
    //     (cf_optimizer.dart:444 注释)
    //
    // v2.1.33 (revert): dart:io **没有 public API 强制 TLS 版本** —
    //   - `SecureSocket.secure.supportedProtocols` 是给 ALPN (HTTP/2 vs HTTP/1.1),
    //     不是 TLS 版本
    //   - `SecurityContext.minimumTlsProtocolVersion` (默认 tls1_2) 只设 floor,
    //     服务端支持 1.3 时 client 还是走 1.3
    //   - `ProtocolVersion` 类在 Dart 3.4 不存在 (老 API 删了)
    //   - BoringSSL 的 `SSL_CTX_set_max_proto_version` 没 dart 包装
    //   之前 v2.1.33 我试加 connectionFactory 强制 TLS 1.2 用了
    //   `supportedProtocols: const [ProtocolVersion.tlsV12]`, **编译都不通过** —
    //   build 会挂. 修回原样.
    //
    // 真要从 client 修 TLS 1.3 cipher 协商失败, 必须换 HTTP stack —
    //   Android MethodChannel + OkHttp/HttpURLConnection (用系统 BoringSSL/Conscrypt),
    //   或者 package:cronet_http (用 Android Cronet). 这个改动大 (要碰
    //   android/app/build.gradle.kts + MainActivity.kt + 创建 Kotlin channel +
    //   Dart wrapper + 17 个 CachedNetworkImage 调用点全改), 跟用户确认再干.
    return _OptimizingHttpClient(super.createHttpClient(context));
  }
}

class _OptimizingHttpClient implements HttpClient {
  final HttpClient _inner;
  _OptimizingHttpClient(this._inner);

  InternetAddress? _tryOverrideAddress(Uri uri) {
    final target = CfOptimizerHttpOverrides._targetDomainCache;
    if (target == null || target.isEmpty) return null;
    final host = uri.host.toLowerCase();
    if (host != target.toLowerCase()) return null;

    // v2.0.76: featureEnabled (新「优选 IP 启用」开关) 决定是否 override
    //   - 优选 IP 开关关 → 不 override, 走系统 DNS (即使有手动 IP)
    //   - 优选 IP 开关开 + 手动 IP 已解析 → 用手动 IP (优先级最高)
    //   - 优选 IP 开关开 + 没手动 IP → 用测速结果第一个 IP
    if (!CfOptimizerHttpOverrides._featureEnabled) return null;

    final resolved = CfOptimizerHttpOverrides._resolvedManualIp;
    if (resolved != null && resolved.isNotEmpty) {
      return InternetAddress(resolved, type: InternetAddressType.IPv4);
    }

    // 退回测速结果 (需要 featureEnabled + 测速结果)
    final ips = CfOptimizerHttpOverrides._bestIpsCache;
    if (ips == null || ips.isEmpty) return null;
    // 返回第一个优选 IP (按延迟最低排)
    return InternetAddress(ips.first, type: InternetAddressType.IPv4);
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    final addr = _tryOverrideAddress(url);
    if (addr != null) {
      final newUri = Uri(
        scheme: url.scheme,
        userInfo: url.userInfo,
        host: addr.address,
        port: url.port,
        path: url.path,
        query: url.query,
        fragment: url.fragment,
      );
      // 用 Host header 保留原域名 (SNI / TLS 验证用)
      return _inner.getUrl(newUri).then((req) {
        req.headers.set('Host', url.host);
        return req;
      });
    }
    return _inner.getUrl(url);
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    final addr = _tryOverrideAddress(url);
    if (addr != null) {
      final newUri = Uri(
        scheme: url.scheme,
        userInfo: url.userInfo,
        host: addr.address,
        port: url.port,
        path: url.path,
        query: url.query,
        fragment: url.fragment,
      );
      return _inner.openUrl(method, newUri).then((req) {
        req.headers.set('Host', url.host);
        return req;
      });
    }
    return _inner.openUrl(method, url);
  }

  // 其余方法透传
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;
  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set userAgent(String? value) => _inner.userAgent = value;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _inner.connectionFactory = f;
  @override
  set keyLog(void Function(String line)? callback) =>
      _inner.keyLog = callback;
  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);
  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);
  @override
  set authenticate(Future<bool> Function(Uri url, String scheme, String? realm)?
          f) =>
      _inner.authenticate = f;
  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _inner.authenticateProxy = f;
  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)?
              callback) =>
      _inner.badCertificateCallback = callback;
  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;
  @override
  void close({bool force = false}) => _inner.close(force: force);

  // Shortcut 方法 (host/port/path 形式)
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _inner.delete(host, port, path);
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _inner.get(host, port, path);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _inner.head(host, port, path);
  @override
  Future<HttpClientRequest> open(String method, String host, int port,
          String path) =>
      _inner.open(method, host, port, path);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _inner.patch(host, port, path);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _inner.post(host, port, path);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _inner.put(host, port, path);

  // *Url 方法
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => _inner.deleteUrl(url);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => _inner.headUrl(url);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => _inner.patchUrl(url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => _inner.postUrl(url);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => _inner.putUrl(url);
}
