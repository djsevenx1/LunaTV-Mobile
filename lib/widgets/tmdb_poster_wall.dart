// v2.0.38: TMDB 海报墙 widget — 首页「热门电影」「热门剧集」section 替换方案
//
// 背景:
//   - v2.0.35 加了 TMDB API key 设置入口 (opt-in 模式: 填 = 启用, 不填 = 保持原样)
//   - v2.0.36 加了 TmdbService (CORSAPI 加速 + 1 天本地缓存)
//   - v2.0.38 (本文件): Phase 2 UI — 用 TMDB 海报墙替换首页 Douban 风格的「热门电影」/「热门剧集」
//     2 个 section. 配了 key 看到海报墙, 没配 key home_screen 走原 HotMoviesSection / HotTvSection
//   - 配套 widget: tmdb_detail_header.dart 给 player_screen 详情页用, 配了 key 把现有的
//     110x150 小海报升级成 TMDB 大背景 + 简介 + 类型 tags
//
// 设计原则 (跟 v2.0.35 一脉相承):
//   - 填 key 字段 = 自动启用, 不填 = 保持原样, 不加 UI toggle
//   - 走 Opt-in 模式: home_screen 在 build 时调 UserDataService.getTmdbApiKeySync()
//     决定用 TmdbPosterWall 还是原 HotMoviesSection
//   - 数据流: TmdbService.getPopular(type) 一次拿 20 个, 1 天本地缓存兜底
//   - 海报图: TMDB CDN https://image.tmdb.org/t/p/w185{poster_path} (直连, 不走 CF Worker,
//     浏览器/CDN 直连 TMDB image CDN 速度 OK, 走 worker 反而慢)
//   - 点击 TMDB 海报: 因为 TMDB item 没有 LunaTV source/episodes, 不能直接跳播放.
//     行为: 弹底部 sheet 显示 TMDB 详情 + 「去 LunaTV 搜索」按钮, 触发 LunaTV 搜索流程
//     (拿 title + year 去 search_service 搜, 跳搜索结果页让用户选源)

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:luna_tv/screens/search_screen.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/tmdb_service.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/widgets/section_title.dart';
import 'package:provider/provider.dart';

/// v2.0.38: TMDB 海报墙 (首页横滚 section, 配 TMDB key 才挂载)
class TmdbPosterWall extends StatefulWidget {
  /// TMDB 媒体类型 (movie / tv)
  final TmdbMediaType mediaType;

  /// Section 标题 (e.g. "热门电影" / "热门剧集")
  final String title;

  /// Section 副标题 (e.g. "TMDB 热门" / "本周热播")
  final String subtitle;

  /// Section 渐变色 (跟现有 HotMoviesSection / HotTvSection 风格统一)
  final SectionColor sectionColor;

  /// Section icon
  final IconData icon;

  /// 点击单张海报回调
  final void Function(TmdbItem item)? onItemTap;

  /// 「查看更多」点击回调 (跟 HotMoviesSection 行为对齐, 跳底部 nav)
  final VoidCallback? onMoreTap;

  const TmdbPosterWall({
    super.key,
    required this.mediaType,
    required this.title,
    required this.subtitle,
    this.sectionColor = SectionColor.amber,
    this.icon = Icons.movie_outlined,
    this.onItemTap,
    this.onMoreTap,
  });

  @override
  State<TmdbPosterWall> createState() => _TmdbPosterWallState();

  /// v2.0.38: 静态方法 — 触发所有已挂载实例刷新 (跟 HotMoviesSection.refreshHotMovies 一致)
  static Future<void> refreshAll() async {
    for (final inst in _instances.toList()) {
      await inst._loadItems();
    }
  }

  static final Set<_TmdbPosterWallState> _instances = {};
}

/// 辅助: 校验 TMDB key 是否配了, 配了才用 TmdbPosterWall (home_screen 用)
bool isTmdbPosterWallEnabled() {
  final k = UserDataService.getTmdbApiKeySync();
  return k != null && k.isNotEmpty;
}

