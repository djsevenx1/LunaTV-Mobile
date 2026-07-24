// lib/danmaku/widgets/danmaku_control_sheet.dart
// 弹幕控制面板 — 点击弹幕按钮弹出
//
// 结构:
//   ┌─────────────────────────────┐
//   │  弹幕               [开关]  │  ← 顶部: 标题 + Switch
//   ├─────────────────────────────┤
//   │  当前: 爱奇艺 · 千香 · 312条 │  ← 当前源状态 (开关 ON 时)
//   ├─────────────────────────────┤
//   │  弹幕源                     │
//   │  ✓ 爱奇艺  千香             │  ← 源列表 (可手动切换)
//   │    优酷    千香             │
//   │    哔哩哔哩 千香            │
//   ├─────────────────────────────┤
//   │  ⚙ 弹幕设置                │  ← 底部: 渲染设置入口
//   └─────────────────────────────┘
//
// 交互:
//   - 打开开关 → 自动搜索 6 源 → 评分选最优 → 拉弹幕 → 显示
//   - 手动点源 → 切换到该源 → 拉弹幕 → 显示
//   - 关闭开关 → 隐藏弹幕
//   - 点设置 → 打开 DanmakuSettingsSheet (透明度/速度/字体等)

import 'package:flutter/material.dart';

import '../danmaku_manager.dart';
import '../models/danmaku_comment.dart';
import '../models/danmaku_media.dart';

class DanmakuControlSheet extends StatefulWidget {
  final bool initiallyEnabled;
  final DanmakuSource? currentSource;
  final String? currentMediaId;
  final String? currentMediaTitle;
  final String? currentSourceTitle;
  final int danmakuCount;

  // 视频信息 (用于搜索)
  final String videoTitle;
  final int? year;
  final String kind;
  final int currentEpisodeIndex;

  // 回调
  final void Function(
    DanmakuSource source,
    String mediaId,
    String mediaTitle,
    String sourceTitle,
    List<DanmakuComment> comments,
  ) onDanmakuLoaded;

  final VoidCallback onDanmakuDisabled;
  final VoidCallback onOpenSettings;

  const DanmakuControlSheet({
    super.key,
    required this.initiallyEnabled,
    this.currentSource,
    this.currentMediaId,
    this.currentMediaTitle,
    this.currentSourceTitle,
    this.danmakuCount = 0,
    required this.videoTitle,
    this.year,
    required this.kind,
    required this.currentEpisodeIndex,
    required this.onDanmakuLoaded,
    required this.onDanmakuDisabled,
    required this.onOpenSettings,
  });

  static Future<void> show(
    BuildContext context, {
    required bool initiallyEnabled,
    DanmakuSource? currentSource,
    String? currentMediaId,
    String? currentMediaTitle,
    String? currentSourceTitle,
    int danmakuCount = 0,
    required String videoTitle,
    int? year,
    required String kind,
    required int currentEpisodeIndex,
    required void Function(
      DanmakuSource source,
      String mediaId,
      String mediaTitle,
      String sourceTitle,
      List<DanmakuComment> comments,
    ) onDanmakuLoaded,
    required VoidCallback onDanmakuDisabled,
    required VoidCallback onOpenSettings,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DanmakuControlSheet(
        initiallyEnabled: initiallyEnabled,
        currentSource: currentSource,
        currentMediaId: currentMediaId,
        currentMediaTitle: currentMediaTitle,
        currentSourceTitle: currentSourceTitle,
        danmakuCount: danmakuCount,
        videoTitle: videoTitle,
        year: year,
        kind: kind,
        currentEpisodeIndex: currentEpisodeIndex,
        onDanmakuLoaded: onDanmakuLoaded,
        onDanmakuDisabled: onDanmakuDisabled,
        onOpenSettings: onOpenSettings,
      ),
    );
  }

  @override
  State<DanmakuControlSheet> createState() => _DanmakuControlSheetState();
}

