// v2.0.38: TMDB 详情大头部 — 给 player_screen「选源播放」详情页用
//
// 背景:
//   - 配了 TMDB key 的用户在 player_screen 详情页看到 TMDB 大背景 + 大海报 + 简介
//   - 没配 key / 拿不到结果 / 短剧 / 标题不匹配 → 走 fallback 海报 (源 cover + 标题)
//
// 数据流:
//   1. TmdbService.search(type, title, year) → 拿第一个匹配结果的 ID
//   2. v2.0.47: 校验 result 标题跟 query 是否对得上 (2-gram 相似度),
//      不匹配 → 走默认海报 (避免大头部显示成另一个完全不相关的剧)
//   3. TmdbService.getDetails(type, id) → 拿完整 metadata (overview, backdrop, voteAverage)
//   4. 1 天本地缓存兜底, 重复打开详情页几乎零网络
//
// Fallback 行为 (v2.0.49):
//   - 有源 cover (`widget.fallbackCover` 非空): 展示源 cover + 标题 + tag (短剧 / 年份) + sourceName
//   - 没源 cover: 灰色电影 icon 占位 + 标题 + tag
//   - 短剧: 跳过 TMDB 请求 (TMDB 几乎没收录短剧), 走 fallback
//
// v2.0.46 改过 fallback: 直接用灰色占位, 不用源 cover. 用户反馈:
//   - 短剧: 列表里能看到图, 点进去看不到了 (源 cover 被丢, 太激进)
//   - TMDB 没资源: 源 cover 经常是对的 (用户已经在列表看到, 期望详情里也看到),
//     用灰色占位反而跟列表视觉不一致
// v2.0.49 修法: 恢复 v2.0.38 ~ v2.0.45 的源 cover 行为, 保留 v2.0.46 的
//   短剧 tag 和"源 cover 也为空才用占位"逻辑.
//
// v2.0.47: TMDB 搜不到精准匹配时 (返回"最接近"的结果), 标题相似度校验
//   不过也走默认海报, 不显示错的剧 (e.g. 搜「山村医馆」返回「千香」).
//
// 用法 (player_screen 调用):
//   TmdbDetailHeader(
//     title: widget.videoInfo.title,
//     year: widget.videoInfo.year,
//     kind: widget.kind ?? (widget.videoInfo.sourceName == '豆瓣' ? 'movie' : 'tv'),
//     fallbackCover: widget.videoInfo.cover,
//     fallbackSource: widget.videoInfo.source,
//     sourceName: widget.videoInfo.sourceName,  // 短剧 = '' 自动跳过 TMDB
//   )

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/tmdb_service.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/video_proxy_log.dart';
import 'package:luna_tv/utils/image_url.dart';
import 'package:provider/provider.dart';

/// v2.0.38: TMDB 详情大头部
/// 配了 TMDB key: 用 TMDB 大背景 + 大海报 + 评分 + 简介
/// 没配 key 或拿不到结果: 默认海报 (灰色电影 icon + 标题, v2.0.46 起)
/// 短剧 (sourceName == ''): 直接走默认海报, 不发 TMDB 请求
class TmdbDetailHeader extends StatefulWidget {
  final String title;
  final String? year; // LunaTV 存的是字符串 (e.g. "2024" 或 "2024-01")
  final String kind; // 'movie' / 'tv'
  final String fallbackCover; // 原 douban / bangumi 海报 (v2.0.46 起不再使用, 保留兼容)
  final String fallbackSource; // 'douban' / 'bangumi' (for getImageUrl)
  final String? sourceName; // 「默认: 豆瓣」那行, 透传下来
  // v2.0.46: 短剧标识 — 空 sourceName 也算, 这里支持显式传入避免歧义
  final bool isShortDrama;

  const TmdbDetailHeader({
    super.key,
    required this.title,
    this.year,
    this.kind = 'tv',
    required this.fallbackCover,
    required this.fallbackSource,
    this.sourceName,
    this.isShortDrama = false,
  });