class _TmdbPosterWallState extends State<TmdbPosterWall> {
  List<TmdbItem> _items = [];
  TmdbConfiguration? _config;
  bool _isLoading = true;
  bool _hasError = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    TmdbPosterWall._instances.add(this);
    _loadItems();
  }

  @override
  void dispose() {
    TmdbPosterWall._instances.remove(this);
    super.dispose();
  }

  Future<void> _loadItems() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _hasError = false;
      _errorMessage = '';
    });
    try {
      // 并行拉: configuration (海报 URL base) + popular (前 20)
      final results = await Future.wait([
        TmdbService.getConfiguration(),
        TmdbService.getPopular(type: widget.mediaType, page: 1),
      ]);
      if (!mounted) return;
      final cfg = results[0] as TmdbConfiguration;
      final paged = results[1] as TmdbPagedResult<TmdbItem>;
      setState(() {
        _config = cfg;
        _items = paged.results.take(20).toList();
        _isLoading = false;
      });
    } on TmdbException catch (e) {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _errorMessage = e.toUserMessage();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _errorMessage = '加载失败: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeService>().isDarkMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          title: widget.title,
          subtitle: widget.subtitle,
          icon: widget.icon,
          color: widget.sectionColor,
          moreText: '查看更多',
          onMore: widget.onMoreTap,
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 230,
          child: _buildBody(isDark),
        ),
      ],
    );
  }

  Widget _buildBody(bool isDark) {
    if (_isLoading) {
      return _buildLoadingState(isDark);
    }
    if (_hasError) {
      return _buildErrorState(isDark);
    }
    if (_items.isEmpty) {
      return _buildEmptyState(isDark);
    }
    return _buildList(isDark);
  }

  Widget _buildList(bool isDark) {
    final cfg = _config!;
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const SizedBox(width: 10),
      itemBuilder: (context, index) {
        final item = _items[index];
        return _PosterCard(
          item: item,
          config: cfg,
          isDark: isDark,
          onTap: () {
            if (widget.onItemTap != null) {
              widget.onItemTap!(item);
            } else {
              _showItemDetailSheet(item, cfg);
            }
          },
        );
      },
    );
  }

  Widget _buildLoadingState(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: widget.sectionColor.colors.first,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '加载中...',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline,
              color: isDark ? Colors.white24 : Colors.black26, size: 32),
          const SizedBox(height: 8),
          Text(
            _errorMessage,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white60 : Colors.black54,
            ),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: _loadItems,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试'),
            style: TextButton.styleFrom(
              foregroundColor: widget.sectionColor.colors.first,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Text(
        '暂无内容',
        style: TextStyle(
          fontSize: 12,
          color: isDark ? Colors.white38 : Colors.black38,
        ),
      ),
    );
  }

  /// v2.0.38: 弹底部 sheet 显示 TMDB 详情 + 「去 LunaTV 搜索」按钮
  void _showItemDetailSheet(TmdbItem item, TmdbConfiguration cfg) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ItemDetailSheet(item: item, config: cfg),
    );
  }
}

/// v2.0.38: 单张 TMDB 海报卡片
class _PosterCard extends StatelessWidget {
  final TmdbItem item;
  final TmdbConfiguration config;
  final bool isDark;
  final VoidCallback onTap;

