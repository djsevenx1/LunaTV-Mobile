// lib/danmaku/widgets/danmaku_panel.dart
// 弹幕搜索面板 — 对齐 SeleneTV Lth0; (danmaku dialog)
//
// SeleneTV 弹幕流程 (反编译 Lth0;/Lhi0;/Llu0;):
//   1. 点弹幕按钮 → 弹出面板, 标题显示影片名
//   2. 面板自动并行搜索所有启用的源 (danmaku_sources)
//   3. 每个源显示状态: 搜索中 / 找到N条 / 未找到
//   4. 用户点某个找到的源 → 展开该源的分集列表
//   5. 用户点某集 → 拉弹幕 → 关闭面板, 回到播放器
//   6. 全部搜索完后自动展开最优源
//
// 返回 DanmakuPanelResult (源/媒体/分集/弹幕列表), null=取消.

import 'package:flutter/material.dart';

import '../danmaku_manager.dart';
import '../danmaku_settings.dart';
import '../models/danmaku_comment.dart';
import '../models/danmaku_media.dart';

/// 弹幕面板返回结果
class DanmakuPanelResult {
  final DanmakuSource source;
  final String mediaId;
  final String mediaTitle;
  final String episodeId;
  final String episodeTitle;
  final List<DanmakuComment> comments;

  const DanmakuPanelResult({
    required this.source,
    required this.mediaId,
    required this.mediaTitle,
    required this.episodeId,
    required this.episodeTitle,
    required this.comments,
  });
}

/// 单个源的搜索状态
enum _SourceStatus { idle, searching, found, notFound, error }

class _SourceState {
  final DanmakuSource source;
  _SourceStatus status;
  List<DanmakuMedia> medias;
  List<DanmakuEpisode> episodes;
  bool episodesLoading;
  String? error;

  _SourceState({
    required this.source,
    this.status = _SourceStatus.idle,
    this.medias = const [],
    this.episodes = const [],
    this.episodesLoading = false,
    this.error,
  });
}

class DanmakuPanel extends StatefulWidget {
  final String title;
  final int? year;
  final String kind; // 'movie' | 'tv'
  final int currentEpisode; // 0-based

  const DanmakuPanel({
    super.key,
    required this.title,
    this.year,
    required this.kind,
    required this.currentEpisode,
  });

  /// 弹出弹幕搜索面板
  /// 返回 DanmakuPanelResult 或 null (用户取消)
  static Future<DanmakuPanelResult?> show(
    BuildContext context, {
    required String title,
    int? year,
    required String kind,
    required int currentEpisode,
  }) {
    return showModalBottomSheet<DanmakuPanelResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DanmakuPanel(
        title: title,
        year: year,
        kind: kind,
        currentEpisode: currentEpisode,
      ),
    );
  }

  @override
  State<DanmakuPanel> createState() => _DanmakuPanelState();
}

class _DanmakuPanelState extends State<DanmakuPanel> {
  final List<_SourceState> _sources = [];
  DanmakuSource? _expandedSource;
  bool _loadingDanmaku = false;
  bool _allDone = false;

  @override
  void initState() {
    super.initState();
    _initSearch();
  }

  Future<void> _initSearch() async {
    // 确保 DanmakuSettings 已加载
    await DanmakuSettings.instance.load();

    final enabled = DanmakuSettings.instance.enabledSources;
    if (enabled.isEmpty) {
      if (mounted) setState(() => _allDone = true);
      return;
    }

    // 初始化每个源的状态 — 全部 6 源都显示
    for (final s in enabled) {
      _sources.add(_SourceState(source: s, status: _SourceStatus.searching));
    }
    if (mounted) setState(() {});

    // 并行搜索所有启用的源 (每个有 10s 超时)
    final futures = <Future<void>>[];
    for (final st in _sources) {
      futures.add(_searchSource(st));
    }
    await Future.wait(futures);

    if (!mounted) return;
    setState(() => _allDone = true);

    // 全部搜索完后自动展开最优源 + 加载分集
    _autoSelectBest();
  }

