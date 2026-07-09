// v2.0.38: TMDB 详情大头部 — 给 player_screen「选源播放」详情页用
//
// 背景:
//   - 配了 TMDB key 的用户在 player_screen 详情页看到 TMDB 大背景 + 大海报 + 简介 + 评分
//   - 没配 key → 走 fallback: 用原 douban 海报, 跟 v2.0.37 一样
//
// 数据流:
//   1. TmdbService.search(type, title, year) → 拿第一个匹配结果的 ID
//   2. TmdbService.getDetails(type, id) → 拿完整 metadata (overview, backdrop, voteAverage)
//   3. 1 天本地缓存兜底, 重复打开详情页几乎零网络
//
// 配了 key 拿不到结果 (TMDB 没收录 / 标题不一样) → 退化为原 douban 海报,
// 不影响播放, 只是没海报墙效果.
//
// 用法 (player_screen 调用):
//   TmdbDetailHeader(
//     title: widget.videoInfo.title,
//     year: widget.videoInfo.year,
//     kind: widget.kind ?? (widget.videoInfo.sourceName == '豆瓣' ? 'movie' : 'tv'),
//     fallbackCover: widget.videoInfo.cover,
//     fallbackSource: widget.videoInfo.source,
//   )

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/tmdb_service.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/utils/image_url.dart';
import 'package:provider/provider.dart';

/// v2.0.38: TMDB 详情大头部
/// 配了 TMDB key: 用 TMDB 大背景 + 大海报 + 评分 + 简介
/// 没配 key 或拿不到结果: 用原 douban 海报 (fallback, 行为跟 v2.0.37 一样)
class TmdbDetailHeader extends StatefulWidget {
  final String title;
  final String? year; // LunaTV 存的是字符串 (e.g. "2024" 或 "2024-01")
  final String kind; // 'movie' / 'tv'
  final String fallbackCover; // 原 douban / bangumi 海报
  final String fallbackSource; // 'douban' / 'bangumi' (for getImageUrl)
  final String? sourceName; // 「默认: 豆瓣」那行, 透传下来

  const TmdbDetailHeader({
    super.key,
    required this.title,
    this.year,
    this.kind = 'tv',
    required this.fallbackCover,
    required this.fallbackSource,
    this.sourceName,
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

  Future<void> _loadTmdb() async {
    if (!isTmdbPosterWallEnabled() || widget.title.isEmpty) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _hasError = false; // 没配 key 不算 error, 是 fallback
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
      final searchFuture = TmdbService.search(
        type: _mediaType,
        query: widget.title,
        year: _yearInt,
        page: 1,
      );
      final cfg = await cfgFuture;
      final results = await searchFuture;
      if (!mounted) return;
      if (results.results.isEmpty) {
        setState(() {
          _isLoading = false;
          _hasError = false; // 搜不到不算 error, 走 fallback
        });
        return;
      }
      // 2) 拿第一个匹配的详情 (含 overview + backdrop)
      final first = results.results.first;
      final details = await TmdbService.getDetails(
        type: _mediaType,
        id: first.id,
      );
      if (!mounted) return;
      setState(() {
        _tmdbConfig = cfg;
        // 用详情 (overview + backdrop) 优先, 拿不到用 search result (基本字段)
        _tmdbItem = details ?? first;
        _isLoading = false;
        _hasError = false;
      });
    } on TmdbException {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _hasError = true; // TMDB error (NO_KEY/INVALID_KEY/NETWORK) → 显 fallback
      });
    } catch (_) {
      if (!mounted) return;
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
      // fallback: 用原 douban 海报 (跟 v2.0.37 一样)
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
          // 1) 背景: backdrop 大图 (16:9) + 重度渐变蒙版 (大竖海报在前景, 背景压暗)
          AspectRatio(
            aspectRatio: 16 / 9,
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

  /// Fallback: 用原 douban 海报 (跟 v2.0.37 _buildPosterHeader 一样, 110x150 小海报)
  Widget _buildPosterFallback(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 110,
              height: 150,
              child: widget.fallbackCover.isNotEmpty
                  ? FutureBuilder<String>(
                      future: getImageUrl(widget.fallbackCover, widget.fallbackSource),
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
                          placeholder: (c, u) => Container(
                            color: isDark
                                ? const Color(0xFF1F2937)
                                : const Color(0xFFE5E7EB),
                          ),
                          errorWidget: (c, u, e) => Container(
                            color: isDark
                                ? const Color(0xFF1F2937)
                                : const Color(0xFFE5E7EB),
                            child: const Icon(Icons.movie_outlined,
                                color: Colors.grey, size: 40),
                          ),
                        );
                      },
                    )
                  : Container(
                      color: isDark
                          ? const Color(0xFF1F2937)
                          : const Color(0xFFE5E7EB),
                      child: const Icon(Icons.movie_outlined,
                          color: Colors.grey, size: 40),
                    ),
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

  Widget _buildFallbackTag(String text, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withOpacity(0.08)
            : Colors.black.withOpacity(0.06),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: isDark ? Colors.white70 : Colors.black87,
        ),
      ),
    );
  }
}
