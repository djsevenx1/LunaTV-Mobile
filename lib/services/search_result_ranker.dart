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

    // v2.6.12: 跟 matchesQuery 用同一套归一化 (去所有非字母数字非中文字符),
    //   之前只去空格, 你-好-a 跟 你好a 在 ranking 里算两个不同 title,
    //   排序会乱
    final titleNorm = _normalize(title);
    final keywordNorm = _normalize(keyword);

    var score = 0;

    // 1. 完全匹配 100
    if (title == keyword || titleNorm == keywordNorm) {
      score = 100;
    }
    // 2. 开头匹配 80
    else if (title.startsWith(keyword) || titleNorm.startsWith(keywordNorm)) {
      score = 80;
    }
    // 3. 包含完整关键词 60
    else if (title.contains(keyword) || titleNorm.contains(keywordNorm)) {
      score = 60;
    }
    // 4. 模糊匹配
    else {
      if (_containsCharsInOrder(titleNorm, keywordNorm)) {
        // 字符间隔越小分数越高
        final similarity = _similarityScore(titleNorm, keywordNorm);
        score = 20 + (similarity * 20).round(); // 20-40
      } else {
        // 部分字符匹配
        final matchedChars = keywordNorm
            .split('')
            .where((c) => titleNorm.contains(c))
            .length;
        final ratio = keywordNorm.isEmpty
            ? 0.0
            : matchedChars / keywordNorm.length;
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

  /// 标题归一化: 转小写 + 去所有标点符号 (只保留字母数字中文).
  /// v2.6.12: 比 web 端去得更狠 — web 只去空格和几个特定标点
  ///   (`[\s\u3000\-—_:：·•・]`), 用户实测「你-好-a」搜「你好a」
  ///   「XX你好a」「你好aXX」都搜不出来. 改成去掉**所有**非字母数字
  ///   非中文字符, 让用户输入的 query 跟 title 里的字符序列对齐.
  static String _normalize(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\u4e00-\u9fff]'), '');
  }

  /// 顺序子序列匹配: title 归一化后, query 字符是否按顺序出现在 title 里.
  /// v2.6.12: 从 v2.6.9 的 substring 改成 subsequence, 跟用户实测反馈对齐:
  ///   搜「你好a」能匹配:
  ///   - 「你-好-a」 (去符号后 = 「你好a」, 直接命中)
  ///   - 「xx你好a」 (前缀)
  ///   - 「你好axx」 (后缀)
  ///   - 「你x好xa」 (中间夹其他字符)
  ///   - 「你好A」「你好a」 (大小写不敏感)
  ///   但不匹配:
  ///   - 「你好」 (query 是 3 字符, title 归一化后只有 2 字符命中)
  ///   - 「好你a」 (乱序, subsequence 失败)
  ///
  /// web 端 page.tsx:602-615 仍是 substring, 但 web 没遇到这个用户场景
  /// (用户反馈的是 app 端问题, web 端搜源就够用). 改成 subsequence 是
  /// app 端的优化, 不影响 web 端逻辑.
  ///
  /// 不做繁简转换: 跟 web 端 chineseConverter.simplized 比简化版只覆盖
  ///   90% 场景 (用户搜简体命中简体 title, 搜繁体命中繁体 title).
  ///   繁简转换是 nice-to-have, 暂不引入 switch-chinese 库增加体积.
  static bool matchesQuery(String title, String query) {
    if (title.isEmpty || query.isEmpty) return true;
    final nt = _normalize(title);
    final nq = _normalize(query);
    if (nq.isEmpty) return true;  // 纯符号 query (如 "---"), 全部放行
    
    // 子序列匹配: 双指针扫描, nt 跳过, nq 必须按顺序找到所有字符
    int ti = 0, qi = 0;
    while (ti < nt.length && qi < nq.length) {
      if (nt[ti] == nq[qi]) {
        qi++;
      }
      ti++;
    }
    return qi == nq.length;
  }

  /// 检查 SearchResult 是否"包含" query. 等价 `matchesQuery(r.title, query)`.
  ///   注: v2.6.12 改成子序列匹配 (顺序 in-order, 中间可夹字符), 适合
  ///   搜索页让「你-好-a」也能搜出「你好a」. 播放详情页定位要严格,
  ///   用下面的 resultMatchesQueryStrict (substring + year 联合).
  static bool resultMatchesQuery(SearchResult r, String query) {
    return matchesQuery(r.title, query);
  }

  /// v2.6.15: 播放详情页「严格匹配」 — 跟 resultMatchesQuery (子序列, 搜索页)
  ///   和 v2.6.14 resultMatchesQueryStrict (substring 包含, 还是会出 xxx凡人修仙传)
  ///   都不够, 改用:
  ///
  ///   1. title 完全等于 query (归一化后)
  ///   2. title 以 query 开头, 后面是已知版本标识 (第X季/新版/重制/电影/年份等)
  ///
  ///   不接受:
  ///   - 「xxx凡人修仙传」 (有任意前缀, 跟前不接)
  ///   - 「凡人修仙传xxx」 (任意后缀不是版本标识)
  ///   - 「凡人修仙传之风起」 (中间夹字)
  ///
  ///   联合 year: 年份不一样 (2023 vs 2024) 也排除
  ///   目标: 播放详情页必须命中用户点的那部剧, 不出衍生剧/前缀/后缀变体
  static bool resultMatchesQueryStrict(
    SearchResult r,
    String query,
    String expectedYear,
  ) {
    if (r.title.isEmpty || query.isEmpty) return true;

    // 1. year 严格匹配 (双方都有年份才比, 缺年份的放行)
    if (expectedYear.isNotEmpty && expectedYear != 'unknown') {
      final rYear = r.year;
      if (rYear.isNotEmpty && rYear != 'unknown' && rYear != expectedYear) {
        return false;
      }
    }

    // 2. title 严格匹配 (归一化后)
    final normTitle = _normalize(r.title);
    final normQuery = _normalize(query);
    if (normQuery.isEmpty) return true;

    // 2.1 完全相等
    if (normTitle == normQuery) return true;

    // 2.2 query 开头 + 合法版本后缀
    if (normTitle.startsWith(normQuery)) {
      final rest = normTitle.substring(normQuery.length);
      if (_isValidVersionSuffix(rest)) return true;
    }

    // 2.3 query 结尾 + 合法版本前缀 (罕见, 比如「剧场版 凡人修仙传」)
    if (normTitle.endsWith(normQuery)) {
      final prefix = normTitle.substring(0, normTitle.length - normQuery.length);
      if (_isValidVersionPrefix(prefix)) return true;
    }

    return false;
  }

  /// 合法版本后缀 — 第X季/新版/重制/电影/TV/Plus/+ 等等.
  /// 用白名单不用黑名单, 避免「之风起」「之灵界」这种 IP 子系列钻空子.
  static bool _isValidVersionSuffix(String s) {
    if (s.isEmpty) return true;  // 完全等于 query, 已在上一步 return
    // 第X季: 第 + 中文数字或阿拉伯数字 + 季
    if (RegExp(r'^第[\d零一二三四五六七八九十百千万]+季$').hasMatch(s)) return true;
    // 第X部
    if (RegExp(r'^第[\d零一二三四五六七八九十百千万]+部$').hasMatch(s)) return true;
    // 新版/重制版/加长版/未删减版/完整版/剧场版/修复版/高清版
    if (RegExp(r'^(新版|重制版?|加长版?|未删减版?|完整版?|剧场版?|修复版?|高清版?)$').hasMatch(s)) return true;
    // 电影/电影版/电视剧/TV版/TV/TV版
    if (RegExp(r'^(电影版?|电视剧|tv版?|tv)$').hasMatch(s)) return true;
    // Plus (英文不区分大小写)
    if (RegExp(r'^plus$', caseSensitive: false).hasMatch(s)) return true;
    // 单 + 符号
    if (s == '+') return true;
    // 4位年份 (e.g., 2024, 2023)
    if (RegExp(r'^\d{4}$').hasMatch(s)) return true;
    // 单数字 (e.g., 1, 2 — 部分源「第1部」会省略「第」)
    if (RegExp(r'^[\d]+$').hasMatch(s)) return true;
    return false;
  }

  /// 合法版本前缀 (罕见). 比如「剧场版 凡人修仙传」「OVA 凡人修仙传」.
  static bool _isValidVersionPrefix(String s) {
    if (s.isEmpty) return true;
    // 剧场版/电影/OVA/TV/TV版/Plus 等在前
    if (RegExp(r'^(剧场版|电影|电影版|电视剧|tv版?|tv|ova|plus)$', caseSensitive: false).hasMatch(s)) return true;
    return false;
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
