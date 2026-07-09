import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/release_calendar_service.dart';
import 'package:luna_tv/models/release_item.dart';
import 'package:luna_tv/utils/font_utils.dart';
import 'package:luna_tv/utils/image_url.dart';

class ReleaseCalendarScreen extends StatefulWidget {
  const ReleaseCalendarScreen({super.key});

  @override
  State<ReleaseCalendarScreen> createState() => _ReleaseCalendarScreenState();
}

class _ReleaseCalendarScreenState extends State<ReleaseCalendarScreen> {
  static const List<_FilterTab> _tabs = [
    _FilterTab(label: '全部', value: null),
    _FilterTab(label: '电影', value: 'movie'),
    _FilterTab(label: '电视剧', value: 'tv'),
    _FilterTab(label: '动漫', value: 'anime'),
  ];

  String? _selectedType;
  List<ReleaseItem> _allItems = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
    });

    final items = await ReleaseCalendarService.getReleaseCalendar(
      type: _selectedType,
    );

    if (!mounted) return;

    setState(() {
      _allItems = items;
      _isLoading = false;
    });
  }

  /// 按日期分组: 今天/明天/本周/更晚
  Map<String, List<ReleaseItem>> _groupByDate(List<ReleaseItem> items) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final weekEnd = today.add(const Duration(days: 7));

    final Map<String, List<ReleaseItem>> grouped = {
      '今天': [],
      '明天': [],
      '本周': [],
      '更晚': [],
    };

    for (final item in items) {
      try {
        final releaseDate = DateTime.parse(item.releaseDate);
        final releaseDay = DateTime(releaseDate.year, releaseDate.month, releaseDate.day);

        if (releaseDay == today) {
          grouped['今天']!.add(item);
        } else if (releaseDay == tomorrow) {
          grouped['明天']!.add(item);
        } else if (!releaseDay.isBefore(today) && releaseDay.isBefore(weekEnd)) {
          grouped['本周']!.add(item);
        } else if (releaseDay.isAfter(tomorrow.add(const Duration(days: 5))) ||
            releaseDay.isAfter(weekEnd)) {
          grouped['更晚']!.add(item);
        } else {
          grouped['更晚']!.add(item);
        }
      } catch (_) {
        grouped['更晚']!.add(item);
      }
    }

    // 移除空分组
    grouped.removeWhere((key, value) => value.isEmpty);

    return grouped;
  }

  void _onItemTap(ReleaseItem item) {
    // 跳转到豆瓣详情或播放器
    Navigator.of(context, rootNavigator: true).pushNamed(
      '/douban-detail',
      arguments: {
        'id': item.id,
        'kind': item.type,
        'title': item.title,
        'poster': item.cover,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeService = Provider.of<ThemeService>(context);
    final isDark = themeService.isDarkMode;

    return Scaffold(
      appBar: AppBar(
        title: const Text('发布日历'),
        elevation: 0,
      ),
      body: Column(
        children: [
          _buildFilterTabs(isDark),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _allItems.isEmpty
                    ? _buildEmptyState(isDark)
                    : RefreshIndicator(
                        color: const Color(0xFF27ae60),
                        onRefresh: _loadData,
                        child: _buildGroupedList(isDark),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterTabs(bool isDark) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _tabs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final tab = _tabs[index];
          final isSelected = _selectedType == tab.value;
          return GestureDetector(
            onTap: () {
              if (_selectedType != tab.value) {
                setState(() {
                  _selectedType = tab.value;
                });
                _loadData();
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF27ae60)
                    : isDark
                        ? Colors.white.withOpacity(0.1)
                        : Colors.grey.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              alignment: Alignment.center,
              child: Text(
                tab.label,
                style: FontUtils.poppins(context,
                                    fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected
                      ? Colors.white
                      : isDark
                          ? const Color(0xFFb0b0b0)
                          : const Color(0xFF7f8c8d),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildGroupedList(bool isDark) {
    final grouped = _groupByDate(_allItems);

    if (grouped.isEmpty) {
      return _buildEmptyState(isDark);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final entry in grouped.entries) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              entry.key,
              style: FontUtils.poppins(context,
                                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDark ? const Color(0xFFffffff) : const Color(0xFF2c3e50),
              ),
            ),
          ),
          ...entry.value.map((item) => _buildReleaseItem(item, isDark)),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  Widget _buildReleaseItem(ReleaseItem item, bool isDark) {
    return GestureDetector(
      onTap: () => _onItemTap(item),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.3 : 0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            // 海报缩略图
            // v2.0.10: 改用 FutureBuilder + getImageUrl 包装, 跟其他屏幕对齐
            // v2.0.6 之前用 Image.network 不传 headers → 403
            // v2.0.6 改 CachedNetworkImage + getImageRequestHeaders → headers 修好
            //   但还是直传 item.cover, 没走 buildBangumiImageUrl 包装层:
            //     - 配了 CF Worker 域名加速 → 没用上, 还是直连 lain.bgm.tv
            //     - 选 cors_proxy / cf_worker 图片源 → 没用上, 还是直连
            //   国内直连 lain.bgm.tv 经常 403/超时, 配了 worker 加速的用户
            //   会觉得 "配了 worker 也不走" — 根因就是这里没走包装
            // v2.0.10 加 getImageUrl 包装, 用户选的图片源 / worker 加速都生效
            // 关键: getImageRequestHeaders 接收包装后 URL,
            //   worker 模式 (https://xx.workers.dev/?url=...) 里
            //   检测 `bgm.tv` 用 contains 仍然能命中 (URL 里还有 lain.bgm.tv)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: item.cover.isNotEmpty
                  ? FutureBuilder<String>(
                      future: getImageUrl(item.cover, 'bangumi'),
                      builder: (context, snapshot) {
                        final imageUrl = snapshot.data ?? item.cover;
                        return CachedNetworkImage(
                          imageUrl: imageUrl,
                          width: 60,
                          height: 85,
                          fit: BoxFit.cover,
                          httpHeaders: getImageRequestHeaders(imageUrl, 'bangumi'),
                          errorWidget: (_, __, ___) => Container(
                            width: 60,
                            height: 85,
                            color: isDark
                                ? Colors.white.withOpacity(0.1)
                                : Colors.grey.withOpacity(0.2),
                            child: Icon(
                              Icons.movie_outlined,
                              color: isDark
                                  ? Colors.white.withOpacity(0.3)
                                  : Colors.grey.withOpacity(0.5),
                              size: 24,
                            ),
                          ),
                        );
                      },
                    )
                  : Container(
                      width: 60,
                      height: 85,
                      color: isDark
                          ? Colors.white.withOpacity(0.1)
                          : Colors.grey.withOpacity(0.2),
                      child: Icon(
                        Icons.movie_outlined,
                        color: isDark
                            ? Colors.white.withOpacity(0.3)
                            : Colors.grey.withOpacity(0.5),
                        size: 24,
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            // 信息区域
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: FontUtils.poppins(context,
                                            fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? const Color(0xFFffffff)
                          : const Color(0xFF2c3e50),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _buildTypeTag(item.typeDisplayName, isDark),
                      if (item.region.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          item.region,
                          style: FontUtils.sourceCodePro(
                            context,
                            fontSize: 12,
                            color: isDark
                                ? const Color(0xFFb0b0b0)
                                : const Color(0xFF7f8c8d),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        Icons.calendar_today_outlined,
                        size: 14,
                        color: const Color(0xFF27ae60),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        item.releaseDate,
                        style: FontUtils.sourceCodePro(
                          context,
                          fontSize: 12,
                          color: isDark
                              ? const Color(0xFFb0b0b0)
                              : const Color(0xFF7f8c8d),
                        ),
                      ),
                    ],
                  ),
                  if (item.description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      item.description,
                      style: FontUtils.poppins(context,
                                                fontSize: 12,
                        color: isDark
                            ? const Color(0xFFb0b0b0)
                            : const Color(0xFF7f8c8d),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeTag(String type, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF27ae60).withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        type,
        style: FontUtils.poppins(context,
                    fontSize: 11,
          fontWeight: FontWeight.w500,
          color: const Color(0xFF27ae60),
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.event_busy_outlined,
            size: 64,
            color: isDark
                ? Colors.white.withOpacity(0.3)
                : Colors.grey.withOpacity(0.4),
          ),
          const SizedBox(height: 16),
          Text(
            '暂无发布信息',
            style: FontUtils.poppins(context,
                            fontSize: 16,
              color: isDark
                  ? const Color(0xFFb0b0b0)
                  : const Color(0xFF7f8c8d),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '下拉刷新获取最新数据',
            style: FontUtils.poppins(context,
                            fontSize: 13,
              color: isDark
                  ? Colors.white.withOpacity(0.4)
                  : Colors.grey.withOpacity(0.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterTab {
  final String label;
  final String? value;

  const _FilterTab({required this.label, this.value});
}