  Future<void> _searchSource(_SourceState st) async {
    try {
      final results = await DanmakuManager.instance.searchSingleSource(
        st.source,
        widget.title,
      );
      if (!mounted) return;
      if (results.isEmpty) {
        st.status = _SourceStatus.notFound;
      } else {
        st.status = _SourceStatus.found;
        st.medias = results;
      }
      if (mounted) setState(() {});
    } catch (e) {
      st.status = _SourceStatus.error;
      st.error = e.toString();
      if (mounted) setState(() {});
    }
  }

  /// 自动选最优源 — 对应 SeleneTV 评分逻辑
  void _autoSelectBest() {
    _SourceState? best;
    int bestScore = -1;
    for (final st in _sources) {
      if (st.status != _SourceStatus.found || st.medias.isEmpty) continue;
      for (final m in st.medias) {
        var s = 0;
        if (m.title.contains(widget.title) ||
            widget.title.contains(m.title)) s += 10;
        if (widget.year != null && m.year == widget.year) s += 5;
        if (widget.kind == m.type) s += 3;
        if (s > bestScore) {
          bestScore = s;
          best = st;
        }
      }
    }
    if (best != null) {
      _expandSource(best);
    }
  }

  Future<void> _expandSource(_SourceState st) async {
    if (_expandedSource == st.source) {
      setState(() => _expandedSource = null);
      return;
    }
    setState(() => _expandedSource = st.source);
    // 如果还没加载分集, 加载之
    if (st.episodes.isEmpty && !st.episodesLoading && st.medias.isNotEmpty) {
      st.episodesLoading = true;
      setState(() {});
      final eps = await DanmakuManager.instance.getEpisodes(
        st.source,
        st.medias.first.mediaId,
      );
      if (mounted) {
        st.episodes = eps;
        st.episodesLoading = false;
        setState(() {});
      }
    }
  }