  const _PosterCard({
    required this.item,
    required this.config,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final posterUrl = config.posterUrl(item.posterPath, size: 'w185');
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 110,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 海报 (圆角 10, 阴影)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: posterUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: posterUrl,
                        fit: BoxFit.cover,
                        memCacheWidth:
                            (110 * MediaQuery.of(context).devicePixelRatio)
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
                          child: Icon(Icons.movie_outlined,
                              color: Colors.grey, size: 28),
                        ),
                      )
                    : Container(
                        color: isDark
                            ? const Color(0xFF1F2937)
                            : const Color(0xFFE5E7EB),
                        child: Icon(Icons.movie_outlined,
                            color: Colors.grey, size: 28),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            // 标题
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white : Colors.black87,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 4),
            // 评分徽章 (TMDB vote 0-10 → 0-100%)
            if (item.voteAverage > 0)
              Row(
                children: [
                  Icon(Icons.star_rounded,
                      size: 12, color: const Color(0xFFFBBF24)),
                  const SizedBox(width: 2),
                  Text(
                    '${item.votePercent}%',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// v2.0.38: TMDB item 详情底部 sheet
/// 显示: 背景图 + 标题 + 评分 + 年份 + 简介 + 「去 LunaTV 搜索」按钮
class _ItemDetailSheet extends StatelessWidget {
  final TmdbItem item;
  final TmdbConfiguration config;

  const _ItemDetailSheet({required this.item, required this.config});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backdropUrl =
        config.backdropUrl(item.backdropPath, size: 'w780');
    final posterUrl = config.posterUrl(item.posterPath, size: 'w342');
    final mq = MediaQuery.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF111827) : Colors.white,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(20),
            ),
          ),
          child: ListView(
            controller: scrollController,
            padding: EdgeInsets.zero,
            children: [
              // 顶部: backdrop 背景 + 海报 + 标题
              Stack(
                children: [
                  // 背景
                  SizedBox(
                    height: 200,
                    width: double.infinity,
                    child: backdropUrl.isNotEmpty
                        ? CachedNetworkImage(
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
                        : Container(
                            color: isDark
                                ? const Color(0xFF1F2937)
                                : const Color(0xFFE5E7EB),
                          ),
                  ),
                  // 渐变蒙版
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(20),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            isDark
                                ? const Color(0xFF111827)
                                : Colors.white,
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 关闭按钮
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Material(
                      color: Colors.black.withOpacity(0.4),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => Navigator.of(context).pop(),
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.close,
                              color: Colors.white, size: 20),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 海报 (浮在 backdrop 下方, 圆角)
                    Transform.translate(
                      offset: const Offset(0, -60),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: SizedBox(
                              width: 100,
                              height: 150,
                              child: posterUrl.isNotEmpty
                                  ? CachedNetworkImage(
                                      imageUrl: posterUrl,
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
                                        child: const Icon(
                                            Icons.movie_outlined,
                                            color: Colors.grey),
                                      ),
                                    )
                                  : Container(
                                      color: isDark
                                          ? const Color(0xFF1F2937)
                                          : const Color(0xFFE5E7EB),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                    color: isDark
                                        ? Colors.white
                                        : Colors.black,
                                    height: 1.2,
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
                                      fontSize: 13,
                                      color: isDark
                                          ? Colors.white60
                                          : Colors.black54,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    if (item.year != null) ...[
                                      Text(
                                        '${item.year}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: isDark
                                              ? Colors.white70
                                              : Colors.black54,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                    ],
                                    if (item.voteAverage > 0)
                                      Row(
                                        children: [
                                          const Icon(
                                              Icons.star_rounded,
                                              size: 14,
                                              color: Color(0xFFFBBF24)),
                                          const SizedBox(width: 2),
                                          Text(
                                            '${item.voteAverage.toStringAsFixed(1)}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: isDark
                                                  ? Colors.white70
                                                  : Colors.black54,
                                            ),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Transform.translate(
                      offset: const Offset(0, -50),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (item.overview.isNotEmpty) ...[
                            Text(
                              '剧情简介',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: isDark
                                    ? Colors.white
                                    : Colors.black,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              item.overview,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.6,
                                color: isDark
                                    ? Colors.white70
                                    : Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 20),
                          ],
                          // 「去 LunaTV 搜索」按钮
                          SizedBox(
                            width: double.infinity,
                            height: 46,
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.of(context).pop();
                                _goLunaTvSearch(context);
                              },
                              icon: const Icon(Icons.search, size: 18),
                              label: const Text('去 LunaTV 搜索'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor:
                                    const Color(0xFF22C55E),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(12),
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '在 LunaTV 中搜索「${item.title}」${item.year != null ? " (${item.year})" : ""} 找源',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark
                                  ? Colors.white38
                                  : Colors.black38,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 底部安全区
              SizedBox(height: mq.padding.bottom),
            ],
          ),
        );
      },
    );
  }

  /// 跳搜索页: 用 TMDB title + year 当 query, 走 LunaTV 现有 search 流程
  void _goLunaTvSearch(BuildContext context) {
    // LunaTV 用 MaterialPageRoute 直接 push SearchScreen, SearchScreen 没接受
    // initialQuery 构造参数, 所以先 push, 让用户根据 sheet 副标题里写的「在 LunaTV 中
    // 搜索 X」自己输入. 后续 SearchScreen 接受 initialQuery 的话可以改造.
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SearchScreen()),
    );
  }
}
