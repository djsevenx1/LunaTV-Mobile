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
/// v2.1.22: 日记增强
///   - 顶部加分类 chip 筛选 (全部 / TMDB / Bangumi / 视频 / 其它), 点击切换
///   - 单条长按弹菜单 (复制单条 / 删除单条)
///   - 顶部状态条实时显示当前容量上限 + 持久化状态
///
/// UX:
///   - AppBar 标题「日记」+ 右侧「清空」+「复制」按钮
///   - 顶部 chip 显示「共 N 条 / 容量 N 条」+ 5 个分类 chip
///   - 主体 ListView 反向滚动 (新条目在底部, 类似聊天记录), 自动滚到底
///   - 空状态: 「暂无日记」+ 副标题「去详情页看剧, 失败时会自动记录」
class DiaryScreen extends StatefulWidget {
  const DiaryScreen({super.key});

  @override
  State<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends State<DiaryScreen> {
  final ScrollController _scrollController = ScrollController();

  // v2.1.22: 当前选中的分类 chip (null = 全部)
  String? _filter;

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
      await DiaryService.clear();
      if (mounted) setState(() {});
    }
  }

  Future<void> _copyAll() async {
    // v2.1.22+: 复制时也要遵守当前分类筛选 — 之前 getAll() 直接全量复制,
    //   选「视频」chip 仍把所有分类都拷了, 用户反馈。
    final all = DiaryService.getAll();
    final entries = _filtered(all);
    if (entries.isEmpty) {
      final hint = _filter == null
          ? '日记为空, 没什么可复制的'
          : '「$_filter」分类下没有日记, 换个分类或先点「全部」';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(hint)),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: entries.join('\n')));
    if (!mounted) return;
    final tag = _filter == null ? '' : '「$_filter」分类 ';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 $tag${entries.length} 条日记到剪贴板')),
    );
  }

  // v2.1.22: 单条长按菜单 — 复制 / 删除
  Future<void> _onEntryLongPress(String entry) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.copy),
              title: const Text('复制这条'),
              onTap: () => Navigator.of(ctx).pop('copy'),
            ),
            ListTile(
              leading: const Icon(LucideIcons.trash2,
                  color: Color(0xFFef4444)),
              title: const Text('删除这条',
                  style: TextStyle(color: Color(0xFFef4444))),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
            ListTile(
              leading: const Icon(LucideIcons.x),
              title: const Text('取消'),
              onTap: () => Navigator.of(ctx).pop(null),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: entry));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制这条日记到剪贴板')),
      );
    } else if (action == 'delete') {
      // v2.1.22: 单条删除 — DiaryService 没有单条删 API, 直接操作 _entries 不行
      // (那是私有). 加个单条删方法最干净, 这次就在服务里加.
      await DiaryService.removeEntry(entry);
      if (mounted) setState(() {});
    }
  }

  // v2.1.24: 分类识别 — v2.1.22 写错了, 只看第一个 [..] 块 (e.g. [09:48:08]),
  // 而日记格式是 "[HH:mm:ss] [分类] 描述", 第一个块是时间戳, 不是分类 tag.
  // 用户装 v2.1.22 后 122 条全归"其它", 因为所有 [..] 块都是 [HH:mm:ss] 形式.
  // 修法: allMatches 拿所有 [..] 块, 跳过 HH:MM:SS 格式的, 用剩下的当 tag.
  String _categoryOf(String entry) {
    final matches = RegExp(r'\[([^\]]+)\]').allMatches(entry);
    String? tag;
    for (final m in matches) {
      final inner = m.group(1)!;
      // 跳过时间戳 (HH:mm:ss)
      if (RegExp(r'^\d{2}:\d{2}:\d{2}$').hasMatch(inner)) continue;
      tag = inner.toLowerCase();
      break;
    }
    if (tag == null) return '其它';
    if (tag.startsWith('tmdb')) return 'TMDB';
    if (tag.startsWith('bangumi')) return 'Bangumi';
    if (tag.startsWith('network') ||
        tag.startsWith('ssl') ||
        tag.startsWith('tls') ||
        tag.startsWith('connect') ||
        entry.contains('网络') ||
        entry.contains('timeout') ||
        entry.contains('handshake') ||
        entry.contains('SSLV3') ||
        entry.contains('ECONN')) {
      return '网络';
    }
    if (tag.startsWith('player') ||
        tag.startsWith('ad_reset') ||
        tag.startsWith('history') ||
        tag.startsWith('douban') ||
        tag.startsWith('video') ||
        tag.startsWith('videoproxy')) {
      return '视频';
    }
    return '其它';
  }

  List<String> _filtered(List<String> all) {
    if (_filter == null) return all;
    return all.where((e) => _categoryOf(e) == _filter).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final all = DiaryService.getAll();
    final entries = _filtered(all);

    // 统计各分类条数
    final counts = <String, int>{
      'TMDB': 0,
      'Bangumi': 0,
      '网络': 0,
      '视频': 0,
      '其它': 0,
    };
    for (final e in all) {
      final c = _categoryOf(e);
      counts[c] = (counts[c] ?? 0) + 1;
    }

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
          // v2.1.22: 顶部状态条 — 实时显示容量 + 持久化状态
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
                Expanded(
                  child: Text(
                    '共 ${all.length} 条 · 容量上限 ${DiaryService.maxEntries} 条'
                    '${DiaryService.persist ? " · 持久化" : ""}',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  DiaryService.clearOnExit ? '退出 app 清空' : '退出保留',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
              ],
            ),
          ),
          // v2.1.22: 分类 chip 行
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _filterChip('全部', _filter == null, all.length, null),
                  const SizedBox(width: 6),
                  _filterChip('TMDB', _filter == 'TMDB', counts['TMDB'] ?? 0, 'TMDB'),
                  const SizedBox(width: 6),
                  _filterChip('Bangumi', _filter == 'Bangumi', counts['Bangumi'] ?? 0, 'Bangumi'),
                  const SizedBox(width: 6),
                  _filterChip('网络', _filter == '网络', counts['网络'] ?? 0, '网络'),
                  const SizedBox(width: 6),
                  _filterChip('视频', _filter == '视频', counts['视频'] ?? 0, '视频'),
                  const SizedBox(width: 6),
                  _filterChip('其它', _filter == '其它', counts['其它'] ?? 0, '其它'),
                ],
              ),
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
                          _filter == null ? '暂无日记' : '「$_filter」分类下没有日记',
                          style: TextStyle(
                            fontSize: 16,
                            color: isDark ? Colors.white60 : Colors.black54,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _filter == null
                              ? '去详情页看剧, 失败时会自动记录'
                              : '换其他分类看看, 或点「全部」',
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
                              entry.contains('skip') ||
                              entry.contains('全挂'));
                      final isNetworkError = _categoryOf(entry) == '网络' ||
                          entry.contains('timeout') ||
                          entry.contains('handshake') ||
                          entry.contains('SSLV3') ||
                          entry.contains('SocketException') ||
                          entry.contains('ECONN');
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
                      return InkWell(
                        onLongPress: () => _onEntryLongPress(entry),
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
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
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // v2.1.22: 单个分类 chip
  Widget _filterChip(String label, bool selected, int count, String? filter) {
    return FilterChip(
      label: Text('$label · $count'),
      selected: selected,
      onSelected: (v) {
        setState(() {
          _filter = v ? filter : null;
        });
      },
    );
  }
}
