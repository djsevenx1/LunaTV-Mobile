import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:luna_tv/models/short_drama.dart';
import 'package:luna_tv/models/raw_short_drama.dart';

/// v2.5.3: 短剧直连 TVBox 源 service.
///
/// 设计目标 (按用户 v2.5.3 决策):
/// 1. **写死源** = 3 个 TVBox 源 URL, 不再依赖 serverUrl.
/// 2. **写死分类关键字** = SHORT_DRAMA_KEYWORDS (含 7 个原 + 2 个新增:
///    「AI 漫剧」 / 「漫剧」). 上游加了新分类看不到, 要发版才能加.
/// 3. **只拉「短剧」主类 type_id** = 跟后端 `src/lib/shortdrama.server.ts` L46
///    `cat.type_name === '短剧'` 优先选父分类的策略 1:1.
/// 4. **只暴露 数据/图片/分类** = 不暴露 parseEpisode(). 播放仍走
///    [ShortDramaService.parseEpisode] 走后端解析 (LunaTV 后端自己有
///    反爬/代理/CDN 缓存, 客户端裸奔不安全).
///
/// 兼容性: 返回的 [ShortDrama] model 跟老 [ShortDramaService] 返的 model
/// 字段名 1:1 ([ShortDrama.fromJson] 可以复用), 但 **id 跟后端 vod_id
/// 是同一种 ID** (后端 `parseShortDramaEpisode(videoId, ...)` 接受 int,
/// 跟 `vod_id` 一致), 所以直连拿到的 `ShortDrama.id` 可以直接调
/// `ShortDramaService.parseEpisode(id, episode)` 走后端解析.
class ShortDramaDirectService {
  /// 3 个写死 TVBox 源 (按 2026-07-21 实测可用排序).
  ///
  /// 1. tyyszyapi.com: 天翼影视资源, 8 短剧子分类, 68k 部, 响应快.
  ///    短剧主类 type_id = 54. (默认)
  /// 2. api.wujinapi.com: 无极, 8 短剧子分类 + 118 部擦边短剧, 116k 部.
  ///    短剧主类 type_id = 41. AI 漫剧 type_id = 63 (3127 部).
  /// 3. cj.lziapi.com: 量子, 1 短剧主类, 14w 部. AI 漫剧 type_id = 52 (4858 部).
  static const List<_DirectSource> _sources = [
    _DirectSource(
      name: '天翼影视',
      apiUrl: 'https://tyyszyapi.com/api.php/provide/vod',
      shortDramaTypeId: 54,
      aiMangaTypeId: null, // 没 AI 漫剧分类
    ),
    _DirectSource(
      name: '无极',
      apiUrl: 'https://api.wujinapi.com/api.php/provide/vod',
      shortDramaTypeId: 41,
      aiMangaTypeId: 63, // 「漫剧」(本质 AI 漫剧) 3127 部
    ),
    _DirectSource(
      name: '量子',
      apiUrl: 'https://cj.lziapi.com/api.php/provide/vod',
      shortDramaTypeId: 46,
      aiMangaTypeId: 52, // 「AI 漫剧」 4858 部
    ),
  ];

