import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:luna_tv/models/short_drama.dart';
import 'package:luna_tv/models/raw_short_drama.dart';
import 'package:luna_tv/services/user_data_service.dart';

/// v2.5.4: 短剧直连 TVBox 源 service (修复 擦边短剧没内容).
///
/// 设计目标 (v2.5.3 沿用, v2.5.4 修 type_id 映射):
/// 1. **写死源** = 3 个 TVBox 源 URL, 不再依赖 serverUrl.
/// 2. **写死分类关键字** = SHORT_DRAMA_KEYWORDS (含 7 个原 + 2 个 AI 漫剧).
/// 3. **每源声明自己提供的 type_id 列表** (`_DirectSource.categories`),
///    v2.5.4 起: 不再假设「短剧」主类在所有源都有数据, 而是按源实际
///    可用 type_id 拉. 这样 tyyszy 子分类 64-69 + wujin 41/62/63 +
///    lzi 46/52 都能稳定拉数据.
/// 4. **只暴露 数据/图片/分类** = 不暴露 parseEpisode(). 播放仍走
///    [ShortDramaService.parseEpisode] 走后端解析.
///
/// v2.5.4 bug fix: v2.5.3 硬编码 `tyyszyapi 短剧主类=54 + 擦边=73`,
/// 但 2026-07-21 实测 tyyszyapi 这 2 个 type_id 实际都返回 0 条,
/// 导致「擦边短剧」tab 进不去. 现在改成:
///   - 擦边短剧 → wujinapi 62 (118 部) ✓
///   - 短剧主类 → wujinapi 41 (763) + lziapi 46 (21,684) ✓
///   - 6 个子分类 → tyyszyapi 64-69 (有数据)
///   - 漫剧 → wujinapi 63 (3127) ✓
///   - AI 漫剧 → lziapi 52 (4858) ✓
class ShortDramaDirectService {
  /// 3 个写死 TVBox 源 (按 2026-07-21 实测可用排序).
  ///
  /// 每个源声明自己**实测有数据**的 type_id 列表 + **每 type 拉几页**.
  /// v2.5.4 起不再假设「短剧主类在所有源都有」, 而是按各源实际情况.
  /// v2.5.6 起加 `pages`: TVBox 协议每页固定 20 条, 一次拉 1 页只够
  /// 20 条 → 用户反馈「全部分类(短剧)怎么只有 20 部」. 现在每 type
  /// 默认拉 3 页 = 60 条/type, 3 源 9 type 聚合 ≈ 540 条原始, 去重
  /// 后 100-300 条展示.
  static const List<_DirectSource> _sources = [
    // 天翼影视: 主类 54 / 擦边 73 当前 0, 改用其 6 个子分类
    _DirectSource(
      name: '天翼影视',
      apiUrl: 'https://tyyszyapi.com/api.php/provide/vod',
      srcKey: 'tyyszy', // v2.5.28: CF Worker /sd-api/ 的 source key
      pages: 3, // 每 type 拉 3 页
      categories: [
        _SourceCategory(64, '女频恋爱'),
        _SourceCategory(65, '反转爽剧'),
        _SourceCategory(66, '古装仙侠'),
        _SourceCategory(67, '年代穿越'),
        _SourceCategory(68, '脑洞悬疑'),
        _SourceCategory(69, '现代都市'),
      ],
    ),
    // 无极: 主类 41 + 擦边 62 + 漫剧 63 (全有数据)
    _DirectSource(
      name: '无极',
      apiUrl: 'https://api.wujinapi.com/api.php/provide/vod',
      srcKey: 'wujin',
      pages: 3,
      categories: [
        _SourceCategory(41, '短剧'),
        _SourceCategory(62, '擦边短剧'),
        _SourceCategory(63, '漫剧'),
      ],
    ),
    // 量子: 主类 46 + AI 漫剧 52 (全有数据)
    _DirectSource(
      name: '量子',
      apiUrl: 'https://cj.lziapi.com/api.php/provide/vod',
      srcKey: 'lzi',
      pages: 3,
      categories: [
        _SourceCategory(46, '短剧'),
        _SourceCategory(52, 'AI 漫剧'),
      ],
    ),
  ];

