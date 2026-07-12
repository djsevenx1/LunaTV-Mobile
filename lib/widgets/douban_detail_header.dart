// v2.0.79: 豆瓣大头部 — 给 player_screen「选源播放」详情页用
//
// 演化:
//   v2.0.77: 删了 TMDB, 只把豆瓣 cover URL 升到 l_ratio_poster, 详情页
//            还是走 _buildPosterHeader (110x150 小海报布局). 用户反馈
//            "豆瓣大海报在哪和 tmdb 一样啊" — 期望像 TMDB 那种大头部
//            视觉 (大背景 + 大海报 + 标题/年份).
//   v2.0.78: 加 DoubanDetailHeader, 沿用 v2.0.43 TMDB hero 思路:
//              - 手机: 2:3 整张海报当背景 + 渐变 + 底部标题
//              - 平板: 21:9 横版 + 前景 150x225 大竖海报 + 右侧标题
//            用户反馈"手机版那个大海报太丑了和之前 tmdb 风格一样吧" —
//            2:3 整张海报 + 底部标题的布局跟 TMDB hero 风格不一致.
//   v2.0.79: 手机也改成跟 TMDB hero 完全一致:
//              - 16:9 大背景 (海报 + 渐变)
//              - 前景左侧 150x225 大竖海报 (主元素, 跟背景同一张图,
//                memCache 复用) + 右侧标题/年份/源
//              - 平板: 21:9 (跟 v2.0.51 TMDB hero 一致, 给选集留空间)
//            整体结构跟 v2.0.43 TMDB hero 一模一样, 只差"没 TMDB API
//            拿 overview / 评分 / 集数" (豆瓣没公开 API, 没必要接).
//   v2.0.84: 平板 21:9 背景用 coverUrl (16:9 横版剧照 l_cover 1280x720),
//            替代 cover (2:3 竖海报 l_ratio_poster 600x900). 平板 2K 屏
//            1024+ 宽, 竖海报拉到全宽边角糊; 横版完美 cover.
//   v2.0.85: 手机 16:9 背景也用 coverUrl (跟平板一致). 之前只平板改,
//            手机仍用竖海报 (注释说"手机 600x900 够清晰"), 但用户反馈
//            "手机也改下" — 手机屏 16:9 也把 l_ratio_poster 600x900 拉
//            到 720-1200 物理像素宽, 边角糊. 改后手机/平板共用
//            _backgroundUrl() (原 _tabletBackgroundUrl 重命名).
//   v2.0.93: 加 tmdbBackdropUrl (TMDB w1280 16:9 backdrop, v2.0.93 引入,
//            从 Selene-TV mk4.a 移植的精准识别产物), 优先级最高.
//            配 TMDB key 时, player_screen 在调 DoubanDetailHeader
//            之前用 TmdbService.search+fetchArt 拿到 w1280 backdrop URL
//            传进来, 替代豆瓣 coverUrl. 没配 / 搜索失败 = 走 coverUrl
//            (v2.0.84/v2.0.85 行为), 行为完全不变.
//            设计选择: backdropUrl 是「已知最优质」信号, 直接信它, 不
//            再回退 — 避免 TMDB 失败时混搭豆瓣图导致视觉割裂.
//
// 数据流 (无网络):
//   1. widget.videoInfo.cover  → getImageUrl(cover, source) 自动
//      升级到 l_ratio_poster (登录态下, 见 image_url.dart v2.0.77 改的)
//   2. 标题/年份/sourceName 直接从 widget.videoInfo 拿 (源 API 已有)
//   3. 渐变蒙版 + 圆角 16 + 阴影, 跟 TMDB hero 视觉一致.
//
// 用法 (player_screen 调用):
//   if (UserDataService.isDoubanLoggedIn() && widget.videoInfo.cover.isNotEmpty)
//     DoubanDetailHeader(
//       title: widget.videoInfo.title,
//       year: widget.videoInfo.year,
//       cover: widget.videoInfo.cover,
//       source: widget.videoInfo.source,
//       sourceName: widget.videoInfo.sourceName,
//       coverUrl: widget.videoInfo.coverUrl,         // v2.0.84
//       tmdbBackdropUrl: state._tmdbBackdropUrl,    // v2.0.93 (可能为 null)
//     )
//   else
//     _buildPosterHeader(isDark),

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/utils/image_url.dart';
import 'package:provider/provider.dart';

