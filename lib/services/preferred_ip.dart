import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

/// App 端 CF 优选 IP 服务
/// 启动时异步测速一组 CF Anycast IP, 按延迟排序取 top N
/// 持久化到 SharedPreferences, 供 buildProxiedUrl 用最优 IP 替换域名
class PreferredIp {
  // CF 公开 Anycast IP 池 (与 CORSAPI 同步)
  static const List<String> defaultIps = [
    '104.16.123.96', '104.16.124.96', '104.17.1.1', '104.18.1.1',
    '104.19.1.1', '104.20.1.1', '104.21.1.1', '172.64.150.6',
    '172.64.151.6', '172.65.1.1', '172.66.1.1', '172.67.1.1',
    '162.158.0.6', '162.159.1.1', '162.159.140.22', '173.245.58.118',
    '141.101.121.6', '190.93.240.6', '188.114.96.6', '197.234.240.6',
    '198.41.192.6', '198.41.193.6', '198.41.194.6', '198.41.195.6',
    '198.41.196.6', '198.41.197.6', '198.41.198.6', '198.41.199.6',
    '198.41.200.6', '198.41.201.6', '198.41.202.6', '198.41.203.6',
  ];

  static const String _keyTopIps = 'preferred_ip_top';
  static const String _keyLastTest = 'preferred_ip_last_test';
  static const String _keyTestDomain = 'preferred_ip_test_domain';

  /// 测速并缓存 top N IP
  /// [workerDomain] 测速时 SNI 用的域名, 也是后续实际访问时的 SNI
  /// 返回按延迟升序的 [(ip, ms), ...]
  static Future<List<MapEntry<String, int>>> testAndCache({
    required String workerDomain,
    int topN = 5,
    int timeoutMs = 1500,
  }) async {
    final results = <MapEntry<String, int>>[];
    // 8 并发测速
    for (var i = 0; i < defaultIps.length; i += 8) {
      final batch = defaultIps.skip(i).take(8);
      final batchResults = await Future.wait(
        batch.map((ip) async {
          final ms = await _pingIp(ip, workerDomain, timeoutMs);
          return MapEntry(ip, ms);
        }),
      );
      results.addAll(batchResults);
    }
    // 过滤成功 (< timeout) + 按延迟升序
    results.removeWhere((e) => e.value >= timeoutMs);
    results.sort((a, b) => a.value.compareTo(b.value));
    final top = results.take(topN).toList();

    // 缓存
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyTestDomain, workerDomain);
    await prefs.setString(_keyLastTest, DateTime.now().toIso8601String());
    await prefs.setStringList(
      _keyTopIps,
      top.map((e) => '${e.key}:${e.value}').toList(),
    );
    return top;
  }

  /// 测速单个 IP (TCP + TLS 握手 + GET /cdn-cgi/trace 拿到首字节)
  static Future<int> _pingIp(String ip, String sni, int timeoutMs) async {
    final start = DateTime.now().millisecondsSinceEpoch;
    try {
      final rawSocket = await RawSocket.connect(ip, 443).timeout(
        Duration(milliseconds: timeoutMs),
      );
      final secure = await SecureSocket.secure(
        rawSocket,
        host: sni, // 强制 SNI = worker 域名
        onBadCertificate: (_) => true,
      ).timeout(Duration(milliseconds: timeoutMs));

      secure.write('GET /cdn-cgi/trace HTTP/1.1\r\n'
          'Host: $sni\r\n'
          'Connection: close\r\n'
          'User-Agent: LunaTV/1.0 PreferredIp\r\n'
          '\r\n');
      await secure.flush();

      // 读到第一个响应字节就返回 (测首字节时间 = 真实下载速度的近似)
      final completer = Completer<int>();
      late StreamSubscription sub;
      sub = secure.listen(
        (_) {
          if (!completer.isCompleted) {
            completer.complete(DateTime.now().millisecondsSinceEpoch - start);
          }
          sub.cancel();
          secure.close();
          rawSocket.close();
        },
        onError: (_) {
          if (!completer.isCompleted) {
            completer.complete(timeoutMs);
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete(timeoutMs);
          }
        },
        cancelOnError: true,
      );
      return await completer.future.timeout(Duration(milliseconds: timeoutMs));
    } catch (_) {
      return timeoutMs;
    }
  }

  /// 获取缓存的最优 IP 列表 [(ip, ms), ...]
  static Future<List<MapEntry<String, int>>> getTopIps() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_keyTopIps) ?? [];
    return list.map((s) {
      final idx = s.lastIndexOf(':');
      return MapEntry(s.substring(0, idx), int.parse(s.substring(idx + 1)));
    }).toList();
  }

  /// 获取测速时用的 worker 域名 (用于强制 SNI)
  static Future<String?> getTestDomain() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyTestDomain);
  }

  /// 获取上次测速时间
  static Future<DateTime?> getLastTestTime() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_keyLastTest);
    return s != null ? DateTime.tryParse(s) : null;
  }

  /// 最优 IP (延迟最低那个, 可能为 null)
  static Future<String?> getBestIp() async {
    final top = await getTopIps();
    return top.isNotEmpty ? top.first.key : null;
  }

  /// 是否需要重新测速 (> 24h)
  static Future<bool> shouldRetest() async {
    final last = await getLastTestTime();
    if (last == null) return true;
    return DateTime.now().difference(last).inHours > 24;
  }

  /// 清除缓存
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyTopIps);
    await prefs.remove(_keyLastTest);
    await prefs.remove(_keyTestDomain);
  }
}