  /// 短剧关键字 (写死 9 个). 跟后端 `src/lib/shortdrama.server.ts` L9
  /// 7 个保持一致 + 新增 2 个 AI 漫剧类.
  ///
  /// 注意: 用 `includes` 匹配 (跟后端 L41 一致), 「短剧」 关键字会同时
  /// 命中「短剧」/「擦边短剧」, 「漫剧」/「AI 漫剧」 各自只命中自己.
  /// 实际拉剧只取各源「实测有数据」的 type_id, 关键字只用于日志标注.
  static const List<String> SHORT_DRAMA_KEYWORDS = [
    '短剧', // 主类关键字 (含「擦边短剧」)
    '女频恋爱',
    '反转爽剧',
    '古装仙侠',
    '年代穿越',
    '脑洞悬疑',
    '现代都市',
    'AI 漫剧', // v2.5.3 新增
    '漫剧', // v2.5.3 新增
  ];

  static const Duration _timeout = Duration(seconds: 10);

  /// 通用 TVBox GET 工具.
  static Future<Map<String, dynamic>> _get(
    String apiUrl,
    String ac,
    Map<String, String> extraParams,
  ) async {
    final params = <String, String>{'ac': ac, ...extraParams};
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final url = '$apiUrl?$query';
    final resp = await http
        .get(Uri.parse(url), headers: {
          'User-Agent': 'Mozilla/5.0 (LunaTV-Mobile/2.5.4)',
          'Accept': 'application/json',
        })
        .timeout(_timeout);
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode} from $url');
    }
    final body = resp.body;
    return json.decode(body) as Map<String, dynamic>;
  }

  /// v2.5.6: 从单个源拉一个 type_id 下的多页列表 (TVBox 协议).
  ///
  /// 串行拉 pg=startPage..startPage+pages-1, 任一页失败不抛 (跟后端
  /// Promise.allSettled 1:1). 拼成一条 list 返回. TVBox 每页固定 20
  /// 条, 这是协议层限制, 加 pagesize/limit 等参数源不识别.
  static Future<List<RawShortDrama>> _fetchFromSource(
    _DirectSource src,
    int typeId, {
    int startPage = 1,
    int pages = 1,
  }) async {
    final allRaw = <RawShortDrama>[];
    // v2.5.28: 配了 CF Worker URL 时走 /sd-api/{srcKey} 代理 (5 分钟边缘缓存).
    //   没配 → 1:1 直连原 apiUrl (跟之前行为一致).
    final apiBase = UserDataService.buildShortDramaApiUrl(src.srcKey) ?? src.apiUrl;
    for (int p = startPage; p < startPage + pages; p++) {
      try {
        final data = await _get(apiBase, 'detail', {
          't': typeId.toString(),
          'pg': p.toString(),
        });
        final list = (data['list'] as List<dynamic>?) ?? [];
        allRaw.addAll(list.map(
            (e) => RawShortDrama.fromVodJson(e as Map<String, dynamic>)));
      } catch (e) {
        // 单页失败不抛, 让其他页/源继续.
        // ignore: avoid_print
        print('[ShortDramaDirect] source=${src.name} type=$typeId page=$p error=$e');
        // 一页失败就停这个 type (源可能挂了/限流, 别再浪费请求)
        break;
      }
    }
    return allRaw;
  }

  /// v2.5.6: 拉全量「短剧」列表 (含 AI 漫剧), 聚合 3 源 + 去重.
  ///
  /// 策略:
  /// 1. 每个源 × 每个 type_id 拉前 [pagesPerType] 页
  /// 2. 合并所有结果 (~540 条原始, 3 源 9 type × 3 页 × 20)
  /// 3. 按 name 去重 (Map<name, item>)
  /// 4. 按 update_time 降序
  /// 5. 返回前 [size] 条
  ///
  /// 性能: 9 type × 3 页 = 27 个并发 HTTP 请求, 9 个 type 是
  /// 并发第一层, 每个 type 内部 3 页是串行 (TVBox pg 是顺序的).
  /// 实测每请求 200-500ms, 27 个 5-10s 完成.
  static Future<List<ShortDrama>> getRecommend({int size = 60}) async {
    final allRaw = <RawShortDrama>[];

    // 每个源并发拉所有 type, 每个 type 内部串行拉多页
    final futures = <Future<List<RawShortDrama>>>[];
    for (final src in _sources) {
      for (final cat in src.categories) {
        futures.add(_fetchFromSource(
          src,
          cat.typeId,
          startPage: 1,
          pages: src.pages,
        ));
      }
    }
    final results = await Future.wait(futures);
    for (final r in results) {
      allRaw.addAll(r);
    }

    // 去重 (按 name)
    final unique = <String, RawShortDrama>{};
    for (final raw in allRaw) {
      if (raw.vodName.isEmpty) continue;
      unique.putIfAbsent(raw.vodName, () => raw);
    }
    final uniqueList = unique.values.toList();

    // 按 update_time 降序
    uniqueList.sort((a, b) {
      final at = DateTime.tryParse(a.vodTime) ?? DateTime(1970);
      final bt = DateTime.tryParse(b.vodTime) ?? DateTime(1970);
      return bt.compareTo(at);
    });

    // slice
    final sliced = uniqueList.take(size).toList();

    return sliced.map(_toShortDrama).toList();
  }

  /// v2.5.6: 「全部」tab 用的分页形式 — 跟 getRecommend 同样的聚合逻辑,
  /// 但支持翻页 (每次把每个 type 拉下一页, 合并去重 + 排除已展示).
  ///
  /// 参数:
  /// - [page]: 当前页码, 从 1 开始. 控制每个 type 拉 pg=page, page+1,
  ///   page+2 (即 source.pages 个页). 翻页时传 page+1, page+2 等.
  /// - [size]: 返回去重后前 size 条.
  /// - [excludeNames]: 已展示的剧名集合 (上一轮拉到的), 用于去重.
  ///
  /// hasMore: 当去重后剩余条数 >= size 时为 true (用户还能继续翻).
  /// 简化: 始终 hasMore = true, 除非所有源全返回 0 (全挂了).
  static Future<ShortDramaListResponse> getRecommendResponse({
    int page = 1,
    int size = 60,
    Set<String>? excludeNames,
  }) async {
    final allRaw = <RawShortDrama>[];

    // 每源并发拉每 type 的 source.pages 个页 (从 page 开始)
    final futures = <Future<List<RawShortDrama>>>[];
    for (final src in _sources) {
      for (final cat in src.categories) {
        futures.add(_fetchFromSource(
          src,
          cat.typeId,
          startPage: page,
          pages: src.pages,
        ));
      }
    }
    final results = await Future.wait(futures);
    for (final r in results) {
      allRaw.addAll(r);
    }

    if (allRaw.isEmpty) {
      return const ShortDramaListResponse(list: [], hasMore: false);
    }

    // 去重 (按 name)
    final unique = <String, RawShortDrama>{};
    for (final raw in allRaw) {
      if (raw.vodName.isEmpty) continue;
      unique.putIfAbsent(raw.vodName, () => raw);
    }
    final uniqueList = unique.values.toList();

    // 排除已展示
    final filtered = excludeNames == null || excludeNames.isEmpty
        ? uniqueList
        : uniqueList.where((r) => !excludeNames.contains(r.vodName)).toList();

    // 按 update_time 降序
    filtered.sort((a, b) {
      final at = DateTime.tryParse(a.vodTime) ?? DateTime(1970);
      final bt = DateTime.tryParse(b.vodTime) ?? DateTime(1970);
      return bt.compareTo(at);
    });

    // slice
    final sliced = filtered.take(size).toList();

    // hasMore: 还有剩余 OR 还有下一页 (page 翻 1 页, 每 type 还可再拉 N-1 页)
    // 简单策略: 翻页上限 5 次 (page <= 5) 才返回 true.
    final hasMore = page < 5;

    return ShortDramaListResponse(
      list: sliced.map(_toShortDrama).toList(),
      hasMore: hasMore,
    );
  }

  /// v2.5.6: 拉单个 type_id 下的列表 (分页), 用于分类 tab 切换.
  ///
  /// 在 3 源中找**首个**声明了该 type_id 的源, 用它拉数据. v2.5.6
  /// 起每页 20 条 + 多页累加 ([maxPages] 兜底, 防止无终止翻页).
  static Future<ShortDramaListResponse> getListByTypeId({
    required int typeId,
    int page = 1,
    int size = 20,
  }) async {
    // 找匹配的源
    _DirectSource? matchSrc;
    for (final src in _sources) {
      for (final cat in src.categories) {
        if (cat.typeId == typeId) {
          matchSrc = src;
          break;
        }
      }
      if (matchSrc != null) break;
    }

    // 兜底: 没找到 (例如 type_id 来自其他源), 用第一个源
    matchSrc ??= _sources.first;

    // v2.5.6: 子分类 tab 默认只拉 2 页 (40 条), 翻页走 +1 page 而不是
    // 重拉所有页 (跟老逻辑兼容).
    final rawList = await _fetchFromSource(
      matchSrc,
      typeId,
      startPage: page,
      pages: 1, // 一次 1 页, 翻页走 +1 page
    );
    final hasMore = rawList.length >= size;
    return ShortDramaListResponse(
      list: rawList.map(_toShortDrama).toList(),
      hasMore: hasMore,
    );
  }

  /// v2.5.4: 拉硬编码的分类列表.
  ///
  /// 合并 3 源声明的所有 type_id → 去重 (按 name 保留首个出现的 typeId) →
  /// 按 (主类优先, 漫剧/AI 漫剧殿后) 排序.
  static Future<List<ShortDramaCategory>> getCategories() async {
    // 按源顺序收集 (天翼 → 无极 → 量子)
    final seen = <String, _SourceCategory>{}; // name → first occurrence
    for (final src in _sources) {
      for (final cat in src.categories) {
        seen.putIfAbsent(cat.typeName, () => cat);
      }
    }

    // 排序: 短剧 (主类) 最前, 然后子分类, 然后 擦边/漫剧/AI 漫剧 殿后
    const priorityNames = [
      '短剧',
      '女频恋爱',
      '反转爽剧',
      '古装仙侠',
      '年代穿越',
      '脑洞悬疑',
      '现代都市',
      '擦边短剧',
      '漫剧',
      'AI 漫剧',
    ];
    final sorted = <_SourceCategory>[];
    for (final name in priorityNames) {
      final cat = seen[name];
      if (cat != null) sorted.add(cat);
    }

    return sorted
        .map((c) => ShortDramaCategory(typeId: c.typeId, typeName: c.typeName))
        .toList();
  }

  /// RawShortDrama → ShortDrama 映射.
  static ShortDrama _toShortDrama(RawShortDrama raw) {
    return ShortDrama(
      id: raw.vodId,
      name: raw.vodName,
      cover: raw.vodPic,
      updateTime: raw.vodTime,
      score: raw.vodScore,
      episodeCount: raw.vodRemarksEpisodeCount,
      description: raw.vodContent.isNotEmpty ? raw.vodContent : raw.vodBlurb,
      author: raw.vodActor,
      backdrop: raw.vodPicSlide.isNotEmpty ? raw.vodPicSlide : raw.vodPic,
      voteAverage: raw.vodScore,
    );
  }
}

/// v2.5.4: 单个源声明的 type_id + name 配对.
class _SourceCategory {
  final int typeId;
  final String typeName;
  const _SourceCategory(this.typeId, this.typeName);
}

/// v2.5.6: 写死的单个 TVBox 源配置 — 用 `categories` 列表替代 v2.5.3
/// 的 `shortDramaTypeId` + `aiMangaTypeId` 两个固定字段, 这样可以
/// 准确声明「这个源实际有数据的 type_id 集合」+ `pages` 声明每 type
/// 默认拉几页 (TVBox 协议每页固定 20 条).
class _DirectSource {
  final String name;
  final String apiUrl;
  final String srcKey; // v2.5.28: CF Worker /sd-api/ 的 source key (tyyszy/wujin/lzi)
  final int pages; // 每 type 拉几页, 每页 20 条
  final List<_SourceCategory> categories;

  const _DirectSource({
    required this.name,
    required this.apiUrl,
    required this.srcKey,
    this.pages = 3,
    required this.categories,
  });
}
