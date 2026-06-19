import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/play_stat_service.dart';
import 'package:luna_tv/models/play_stat.dart';
import 'package:luna_tv/utils/font_utils.dart';

class PlayStatsScreen extends StatefulWidget {
  const PlayStatsScreen({super.key});

  @override
  State<PlayStatsScreen> createState() => _PlayStatsScreenState();
}

class _PlayStatsScreenState extends State<PlayStatsScreen> {
  List<PlayStat> _stats = [];
  Map<String, dynamic> _summary = {};
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

    final stats = await PlayStatService.getPlayStats();
    final summary = await PlayStatService.getPlaySummary();

    if (!mounted) return;

    setState(() {
      _stats = stats;
      _summary = summary;
      _isLoading = false;
    });
  }

  /// 格式化总时长
  String _formatTotalDuration(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;

    if (hours > 0) {
      return '$hours小时${minutes}分钟';
    } else {
      return '$minutes分钟';
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeService = Provider.of<ThemeService>(context);
    final isDark = themeService.isDarkMode;

    return Scaffold(
      appBar: AppBar(
        title: const Text('播放统计'),
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _stats.isEmpty
              ? _buildEmptyState(isDark)
              : RefreshIndicator(
                  color: const Color(0xFF27ae60),
                  onRefresh: _loadData,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildSummaryCards(isDark),
                      const SizedBox(height: 20),
                      Text(
                        '播放排行',
                        style: FontUtils.poppins(context, 
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? const Color(0xFFffffff)
                              : const Color(0xFF2c3e50),
                        ),
                      ),
                      const SizedBox(height: 12),
                      ..._stats.map((stat) => _buildStatItem(stat, isDark)),
                    ],
                  ),
                ),
    );
  }

  Widget _buildSummaryCards(bool isDark) {
    final totalPlayCount = _summary['totalPlayCount'] as int? ?? 0;
    final totalDuration = _summary['totalDuration'] as int? ?? 0;
    final totalItems = _summary['totalItems'] as int? ?? 0;
    final mostWatchedType = _summary['mostWatchedType'] as String? ?? '暂无';

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildSummaryCard(
                icon: Icons.play_circle_outline,
                label: '总播放次数',
                value: '$totalPlayCount',
                isDark: isDark,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildSummaryCard(
                icon: Icons.schedule_outlined,
                label: '总观看时长',
                value: _formatTotalDuration(totalDuration),
                isDark: isDark,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildSummaryCard(
                icon: Icons.video_library_outlined,
                label: '观看作品数',
                value: '$totalItems',
                isDark: isDark,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildSummaryCard(
                icon: Icons.star_outline,
                label: '最常观看',
                value: mostWatchedType,
                isDark: isDark,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSummaryCard({
    required IconData icon,
    required String label,
    required String value,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: const Color(0xFF27ae60),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: FontUtils.poppins(context, 
                  fontSize: 12,
                  color: isDark
                      ? const Color(0xFFb0b0b0)
                      : const Color(0xFF7f8c8d),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: FontUtils.poppins(context, 
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: isDark
                  ? const Color(0xFFffffff)
                  : const Color(0xFF2c3e50),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(PlayStat stat, bool isDark) {
    return Container(
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
          // 封面
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: stat.cover.isNotEmpty
                ? Image.network(
                    stat.cover,
                    width: 56,
                    height: 78,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 56,
                      height: 78,
                      color: isDark
                          ? Colors.white.withOpacity(0.1)
                          : Colors.grey.withOpacity(0.2),
                      child: Icon(
                        Icons.movie_outlined,
                        color: isDark
                            ? Colors.white.withOpacity(0.3)
                            : Colors.grey.withOpacity(0.5),
                        size: 22,
                      ),
                    ),
                  )
                : Container(
                    width: 56,
                    height: 78,
                    color: isDark
                        ? Colors.white.withOpacity(0.1)
                        : Colors.grey.withOpacity(0.2),
                    child: Icon(
                      Icons.movie_outlined,
                      color: isDark
                          ? Colors.white.withOpacity(0.3)
                          : Colors.grey.withOpacity(0.5),
                      size: 22,
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
                  stat.title,
                  style: FontUtils.poppins(context, 
                    fontSize: 14,
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
                    Icon(
                      Icons.play_arrow_outlined,
                      size: 14,
                      color: const Color(0xFF27ae60),
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '${stat.playCount}次',
                      style: FontUtils.sourceCodePro(
                        fontSize: 12,
                        color: isDark
                            ? const Color(0xFFb0b0b0)
                            : const Color(0xFF7f8c8d),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(
                      Icons.access_time_outlined,
                      size: 14,
                      color: const Color(0xFF27ae60),
                    ),
                    const SizedBox(width: 2),
                    Text(
                      stat.formattedDuration,
                      style: FontUtils.sourceCodePro(
                        fontSize: 12,
                        color: isDark
                            ? const Color(0xFFb0b0b0)
                            : const Color(0xFF7f8c8d),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (stat.type.isNotEmpty) ...[
                      _buildTypeTag(stat.typeDisplayName, isDark),
                      const SizedBox(width: 8),
                    ],
                    if (stat.lastPlayTime.isNotEmpty)
                      Text(
                        '最后播放: ${_formatLastPlayTime(stat.lastPlayTime)}',
                        style: FontUtils.sourceCodePro(
                          fontSize: 11,
                          color: isDark
                              ? Colors.white.withOpacity(0.4)
                              : Colors.grey.withOpacity(0.6),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypeTag(String type, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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

  /// 格式化最后播放时间戳
  String _formatLastPlayTime(String timestamp) {
    try {
      final seconds = int.tryParse(timestamp) ?? 0;
      if (seconds == 0) return timestamp;

      final dateTime = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
      final now = DateTime.now();
      final diff = now.difference(dateTime);

      if (diff.inDays == 0) {
        if (diff.inHours == 0) {
          return '${diff.inMinutes}分钟前';
        }
        return '${diff.inHours}小时前';
      } else if (diff.inDays == 1) {
        return '昨天';
      } else if (diff.inDays < 7) {
        return '${diff.inDays}天前';
      } else {
        return '${dateTime.month}-${dateTime.day}';
      }
    } catch (_) {
      return timestamp;
    }
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bar_chart_outlined,
            size: 64,
            color: isDark
                ? Colors.white.withOpacity(0.3)
                : Colors.grey.withOpacity(0.4),
          ),
          const SizedBox(height: 16),
          Text(
            '暂无播放记录',
            style: FontUtils.poppins(context, 
              fontSize: 16,
              color: isDark
                  ? const Color(0xFFb0b0b0)
                  : const Color(0xFF7f8c8d),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '观看影视内容后这里会显示统计信息',
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
