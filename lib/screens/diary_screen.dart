import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/theme_service.dart';

/// v2.0.99.2: 应用内「日记」页面 — 跟 v2.0.95 失败 SnackBar 错误提示互补.
///   v2.0.95 失败时弹 SnackBar (3 秒消失), 用户来不及看细节.
///   v2.0.99.2 把全流程写进 DiaryService, 用户点开「日记」页能看历史, 排查
///   「TMDB 大背景没出来为啥」. 跟 v2.0.91 删的「log UI」区别: 那个是开发者
///   log 实时浮层 ([VideoProxy] xxx 一直滚, 乱), 这次是日记独立页面
///   (按时间序, 用户主动点开, 不打扰, 类似 dev console).
///
/// UX:
///   - AppBar 标题「日记」+ 右侧「清空」+「复制」按钮
///   - 顶部 chip 显示「共 N 条 / 容量 500」+ 类别筛选 (默认全显示)
///   - 主体 ListView 反向滚动 (新条目在底部, 类似聊天记录), 自动滚到底
///   - 空状态: 「暂无日记」+ 副标题「去详情页看剧, 失败时会自动记录」
class DiaryScreen extends StatefulWidget {
  const DiaryScreen({super.key});

  @override
  State<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends State<DiaryScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空日记'),
        content: const Text('确认清空所有日记? 这步不可撤销.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFef4444)),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      DiaryService.clear();
      if (mounted) setState(() {});
    }
  }

  Future<void> _copyAll() async {
    final all = DiaryService.getAll();
    if (all.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('日记为空, 没什么可复制的')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: all.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${all.length} 条日记到剪贴板')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final entries = DiaryService.getAll();

    return Scaffold(
      appBar: AppBar(
        title: const Text('日记'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.copy),
            tooltip: '复制全部',
            onPressed: _copyAll,
          ),
          IconButton(
            icon: const Icon(LucideIcons.trash2),
            tooltip: '清空',
            onPressed: _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          // 顶部状态条
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: isDark
                ? const Color(0xFF1f2937)
                : const Color(0xFFf3f4f6),
            child: Row(
              children: [
                Icon(
                  LucideIcons.fileText,
                  size: 16,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
                const SizedBox(width: 8),
                Text(
                  '共 ${entries.length} 条 · 容量上限 500 条',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
                const Spacer(),
                Text(
                  '退出 app 自动清空',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
              ],
            ),
          ),
          // 主体列表
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.fileText,
                          size: 64,
                          color: isDark ? Colors.white24 : Colors.black26,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '暂无日记',
                          style: TextStyle(
                            fontSize: 16,
                            color: isDark ? Colors.white60 : Colors.black54,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '去详情页看剧, 失败时会自动记录',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white38 : Colors.black38,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    itemCount: entries.length,
                    itemBuilder: (ctx, i) {
                      final entry = entries[i];
                      // 高亮 [TMDB] 失败
                      final isTmdbError = entry.contains('[TMDB]') &&
                          (entry.contains('error') ||
                              entry.contains('no result') ||
                              entry.contains('no backdrop') ||
                              entry.contains('skip'));
                      final isNetworkError =
                          entry.contains('[Network]') || entry.contains('timeout');
                      Color? bg;
                      if (isTmdbError) {
                        bg = isDark
                            ? const Color(0xFF4a1a1a)
                            : const Color(0xFFfee2e2);
                      } else if (isNetworkError) {
                        bg = isDark
                            ? const Color(0xFF4a3a1a)
                            : const Color(0xFFfef3c7);
                      }
                      return Container(
                        margin: const EdgeInsets.only(bottom: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          entry,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.4,
                            color: isDark
                                ? Colors.white.withOpacity(0.9)
                                : Colors.black87,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
