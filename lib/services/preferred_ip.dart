import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

/// 优选IP服务
/// 实现参考 cmliu/edgetunnel:
///   1. 从 URL/订阅获取 IP 列表
///   2. 自动识别用户宽带运营商 (移动/电信/联通)
///   3. 测速每个 IP 的延迟
///   4. 取最快的 IP 作为请求代理入口
class PreferredIp {
  static const String _ipsKey = 'preferred_ips_v1';
  static const String _ipsSourceKey = 'preferred_ips_source_url';
  static const String _autoTestKey = 'preferred_ips_auto_test';
  static const String _lastTestKey = 'preferred_ips_last_test_time';
  static const String _bestIspKey = 'preferred_ips_best_isp';
  static const String _bestIpKey = 'preferred_ips_best_ip';

  // 默认优选IP源 (cmliu 公开的优选IP列表)
  static const String _defaultSourceUrl =
      'https://raw.githubusercontent.com/cmliu/CF-IPQuality/main/ipv4.txt';

  // 默认的 Cloudflare 优选IP段 (作为保底)
  static const List<String> _defaultCloudflareIps = [
    '104.16.124.96',
    '104.16.123.96',
    '162.159.140.22',
    '108.162.198.6',
    '172.64.152.6',
    '172.64.150.6',
    '173.245.58.118',
    '103.21.244.6',
    '103.21.245.6',
    '103.21.246.6',
    '103.21.247.6',
    '103.22.200.6',
    '103.22.201.6',
    '103.22.202.6',
    '103.22.203.6',
    '141.101.121.6',
    '141.101.122.6',
    '141.101.123.6',
    '190.93.240.6',
    '190.93.241.6',
    '190.93.242.6',
    '188.114.96.6',
    '188.114.97.6',
    '188.114.98.6',
    '188.114.99.6',
    '197.234.240.6',
    '197.234.241.6',
    '197.234.242.6',
    '197.234.243.6',
    '198.41.192.6',
    '198.41.192.7',
    '198.41.192.107',
    '198.41.193.6',
    '198.41.194.6',
    '198.41.195.6',
    '198.41.196.6',
    '198.41.197.6',
    '198.41.198.6',
    '198.41.199.6',
    '198.41.200.6',
    '198.41.201.6',
    '198.41.202.6',
    '198.41.203.6',
    '198.41.204.6',
    '198.41.205.6',
    '198.41.206.6',
    '162.158.0.6',
    '162.158.1.6',
    '162.158.2.6',
    '162.158.3.6',
    '162.158.4.6',
    '162.158.5.6',
    '162.158.6.6',
    '162.158.7.6',
  ];

  // 当前用户运营商 (从IP判断)
  static String _userIsp = '未知';

  // 测速结果缓存 (ip -> ms)
  static final Map<String, int> _pingCache = {};

