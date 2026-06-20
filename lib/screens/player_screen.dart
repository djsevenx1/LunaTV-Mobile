import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/models/search_result.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:provider/provider.dart';

/// LunaTV Web 风格播放详情页
///
/// 阶段:
///   1. detail       - 海报 + 标题 + 元信息 + 源/集数面板 + 播放按钮
///   2. playing      - 全屏视频播放
///
/// 源面板: 显示所有源、测速 (head 请求)、自动选中最低延迟
/// 集数面板: 6列网格,显示集数标题
class PlayerScreen extends StatefulWidget {
  final VideoInfo videoInfo;
  final String? preferredSource;

  const PlayerScreen({
    super.key,
    required this.videoInfo,
    this.preferredSource,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // 播放器
  late final Player _player;
  late final VideoController _controller;

  // 状态
  String _phase = 'detail'; // detail | playing
  bool _isBuffering = false;
  String? _error;

  // 多源结果
  List<SearchResult> _sourceResults = [];
  bool _sourcesLoading = true;
  final Map<String, int> _pingCache = {};
  final Map<String, PingState> _pingState = {};
  String? _autoSelectedSource;

  // 当前选中的源 / 集
  SearchResult? _selectedSource;
  int _currentEpisodeIndex = 0;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    // 播放结束自动播下一集
    _player.stream.playing.listen((playing) {
      if (!playing && _phase == 'playing') {
        Future.delayed(const Duration(milliseconds: 800), () {
          if (!mounted) return;
          final src = _selectedSource;
          if (src != null && _currentEpisodeIndex < src.episodes.length - 1) {
            _playEpisode(_currentEpisodeIndex + 1);
          }
        });
      }
    });
    _loadSources();
  }

  @override
  void dispose() {
    _player.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  /// 加载多源并自动测速
  Future<void> _loadSources() async {
    final title = widget.videoInfo.searchTitle.isNotEmpty
        ? widget.videoInfo.searchTitle
        : widget.videoInfo.title;
    if (title.isEmpty) {
      setState(() {
        _sourcesLoading = false;
        _error = '视频标题为空,无法搜索';
      });
      return;
    }

    setState(() {
      _sourcesLoading = true;
      _error = null;
    });

    try {
      final results = await ApiService.fetchSourcesData(title);
      if (!mounted) return;
      if (results.isEmpty) {
        setState(() {
          _sourceResults = [];
          _sourcesLoading = false;
          _error = '没有找到可用的播放源';
        });
        return;
      }
      setState(() {
        _sourceResults = results;
        _sourcesLoading = false;
      });

      // 默认选第一个
      SearchResult toSelect = results.first;
      if (widget.preferredSource != null && widget.preferredSource!.isNotEmpty) {
        for (final r in results) {
          if (r.source == widget.preferredSource) {
            toSelect = r;
            break;
          }
        }
      }
      _selectSource(toSelect);

      // 启动自动测速
      _testAllSourcesInBackground();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sourcesLoading = false;
        _error = '搜索失败: $e';
      });
    }
  }

  void _selectSource(SearchResult result) {
    setState(() {
      _selectedSource = result;
      _currentEpisodeIndex = 0;
    });
  }

  /// 后台测速所有源
  Future<void> _testAllSourcesInBackground() async {
    for (final s in _sourceResults) {
      if (!mounted) return;
      if (s.episodes.isEmpty) continue;
      _pingState[s.source] = PingState.testing;
      if (mounted) setState(() {});
      final ms = await _pingSource(s.episodes.first);
      if (!mounted) return;
      _pingState[s.source] = _stateFromMs(ms);
    }
    if (mounted) setState(() {});

    // 自动选最快源 (除非用户已经主动选过)
    if (_autoSelectedSource == null && _sourceResults.isNotEmpty) {
      int bestMs = 1 << 30;
      String? bestSource;
      for (final s in _sourceResults) {
        final ms = _pingCache[s.episodes.isNotEmpty ? s.episodes.first : ''];
        if (ms != null && ms < bestMs) {
          bestMs = ms;
          bestSource = s.source;
        }
      }
      if (bestSource != null) {
        _autoSelectedSource = bestSource;
        final src = _sourceResults.firstWhere((s) => s.source == bestSource);
        if (_selectedSource?.source != bestSource) {
          _selectSource(src);
        }
      }
    }
  }