  /// 短剧关键字 (写死 9 个). 跟后端 `src/lib/shortdrama.server.ts` L9
  /// 7 个保持一致 + 新增 2 个 AI 漫剧类.
  ///
  /// 注意: 用 `includes` 匹配 (跟后端 L41 一致), 「短剧」 关键字会同时
  /// 命中「短剧」/「擦边短剧」, 「漫剧」/「AI 漫剧」 各自只命中自己.
  /// 实际拉剧只取「短剧」主类 (L82), 关键字只用于 filter 分类是否在
  /// 短剧范围内 (给分类页展示用, 列表页直接用主类 type_id 拉).
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
          'User-Agent': 'Mozilla/5.0 (LunaTV-Mobile/2.5.3)',
          'Accept': 'application/json',
        })
        .timeout(_timeout);
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode} from $url');
    }
    final body = resp.body;
    return json.decode(body) as Map<String, dynamic>;
  }

  /// 从单个源拉一条分类下的列表 (TVBox 协议).
  static Future<List<RawShortDrama>> _fetchFromSource(
    _DirectSource src,
    int typeId,
    int page,
    int size,
  ) async {
    try {
      final data = await _get(src.apiUrl, 'detail', {
        't': typeId.toString(),
        'pg': page.toString(),
      });
      final list = (data['list'] as List<dynamic>?) ?? [];
      return list
          .map((e) => RawShortDrama.fromVodJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // 单源失败不抛, 让其他源继续 (跟后端 L107 Promise.allSettled 1:1).
      // ignore: avoid_print
      print('[ShortDramaDirect] source=${src.name} type=$typeId page=$page error=$e');
      return [];
    }
  }

  /// v2.5.3: 拉全量「短剧」列表 (含 AI 漫剧), 聚合 3 源 + 去重.
  ///
  /// 策略 (跟后端 `src/lib/shortdrama.server.ts` L75-110 1:1):
  /// 1. 每个源按自己的 `shortDramaTypeId` 拉第一页
  /// 2. 带 `aiMangaTypeId` 的源同时拉 AI 漫剧第一页
  /// 3. 合并所有结果
  /// 4. 按 name 去重 (Map<name, item>)
  /// 5. 按 update_time 降序
  /// 6. 返回前 [size] 条
  static Future<List<ShortDrama>> getRecommend({int size = 20}) async {
    final allRaw = <RawShortDrama>[];

    // 每个源并发拉 (Promise.allSettled 1:1)
    final futures = <Future<List<RawShortDrama>>>[];
    for (final src in _sources) {
      futures.add(_fetchFromSource(src, src.shortDramaTypeId, 1, size));
      if (src.aiMangaTypeId != null) {
        futures.add(_fetchFromSource(src, src.aiMangaTypeId!, 1, size));
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
      // 已有同名 → 保留先到的 (一般按 update_time 降序后, 先到的是新的)
      unique.putIfAbsent(raw.vodName, () => raw);
    }
    final uniqueList = unique.values.toList();

    // 按 update_time 降序 (跟后端 L88 1:1)
    uniqueList.sort((a, b) {
      final at = DateTime.tryParse(a.vodTime) ?? DateTime(1970);
      final bt = DateTime.tryParse(b.vodTime) ?? DateTime(1970);
      return bt.compareTo(at);
    });

    // slice
    final sliced = uniqueList.take(size).toList();

    return sliced.map(_toShortDrama).toList();
  }

  /// v2.5.3: 拉单个 type_id 下的列表 (分页), 用于分类 tab 切换.
  ///
  /// 跟后端 `/api/shortdrama/list?categoryId=&page=&size=` 行为 1:1.
  /// 但因为直连 TVBox, 多源数据没法按 type_id 精确切分 (一个 type_id
  /// 在不同源 ID 不同), 暂时只拉第一个匹配该 type_id 的源.
  /// 简单实现: 在 3 源中找 `shortDramaTypeId == typeId` 或
  /// `aiMangaTypeId == typeId` 的源.
  static Future<ShortDramaListResponse> getListByTypeId({
    required int typeId,
    int page = 1,
    int size = 20,
  }) async {
    // 找匹配的源
    _DirectSource? matchSrc;
    for (final src in _sources) {
      if (src.shortDramaTypeId == typeId ||
          src.aiMangaTypeId == typeId) {
        matchSrc = src;
        break;
      }
    }

    // 兜底: 没找到 (例如 type_id 来自其他源), 用第一个源
    matchSrc ??= _sources.first;

    final rawList = await _fetchFromSource(matchSrc, typeId, page, size);
    final hasMore = rawList.length >= size;
    return ShortDramaListResponse(
      list: rawList.map(_toShortDrama).toList(),
      hasMore: hasMore,
    );
  }

  /// v2.5.3: 拉硬编码的分类列表.
  ///
  /// 跟后端不同: 不调用 `?ac=list` 实时拉 (太慢, 8s+), 直接写死 9 个
  /// 分类 + 每个 type_id 绑定到具体源.
  /// 这样:
  /// - 启动 0 延迟 (无网络)
  /// - 跟用户原话「分类写死到 app」 1:1
  /// - 跟下游 getListByTypeId 配合, 点分类就能跳到对应 type_id 拉剧
  static Future<List<ShortDramaCategory>> getCategories() async {
    return const [
      // 短剧 (主类, 3 源中任一都有)
      ShortDramaCategory(typeId: 54, typeName: '短剧'),  // 天翼影视主类
      // 短剧子分类
      ShortDramaCategory(typeId: 64, typeName: '女频恋爱'),  // 天翼影视
      ShortDramaCategory(typeId: 65, typeName: '反转爽剧'),  // 天翼影视
      ShortDramaCategory(typeId: 66, typeName: '古装仙侠'),  // 天翼影视
      ShortDramaCategory(typeId: 67, typeName: '年代穿越'),  // 天翼影视
      ShortDramaCategory(typeId: 68, typeName: '脑洞悬疑'),  // 天翼影视
      ShortDramaCategory(typeId: 69, typeName: '现代都市'),  // 天翼影视
      ShortDramaCategory(typeId: 73, typeName: '擦边短剧'),  // 天翼影视
      // AI 漫剧 / 漫剧 (v2.5.3 新增)
      ShortDramaCategory(typeId: 63, typeName: '漫剧'),      // 无极
      ShortDramaCategory(typeId: 52, typeName: 'AI 漫剧'),  // 量子
    ];
  }

  /// RawShortDrama → ShortDrama 映射, 跟后端 `shortdrama.server.ts` L62-66 1:1.
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

/// 写死的单个 TVBox 源配置.
class _DirectSource {
  final String name;
  final String apiUrl;
  final int shortDramaTypeId;
  final int? aiMangaTypeId; // null = 没 AI 漫剧分类

  const _DirectSource({
    required this.name,
    required this.apiUrl,
    required this.shortDramaTypeId,
    this.aiMangaTypeId,
  });
}
