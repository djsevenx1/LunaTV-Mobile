import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:luna_tv/services/douban_service.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/models/douban_movie.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/utils/image_url.dart';
import 'package:provider/provider.dart';

/// LunaTV 风格的豆瓣详情页 (对齐 Web 版 PlayInfoPanel)
class DoubanDetailScreen extends StatefulWidget {
  final String id;
  final String kind;
  final String? title;
  final String? poster;

  const DoubanDetailScreen({
    super.key,
    required this.id,
    required this.kind,
    this.title,
    this.poster,
  });

  factory DoubanDetailScreen.fromArgs(BuildContext context) {
    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    return DoubanDetailScreen(
      id: args?['id'] ?? '',
      kind: args?['kind'] ?? 'movie',
      title: args?['title'],
      poster: args?['poster'],
    );
  }

  @override
  State<DoubanDetailScreen> createState() => _DoubanDetailScreenState();
}

class _DoubanDetailScreenState extends State<DoubanDetailScreen>
    with SingleTickerProviderStateMixin {
  late Future<ApiResponse<DoubanMovieDetails>> _future;
  DoubanMovieDetails? _details;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _future = DoubanService.getDoubanDetails(context, doubanId: widget.id);
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeService>().isDarkMode;
    final isTv = widget.kind == 'tv';

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF0F1117)
          : const Color(0xFFF5F7F5),
      body: FutureBuilder<ApiResponse<DoubanMovieDetails>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _buildLoadingState(isDark);
          }
          final resp = snapshot.data;
          if (resp == null || !resp.success) {
            return _buildErrorState(
                resp?.message ?? '未知错误', isDark);
          }
          final d = resp.data!;
          _details = d;
          return _buildContent(d, isTv, isDark);
        },
      ),
    );
  }

  Widget _buildLoadingState(bool isDark) {
    return Stack(
      children: [
        _buildHeroBackground(widget.poster, isDark),
        SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(
                    color: AppColors.primary),
                const SizedBox(height: 16),
                Text('加载中...',
                    style: TextStyle(
                        color: isDark ? Colors.white70 : Colors.black54)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorState(String msg, bool isDark) {
    return Stack(
      children: [
        _buildHeroBackground(widget.poster, isDark),
        SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline,
                    color: isDark ? Colors.white : Colors.black, size: 48),
                const SizedBox(height: 12),
                Text('加载失败：$msg',
                    style: TextStyle(
                        color: isDark ? Colors.white70 : Colors.black54)),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _future = DoubanService.getDoubanDetails(
                          context, doubanId: widget.id);
                    });
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeroBackground(String? poster, bool isDark) {
    return Stack(
      children: [
        Positioned.fill(
          child: poster != null && poster.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: poster,
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
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? [
                        Colors.black.withOpacity(0.4),
                        Colors.black.withOpacity(0.92),
                        const Color(0xFF0F1117),
                      ]
                    : [
                        Colors.white.withOpacity(0.3),
                        Colors.white.withOpacity(0.7),
                        const Color(0xFFF5F7F5),
                    ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(DoubanMovieDetails d, bool isTv, bool isDark) {
    return Stack(
      children: [
        _buildHeroBackground(d.poster, isDark),
        SafeArea(
          child: Column(
            children: [
              // 自定义顶栏
              _buildTopBar(isDark),
              // Tab 栏
              _buildTabBar(isDark),
              // 内容
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildOverviewTab(d, isTv, isDark),
                    _buildCastTab(d, isDark),
                    _buildRecommendTab(d, isDark),
                    _buildCommentTab(isDark),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back,
                color: isDark ? Colors.white : Colors.black),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Text(
              _details?.title ?? widget.title ?? '详情',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isDark ? Colors.white : Colors.black,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.share_outlined,
                color: isDark ? Colors.white : Colors.black),
            onPressed: () {},
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(bool isDark) {
    final selectedColor = AppColors.primary;
    final unselectedColor = isDark ? Colors.white60 : Colors.black54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: TabBar(
        controller: _tabController,
        isScrollable: false,
        labelColor: selectedColor,
        unselectedLabelColor: unselectedColor,
        indicatorColor: selectedColor,
        indicatorWeight: 3,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle:
            const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        unselectedLabelStyle:
            const TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
        tabs: const [
          Tab(text: '概览'),
          Tab(text: '演员'),
          Tab(text: '推荐'),
          Tab(text: '短评'),
        ],
      ),
    );
  }

  Widget _buildOverviewTab(DoubanMovieDetails d, bool isTv, bool isDark) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeaderCard(d, isTv, isDark),
          const SizedBox(height: 16),
          _buildActionButtons(d, isTv, isDark),
          const SizedBox(height: 16),
          _buildMetaTags(d, isDark),
          const SizedBox(height: 16),
          _buildSummary(d, isDark),
          const SizedBox(height: 16),
          _buildStaffCard(d, isDark),
        ],
      ),
    );
  }

  Widget _buildHeaderCard(DoubanMovieDetails d, bool isTv, bool isDark) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 海报
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 100,
            height: 150,
            child: FutureBuilder<String>(
              future: getImageUrl(d.poster, 'douban'),
              builder: (context, snapshot) {
                final imageUrl = snapshot.data ?? d.poster;
                final headers = getImageRequestHeaders(imageUrl, 'douban');
                return CachedNetworkImage(
                  imageUrl: imageUrl,
                  width: 100,
                  height: 150,
                  fit: BoxFit.cover,
                  httpHeaders: headers,
                  placeholder: (c, u) => Container(
                    width: 100,
                    height: 150,
                    color: isDark
                        ? const Color(0xFF1F2937)
                        : const Color(0xFFE5E7EB),
                  ),
                  errorWidget: (c, u, e) => Container(
                    width: 100,
                    height: 150,
                    color: isDark
                        ? const Color(0xFF1F2937)
                        : const Color(0xFFE5E7EB),
                    child: const Icon(Icons.movie_outlined,
                        color: Colors.grey),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                d.title,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black,
                  height: 1.3,
                ),
              ),
              if (d.originalTitle != null &&
                  d.originalTitle!.isNotEmpty &&
                  d.originalTitle != d.title)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    d.originalTitle!,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              if (d.rate != null && d.rate!.isNotEmpty)
                _buildRatingBadge(d.rate!, isDark),
              const SizedBox(height: 8),
              if (d.year.isNotEmpty)
                _buildInfoRow(
                  icon: Icons.calendar_today_outlined,
                  text: d.year,
                  isDark: isDark,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRatingBadge(String rate, bool isDark) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFB923C), Color(0xFFF59E0B)],
        ),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFF59E0B).withOpacity(0.35),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, color: Colors.white, size: 16),
          const SizedBox(width: 4),
          Text(
            rate,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(
      {required IconData icon, required String text, required bool isDark}) {
    return Row(
      children: [
        Icon(icon,
            size: 14,
            color: isDark ? Colors.white54 : Colors.black45),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
      ],
    );
  }

  Widget _buildActionButtons(
      DoubanMovieDetails d, bool isTv, bool isDark) {
    return Row(
      children: [
        Expanded(
          child: _buildGradientButton(
            icon: Icons.play_arrow_rounded,
            label: isTv ? '立即观看' : '立即播放',
            onTap: () {
              // 跳转到选源/选集/播放器
              Navigator.of(context).pushNamed(
                '/play',
                arguments: {
                  'title': d.title,
                  'doubanId': d.id,
                  'kind': widget.kind,
                },
              );
            },
            isDark: isDark,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildOutlineButton(
            icon: Icons.bookmark_add_outlined,
            label: '收藏',
            onTap: () {},
            isDark: isDark,
          ),
        ),
      ],
    );
  }

  Widget _buildGradientButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF22C55E), Color(0xFF10B981)],
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF22C55E).withOpacity(0.35),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOutlineButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark
                ? Colors.white.withOpacity(0.18)
                : Colors.black.withOpacity(0.12),
          ),
          color: isDark
              ? Colors.white.withOpacity(0.05)
              : Colors.white.withOpacity(0.6),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                color: isDark ? Colors.white : Colors.black87, size: 20),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaTags(DoubanMovieDetails d, bool isDark) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (d.genres.isNotEmpty)
          for (final g in d.genres) _buildTag(g, TagType.genre, isDark),
        if (d.countries.isNotEmpty)
          for (final c in d.countries) _buildTag(c, TagType.country, isDark),
        if (d.languages.isNotEmpty)
          for (final l in d.languages)
            _buildTag(l, TagType.language, isDark),
        if (d.duration != null && d.duration!.isNotEmpty)
          _buildTag(d.duration!, TagType.duration, isDark),
        if (d.totalEpisodes != null && d.totalEpisodes! > 0)
          _buildTag('共${d.totalEpisodes}集', TagType.episode, isDark),
      ],
    );
  }

  Widget _buildTag(String label, TagType type, bool isDark) {
    final colors = _getTagColors(type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colors.$1.withOpacity(isDark ? 0.15 : 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colors.$1.withOpacity(isDark ? 0.4 : 0.5),
          width: 1,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: colors.$2,
        ),
      ),
    );
  }

  (Color, Color) _getTagColors(TagType type) {
    switch (type) {
      case TagType.country:
        return (const Color(0xFF3B82F6), const Color(0xFF1E40AF));
      case TagType.language:
        return (const Color(0xFF8B5CF6), const Color(0xFF6D28D9));
      case TagType.genre:
        return (const Color(0xFFEC4899), const Color(0xFFBE185D));
      case TagType.duration:
        return (const Color(0xFFF97316), const Color(0xFFC2410C));
      case TagType.episode:
        return (const Color(0xFF22C55E), const Color(0xFF15803D));
    }
  }

  Widget _buildSummary(DoubanMovieDetails d, bool isDark) {
    final summary = d.summary;
    if (summary == null || summary.isEmpty) {
      return const SizedBox.shrink();
    }
    return _buildSectionCard(
      title: '剧情简介',
      isDark: isDark,
      child: Text(
        summary,
        style: TextStyle(
          fontSize: 14,
          color: isDark ? Colors.white70 : Colors.black87,
          height: 1.7,
        ),
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required Widget child,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withOpacity(0.05)
            : Colors.white.withOpacity(0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? Colors.white.withOpacity(0.1)
              : Colors.black.withOpacity(0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 16,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF22C55E), Color(0xFF10B981)],
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _buildStaffCard(DoubanMovieDetails d, bool isDark) {
    final hasData = d.directors.isNotEmpty ||
        d.screenwriters.isNotEmpty ||
        d.actors.isNotEmpty;
    if (!hasData) return const SizedBox.shrink();
    return _buildSectionCard(
      title: '主创信息',
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (d.directors.isNotEmpty)
            _buildStaffRow('导演', d.directors, isDark),
          if (d.screenwriters.isNotEmpty)
            _buildStaffRow('编剧', d.screenwriters, isDark),
          if (d.actors.isNotEmpty)
            _buildStaffRow('主演', d.actors, isDark, maxLines: 3),
        ],
      ),
    );
  }

  Widget _buildStaffRow(
      String label, List<String> people, bool isDark,
      {int maxLines = 2}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: Text(
              '$label:',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
          ),
          Expanded(
            child: Text(
              people.join('、'),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCastTab(DoubanMovieDetails d, bool isDark) {
    if (d.actors.isEmpty) {
      return Center(
        child: Text('暂无演员信息',
            style: TextStyle(
                color: isDark ? Colors.white60 : Colors.black54)),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: d.actors
            .map((a) => _buildActorChip(a, isDark))
            .toList(),
      ),
    );
  }

  Widget _buildActorChip(String name, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withOpacity(0.05)
            : Colors.white.withOpacity(0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark
              ? Colors.white.withOpacity(0.1)
              : Colors.black.withOpacity(0.08),
        ),
      ),
      child: Text(
        name,
        style: TextStyle(
          fontSize: 13,
          color: isDark ? Colors.white : Colors.black87,
        ),
      ),
    );
  }

  Widget _buildRecommendTab(DoubanMovieDetails d, bool isDark) {
    if (d.recommends.isEmpty) {
      return Center(
        child: Text('暂无推荐',
            style: TextStyle(
                color: isDark ? Colors.white60 : Colors.black54)),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.6,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
        itemCount: d.recommends.length,
        itemBuilder: (context, i) {
          final r = d.recommends[i];
          return GestureDetector(
            onTap: () {
              Navigator.of(context).pushNamed(
                '/douban_detail',
                arguments: {
                  'id': r.id,
                  'kind': widget.kind,
                  'title': r.title,
                  'poster': r.poster,
                },
              );
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: FutureBuilder<String>(
                      future: getImageUrl(r.poster, 'douban'),
                      builder: (context, snapshot) {
                        final imageUrl = snapshot.data ?? r.poster;
                        final headers =
                            getImageRequestHeaders(imageUrl, 'douban');
                        return CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          width: double.infinity,
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
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  r.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white : Colors.black87,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCommentTab(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline,
              size: 48,
              color: isDark ? Colors.white24 : Colors.black26),
          const SizedBox(height: 12),
          Text('短评功能开发中',
              style: TextStyle(
                  color: isDark ? Colors.white60 : Colors.black54)),
        ],
      ),
    );
  }
}

enum TagType { country, language, genre, duration, episode }
