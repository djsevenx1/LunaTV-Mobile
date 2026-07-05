import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/log_service.dart';

/// 调试日志查看界面
///
/// v1.0.62 新增. 实时显示 LogService 里的日志, 用于排查 resume / seek
/// / buffering 等问题. 入口: 播放器长按标题.
class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  late final StreamSubscription<List<LogEntry>> _sub;
  List<LogEntry> _entries = LogService.instance.entries;
  final _scrollController = ScrollController();
  bool _autoScroll = true;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _sub = LogService.instance.stream.listen((list) {
      if (!mounted) return;
      setState(() => _entries = list);
      if (_autoScroll && _scrollController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  List<LogEntry> get _filtered {
    if (_filter.isEmpty) return _entries;
    final lower = _filter.toLowerCase();
    return _entries
        .where((e) =>
            e.tag.toLowerCase().contains(lower) ||
            e.message.toLowerCase().contains(lower))
        .toList();
  }

  Color _colorFor(LogLevel level) {
    switch (level) {
      case LogLevel.info:
        return Colors.grey[300]!;
      case LogLevel.warn:
        return Colors.orange[300]!;
      case LogLevel.error:
        return Colors.red[300]!;
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _filtered;
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF222222),
        title: const Text('调试日志', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.vertical_align_top : Icons.vertical_align_center,
              color: Colors.white,
            ),
            tooltip: _autoScroll ? '自动滚动 开' : '自动滚动 关',
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          IconButton(
            icon: const Icon(Icons.copy, color: Colors.white),
            tooltip: '复制全部',
            onPressed: () async {
              final buf = StringBuffer();
              for (final e in entries) {
                buf.writeln('[${e.formattedTime}] [${e.levelLabel}] '
                    '[${e.tag}] ${e.message}');
              }
              await Clipboard.setData(ClipboardData(text: buf.toString()));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已复制到剪贴板'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.white),
            tooltip: '清空',
            onPressed: () {
              LogService.instance.clear();
              setState(() => _entries = []);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: '过滤 (tag / 关键词)',
                hintStyle: TextStyle(color: Colors.grey[500], fontSize: 13),
                prefixIcon:
                    Icon(Icons.search, color: Colors.grey[500], size: 18),
                filled: true,
                fillColor: const Color(0xFF2A2A2A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: _filter.isEmpty
                    ? null
                    : IconButton(
                        icon:
                            Icon(Icons.close, color: Colors.grey[500], size: 18),
                        onPressed: () => setState(() => _filter = ''),
                      ),
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(
                  '${entries.length} 条${_filter.isNotEmpty ? " (过滤后)" : ""} · '
                  '总 ${LogService.instance.entries.length} 条',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
                const Spacer(),
                Text(
                  '蓝色 = 播放器事件',
                  style: TextStyle(color: Colors.blue[300], fontSize: 11),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      _filter.isEmpty ? '暂无日志' : '无匹配项',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: entries.length,
                    itemBuilder: (_, i) {
                      final e = entries[i];
                      final isPlayer = e.tag.startsWith('Player');
                      return Container(
                        color: i.isEven
                            ? const Color(0xFF1F1F1F)
                            : const Color(0xFF1A1A1A),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        child: SelectableText.rich(
                          TextSpan(
                            style: const TextStyle(
                                fontSize: 11, fontFamily: 'monospace'),
                            children: [
                              TextSpan(
                                text: e.formattedTime,
                                style: TextStyle(color: Colors.grey[600]),
                              ),
                              TextSpan(text: ' '),
                              TextSpan(
                                text: '[${e.levelLabel}]',
                                style: TextStyle(color: _colorFor(e.level)),
                              ),
                              TextSpan(
                                text: ' [${e.tag}]',
                                style: TextStyle(
                                    color: isPlayer
                                        ? Colors.blue[300]
                                        : Colors.grey[500]),
                              ),
                              TextSpan(
                                text: ' ${e.message}',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ],
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
