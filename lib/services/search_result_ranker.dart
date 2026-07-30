// lib/services/search_result_ranker.dart
//
// v2.6.7: 搜索结果相关性排序, 跟 web src/lib/search-ranking.ts 1:1.
//   之前 app 端 SSE 拿到结果直接 addAll 进 _searchResults, 没排序, 出现
//   "搜凡人修仙传结果里出现凡人修仙传 电影 / 凡人修仙之风起 仙林外传 等无关
//    剧名卡片"的问题. web 端有 calculateRelevanceScore / rankSearchResults /
//    groupSearchResultsByRelevance, app 端缺失, 行为不一致.
//
// 评分规则 (从 web 端 search-ranking.ts 1:1 复刻, 跟 web 行为一致):
//   1. 完全匹配 (title === keyword): 100
//   2. 开头匹配 (title startsWith keyword): 80
//   3. 包含完整关键词: 60
//   4. 模糊匹配: 20-40
//   5. 年份加分: +10 (近5年) / +5 (近10年) / +2 (近20年)
//   6. 豆瓣加分: +5
//   最高 110.
//
// 排序优先级: score desc → year desc → title asc. 跟 web 端 rankSearchResults
//   实现一致.

import 'dart:math' as math;

import 'package:luna_tv/models/search_result.dart';

class SearchResultRanker {
  SearchResultRanker._();

  /// 计算 Levenshtein 距离
  static int _levenshteinDistance(String s1, String s2) {
    final len1 = s1.length;
    final len2 = s2.length;
    final matrix = List<List<int>>.generate(
      len1 + 1,
      (_) => List<int>.filled(len2 + 1, 0),
    );
    for (var i = 0; i <= len1; i++) {
      matrix[i][0] = i;
    }
    for (var j = 0; j <= len2; j++) {
      matrix[0][j] = j;
    }
    for (var i = 1; i <= len1; i++) {
      for (var j = 1; j <= len2; j++) {
        final cost = s1[i - 1] == s2[j - 1] ? 0 : 1;
        matrix[i][j] = math.min(
          matrix[i - 1][j] + 1, // 删除
          math.min(
            matrix[i][j - 1] + 1, // 插入
            matrix[i - 1][j - 1] + cost, // 替换
          ),
        );
      }
    }
    return matrix[len1][len2];
  }

  /// 计算相似度百分比 (0-1)
  static double _similarityScore(String s1, String s2) {
    final distance = _levenshteinDistance(s1, s2);
    final maxLen = math.max(s1.length, s2.length);
    return maxLen == 0 ? 1.0 : 1.0 - distance / maxLen;
  }

  /// 检查 title 中是否按顺序包含 keyword 的所有字符 (可有间隔).
  /// 例如 "后浪" 可匹配 "后来的浪潮".
  static bool _containsCharsInOrder(String title, String keyword) {
    var keywordIndex = 0;
    for (var i = 0; i < title.length && keywordIndex < keyword.length; i++) {
      if (title[i] == keyword[keywordIndex]) {
        keywordIndex++;
      }
    }
    return keywordIndex == keyword.length;
  }