/// v2.0.78: 豆瓣大头部
///
/// 登录豆瓣 (cookie 有效) 时, 在 player_screen 详情页展示:
/// - 手机: 整张竖版海报 + 渐变压暗 + 底部标题
/// - 平板: 21:9 横版 + 左侧大竖海报 + 右侧渐变背景 + 标题
///
/// 没登录: 调用方走 _buildPosterHeader (小海报), 行为不变。
class DoubanDetailHeader extends StatefulWidget {
  final String title;
  final String? year;
  final String cover; // douban / bangumi URL (v2.0.77 自动升 l_ratio)
  final String source; // 'douban' / 'bangumi'
  final String? sourceName; // 「默认: 豆瓣」那行
  // v2.0.84: 16:9 横版剧照 coverUrl (l_cover 1280x720). 平板/横屏用这个
  //   当大背景 (iPad 屏 1024+ 宽, 竖海报 l_ratio_poster 600x900 缩到 2K 宽
  //   边角糊, 横版 l_cover 1280x720 完美 cover). 有则用, 无则 fallback cover.
  final String? coverUrl;
  // v2.0.93: TMDB w1280 16:9 backdrop (精准识别结果). 配 TMDB key 时
  //   player_screen 传进来, 优先级 > coverUrl > cover. 留空 = 走 coverUrl.
  //   TMDB image CDN (image.tmdb.org) 直连即可, 不需要 worker 加速.
  final String? tmdbBackdropUrl;

  const DoubanDetailHeader({
    super.key,
    required this.title,
    this.year,
    required this.cover,
    required this.source,
    this.sourceName,
    this.coverUrl,
    this.tmdbBackdropUrl,
  });

  @override
  State<DoubanDetailHeader> createState() => _DoubanDetailHeaderState();
}

