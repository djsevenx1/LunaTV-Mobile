/// 内容过滤服务
class ContentFilterService {
  /// 黄色关键词列表
  static const List<String> yellowWords = [
    '伦理片',
    '福利',
    '里番动漫',
    '门事件',
    '萝莉少女',
    '制服诱惑',
    '国产传媒',
    'cosplay',
    '黑丝诱惑',
    '无码',
    '日本无码',
    '有码',
    '日本有码',
    'SWAG',
    '网红主播',
    '色情片',
    '同性片',
    '福利视频',
    '福利片',
    '写真热舞',
    '倫理片',
    '理论片',
    '韩国伦理',
    '港台三级',
    '电影解说',
    '伦理',
    '日本伦理',
  ];

  /// 检查类型名称是否包含黄色关键词
  static bool containsYellowWord(String? typeName) {
    if (typeName == null || typeName.isEmpty) {
      return false;
    }

    return yellowWords.any((word) => typeName.contains(word));
  }

  /// 检查搜索结果是否应该被过滤
  static bool shouldFilter(String? typeName) {
    return containsYellowWord(typeName);
  }
}
