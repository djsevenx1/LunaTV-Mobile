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
//   v2.0.94: tmdbBackdropUrl 走 worker 加速 (跟豆瓣/番剧图一致, 通过
//            「加速 → CF Worker 域名」配 .workers.dev 域名生效). v2.0.93
//            当初直连 image.tmdb.org (CF 全球 CDN 跟 worker 一样快),
//            但用户反馈国内 image.tmdb.org 偶发加载慢, 走 worker 稳.
//            没配 worker 域名 = 直连 image.tmdb.org (v2.0.93 行为, 不变).
//   v2.0.99: 解除「DoubanDetailHeader 必须豆瓣登录才显示」绑定 — 见
//            player_screen.dart 注释. DoubanDetailHeader 内部本就不依赖
//            登录态 (只用 cover / coverUrl / tmdbBackdropUrl), v2.0.93
//            我在调用方加的 isDoubanLoggedIn() 条件错了, 改成
//            `cover.isNotEmpty`. TMDB backdrop 独立生效, 跟登录无关.
//
// 数据流 (无网络):
//   1. widget.videoInfo.cover  → getImageUrl(cover, source) 自动
//      升级到 l_ratio_poster (登录态下, 见 image_url.dart v2.0.77 改的)
//   2. 标题/年份/sourceName 直接从 widget.videoInfo 拿 (源 API 已有)
//   3. 渐变蒙版 + 圆角 16 + 阴影, 跟 TMDB hero 视觉一致.
//
// 用法 (player_screen 调用):
//   v2.0.99: 只要 cover 不空就显示大头部, 不依赖豆瓣登录.
//   if (widget.videoInfo.cover.isNotEmpty)
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
import 'package:luna_tv/services/luna_image_http.dart';
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
  // v2.1.8: 豆瓣剧情简介. 平板/宽屏 layout 把它放进 header 右侧 (标题/年份
  //   下方), 填满原来大片空白. 手机 layout 屏太窄不放 (走独立 summary section).
  //   null/空 = 不渲染简介部分, 跟 v2.1.7 之前完全一致.
  final String? summary;
  // v2.1.17: 平板大头部背景图下半部嵌入横向滚动的演员头像+名字 (填充原来
  //   大头部的空白). 用户反馈"海报内好多空白的地方 / 放上演员吧 / 都在一行
  //   要有演员图片那种 / 不够排就滑动". 平板 build 时把它 Positioned 在背景
  //   图下半部 (避开左边海报), 手机 build 忽略这个字段 (演员在手机端
  //   不展示, 跟之前一致 — 用户只要平板). null = 不渲染 (没配 TMDB key /
  //   拉不到演员), 跟 v2.1.16 视觉一致.
  final Widget? castOverlay;

  const DoubanDetailHeader({
    super.key,
    required this.title,
    this.year,
    required this.cover,
    required this.source,
    this.sourceName,
    this.coverUrl,
    this.tmdbBackdropUrl,
    this.summary,
    this.castOverlay,
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
  /// v2.1.25: tmdbBackdropUrl 走 [getImageUrl] 包装 (跟 Bangumi 图一个模式,
  ///   跟 [getImageUrl] tmdb case 1:1 平行). 之前 v2.0.93 ~ v2.1.24 是直接
  ///   信 art.backdropUrl (worker-wrapped URL), v2.1.25 改回原始
  ///   image.tmdb.org URL, 这里必须走 buildTmdbImageUrl 包装, 不然国内
  ///   image.tmdb.org 被墙, 大头部背景图加载不出来.
  /// v2.0.84: coverUrl 走 [getDoubanCoverUrl] 升级到 l_cover 1280x720 + CDN 切换.
  ///   无 coverUrl 时 fallback cover (竖海报, 走 getImageUrl 升 l_ratio_poster).
  ///   手机/平板都用这个 (v2.0.85 起手机也用, 之前只有平板用).
  Future<String> _backgroundUrl() async {
    if (widget.tmdbBackdropUrl != null && widget.tmdbBackdropUrl!.isNotEmpty) {
      // v2.1.25: 走 getImageUrl 包装, 跟 hero_banner / 其它屏幕对齐
      return getImageUrl(widget.tmdbBackdropUrl!, 'tmdb');
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
                // v2.1.33: 走 OkHttp (强制 TLS 1.2), 避开 dart:io TLS 1.3
                //   cipher 跟 CF edge zone 协商失败
                httpClient: LunaImageHttp(),
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
          // 2) 前景: 左侧大竖海报 (主元素) + 右侧标题/年份/源/简介
          // v2.1.8: 用 LayoutBuilder 拿容器高度, 海报高度 = 容器高 - padding,
          //   宽度 = 高度 * 2/3. 修复"海报和片名错位" — 之前海报固定 150x225,
          //   16:9 窄屏容器高 < 225 时海报溢出, Row 被撑高, 标题贴底对不齐海报.
          // v2.1.16: 简介改小说翻页式. 之前外层 SingleChildScrollView 把海报+
          //   标题+简介整条左滑, 用户反馈"能不能只滑动文字往左滑动是下半段
          //   内容而不是连着 / 和小说翻页一样". 改: 海报+标题+年份固定不动,
          //   只有简介区用 PageView 横向翻页, 每页显示一段简介文本. 简介按
          //   可见宽+高度切多页, 左滑翻下一页 (下半段), 右滑翻上一页.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxH = constraints.maxHeight;
                // 海报高度不超过容器高, 不超过 225 (大屏不无限放大)
                final posterH = maxH < 225 ? maxH : 225.0;
                final posterW = posterH * 2 / 3;
                // 右侧 meta 可见宽度 = 总宽 - 海报 - gap (padding 已在外层
                // Padding 扣过, 不再重复减).
                final metaW = constraints.maxWidth - posterW - 14;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: posterW,
                        height: posterH,
                        child: FutureBuilder<String>(
                          future: getImageUrl(widget.cover, widget.source),
                          builder: (context, snapshot) {
                            final imageUrl = snapshot.data ?? widget.cover;
                            final headers = getImageRequestHeaders(
                                imageUrl, widget.source);
                            return CachedNetworkImage(
                              imageUrl: imageUrl,
                              // v2.1.33: 走 OkHttp (强制 TLS 1.2), 避开 dart:io TLS 1.3
                              //   cipher 跟 CF edge zone 协商失败
                              httpClient: LunaImageHttp(),
                              fit: BoxFit.cover,
                              httpHeaders: headers,
                              memCacheWidth: (posterW *
                                      MediaQuery.of(context).devicePixelRatio)
                                  .round(),
                              memCacheHeight: (posterH *
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
                    // 右侧: 标题 + 年份 + 源 + 简介 (简介区小说翻页式)
                    SizedBox(
                      width: metaW,
                      height: posterH,
                      child: _buildMetaColumn(
                          alignEnd: false, showSummary: true, summaryW: metaW),
                    ),
                  ],
                );
              },
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
                // v2.1.33: 走 OkHttp (强制 TLS 1.2), 避开 dart:io TLS 1.3
                //   cipher 跟 CF edge zone 协商失败
                httpClient: LunaImageHttp(),
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
                          // v2.1.33: 走 OkHttp (强制 TLS 1.2), 避开 dart:io TLS 1.3
                          //   cipher 跟 CF edge zone 协商失败
                          httpClient: LunaImageHttp(),
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
                // 右侧: 标题 + 年份 + 源 + 简介 (v2.1.8: 平板填满右侧空白)
                // v2.1.16: LayoutBuilder 拿 Expanded 给的宽度传给 summaryW,
                //   让平板也能用小说翻页式简介 (跟手机一致).
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return _buildMetaColumn(
                        alignEnd: false,
                        showSummary: true,
                        summaryW: constraints.maxWidth,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          // v2.1.17: 演员卡司 — 浮在背景图下半部 (避开左边海报), 横向滚动的
          //   圆形头像 + 名字. castOverlay 是个 SizedBox(100) ListView, 调用方
          //   (player_screen) 传. null 时不渲染, 跟 v2.1.16 视觉一致.
          //   高度 100 (头像 70 + 间距 6 + 名字 ~17 + 上下 padding) 在
          //   21:9 大背景图下半部比例协调, 比 v2.1.17 首发 80 更显眼.
          if (widget.castOverlay != null)
            Positioned(
              left: 180, // 避开左边海报 (150) + 间距 (14) + padding (16)
              right: 16,
              bottom: 14,
              child: widget.castOverlay!,
            ),
        ],
      ),
    );
  }

  /// v2.0.78: 标题 + 年份 + 源 — 浮在渐变蒙版上, 白字带阴影
  ///
  /// 共用手机/平板布局, 文字颜色 + 阴影一致 (跟 TMDB hero v2.0.43 风格).
  /// v2.1.8: 平板 (showSummary=true) 在年份下方加剧情简介, Expanded 撑满
  ///   剩余高度, 解决"右侧大片空白". 手机 (showSummary=false) 屏窄不放简介,
  ///   走独立 summary section. alignEnd 参数保留但当前都传 false.
  /// v2.1.16: 简介改小说翻页式. [summaryW] = 简介区可见宽, 用它把简介切成
  ///   多页, 用 PageView 横向翻页. 标题/年份固定不动, 左滑只翻简介下半段.
  Widget _buildMetaColumn({
    required bool alignEnd,
    bool showSummary = false,
    double summaryW = 0,
  }) {
    final hasSummary = showSummary &&
        widget.summary != null &&
        widget.summary!.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      // v2.1.8: 有简介时顶部对齐 (标题置顶 → 简介 Expanded 撑满 → 年份贴底);
      //   无简介时保持原底部对齐 (标题/年份贴底, 跟 v2.0.78 视觉一致).
      mainAxisAlignment:
          hasSummary ? MainAxisAlignment.start : MainAxisAlignment.end,
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
        // v2.1.16: 简介 — 小说翻页式 PageView. 标题/年份固定不动, 左滑只翻
        //   简介下半段 (下一页), 右滑翻上一页. 简介短到一页放得下时只有 1 页,
        //   PageView 不会滚动 (跟原来单 Text 视觉一致).
        if (hasSummary) ...[
          const SizedBox(height: 10),
          Expanded(
            child: _buildSummaryPager(summaryW),
          ),
        ],
      ],
    );
  }

  /// v2.1.16: 简介小说翻页器. 用 TextPainter 量简介在 [pageW] 宽度下的
  /// 排版, 按"每页能放下的行数"把简介切成多页, PageView 横向翻页.
  /// - 简介短 (1 页放得下): PageView 只 1 页, 不滚动, 视觉跟单 Text 一样.
  /// - 简介长 (多页): 左滑翻下一页 (下半段), 右滑翻上一页. 海报/标题/年份
  ///   固定不动, 只有简介区翻页.
  Widget _buildSummaryPager(double pageW) {
    final summary = widget.summary?.trim() ?? '';
    if (summary.isEmpty || pageW <= 0) {
      return const SizedBox.shrink();
    }
    // 用 TextPainter 量完整简介在 pageW 宽度下占多少行.
    final tp = TextPainter(
      text: TextSpan(
        text: summary,
        style: const TextStyle(fontSize: 13, height: 1.5),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: pageW);
    final lines = tp.computeLineMetrics();
    final fullLines = lines.length;
    tp.dispose();
    // 每页固定 8 行 (跟原来 maxLines:8 一致), 末页可能不满 8 行.
    const linesPerPage = 8;
    final pageCount = (fullLines / linesPerPage).ceil();
    if (pageCount <= 1) {
      // 1 页放得下, 不用翻页, 直接渲染 Text (跟原视觉一致).
      return Text(
        summary,
        maxLines: 8,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: Colors.white.withOpacity(0.82),
          shadows: const [
            Shadow(color: Colors.black54, blurRadius: 4),
          ],
        ),
      );
    }
    // 多页: 用一次完整 layout 拿所有行的 right/baseline, 逐行取该行
    // 最右一个字符的 offset → getPositionForOffset → TextPosition.offset
    // 就是这行末尾字符在原文里的位置. 累加 linesPerPage 行切出一页.
    final fullTp = TextPainter(
      text: TextSpan(
        text: summary,
        style: const TextStyle(fontSize: 13, height: 1.5),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: pageW);
    final allLines = fullTp.computeLineMetrics();
    // 算每行末尾字符在原文中的 offset.
    final lineEndOffsets = <int>[];
    for (final line in allLines) {
      // baseline 是文字基线 y, 行末 x 用 line.width (这行最后一个字符右沿).
      // getPositionForOffset 返回最接近这个点的字符位置.
      final pos = fullTp.getPositionForOffset(
        Offset(line.width - 0.5, line.baseline - 0.5),
      );
      lineEndOffsets.add(pos.offset);
    }
    fullTp.dispose();
    // 按 linesPerPage 行切页.
    final pages = <String>[];
    var lineIdx = 0;
    var lastEnd = 0;
    while (lineIdx < allLines.length) {
      final pageLastLineIdx =
          (lineIdx + linesPerPage - 1) < allLines.length
              ? lineIdx + linesPerPage - 1
              : allLines.length - 1;
      final end = lineEndOffsets[pageLastLineIdx];
      // +1 让 substring 包含末尾字符; 末行特殊处理到原文末尾.
      final sliceEnd = end + 1 > summary.length ? summary.length : end + 1;
      final pageText = summary.substring(lastEnd, sliceEnd).trim();
      if (pageText.isNotEmpty) {
        pages.add(pageText);
      }
      lastEnd = sliceEnd;
      lineIdx = pageLastLineIdx + 1;
    }
    if (pages.isEmpty) {
      return const SizedBox.shrink();
    }
    return PageView.builder(
      scrollDirection: Axis.horizontal,
      itemCount: pages.length,
      itemBuilder: (context, index) {
        return Stack(
          children: [
            Text(
              pages[index],
              maxLines: linesPerPage,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: Colors.white.withOpacity(0.82),
                shadows: const [
                  Shadow(color: Colors.black54, blurRadius: 4),
                ],
              ),
            ),
            // 右下角页码提示, 告诉用户当前第几页 / 共几页.
            Positioned(
              right: 0,
              bottom: 0,
              child: Text(
                '${index + 1}/${pages.length}',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white.withOpacity(0.5),
                ),
              ),
            ),
          ],
        );
      },
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
