import 'search_result.dart';
import 'video_info.dart';

/// 聚合搜索结果数据模型
class AggregatedSearchResult {
  final String key; // 聚合键：标题+年份+类型
  final String title;
  final String year;
  final String type; // movie 或 tv
  final String cover; // 封面图片
  final Map<String, int> episodeCounts; // 源名称 -> 集数的映射
  final Map<String, int> doubanIds; // 豆瓣ID -> 出现次数的映射
  final List<String> sourceNames; // 所有源名称列表
  final List<SearchResult> originalResults; // 原始搜索结果列表
  final int addedTimestamp; // 首次添加的时间戳

  AggregatedSearchResult({
    required this.key,
    required this.title,
    required this.year,
    required this.type,
    required this.cover,
    required this.episodeCounts,
    required this.doubanIds,
    required this.sourceNames,
    required this.originalResults,
    required this.addedTimestamp,
  });

  /// 从搜索结果创建聚合结果
  factory AggregatedSearchResult.fromSearchResult(SearchResult result) {
    final type = result.episodes.length > 1 ? 'tv' : 'movie';
    final key = '${result.title}_${result.year}_$type';
    
    Map<String, int> episodeCounts = {};
    episodeCounts[result.sourceName] = result.episodes.length;
    
    Map<String, int> doubanIds = {};
    if (result.doubanId != null && result.doubanId! > 0) {
      doubanIds[result.doubanId.toString()] = 1;
    }
    
    return AggregatedSearchResult(
      key: key,
      title: result.title,
      year: result.year,
      type: type,
      cover: result.poster,
      episodeCounts: episodeCounts,
      doubanIds: doubanIds,
      sourceNames: [result.sourceName],
      originalResults: [result],
      addedTimestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 添加新的搜索结果到聚合结果中
  AggregatedSearchResult addResult(SearchResult result) {
    final newEpisodeCounts = Map<String, int>.from(episodeCounts);
    newEpisodeCounts[result.sourceName] = result.episodes.length;

    final newDoubanIds = Map<String, int>.from(doubanIds);
    if (result.doubanId != null && result.doubanId! > 0) {
      final doubanIdStr = result.doubanId.toString();
      newDoubanIds[doubanIdStr] = (newDoubanIds[doubanIdStr] ?? 0) + 1;
    }

    final newSourceNames = List<String>.from(sourceNames);
    if (!newSourceNames.contains(result.sourceName)) {
      newSourceNames.add(result.sourceName);
    }

    final newOriginalResults = List<SearchResult>.from(originalResults);
    newOriginalResults.add(result);

    return AggregatedSearchResult(
      key: key,
      title: title,
      year: year,
      type: type,
      cover: cover,
      episodeCounts: newEpisodeCounts,
      doubanIds: newDoubanIds,
      sourceNames: newSourceNames,
      originalResults: newOriginalResults,
      addedTimestamp: addedTimestamp,
    );
  }

  /// 获取最常见的集数
  int get mostCommonEpisodeCount {
    if (episodeCounts.isEmpty) return 0;
    
    // 统计每个集数的出现次数
    Map<int, int> countFrequency = {};
    for (int count in episodeCounts.values) {
      countFrequency[count] = (countFrequency[count] ?? 0) + 1;
    }
    
    // 找出出现次数最多的集数
    int mostCommon = episodeCounts.values.first;
    int maxFrequency = 0;
    
    countFrequency.forEach((count, frequency) {
      if (frequency > maxFrequency) {
        maxFrequency = frequency;
        mostCommon = count;
      }
    });
    
    return mostCommon;
  }

  /// 获取最常见的豆瓣ID
  String? get mostCommonDoubanId {
    if (doubanIds.isEmpty) return null;
    
    String? mostCommon;
    int maxCount = 0;
    
    doubanIds.forEach((id, count) {
      if (count > maxCount) {
        maxCount = count;
        mostCommon = id;
      }
    });
    
    return mostCommon;
  }

  /// 转换为VideoInfo用于显示
  VideoInfo toVideoInfo() {
    return VideoInfo(
      id: key, // 使用聚合键作为ID
      source: 'aggregated', // 标记为聚合来源
      title: title,
      sourceName: sourceNames.join(', '), // 显示所有源名称
      year: year,
      cover: cover,
      index: 1,
      totalEpisodes: mostCommonEpisodeCount,
      playTime: 0,
      totalTime: 0,
      saveTime: addedTimestamp,
      searchTitle: title,
      doubanId: mostCommonDoubanId,
    );
  }

  /// 生成聚合键
  static String generateKey(String title, String year, int episodeCount) {
    final type = episodeCount > 1 ? 'tv' : 'movie';
    return '${title}_${year}_$type';
  }
}