  /// 计算单个结果的相关性分数. 跟 web 端 calculateRelevanceScore 1:1.
  static int calculateRelevanceScore(SearchResult result, String query) {
    final title = result.title.trim();
    final keyword = query.trim();
    if (title.isEmpty || keyword.isEmpty) return 0;

    final titleNoSpace = title.replaceAll(RegExp(r'\s+'), '');
    final keywordNoSpace = keyword.replaceAll(RegExp(r'\s+'), '');

    var score = 0;

    // 1. 完全匹配 100
    if (title == keyword || titleNoSpace == keywordNoSpace) {
      score = 100;
    }
    // 2. 开头匹配 80
    else if (title.startsWith(keyword) || titleNoSpace.startsWith(keywordNoSpace)) {
      score = 80;
    }
    // 3. 包含完整关键词 60
    else if (title.contains(keyword) || titleNoSpace.contains(keywordNoSpace)) {
      score = 60;
    }
    // 4. 模糊匹配
    else {
      if (_containsCharsInOrder(titleNoSpace, keywordNoSpace)) {
        // 字符间隔越小分数越高
        final similarity = _similarityScore(titleNoSpace, keywordNoSpace);
        score = 20 + (similarity * 20).round(); // 20-40
      } else {
        // 部分字符匹配
        final matchedChars = keywordNoSpace
            .split('')
            .where((c) => titleNoSpace.contains(c))
            .length;
        final ratio = keywordNoSpace.isEmpty
            ? 0.0
            : matchedChars / keywordNoSpace.length;
        score = (ratio * 15).round(); // 0-15
      }
    }

    // 5. 年份加分 (最新作品加分, 最多 +10)
    final year = int.tryParse(result.year) ?? 0;
    if (year > 0) {
      final currentYear = DateTime.now().year;
      final yearDiff = currentYear - year;
      if (yearDiff >= 0) {
        if (yearDiff <= 5) {
          score += 10 - yearDiff; // 5-10
        } else if (yearDiff <= 10) {
          score += 5;
        } else if (yearDiff <= 20) {
          score += 2;
        }
      }
    }

    // 6. 豆瓣评分加分
    if (result.doubanId != null && result.doubanId! > 0) {
      score += 5;
    }

    return math.min(score, 110);
  }

  /// 标题归一化: 转小写 + 去空格 + 去常见标点.
  /// 跟 web 端 `title.toLowerCase().includes(query.toLowerCase())` 行为对齐,
  /// 同时去掉空格让 "凡人修仙传" 能匹配 "凡 人 修 仙 传" 这种带空格的标题.
  static String _normalize(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'[\s\u3000\-—_:：·•・]+'), '');
  }

  /// 检查 title 是否"包含" query (titleContainsQuery 跟 web 端
  ///   src/app/search/page.tsx:602-615 1:1).
  ///
  /// 行为: 归一化后 title.includes(query). 搜「凡人修仙传」匹配
  ///   「凡人修仙传」「凡人修仙传 新版」「凡人修仙传之风起」等
  ///   title 里含「凡人修仙传」的剧, 但不匹配「凡人修仙之风起」
  ///   (title 不含 query) / 「仙林外传」 (无关剧).
  ///
  /// exactSearch=false 时返回 true (不过滤, 跟 web 端 `if (!exactSearch)
  ///   return true` 一致). 打开 toggle 后能看到全部结果, 不再被强制过滤.
  ///
  /// 不做繁简转换: 跟 web 端 chineseConverter.simplized 比简化版只覆盖
  ///   90% 场景 (用户搜简体命中简体 title, 搜繁体命中繁体 title).
  ///   繁简转换是 nice-to-have, v2.6.9 暂不引入 switch-chinese 库增加体积.
  static bool matchesQuery(String title, String query) {
    if (title.isEmpty || query.isEmpty) return true;
    final nt = _normalize(title);
    final nq = _normalize(query);
    if (nt.contains(nq)) return true;
    return false;
  }

  /// 检查 SearchResult 是否"包含" query. 等价 `matchesQuery(r.title, query)`.
  static bool resultMatchesQuery(SearchResult r, String query) {
    return matchesQuery(r.title, query);
  }

  /// 对结果按相关性排序. 跟 web 端 rankSearchResults 1:1.
  /// 排序: score desc → year desc → title asc.
  static List<SearchResult> rankSearchResults(
    List<SearchResult> results,
    String query,
  ) {
    if (results.isEmpty) return [];

    final scored = results
        .map((r) => MapEntry(r, calculateRelevanceScore(r, query)))
        .toList();

    scored.sort((a, b) {
      // 1. 分数降序
      if (b.value != a.value) {
        return b.value.compareTo(a.value);
      }
      // 2. 分数相同按年份倒序
      final yearA = int.tryParse(a.key.year) ?? 0;
      final yearB = int.tryParse(b.key.year) ?? 0;
      if (yearB != yearA) {
        return yearB.compareTo(yearA);
      }
      // 3. 年份相同按标题字母序
      return a.key.title.compareTo(b.key.title);
    });

    return scored.map((e) => e.key).toList();
  }
}