  PingState _stateFromMs(int ms) {
    if (ms >= 3000) return PingState.unavailable;
    if (ms < 500) return PingState.fast;
    if (ms < 1500) return PingState.medium;
    return PingState.slow;
  }

  Future<int> _pingSource(String url) async {
    if (_pingCache.containsKey(url)) return _pingCache[url]!;
    final start = DateTime.now();
    try {
      final req = http.Request('HEAD', Uri.parse(url))
        ..followRedirects = true
        ..maxRedirects = 3;
      final response =
          await req.send().timeout(const Duration(seconds: 3));
      try {
        await response.stream.drain();
      } catch (_) {}
    } catch (_) {}
    final ms = DateTime.now().difference(start).inMilliseconds;
    _pingCache[url] = ms;
    return ms;
  }

  /// 播放指定集数
  Future<void> _playEpisode(int index) async {
    final source = _selectedSource;
    if (source == null) return;
    if (index < 0 || index >= source.episodes.length) return;
    final url = source.episodes[index];
    if (url.isEmpty) return;

    setState(() {
      _currentEpisodeIndex = index;
      _isBuffering = true;
      _phase = 'playing';
    });

    try {
      await _player.stop();
      await _player.open(Media(url));
      if (!mounted) return;
      setState(() => _isBuffering = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isBuffering = false;
        _error = '播放失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, theme, _) {
        final isDark = theme.isDarkMode;
        return PopScope(
          canPop: _phase == 'detail',
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && _phase == 'playing') {
              setState(() {
                _phase = 'detail';
              });
            }
          },
          child: Scaffold(
            backgroundColor:
                isDark ? const Color(0xFF0F1117) : const Color(0xFFF5F7F5),
            body: SafeArea(
              child: _phase == 'playing'
                  ? _buildPlayingView(isDark)
                  : _buildDetailView(isDark),
            ),
          ),
        );
      },
    );
  }

  // ================= 详情视图 =================

  Widget _buildDetailView(bool isDark) {
    return Column(
      children: [
        // 顶部 bar
        _buildTopBar(isDark),
        // 内容滚动
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 海报 + 信息头部
                _buildPosterHeader(isDark),
                // 源 + 测速
                _buildSourceSection(isDark),
                // 集数
                _buildEpisodeSection(isDark),
                const SizedBox(height: 100),
              ],
            ),
          ),
        ),
        // 底部播放按钮
        _buildBottomPlayButton(isDark),
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
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Text(
              '选源播放',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPosterHeader(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 海报
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 110,
              height: 150,
              child: widget.videoInfo.cover.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: widget.videoInfo.cover,
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
                        child: const Icon(Icons.movie_outlined,
                            color: Colors.grey, size: 40),
                      ),
                    )
                  : Container(
                      color: isDark
                          ? const Color(0xFF1F2937)
                          : const Color(0xFFE5E7EB),
                      child: const Icon(Icons.movie_outlined,
                          color: Colors.grey, size: 40),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          // 标题 + 元信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.videoInfo.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : Colors.black,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (widget.videoInfo.year.isNotEmpty)
                      _buildTag(widget.videoInfo.year, isDark),
                    if (widget.videoInfo.rate != null &&
                        widget.videoInfo.rate!.isNotEmpty)
                      _buildRatingTag(widget.videoInfo.rate!),
                  ],
                ),
                if (widget.videoInfo.sourceName.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.cloud_outlined,
                          size: 12,
                          color:
                              isDark ? Colors.white60 : Colors.black54),
                      const SizedBox(width: 4),
                      Text(
                        '默认: ${widget.videoInfo.sourceName}',
                        style: TextStyle(
                          fontSize: 11,
                          color:
                              isDark ? Colors.white60 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTag(String text, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isDark ? Colors.white12 : Colors.black12,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: isDark ? Colors.white70 : Colors.black87,
        ),
      ),
    );
  }

  Widget _buildRatingTag(String rate) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFB923C), Color(0xFFF59E0B)],
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, size: 11, color: Colors.white),
          const SizedBox(width: 2),
          Text(
            rate,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 源选择 ----------

  Widget _buildSourceSection(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildSectionTitle('播放源', isDark),
              const Spacer(),
              if (_sourcesLoading)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Color(0xFF22C55E),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_sourceResults.isEmpty && !_sourcesLoading)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error ?? '暂无源',
                style: TextStyle(
                  color: isDark ? Colors.white60 : Colors.black54,
                  fontSize: 12,
                ),
              ),
            )
          else
            Column(
              children: _sourceResults
                  .map((s) => _buildSourceTile(s, isDark))
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildSourceTile(SearchResult s, bool isDark) {
    final selected = _selectedSource?.source == s.source;
    final state = _pingState[s.source] ?? PingState.idle;
    final ms = _pingCache[s.episodes.isNotEmpty ? s.episodes.first : ''];
    return InkWell(
      onTap: () => _selectSource(s),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF22C55E).withOpacity(0.15)
              : (isDark
                  ? Colors.white.withOpacity(0.05)
                  : Colors.white.withOpacity(0.6)),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? const Color(0xFF22C55E)
                : (isDark
                    ? Colors.white.withOpacity(0.1)
                    : Colors.black.withOpacity(0.08)),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            // 状态图标
            _buildPingIcon(state, ms),
            const SizedBox(width: 10),
            // 名称 + 集数
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.sourceName.isNotEmpty ? s.sourceName : s.source,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '共 ${s.episodes.length} 集',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                ],
              ),
            ),
            // 测速文字
            _buildPingLabel(state, ms),
          ],
        ),
      ),
    );
  }

  Widget _buildPingIcon(PingState state, int? ms) {
    Color color;
    IconData icon;
    if (state == PingState.testing) {
      color = const Color(0xFFF59E0B);
      icon = Icons.access_time;
    } else if (state == PingState.idle) {
      color = const Color(0xFF9CA3AF);
      icon = Icons.help_outline;
    } else if (state == PingState.unavailable) {
      color = const Color(0xFFEF4444);
      icon = Icons.error_outline;
    } else {
      color = _stateToColor(state);
      icon = Icons.bolt;
    }
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 16, color: color),
    );
  }

  Widget _buildPingLabel(PingState state, int? ms) {
    String text;
    Color color;
    if (state == PingState.testing) {
      text = '测速中';
      color = const Color(0xFFF59E0B);
    } else if (state == PingState.idle) {
      text = '待测';
      color = const Color(0xFF9CA3AF);
    } else if (state == PingState.unavailable) {
      text = '不可用';
      color = const Color(0xFFEF4444);
    } else {
      text = '${ms}ms';
      color = _stateToColor(state);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Color _stateToColor(PingState state) {
    switch (state) {
      case PingState.fast:
        return const Color(0xFF22C55E);
      case PingState.medium:
        return const Color(0xFFF59E0B);
      case PingState.slow:
        return const Color(0xFFF97316);
      case PingState.unavailable:
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFF9CA3AF);
    }
  }

  // ---------- 集数选择 ----------

  Widget _buildEpisodeSection(bool isDark) {
    final source = _selectedSource;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle('选集', isDark),
          const SizedBox(height: 8),
          if (source == null || source.episodes.isEmpty)
            Text(
              _sourcesLoading ? '加载中...' : '请先选择播放源',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 6,
                childAspectRatio: 1.2,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
              ),
              itemCount: source.episodes.length,
              itemBuilder: (context, index) {
                final isCurrent = index == _currentEpisodeIndex;
                final title = index < source.episodesTitles.length
                    ? source.episodesTitles[index]
                    : '${index + 1}';
                return InkWell(
                  onTap: () => setState(() {
                    _currentEpisodeIndex = index;
                  }),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: isCurrent
                          ? const LinearGradient(
                              colors: [
                                Color(0xFF22C55E),
                                Color(0xFF10B981)
                              ],
                            )
                          : null,
                      color: !isCurrent
                          ? (isDark
                              ? Colors.white.withOpacity(0.06)
                              : Colors.black.withOpacity(0.04))
                          : null,
                      borderRadius: BorderRadius.circular(6),
                      border: !isCurrent
                          ? Border.all(
                              color: isDark
                                  ? Colors.white.withOpacity(0.08)
                                  : Colors.black.withOpacity(0.06),
                            )
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Text(
                        title,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isCurrent
                              ? Colors.white
                              : (isDark ? Colors.white70 : Colors.black87),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String text, bool isDark) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 14,
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
          text,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white : Colors.black,
          ),
        ),
      ],
    );
  }

  // ---------- 底部播放按钮 ----------

  Widget _buildBottomPlayButton(bool isDark) {
    final source = _selectedSource;
    final canPlay = source != null && source.episodes.isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F1117) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark
                ? Colors.white.withOpacity(0.08)
                : Colors.black.withOpacity(0.06),
          ),
        ),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: canPlay
                ? const LinearGradient(
                    colors: [Color(0xFF22C55E), Color(0xFF10B981)],
                  )
                : null,
            color: !canPlay ? Colors.grey : null,
            borderRadius: BorderRadius.circular(12),
            boxShadow: canPlay
                ? [
                    BoxShadow(
                      color: const Color(0xFF22C55E).withOpacity(0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: canPlay
                  ? () => _playEpisode(_currentEpisodeIndex)
                  : null,
              borderRadius: BorderRadius.circular(12),
              child: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.play_arrow,
                        color: Colors.white, size: 22),
                    const SizedBox(width: 6),
                    Text(
                      source == null
                          ? '请选择播放源'
                          : (source.episodes.isEmpty
                              ? '该源无集数'
                              : '播放 第${_currentEpisodeIndex + 1}集'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ================= 播放视图 =================

  Widget _buildPlayingView(bool isDark) {
    return Stack(
      children: [
        // 视频
        Positioned.fill(
          child: Container(
            color: Colors.black,
            child: Center(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Video(controller: _controller),
                    if (_isBuffering)
                      const SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                            color: Color(0xFF22C55E), strokeWidth: 3),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 顶部工具栏
        Positioned(
          top: 8,
          left: 8,
          right: 8,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => setState(() {
                  _phase = 'detail';
                }),
              ),
              Expanded(
                child: Text(
                  widget.videoInfo.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    shadows: [
                      Shadow(blurRadius: 4, color: Colors.black54),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // 底部控制条
        Positioned(
          left: 12,
          right: 12,
          bottom: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.55),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous,
                      color: Colors.white),
                  onPressed: _currentEpisodeIndex > 0
                      ? () => _playEpisode(_currentEpisodeIndex - 1)
                      : null,
                ),
                Text(
                  '第${_currentEpisodeIndex + 1}集 / '
                  '${_selectedSource?.episodes.length ?? 0}集',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next, color: Colors.white),
                  onPressed: () {
                    final src = _selectedSource;
                    if (src != null &&
                        _currentEpisodeIndex < src.episodes.length - 1) {
                      _playEpisode(_currentEpisodeIndex + 1);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

enum PingState { idle, testing, fast, medium, slow, unavailable }