  @override
  State<TmdbDetailHeader> createState() => _TmdbDetailHeaderState();
}

class _TmdbDetailHeaderState extends State<TmdbDetailHeader> {
  TmdbItem? _tmdbItem;
  TmdbConfiguration? _tmdbConfig;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadTmdb();
  }

  @override
  void didUpdateWidget(covariant TmdbDetailHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title ||
        oldWidget.year != widget.year ||
        oldWidget.kind != widget.kind) {
      _loadTmdb();
    }
  }

  int? get _yearInt {
    final y = widget.year;
    if (y == null || y.isEmpty) return null;
    return int.tryParse(y.substring(0, y.length >= 4 ? 4 : y.length));
  }

  TmdbMediaType get _mediaType =>
      widget.kind == 'movie' ? TmdbMediaType.movie : TmdbMediaType.tv;

  // v2.0.46: 短剧 = 显式 isShortDrama || sourceName 为空 (短剧入口 sourceName='')。
  // TMDB 几乎没收录短剧, 不发请求直接走默认海报。
  bool get _isShortDrama {
    if (widget.isShortDrama) return true;
    final name = widget.sourceName;
    if (name == null || name.isEmpty) return true;
    return false;
  }

  // v2.0.47: 校验 TMDB search 返回的第一条结果跟用户搜的标题是否"对得上".
  //
  // 背景: TMDB 搜不到完全匹配时, 会返回"最接近"的结果 (e.g. 搜「山村医馆」
  // 短剧, TMDB 没收录, 返回第一条「千香」). 之前 v2.0.46 直接用 first
  // 当作正确结果, 大头部显示「千香」海报/标题, 跟实际视频完全不符.
  //
  // 校验策略: 看 result.title / originalTitle 跟 query 有没有"足够多"的
  // 公共子串. 算法简单粗暴但够用 (中文 2-gram 匹配):
  //   1. 提取 query 的 2-字符子串集合 (e.g. "山村医馆" → {山村, 村医, 医馆})
  //   2. 跟 result.title 的 2-gram 集合求交集
  //   3. 交集 / query 2-gram 总数 >= 0.5 算"匹配上"
  //
  // 例外: query 长度 < 2 (不可能) 跳过; title 含完整 query (substring) 直接算匹配.
  //
  // 返回 true = 标题大致对得上, 可以用 TMDB 数据.
  // 返回 false = 标题不匹配, 走默认海报 (避免大头部显示错误的剧).
  bool _isTitleMatch(TmdbItem item, String query) =>
      _isTitleMatchWithScore(item, query).$1;

  /// v2.0.71: 返回 (是否匹配, 分数) 方便日记输出.
  /// 分数 = 2-gram 命中率 [0,1], substring 命中记 1.0.
  (bool, double) _isTitleMatchWithScore(TmdbItem item, String query) {
    final q = query.trim();
    if (q.isEmpty) return (false, 0);
    final candidates = <String>[
      item.title,
      item.originalTitle,
    ].where((s) => s.isNotEmpty).toList();
    if (candidates.isEmpty) return (false, 0);

    // 1) substring 检查 (任一 candidate 包含完整 query 就算匹配)
    for (final c in candidates) {
      if (c.contains(q) || q.contains(c)) return (true, 1.0);
    }

    // v2.0.58: 2-gram 前清洗 query + candidate, 去掉标点/空格/括号年份.
    //   之前 v2.0.52 降阈值到 0.3 仍不够, 因为 query "你好，李焕英 (2021)"
    //   的 2-grams 里有大量 "好，" "，李" " (2" "20" "01" "21" "1)" 等标点/数字
    //   gram, 在纯中文 candidate "你好李焕英" 里全找不到, 9 grams 只命中 3 个
    //   = 0.33 勉强过 0.3, 再短一点的就挂了. 清洗后 "你好李焕英2021" vs
    //   "你好李焕英": substring 兜住 (q.contains(c)); 即使 substring 没兜住,
    //   2-gram 也只算有效字符, 命中率不被标点稀释.
    final qClean = _normalizeForGram(q);
    if (qClean.isEmpty) return (false, 0);
    final cCleans = candidates.map(_normalizeForGram).where((s) => s.isNotEmpty).toList();
    if (cCleans.isEmpty) return (false, 0);

    // substring 再查一遍清洗后的 (去掉标点后可能命中)
    for (final c in cCleans) {
      if (c.contains(qClean) || qClean.contains(c)) return (true, 1.0);
    }

    // 2) 2-gram 相似度 (基于清洗后的字符串)
    int qGrams;
    if (qClean.length <= 1) {
      qGrams = 1;
    } else {
      qGrams = qClean.length - 1;
    }
    if (qGrams <= 0) return (false, 0);

    double bestScore = 0;
    for (final c in cCleans) {
      if (c.length < 2) continue;
      int hit = 0;
      for (var i = 0; i < qClean.length - 1; i++) {
        final g = qClean.substring(i, i + 2);
        if (c.contains(g)) hit++;
      }
      final score = hit / qGrams;
      if (score > bestScore) bestScore = score;
      // v2.0.52: 阈值 0.5 → 0.3.
      // v2.0.58: 清洗后阈值回到 0.4 (清洗掉了标点稀释, 0.4 更准, 仍能拒掉
      //   「搜"山村医馆"返"千香"」命中率 0)
      // v2.0.71: 阈值降到 0.35 (用户反馈"很多都不刮削", 0.4 偶尔拒掉真剧)
      if (score >= 0.35) return (true, score);
    }
    return (false, bestScore);
  }

  /// v2.0.58: 清洗字符串用于 2-gram 匹配.
  /// 去掉: 空白 + 全/半角标点 + 括号及其内容 (年份) + 其他非中文/字母/数字符号.
  /// 保留: 中文 + 字母 + 数字. 这样 "你好，李焕英 (2021)" → "你好李焕英2021".
  static String _normalizeForGram(String s) {
    final sb = StringBuffer();
    var skipParen = 0;
    for (final ch in s.runes) {
      // 跳过括号内容 (年份等): ( [ 【 「 进 skip
      if (ch == 0x28 || ch == 0x5B || ch == 0x3010 || ch == 0x300C) {
        skipParen++;
        continue;
      }
      if (ch == 0x29 || ch == 0x5D || ch == 0x3011 || ch == 0x300D) {
        if (skipParen > 0) skipParen--;
        continue;
      }
      if (skipParen > 0) continue;
      // 空白
      if (ch <= 0x20) continue;
      // ASCII 标点
      if (ch >= 0x21 && ch <= 0x2F) continue;
      if (ch >= 0x3A && ch <= 0x40) continue;
      if (ch >= 0x5B && ch <= 0x60) continue;
      if (ch >= 0x7B && ch <= 0x7E) continue;
      // 中文标点 (常用区间)
      if (ch >= 0x3000 && ch <= 0x303F) continue; // CJK Symbols and Punctuation
      if (ch >= 0xFF00 && ch <= 0xFFEF) continue; // Halfwidth and Fullwidth Forms 标点
      sb.writeCharCode(ch);
    }
    return sb.toString();
  }

  Future<void> _loadTmdb() async {
    if (!UserDataService.isTmdbApiKeyConfigured() || widget.title.isEmpty) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _hasError = false; // 没配 key 不算 error, 是 fallback
      });
      return;
    }
    // v2.0.46: 短剧不查 TMDB, 直接默认海报
    if (_isShortDrama) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _hasError = false;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    try {
      // 1) 拿 config (图片 CDN base) + 搜剧 (拿 ID)
      final cfgFuture = TmdbService.getConfiguration();
      // v2.0.58: 搜索兜底链 — 4 步, 任一步搜到就停. 之前只搜 1 次 (带 year 的
      //   当前 mediaType), 源给的 year / totalEpisodes 不准时直接搜空 → 不刮削:
      //   - year 不准: 源给采集年, TMDB 是首播年, 差 1 年 → 带 year 搜空
      //   - kind 误判: totalEpisodes 给 0/1, 实际多集剧被当 movie 搜, TMDB movie 搜不到
      //   兜底链: 当前类型+year → 当前类型去year → 换类型去year → fallback
      Future<TmdbPagedResult<TmdbItem>> doSearch(TmdbMediaType t, int? y) =>
          TmdbService.search(type: t, query: widget.title, year: y, page: 1);

      // v2.0.71: 搜索全过程写日记, 方便诊断"很多都不刮削"
      VideoProxyLog.append('[TMDBHeader] 开始刮削: title="${widget.title}" '
          'kind=${widget.kind} year=${widget.year ?? "无"} '
          'mediaType=${_mediaType.value} yearInt=${_yearInt ?? "无"} '
          'isShortDrama=$_isShortDrama');
      var results = await doSearch(_mediaType, _yearInt);
      final cfg = await cfgFuture;
      if (!mounted) return;
      VideoProxyLog.append('[TMDBHeader] 第1搜 ${_mediaType.value}+year=${_yearInt ?? "无"} '
          '"${widget.title}" → ${results.results.length} 条'
          '${results.results.isEmpty ? "" : ", 前3: ${results.results.take(3).map((r) => '"${r.title}"(${r.id})').join(', ')}"}');
      if (results.results.isEmpty && _yearInt != null) {
        VideoProxyLog.append('[TMDBHeader] 带 year=$_yearInt 搜 "${widget.title}" (${_mediaType.value}) 空, 去 year 重搜');
        results = await doSearch(_mediaType, null);
        if (!mounted) return;
        VideoProxyLog.append('[TMDBHeader] 第2搜 ${_mediaType.value} 去year '
            '"${widget.title}" → ${results.results.length} 条'
            '${results.results.isEmpty ? "" : ", 前3: ${results.results.take(3).map((r) => '"${r.title}"(${r.id})').join(', ')}"}');
      }
      if (results.results.isEmpty) {
        final other = _mediaType == TmdbMediaType.movie
            ? TmdbMediaType.tv
            : TmdbMediaType.movie;
        VideoProxyLog.append('[TMDBHeader] ${_mediaType.value} 搜 "${widget.title}" 空, 换 ${other.value} 重搜 (kind 可能误判)');
        results = await doSearch(other, null);
        if (!mounted) return;
        VideoProxyLog.append('[TMDBHeader] 第3搜 ${other.value} 去year '
            '"${widget.title}" → ${results.results.length} 条'
            '${results.results.isEmpty ? "" : ", 前3: ${results.results.take(3).map((r) => '"${r.title}"(${r.id})').join(', ')}"}');
      }
      if (results.results.isEmpty) {
        VideoProxyLog.append('[TMDBHeader] 搜不到 "${widget.title}" (movie+tv 都试过), 走默认海报');
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _hasError = false; // 搜不到不算 error, 走 fallback
        });
        return;
      }
      // 2) v2.0.47: 校验结果的标题跟 query 是否"对得上".
      //   短剧 / 没收录 / 拼错名的剧, TMDB 会返回"最接近"的结果
      //   (e.g. 搜「山村医馆」→ 返回「千香」), 标题不匹配, 走默认海报
      //   而不是把大头部显示成另一个完全不相关的剧.
      // v2.0.52: 不只取第一个, 遍历前 3 个, 第一个匹配的就用.
      //   之前只看 first, 偶尔 first 是同名前缀的近似剧 (e.g. 搜「长相思」,
      //   first 是「长相思：千古玦尘」), 第 2 个才是真剧, 全废了
      //   走 Douban fallback.
      // v2.0.71: 遍历前 5 个 (从 3 提到 5), 并写每个的匹配详情到日记.
      TmdbItem? matched;
      final matchDetails = <String>[];
      for (final r in results.results.take(5)) {
        final (ok, score) = _isTitleMatchWithScore(r, widget.title);
        matchDetails.add('"${r.title}"(${r.id})=${ok ? "✓" : "✗"}(${score.toStringAsFixed(2)})');
        if (ok && matched == null) {
          matched = r;
        }
      }
      VideoProxyLog.append('[TMDBHeader] 标题匹配: 搜 "${widget.title}", '
          '前 ${matchDetails.length} 个: ${matchDetails.join(", ")}'
          '${matched == null ? " → 全不匹配, 走默认海报" : " → 命中 \"${matched.title}\"(${matched.id})"}');
      if (matched == null) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _hasError = false; // 标题不匹配不算 error, 走 fallback
        });
        return;
      }
      // 3) 拿匹配那一个的详情 (含 overview + backdrop)
      final details = await TmdbService.getDetails(
        type: _mediaType,
        id: matched.id,
      );
      if (!mounted) return;
      VideoProxyLog.append('[TMDBHeader] 刮削成功: "${widget.title}" → '
          '"${(details ?? matched).title}" overview=${((details ?? matched).overview?.isNotEmpty ?? false) ? "有" : "无"} '
          'backdrop=${(details ?? matched).backdropPath != null ? "有" : "无"}');
      setState(() {
        _tmdbConfig = cfg;
        // 用详情 (overview + backdrop) 优先, 拿不到用 search result (基本字段)
        _tmdbItem = details ?? matched;
        _isLoading = false;
        _hasError = false;
      });
    } on TmdbException {
      if (!mounted) return;
      VideoProxyLog.append('[TMDBHeader] TmdbException → 走 fallback');
      setState(() {
        _isLoading = false;
        _hasError = true; // TMDB error (NO_KEY/INVALID_KEY/NETWORK) → 显 fallback
      });
    } catch (e) {
      if (!mounted) return;
      VideoProxyLog.append('[TMDBHeader] 其它异常: $e → 走 fallback');
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeService>().isDarkMode;
    if (_isLoading) {
      return _buildLoadingFallback(isDark);
    }
    final item = _tmdbItem;
    final cfg = _tmdbConfig;
    if (item == null || cfg == null || _hasError) {
      // v2.0.46: fallback = 默认海报 (灰色电影 icon + 标题, 不再用 douban 海报).
      return _buildPosterFallback(isDark);
    }
    return _buildTmdbHero(item, cfg, isDark);
  }

  /// 配 key + 拿到结果: TMDB 大背景 + 大海报 + 标题 + 评分 + 简介
  ///
  /// v2.0.43: 升级为更突出的大竖海报 (150x225 主元素) + 右侧大标题/评分/简介.
  ///   之前 v2.0.38 是 16:9 backdrop 兜着 90x135 小海报浮在上面, 不够"大".
  ///   用户反馈 "选源播放里面放 tmdb 大海报啊", 改成主元素就是大竖海报, 直观好看.
  Widget _buildTmdbHero(TmdbItem item, TmdbConfiguration cfg, bool isDark) {
    final backdropUrl = cfg.backdropUrl(item.backdropPath, size: 'w1280');
    final posterUrl = cfg.posterUrl(item.posterPath, size: 'w500');
    final hasBackdrop = backdropUrl.isNotEmpty;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: isDark ? const Color(0xFF1F2937) : const Color(0xFFE5E7EB),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Stack(
        children: [
          // 1) 背景: backdrop 大图 + 重度渐变蒙版 (大竖海报在前景, 背景压暗)
          // v2.0.51: 平板 (宽 >= 600) 改用 21:9, 不再 16:9 — 平板横屏 16:9
          //   backdrop 巨高 (e.g. 1280dp 宽 → 720dp 高), 加上下面 title
          //   / rating / 简介 / tag, 总高 800+ dp, 几乎占满整个平板横屏
          //   高度, 把选集 (episode list) 挤到 fold 下面, 用户看不到.
          //   21:9 比例下 1280dp 宽 → 549dp 高, 给选集 / source list 留
          //   出 200+ dp 空间, 用户能直接在第一屏看到选集 PageView
          AspectRatio(
            aspectRatio: MediaQuery.of(context).size.width >= 600 ? 21 / 9 : 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasBackdrop)
                  CachedNetworkImage(
                    imageUrl: backdropUrl,
                    fit: BoxFit.cover,
                    placeholder: (c, u) => Container(
                      color: isDark
                          ? const Color(0xFF1F2937)
                          : const Color(0xFFE5E7EB),
                    ),
                    errorWidget: (c, u, e) => Container(
                      color: isDark
                          ? const Color(0xFF1F2937)
                          : const Color(0xFFE5E7EB),
                    ),
                  )
                else
                  Container(
                    color: isDark
                        ? const Color(0xFF1F2937)
                        : const Color(0xFFE5E7EB),
                  ),
                // 重度渐变: 顶部更暗 (让大竖海报更突出), 底部深色
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.35),
                        Colors.black.withOpacity(0.65),
                        Colors.black.withOpacity(0.90),
                      ],
                      stops: const [0.0, 0.55, 1.0],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 2) 前景: 大竖海报 (主元素, 150x225) + 右侧大标题/评分/简介
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 大竖海报 (主元素, 150x225 = 2:3 海报比例)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 150,
                      height: 225,
                      child: posterUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: posterUrl,
                              fit: BoxFit.cover,
                              memCacheWidth: (150 *
                                      MediaQuery.of(context)
                                          .devicePixelRatio)
                                  .round(),
                              memCacheHeight: (225 *
                                      MediaQuery.of(context)
                                          .devicePixelRatio)
                                  .round(),
                              placeholder: (c, u) => Container(
                                color: isDark
                                    ? const Color(0xFF1F2937)
                                    : const Color(0xFFE5E7EB),
                              ),
                              errorWidget: (c, u, e) => Container(
                                color: isDark
                                    ? const Color(0xFF1F2937)
                                    : const Color(0xFFE5E7EB),
                                child: const Icon(
                                    Icons.movie_outlined,
                                    color: Colors.grey,
                                    size: 48),
                              ),
                            )
                          : Container(
                              color: isDark
                                  ? const Color(0xFF1F2937)
                                  : const Color(0xFFE5E7EB),
                            ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  // 右侧: 大标题 + 年份/评分 + 简介 + 「默认: 豆瓣」
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        // 大标题
                        Text(
                          item.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            height: 1.2,
                            shadows: [
                              Shadow(
                                color: Colors.black87,
                                blurRadius: 6,
                              ),
                            ],
                          ),
                        ),
                        if (item.originalTitle.isNotEmpty &&
                            item.originalTitle != item.title) ...[
                          const SizedBox(height: 4),
                          Text(
                            item.originalTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withOpacity(0.75),
                              fontStyle: FontStyle.italic,
                              shadows: const [
                                Shadow(
                                  color: Colors.black54,
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        // 年份 + 评分
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            if (item.year != null)
                              _buildMetaChip('${item.year}'),
                            if (item.voteAverage > 0)
                              _buildRatingChip(item.voteAverage),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // 简介 (3 行)
                        if (item.overview.isNotEmpty)
                          Expanded(
                            child: Text(
                              item.overview,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.45,
                                color: Colors.white.withOpacity(0.9),
                                shadows: const [
                                  Shadow(color: Colors.black54, blurRadius: 4),
                                ],
                              ),
                            ),
                          ),
                        // 「默认: 豆瓣」行 (底部对齐)
                        if (widget.sourceName != null &&
                            widget.sourceName!.isNotEmpty)
                          Row(
                            children: [
                              Icon(Icons.cloud_outlined,
                                  size: 11,
                                  color: Colors.white.withOpacity(0.7)),
                              const SizedBox(width: 3),
                              Text(
                                '默认: ${widget.sourceName}',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.white.withOpacity(0.7),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// v2.0.49 (回滚 v2.0.46): 海报 fallback — 优先用源 cover, 没了再默认占位.
  ///
  /// v2.0.46 把 fallback 改成纯灰色电影 icon, 用户反馈:
  ///   1. 短剧: 列表里能看到图, 点进去看不到了 (源 cover 被丢了, 太激进)
  ///   2. TMDB 没资源: 源 cover 经常是对的 (用户已经在列表看到, 期望详情里也看到),
  ///      用灰色占位反而跟列表视觉不一致
  ///
  /// v2.0.49 修法: 恢复 v2.0.38 ~ v2.0.45 的源 cover 行为 (有就用源 cover),
  ///   但保留 v2.0.46 的两个增量:
  ///     - 短剧 tag (橙色, _isShortDrama 为 true 时显示)
  ///     - 当源 cover 也为空时, 才显示灰色电影 icon 占位
  ///
  /// 布局: 110x150 海报 (源 cover 或灰色占位) + 标题 + 年份/类型/短剧 tag + sourceName.
  Widget _buildPosterFallback(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 110x150 海报: 优先源 cover, 没有走灰色占位
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 110,
              height: 150,
              child: widget.fallbackCover.isNotEmpty
                  ? FutureBuilder<String>(
                      future: getImageUrl(
                          widget.fallbackCover, widget.fallbackSource),
                      builder: (context, snapshot) {
                        final imageUrl =
                            snapshot.data ?? widget.fallbackCover;
                        final headers = getImageRequestHeaders(
                            imageUrl, widget.fallbackSource);
                        return CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          width: 110,
                          height: 150,
                          httpHeaders: headers,
                          memCacheWidth: (110 *
                                  MediaQuery.of(context).devicePixelRatio)
                              .round(),
                          memCacheHeight: (150 *
                                  MediaQuery.of(context).devicePixelRatio)
                              .round(),
                          placeholder: (c, u) => _buildDefaultPoster(isDark),
                          errorWidget: (c, u, e) => _buildDefaultPoster(isDark),
                        );
                      },
                    )
                  : _buildDefaultPoster(isDark),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : Colors.black,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (widget.year != null && widget.year!.isNotEmpty)
                      _buildFallbackTag(widget.year!, isDark),
                    // v2.0.49: 保留 v2.0.46 的短剧 tag
                    if (_isShortDrama)
                      _buildFallbackTag('短剧', isDark,
                          color: const Color(0xFFf59e0b)),
                  ],
                ),
                if (widget.sourceName != null &&
                    widget.sourceName!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.cloud_outlined,
                          size: 12,
                          color: isDark ? Colors.white60 : Colors.black54),
                      const SizedBox(width: 4),
                      Text(
                        '默认: ${widget.sourceName}',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.white60 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// v2.0.49: 默认灰色电影 icon 占位 (110x150, 短剧 / 源 cover 也为空时用).
  Widget _buildDefaultPoster(bool isDark) {
    return Container(
      width: 110,
      height: 150,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF374151), Color(0xFF1F2937)]
              : const [Color(0xFFE5E7EB), Color(0xFFD1D5DB)],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          color: isDark
              ? Colors.white.withOpacity(0.4)
              : Colors.black.withOpacity(0.35),
          size: 48,
        ),
      ),
    );
  }

  /// 加载中: 跟 fallback 一样的占位 (110x150 占位框)
  Widget _buildLoadingFallback(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 110,
            height: 150,
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF1F2937)
                  : const Color(0xFFE5E7EB),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  height: 18,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF1F2937)
                        : const Color(0xFFE5E7EB),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 80,
                  height: 12,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF1F2937)
                        : const Color(0xFFE5E7EB),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white.withOpacity(0.25), width: 0.5),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildRatingChip(double vote) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFB923C), Color(0xFFF59E0B)],
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, color: Colors.white, size: 11),
          const SizedBox(width: 2),
          Text(
            vote.toStringAsFixed(1),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFallbackTag(String text, bool isDark, {Color? color}) {
    final bg = color != null
        ? color.withOpacity(0.15)
        : (isDark
            ? Colors.white.withOpacity(0.08)
            : Colors.black.withOpacity(0.06));
    final fg = color ??
        (isDark ? Colors.white70 : Colors.black87);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: fg,
          fontWeight: color != null ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}