  /// 获取当前配置的优选IP源URL
  static Future<String> getSourceUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_ipsSourceKey) ?? _defaultSourceUrl;
  }

  /// 设置优选IP源URL
  static Future<void> setSourceUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ipsSourceKey, url);
  }

  /// 是否开启自动测速
  static Future<bool> getAutoTest() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoTestKey) ?? true;
  }

  /// 设置是否自动测速
  static Future<void> setAutoTest(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoTestKey, enabled);
  }

  /// 检测用户运营商 (从公网IP反查)
  /// 简单实现: 通过 ip-api.com 查询
  static Future<String> detectUserIsp() async {
    try {
      final httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 5);
      final request = await httpClient.getUrl(
        Uri.parse('http://ip-api.com/json/?lang=zh-CN'),
      );
      request.headers.set('User-Agent', 'LunaTV/1.0');
      final response = await request.close();
      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final isp = (data['isp'] ?? '').toString().toLowerCase();
        final org = (data['org'] ?? '').toString().toLowerCase();

        if (isp.contains('移动') ||
            isp.contains('mobile') ||
            isp.contains('chinamobile') ||
            org.contains('mobile')) {
          _userIsp = '移动';
        } else if (isp.contains('电信') ||
            isp.contains('telecom') ||
            isp.contains('chinanet') ||
            org.contains('telecom')) {
          _userIsp = '电信';
        } else if (isp.contains('联通') ||
            isp.contains('unicom') ||
            isp.contains('chinaunicom') ||
            org.contains('unicom')) {
          _userIsp = '联通';
        } else if (isp.contains('教育') || org.contains('cernet')) {
          _userIsp = '教育网';
        } else {
          _userIsp = isp.isNotEmpty ? isp : '未知';
        }
      }
      httpClient.close();
    } catch (_) {
      _userIsp = '未知';
    }
    return _userIsp;
  }

  /// 获取当前用户运营商 (同步, 需先调用 detectUserIsp)
  static String get userIsp => _userIsp;

  /// 从URL/订阅获取IP列表
  static Future<List<String>> fetchIpList({String? customUrl}) async {
    final url = customUrl ?? await getSourceUrl();
    try {
      final httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 10);
      final request = await httpClient.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'LunaTV/1.0');
      final response = await request.close();
      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        // 每行一个IP
        final ips = body
            .split(RegExp(r'[\r\n]+'))
            .map((line) {
              // 去除端口号/注释/空白
              final parts = line.trim().split(RegExp(r'[\s,#]+'));
              if (parts.isEmpty) return '';
              return parts.first;
            })
            .where((ip) => _isValidIp(ip))
            .toList();
        httpClient.close();
        if (ips.isNotEmpty) {
          return ips;
        }
      }
      httpClient.close();
    } catch (_) {}
    return _defaultCloudflareIps;
  }

  /// IP格式校验
  static bool _isValidIp(String ip) {
    if (ip.isEmpty) return false;
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }

  /// 测速单个IP (TCP 连接时间, 端口 443)
  static Future<int> pingIp(String ip,
      {int port = 443, int timeoutMs = 1500}) async {
    if (_pingCache.containsKey(ip)) return _pingCache[ip]!;
    final start = DateTime.now();
    try {
      final socket = await Socket.connect(ip, port,
          timeout: Duration(milliseconds: timeoutMs));
      socket.destroy();
    } catch (_) {
      _pingCache[ip] = 3000;
      return 3000;
    }
    final ms = DateTime.now().difference(start).inMilliseconds;
    _pingCache[ip] = ms;
    return ms;
  }

  /// 批量测速并排序
  /// 返回 [ip, ms] 列表, 按延迟升序
  static Future<List<MapEntry<String, int>>> testIps(
      List<String> ips, {
        int maxConcurrent = 10,
        int maxIps = 30,
        int? progressCallback(int current, int total),
      }) async {
    // 只测前 N 个 IP 避免太久
    final testList = ips.take(maxIps).toList();
    final results = <MapEntry<String, int>>[];
    var done = 0;
    for (var i = 0; i < testList.length; i += maxConcurrent) {
      final batch = testList.skip(i).take(maxConcurrent).toList();
      final batchResults = await Future.wait(
        batch.map((ip) async {
          final ms = await pingIp(ip);
          return MapEntry(ip, ms);
        }),
      );
      results.addAll(batchResults.where((e) => e.value < 3000));
      done += batch.length;
      progressCallback?.call(done, testList.length);
    }
    results.sort((a, b) => a.value.compareTo(b.value));
    return results;
  }

  /// 启动优选: 获取IP列表 + 测速 + 保存最优结果
  /// 返回排好序的 [ip, ms] 列表
  static Future<List<MapEntry<String, int>>> runPreferredIpTest({
    int maxIps = 30,
    int? Function(int current, int total)? progressCallback,
  }) async {
    // 1. 检测运营商
    await detectUserIsp();
    progressCallback?.call(0, 100);

    // 2. 拉取IP列表
    final ips = await fetchIpList();
    progressCallback?.call(10, 100);

    // 3. 测速
    final results = await testIps(
      ips,
      maxIps: maxIps,
      progressCallback: (cur, total) {
        // 10% - 90% 用于测速
        progressCallback?.call(10 + (cur * 80 ~/ total), 100);
      },
    );

    // 4. 保存最优结果
    if (results.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      final best = results.first;
      await prefs.setInt(_lastTestKey, DateTime.now().millisecondsSinceEpoch);
      await prefs.setString(_bestIspKey, _userIsp);
      await prefs.setString(_bestIpKey, best.key);
      await prefs.setString(_ipsKey, jsonEncode(results.map((e) {
        return {'ip': e.key, 'ms': e.value};
      }).toList()));
    }

    progressCallback?.call(100, 100);
    return results;
  }

  /// 获取上次保存的优选结果
  static Future<List<MapEntry<String, int>>> getLastResults() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_ipsKey);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map((m) => MapEntry(m['ip']?.toString() ?? '', m['ms'] as int? ?? 3000))
          .where((e) => e.key.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 获取最优IP
  static Future<String?> getBestIp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_bestIpKey);
  }

  /// 获取上次测速的运营商
  static Future<String> getBestIsp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_bestIspKey) ?? '未知';
  }

  /// 获取上次测速时间
  static Future<DateTime?> getLastTestTime() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_lastTestKey);
    if (ts == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ts);
  }

  /// 清除优选IP缓存
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_ipsKey);
    await prefs.remove(_bestIspKey);
    await prefs.remove(_bestIpKey);
    await prefs.remove(_lastTestKey);
    _pingCache.clear();
  }
}
