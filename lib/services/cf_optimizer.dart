import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

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
///   - 用户必须先打开 "CF Worker 加速源" 开关 ([UserDataService.getCfWorkerEnabled])
///   - 用户可以单独关 "CF 优选测速" 开关 (默认开)
///   - 启动时如果 7 天没测过 → 后台跑
///   - 用户菜单里可以手动 "立即优选测速"
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
  static String? _manualPreferredIp;

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
  }

  /// 刷新缓存 (优选测速完后调用)
  static void refresh({
    required List<String> bestIps,
    required String targetDomain,
  }) {
    _bestIpsCache = bestIps;
    _targetDomainCache = targetDomain;
  }

  /// v2.0.31: 用户在设置页改了手动优选 IP, 立即生效 (不用重启 App)
  static void setManualPreferredIp(String? ip) {
    if (ip == null || ip.isEmpty) {
      _manualPreferredIp = null;
    } else {
      _manualPreferredIp = ip;
    }
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
  ///   现在对所有域名都返回优选 IP:
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

  /// 安装全局 override (app 启动时调用)
  static Future<void> install() async {
    if (_globalInstalled) return;
    HttpOverrides.global = CfOptimizerHttpOverrides();
    _globalInstalled = true;
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
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

    // v2.0.31: 手动优选 IP 优先级最高, 不受 featureEnabled 控制
    final manualIp = CfOptimizerHttpOverrides._manualPreferredIp;
    if (manualIp != null && manualIp.isNotEmpty) {
      return InternetAddress(manualIp, type: InternetAddressType.IPv4);
    }

    // 退回测速结果 (需要 featureEnabled + 测速结果)
    if (!CfOptimizerHttpOverrides._featureEnabled) return null;
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