class _DanmakuControlSheetState extends State<DanmakuControlSheet> {
  bool _enabled = false;
  bool _loading = false;
  String? _statusMsg;

  // 搜索结果
  List<DanmakuMedia> _searchResults = const [];
  // 当前选中的源
  DanmakuSource? _selSource;
  String? _selMediaId;
  String? _selMediaTitle;
  int _danmakuCount = 0;

  // 每个源的弹幕加载状态 (切源时显示 loading)
  DanmakuSource? _loadingSource;

  @override
  void initState() {
    super.initState();
    _enabled = widget.initiallyEnabled;
    _selSource = widget.currentSource;
    _selMediaId = widget.currentMediaId;
    _selMediaTitle = widget.currentMediaTitle;
    _danmakuCount = widget.danmakuCount;
    // 如果已开启, 自动搜索填充源列表
    if (_enabled) {
      _doSearch();
    }
  }

  Future<void> _doSearch() async {
    final title = widget.videoTitle.trim();
    if (title.isEmpty) {
      setState(() => _statusMsg = '标题为空');
      return;
    }
    setState(() {
      _loading = true;
      _statusMsg = null;
    });
    try {
      final results = await DanmakuManager.instance.searchByTitle(title);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _loading = false;
      });
      // 如果还没选过源, 自动选最优
      if (_selSource == null && results.isNotEmpty) {
        _autoSelectBest(results);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _statusMsg = '搜索失败';
      });
    }
  }

  DanmakuEpisode? _pickEpisode(List<DanmakuEpisode> eps, int wantOrder, String kind) {
    if (eps.isEmpty) return null;
    for (final e in eps) {
      if (e.order == wantOrder) return e;
    }
    if (wantOrder - 1 >= 0 && wantOrder - 1 < eps.length) {
      return eps[wantOrder - 1];
    }
    if (kind == 'movie') return eps.first;
    return eps.first;
  }

  // 评分选最优 + 自动拉弹幕
  Future<void> _autoSelectBest(List<DanmakuMedia> results) async {
    DanmakuMedia? best;
    int bestScore = -1;
    for (final m in results) {
      var s = 0;
      if (m.title.contains(widget.videoTitle) ||
          widget.videoTitle.contains(m.title)) s += 10;
      if (widget.year != null && m.year == widget.year) s += 5;
      if (widget.kind == m.type) s += 3;
      if (s > bestScore) {
        bestScore = s;
        best = m;
      }
    }
    if (best == null) {
      setState(() => _statusMsg = '未找到匹配的弹幕');
      return;
    }
    await _loadFromSource(best);
  }

  // 从指定源拉弹幕
  Future<void> _loadFromSource(DanmakuMedia media) async {
    setState(() {
      _loadingSource = media.source;
      _statusMsg = null;
    });
    try {
      final eps = await DanmakuManager.instance.getEpisodes(
        media.source,
        media.mediaId,
      );
      if (!mounted) return;
      if (eps.isEmpty) {
        setState(() {
          _loadingSource = null;
          _statusMsg = '${media.source.displayName} 无分集信息';
        });
        return;
      }
      final ep = _pickEpisode(eps, widget.currentEpisodeIndex + 1, widget.kind);
      if (ep == null) {
        setState(() {
          _loadingSource = null;
          _statusMsg = '无法匹配当前集';
        });
        return;
      }
      final list = await DanmakuManager.instance.loadDanmaku(
        media.source,
        ep.episodeId,
      );
      if (!mounted) return;
      final sourceTitle =
          '${media.source.displayName} · ${media.title} · ${ep.title}';
      setState(() {
        _selSource = media.source;
        _selMediaId = media.mediaId;
        _selMediaTitle = media.title;
        _danmakuCount = list.length;
        _loadingSource = null;
      });
      if (list.isEmpty) {
        setState(() => _statusMsg = '${media.source.displayName} 暂无弹幕');
      }
      // 通知 player 更新状态
      widget.onDanmakuLoaded(
        media.source,
        media.mediaId,
        media.title,
        sourceTitle,
        list,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingSource = null;
        _statusMsg = '加载失败';
      });
    }
  }

  void _onToggleChanged(bool v) {
    if (v) {
      // 开启: 搜索 + 自动选最优
      setState(() {
        _enabled = true;
        _statusMsg = null;
      });
      _doSearch();
    } else {
      // 关闭
      setState(() {
        _enabled = false;
        _selSource = null;
        _selMediaId = null;
        _selMediaTitle = null;
        _danmakuCount = 0;
        _statusMsg = null;
      });
      widget.onDanmakuDisabled();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.65,
      ),
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
            // 标题栏 + 开关
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.subtitles,
                      color: Color(0xFF22C55E), size: 22),
                  const SizedBox(width: 8),
                  const Text(
                    '弹幕',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  // 弹幕设置按钮
                  if (_enabled)
                    IconButton(
                      icon: const Icon(Icons.tune,
                          color: Colors.white70, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 36, minHeight: 36),
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onOpenSettings();
                      },
                    ),
                  const SizedBox(width: 4),
                  // 开关
                  Switch(
                    value: _enabled,
                    activeColor: const Color(0xFF22C55E),
                    onChanged: _onToggleChanged,
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF2A2A4E), height: 1),
            // 内容区
            Flexible(
              child: _enabled
                  ? _buildEnabledContent()
                  : _buildDisabledHint(),
            ),
          ],
        ),
      ),
    );
  }

  // 关闭状态提示
  Widget _buildDisabledHint() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 32, horizontal: 20),
      child: Center(
        child: Text(
          '打开开关后自动搜索弹幕源',
          style: TextStyle(color: Colors.grey, fontSize: 14),
        ),
      ),
    );
  }

  // 开启状态: 当前源信息 + 源列表
  Widget _buildEnabledContent() {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // 当前源状态
        if (_selSource != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.check_circle,
                    color: const Color(0xFF22C55E), size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '$_selMediaTitle · $_danmakuCount条',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_loadingSource == _selSource)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF22C55E),
                    ),
                  ),
              ],
            ),
          ),
        // 状态消息 (错误/提示)
        if (_statusMsg != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Text(
              _statusMsg!,
              style: TextStyle(color: Colors.orange[300], fontSize: 13),
            ),
          ),
        // 搜索中
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF22C55E),
                ),
              ),
            ),
          ),
        // 源列表
        if (_searchResults.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(left: 20, top: 8, bottom: 4),
            child: Text(
              '弹幕源',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          ..._searchResults.map((m) => _buildSourceTile(m)),
        ],
        // 搜索完毕但无结果
        if (!_loading && _searchResults.isEmpty && _statusMsg == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            child: Text(
              '未找到弹幕源',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  // 单个源 tile
  Widget _buildSourceTile(DanmakuMedia media) {
    final isSelected = _selSource == media.source &&
        _selMediaId == media.mediaId;
    final isLoading = _loadingSource == media.source;
    return InkWell(
      onTap: isLoading ? null : () => _loadFromSource(media),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            // 选中标记
            SizedBox(
              width: 20,
              child: isSelected
                  ? const Icon(Icons.check,
                      color: Color(0xFF22C55E), size: 18)
                  : null,
            ),
            const SizedBox(width: 4),
            // 源名
            Text(
              media.source.displayName,
              style: TextStyle(
                color: isSelected ? const Color(0xFF22C55E) : Colors.white,
                fontSize: 15,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(width: 8),
            // 媒体标题
            Expanded(
              child: Text(
                media.title,
                style: TextStyle(
                  color: Colors.grey[400],
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // 年份
            if (media.year != null)
              Text(
                '${media.year}',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
              ),
            // loading
            if (isLoading)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF22C55E),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
