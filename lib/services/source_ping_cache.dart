import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 源测速缓存服务
/// 用于持久化存储每个源（按 source key）最近一次的测速结果
class SourcePingCache {
  static const String _key = 'source_ping_cache_v1';

  /// 读取所有缓存
  static Future<Map<String, int>> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, int>{};
      decoded.forEach((k, v) {
        if (v is int) {
          result[k.toString()] = v;
        } else if (v is num) {
          result[k.toString()] = v.toInt();
        }
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  /// 获取某个 source 的缓存测速（毫秒），未命中返回 null
  static Future<int?> get(String source) async {
    if (source.isEmpty) return null;
    final all = await _load();
    return all[source];
  }

  /// 批量获取
  static Future<Map<String, int>> getAll() async {
    return await _load();
  }

  /// 保存某个 source 的测速结果
  static Future<void> set(String source, int ms) async {
    if (source.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final all = await _load();
    all[source] = ms;
    await prefs.setString(_key, jsonEncode(all));
  }

  /// 清除缓存
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
