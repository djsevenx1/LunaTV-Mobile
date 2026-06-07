import 'package:shared_preferences/shared_preferences.dart';

/// 内容过滤服务
class ContentFilterService {
  static const String _key = 'user_blocklist';
  static const List<String> _defaultBlocklist = [
    '伦理片', '福利', '里番动漫', '门事件', '萝莉少女', '制服诱惑', '国产传媒', 'cosplay',
    '黑丝诱惑', '无码', '日本无码', '有码', '日本有码', 'SWAG', '网红主播', '色情片',
    '同性片', '福利视频', '福利片', '写真热舞', '倫理片', '理论片', '韩国伦理',
    '港台三级', '电影解说', '伦理', '日本伦理',
  ];

  /// 黄色关键词列表（默认 + 用户自定义合并，只读快照）
  static List<String> get activeKeywords => [..._defaultBlocklist, ..._customBlocklist];

  /// 用户自定义关键词（Runtime 缓存）
  static List<String> _customBlocklist = [];

  static const String _enabledKey = 'filter_enabled';

  static bool _enabled = false;

  /// 从 SharedPreferences 加载用户自定义列表 & enabled 状态
  static Future<void> loadUserRules() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _customBlocklist = prefs.getStringList(_key) ?? [];
      _enabled = prefs.getBool(_enabledKey) ?? false;
    } catch (_) {
      _customBlocklist = [];
      _enabled = false;
    }
  }

  /// 读取当前用户自定义规则（纯内存快照，可安全直接读取）
  static List<String> getUserRules() => List.unmodifiable(_customBlocklist);

  /// 保存用户自定义关键词
  static Future<void> setUserRules(List<String> rules) async {
    final prefs = await SharedPreferences.getInstance();
    final deduped = rules.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
    await prefs.setStringList(_key, deduped);
    _customBlocklist = deduped;
  }

  /// 开关状态
  static bool isEnabled() => _enabled;
  static Future<void> setEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, v);
    _enabled = v;
  }

  /// 检查文本是否包含任何关键词
  static bool containsAnyKeyword(String? text, List<String> keywords) {
    if (text == null || text.isEmpty) return false;
    for (final word in keywords) {
      if (text.contains(word)) return true;
    }
    return false;
  }

  /// 检查是否应过滤（默认行为：使用 activeKeywords）
  static bool containsYellowWord(String? text) => containsAnyKeyword(text, activeKeywords);

  /// 检查搜索结果是否应该被过滤
  static bool shouldFilter(String? typeName) => containsYellowWord(typeName);
}