  Future<void> _selectEpisode(_SourceState st, DanmakuEpisode ep) async {
    if (_loadingDanmaku) return;
    setState(() => _loadingDanmaku = true);
    try {
      final list = await DanmakuManager.instance.loadDanmaku(
        st.source,
        ep.episodeId,
      );
      if (!mounted) return;
      final media = st.medias.isNotEmpty ? st.medias.first : null;
      Navigator.of(context).pop(DanmakuPanelResult(
        source: st.source,
        mediaId: media?.mediaId ?? '',
        mediaTitle: media?.title ?? widget.title,
        episodeId: ep.episodeId,
        episodeTitle: ep.title,
        comments: list,
      ));
    } catch (e) {
      if (mounted) {
        setState(() => _loadingDanmaku = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('弹幕加载失败: $e', style: const TextStyle(fontSize: 13)),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Color _sourceColor(DanmakuSource s) {
    switch (s) {
      case DanmakuSource.bilibili: return const Color(0xFFFB7299);
      case DanmakuSource.tencent:  return const Color(0xFFFF6B6B);
      case DanmakuSource.iqiyi:    return const Color(0xFF00BE06);
      case DanmakuSource.youku:    return const Color(0xFF1989FA);
      case DanmakuSource.mgtv:     return const Color(0xFFFF6000);
      case DanmakuSource.le:       return const Color(0xFFFF6600);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    return Container(
      constraints: BoxConstraints(maxHeight: screenHeight * 0.8),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A2E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖拽条
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 标题栏
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.subtitles, color: Color(0xFF22C55E), size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '弹幕搜索',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消', style: TextStyle(color: Colors.grey)),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF2A2A4E), height: 1),
            // 源列表 — 可滚动, 不用 shrinkWrap
            Flexible(
              child: _sources.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          '没有启用的弹幕源\n请在设置中开启',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[500], fontSize: 14),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _sources.length,
                      itemBuilder: (_, i) => _buildSourceRow(_sources[i]),
                    ),
            ),
            // 底部状态
            if (_loadingDanmaku)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF22C55E),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '加载弹幕中...',
                      style: TextStyle(color: Colors.grey[400], fontSize: 13),
                    ),
                  ],
                ),
              )
            else if (_allDone)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, size: 14, color: Colors.grey[600]),
                    const SizedBox(width: 6),
                    Text(
                      '搜索完成 · 点击源查看分集',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceRow(_SourceState st) {
    final color = _sourceColor(st.source);
    final isExpanded = _expandedSource == st.source;
    final found = st.status == _SourceStatus.found;

    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: found ? () => _expandSource(st) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                children: [
                  // 源图标/色块
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        st.source.displayName.substring(0, 1),
                        style: TextStyle(
                          color: color,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 源名 + 状态
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          st.source.displayName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        _buildStatusText(st),
                      ],
                    ),
                  ),
                  // 右侧状态图标
                  _buildStatusIcon(st),
                ],
              ),
            ),
          ),
        ),
        // 展开分集列表
        if (isExpanded && found) _buildEpisodeList(st),
        const Divider(color: Color(0xFF2A2A4E), height: 1, indent: 20, endIndent: 20),
      ],
    );
  }

  Widget _buildStatusText(_SourceState st) {
    switch (st.status) {
      case _SourceStatus.idle:
        return Text('等待中', style: TextStyle(color: Colors.grey[600], fontSize: 12));
      case _SourceStatus.searching:
        return Text('搜索中...', style: TextStyle(color: Colors.grey[500], fontSize: 12));
      case _SourceStatus.found:
        if (st.medias.length == 1) {
          return Text(
            '${st.medias.first.title}${st.episodes.isNotEmpty ? " · ${st.episodes.length}集" : ""}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFF22C55E), fontSize: 12),
          );
        }
        return Text(
          '找到 ${st.medias.length} 条结果',
          style: const TextStyle(color: Color(0xFF22C55E), fontSize: 12),
        );
      case _SourceStatus.notFound:
        return Text('未找到', style: TextStyle(color: Colors.grey[600], fontSize: 12));
      case _SourceStatus.error:
        return Text('出错', style: TextStyle(color: Colors.red[400], fontSize: 12));
    }
  }

  Widget _buildStatusIcon(_SourceState st) {
    switch (st.status) {
      case _SourceStatus.idle:
        return Icon(Icons.hourglass_empty, size: 18, color: Colors.grey[700]);
      case _SourceStatus.searching:
        return SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.grey[500],
          ),
        );
      case _SourceStatus.found:
        return const Icon(Icons.check_circle, size: 18, color: Color(0xFF22C55E));
      case _SourceStatus.notFound:
        return Icon(Icons.remove_circle_outline, size: 18, color: Colors.grey[700]);
      case _SourceStatus.error:
        return Icon(Icons.error_outline, size: 18, color: Colors.red[400]);
    }
  }

  Widget _buildEpisodeList(_SourceState st) {
    final media = st.medias.isNotEmpty ? st.medias.first : null;
    final eps = st.episodes;
    final want = widget.currentEpisode + 1;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      color: const Color(0xFF151528),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (media != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                media.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.grey[400], fontSize: 12),
              ),
            ),
          if (st.episodesLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.grey[500],
                  ),
                ),
              ),
            )
          else if (eps.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: Text(
                  '暂无分集',
                  style: TextStyle(color: Colors.grey[600], fontSize: 13),
                ),
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: eps.map((ep) {
                final isCurrent = ep.order == want ||
                    (want - 1 >= 0 && want - 1 < eps.length && eps[want - 1].episodeId == ep.episodeId);
                return GestureDetector(
                  onTap: _loadingDanmaku ? null : () => _selectEpisode(st, ep),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? const Color(0xFF22C55E)
                          : const Color(0xFF2A2A4E),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      ep.title.isEmpty ? '第${ep.order}集' : ep.title,
                      style: TextStyle(
                        color: isCurrent ? Colors.white : Colors.grey[300],
                        fontSize: 13,
                        fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}