class _DoubanDetailHeaderState extends State<DoubanDetailHeader> {
  /// v2.0.93: 背景 URL 优先级 —
  ///   1) tmdbBackdropUrl (TMDB w1280 16:9 backdrop, 精准识别结果, 最优)
  ///   2) coverUrl (豆瓣 16:9 横版剧照 l_cover 1280x720, v2.0.84 引入)
  ///   3) cover (豆瓣 2:3 竖海报 l_ratio_poster 600x900, 兜底)
  ///
  /// v2.0.93: tmdbBackdropUrl 是「直连 TMDB image CDN」, 不走 worker 加速
  /// (image.tmdb.org 是 CF 全球 CDN, 跟 worker 一样快). 直接用, 不需
  /// 要 getImageUrl 升级.
  /// v2.0.84: coverUrl 走 [getDoubanCoverUrl] 升级到 l_cover 1280x720 + CDN 切换.
  ///   无 coverUrl 时 fallback cover (竖海报, 走 getImageUrl 升 l_ratio_poster).
  ///   手机/平板都用这个 (v2.0.85 起手机也用, 之前只有平板用).
  Future<String> _backgroundUrl() async {
    if (widget.tmdbBackdropUrl != null && widget.tmdbBackdropUrl!.isNotEmpty) {
      return widget.tmdbBackdropUrl!;
    }
    if (widget.coverUrl != null && widget.coverUrl!.isNotEmpty) {
      return getDoubanCoverUrl(widget.coverUrl!);
    }
    return getImageUrl(widget.cover, widget.source);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeService>().isDarkMode;
    final isTablet = MediaQuery.of(context).size.width >= 600;

    if (widget.cover.isEmpty) {
      // cover 为空 (源没给), 不进大头部逻辑 — 调用方应该已经过滤
      return const SizedBox.shrink();
    }

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
      child: isTablet ? _buildTabletLayout(isDark) : _buildPhoneLayout(isDark),
    );
  }

  /// v2.0.79: 手机 — 16:9 TMDB hero 风格 (跟 v2.0.43 TMDB 完全一致)
  ///
  /// v2.0.78 第一版走的是「2:3 整张海报当背景 + 渐变 + 底部标题」,
  /// 用户反馈「手机版那个大海报太丑了和之前 tmdb 风格一样吧」, 改回
  /// 跟 v2.0.43 ~ v2.0.76 TMDB 详情大头部完全一致的布局:
  ///   - 16:9 大背景 (海报 + 渐变)
  ///   - 前景左侧 150x225 大竖海报 (主元素, 跟背景海报同一张图,
  ///     用 memCache 复用, 跟 v2.0.43 一致)
  ///   - 前景右侧: 大标题 + 年份/源
  ///
  /// v2.0.85: 背景改用 coverUrl (16:9 横版剧照 l_cover 1280x720), 跟平板一致.
  ///   用户反馈「手机也改下」 — 之前注释说"手机仍用竖海报", 但手机屏
  ///   16:9 也把 l_ratio_poster 600x900 拉到 720-1200 物理像素宽, 边角糊.
  ///   coverUrl 横版 1280x720 完美 cover 16:9 手机屏, 前景 150x225 竖海报
  ///   不变 (主元素).
  Widget _buildPhoneLayout(bool isDark) {
    return AspectRatio(
      aspectRatio: 16 / 9, // v2.0.43 TMDB hero 手机比例
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1) 背景: 横版 coverUrl (有则) / 竖版 cover (无则)
          FutureBuilder<String>(
            future: _backgroundUrl(),
            builder: (context, snapshot) {
              final imageUrl = snapshot.data ?? widget.cover;
              final headers = getImageRequestHeaders(imageUrl, widget.source);
              return CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                httpHeaders: headers,
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
              );
            },
          ),
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
          // 2) 前景: 左侧 150x225 大竖海报 (主元素) + 右侧标题/年份/源
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左侧大竖海报 (主元素, 跟 v2.0.43 TMDB hero 一致)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 150,
                    height: 225,
                    child: FutureBuilder<String>(
                      future: getImageUrl(widget.cover, widget.source),
                      builder: (context, snapshot) {
                        final imageUrl = snapshot.data ?? widget.cover;
                        final headers =
                            getImageRequestHeaders(imageUrl, widget.source);
                        return CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          httpHeaders: headers,
                          memCacheWidth: (150 *
                                  MediaQuery.of(context).devicePixelRatio)
                              .round(),
                          memCacheHeight: (225 *
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
                                color: Colors.grey, size: 48),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // 右侧: 标题 + 年份 + 源
                Expanded(
                  child: _buildMetaColumn(alignEnd: false),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// v2.0.78: 平板 — 21:9 横版, 左侧 150x225 大竖海报 + 右侧渐变 + 标题
  ///
  /// v2.0.51 平板 21:9 比例, 给选集 / source list 留出空间.
  /// v2.0.84: 背景用 coverUrl (16:9 横版剧照) 替代 cover (2:3 竖海报).
  ///   平板 2K 屏 1024+ 宽, 竖海报 600x900 拉到全宽会糊;
  ///   横版 l_cover 1280x720 完美 cover 平板宽度.
  ///   无 coverUrl 时 fallback 到 cover (竖海报).
  /// v2.0.85: 跟手机共用 _backgroundUrl() (方法重命名).
  Widget _buildTabletLayout(bool isDark) {
    return AspectRatio(
      aspectRatio: 21 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1) 背景: 横版 coverUrl (有则) / 竖版 cover (无则)
          FutureBuilder<String>(
            future: _backgroundUrl(),
            builder: (context, snapshot) {
              final imageUrl = snapshot.data ?? widget.cover;
              final headers = getImageRequestHeaders(imageUrl, widget.source);
              return CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                httpHeaders: headers,
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
              );
            },
          ),
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
          // 2) 前景: 左侧 150x225 大竖海报 (主元素) + 右侧标题/年份/源
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左侧大竖海报 (主元素)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 150,
                    height: 225,
                    child: FutureBuilder<String>(
                      future: getImageUrl(widget.cover, widget.source),
                      builder: (context, snapshot) {
                        final imageUrl = snapshot.data ?? widget.cover;
                        final headers =
                            getImageRequestHeaders(imageUrl, widget.source);
                        return CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          httpHeaders: headers,
                          memCacheWidth: (150 *
                                  MediaQuery.of(context).devicePixelRatio)
                              .round(),
                          memCacheHeight: (225 *
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
                                color: Colors.grey, size: 48),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // 右侧: 标题 + 年份 + 源
                Expanded(
                  child: _buildMetaColumn(alignEnd: false),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// v2.0.78: 标题 + 年份 + 源 — 浮在渐变蒙版上, 白字带阴影
  ///
  /// 共用手机/平板布局, 文字颜色 + 阴影一致 (跟 TMDB hero v2.0.43 风格).
  Widget _buildMetaColumn({required bool alignEnd}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.end, // 底部对齐
      mainAxisSize: MainAxisSize.max,
      children: [
        // 大标题
        Text(
          widget.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            height: 1.2,
            shadows: [
              Shadow(color: Colors.black87, blurRadius: 6),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 年份 + 源
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (widget.year != null && widget.year!.isNotEmpty)
              _buildMetaChip(widget.year!),
            if (widget.sourceName != null && widget.sourceName!.isNotEmpty)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_outlined,
                      size: 11, color: Colors.white.withOpacity(0.75)),
                  const SizedBox(width: 3),
                  Text(
                    '默认: ${widget.sourceName}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withOpacity(0.75),
                      shadows: const [
                        Shadow(color: Colors.black54, blurRadius: 4),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }

  /// v2.0.78: 年份 chip — 半透明白底 + 阴影, 跟 TMDB hero 一致
  Widget _buildMetaChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withOpacity(0.25)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
        ),
      ),
    );
  }
}
