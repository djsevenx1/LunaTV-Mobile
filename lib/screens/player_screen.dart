import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/models/search_result.dart';
import 'package:luna_tv/models/video_info.dart';

/// LunaTV 风格播放器
/// 流程：多源搜索 → 选源 → 选集 → 播放
class PlayerScreen extends StatefulWidget {
  /// 视频信息（含 searchTitle / doubanId / source / id 等）
  final VideoInfo videoInfo;

  /// 初始选中的源（可选，由详情页传入）
  final String? preferredSource;

  const PlayerScreen({
    super.key,
    required this.videoInfo,
    this.preferredSource,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  // 播放器
  late final Player _player;
  late final VideoController _controller;

  // 状态机：searching(搜源) → playing(播放)
  String _phase = 'searching';
  bool _isPlaying = false;
  bool _isBuffering = false;
  String? _error;

  // 多源结果
  List<SearchResult> _sourceResults = [];
  SearchResult? _selectedSource;
  int _currentEpisodeIndex = 0;

  // 选集面板 / 选源面板
  bool _showEpisodeSheet = false;
  bool _showSourceSheet = false;
  late TabController _sheetTabController;

  // 测速结果缓存 source -> ms
  final Map<String, int> _pingCache = {};

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _sheetTabController = TabController(length: 2, vsync: this);
    // 监听播放结束自动播下一集
    _player.stream.playing.listen((playing) {
      if (!playing && _isPlaying) {
        Future.delayed(const Duration(milliseconds: 800), () {
          if (!mounted) return;
          if (_phase == 'playing' &&
              _selectedSource != null &&
              _currentEpisodeIndex < _selectedSource!.episodes.length - 1) {
            _playEpisode(_currentEpisodeIndex + 1);
          }
        });
      }
    });
    _searchAndStart();
  }

  @override
  void dispose() {
    _sheetTabController.dispose();
    _player.dispose();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    super.dispose();
  }

  /// 搜索多源 → 自动选源 → 选集 → 播放
  Future<void> _searchAndStart() async {
    final title = widget.videoInfo.searchTitle.isNotEmpty
        ? widget.videoInfo.searchTitle
        : widget.videoInfo.title;
    if (title.isEmpty) {
      setState(() {
        _phase = 'error';
        _error = '视频标题为空,无法搜索';
      });
      return;
    }

    setState(() {
      _phase = 'searching';
      _error = null;
    });

    try {
      final results = await ApiService.fetchSourcesData(title);
      if (!mounted) return;

      if (results.isEmpty) {
        setState(() {
          _sourceResults = [];
          _phase = 'error';
          _error = '没有找到可用的播放源';
        });
        return;
      }

      setState(() {
        _sourceResults = results;
      });

      // 优先选 preferredSource，否则选第一个
      SearchResult toPlay;
      if (widget.preferredSource != null && widget.preferredSource!.isNotEmpty) {
        toPlay = results.firstWhere(
          (r) => r.source == widget.preferredSource,
          orElse: () => results.first,
        );
      } else {
        toPlay = results.first;
      }

      _selectSource(toPlay);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = 'error';
        _error = '搜索失败: $e';
      });
    }
  }

  /// 用户选择某个源
  void _selectSource(SearchResult result) {
    setState(() {
      _selectedSource = result;
      _currentEpisodeIndex = 0;
    });
    if (result.episodes.isNotEmpty) {
      _playEpisode(0);
    } else {
      setState(() {
        _phase = 'error';
        _error = '该源没有可用集数';
      });
    }
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
      _error = null;
    });

    try {
      await _player.stop();
      await _player.open(Media(url));
      if (!mounted) return;
      setState(() {
        _isBuffering = false;
        _isPlaying = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isBuffering = false;
        _isPlaying = false;
        _error = '播放失败: $e';
      });
    }
  }

  /// 测速 (HEAD 请求)
  Future<int> _pingSource(String url) async {
    if (_pingCache.containsKey(url)) return _pingCache[url]!;
    final start = DateTime.now();
    try {
      final req = http.Request('HEAD', Uri.parse(url))
        ..followRedirects = true
        ..maxRedirects = 3;
      final response = await req.send().timeout(const Duration(seconds: 3));
      // 关闭响应
      try {
        await response.stream.drain();
      } catch (_) {}
    } catch (_) {
      // 失败
    }
    final ms = DateTime.now().difference(start).inMilliseconds;
    _pingCache[url] = ms;
    return ms;
  }

  Future<void> _testAllSources() async {
    for (final s in _sourceResults) {
      if (s.episodes.isNotEmpty) {
        await _pingSource(s.episodes.first);
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 视频层
          Positioned.fill(child: _buildVideoLayer()),
          // 顶部工具栏
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Text(
                        widget.videoInfo.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (_selectedSource != null) ...[
                      // 选集按钮
                      IconButton(
                        icon: const Icon(Icons.list, color: Colors.white),
                        onPressed: () {
                          setState(() {
                            _showEpisodeSheet = !_showEpisodeSheet;
                            _showSourceSheet = false;
                          });
                        },
                      ),
                      // 选源按钮
                      IconButton(
                        icon: const Icon(Icons.swap_vert, color: Colors.white),
                        onPressed: () {
                          setState(() {
                            _showSourceSheet = !_showSourceSheet;
                            _showEpisodeSheet = false;
                          });
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // 状态层
          if (_phase == 'searching' || _isBuffering) _buildCenterLoader(),
          if (_phase == 'error') _buildCenterError(),
          // 选集 / 选源底部弹出
          if (_showEpisodeSheet) _buildEpisodeSheet(),
          if (_showSourceSheet) _buildSourceSheet(),
        ],
      ),
    );
  }

  Widget _buildVideoLayer() {
    if (_phase == 'error' && !_isPlaying) {
      return const SizedBox.shrink();
    }
    return Center(
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Video(controller: _controller),
      ),
    );
  }

  Widget _buildCenterLoader() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: Colors.black.withOpacity(0.5),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Color(0xFF22C55E)),
              const SizedBox(height: 12),
              Text(
                _phase == 'searching' ? '正在搜索播放源...' : '正在加载视频...',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCenterError() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.85),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _error ?? '未知错误',
                style: const TextStyle(color: Colors.white, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _searchAndStart,
              child: const Text(
                '重新搜索',
                style: TextStyle(color: Color(0xFF22C55E)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 选集底部弹出
  Widget _buildEpisodeSheet() {
    final source = _selectedSource;
    if (source == null) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        color: Colors.transparent,
        child: Container(
          height: MediaQuery.of(context).size.height * 0.55,
          decoration: const BoxDecoration(
            color: Color(0xFF1F2025),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              // 拖把
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // 标题栏
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Text(
                      '选集 (${source.episodes.length})',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '当前: 第${_currentEpisodeIndex + 1}集',
                      style: const TextStyle(
                          color: Color(0xFF22C55E), fontSize: 12),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () {
                        setState(() {
                          _showEpisodeSheet = false;
                        });
                      },
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12, height: 1),
              // 集数网格
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 6,
                    childAspectRatio: 1.2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: source.episodes.length,
                  itemBuilder: (context, index) {
                    final isCurrent = index == _currentEpisodeIndex;
                    final title = index < source.episodesTitles.length
                        ? source.episodesTitles[index]
                        : '${index + 1}';
                    return InkWell(
                      onTap: () {
                        _playEpisode(index);
                        setState(() {
                          _showEpisodeSheet = false;
                        });
                      },
                      borderRadius: BorderRadius.circular(8),
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
                              ? Colors.white.withOpacity(0.08)
                              : null,
                          borderRadius: BorderRadius.circular(8),
                          border: !isCurrent
                              ? Border.all(color: Colors.white12)
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Text(
                            title,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isCurrent
                                  ? Colors.white
                                  : Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 选源底部弹出
  Widget _buildSourceSheet() {
    if (_sourceResults.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        color: Colors.transparent,
        child: Container(
          height: MediaQuery.of(context).size.height * 0.6,
          decoration: const BoxDecoration(
            color: Color(0xFF1F2025),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Text(
                      '选择播放源 (${_sourceResults.length})',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.speed,
                          color: Color(0xFF22C55E), size: 16),
                      label: const Text(
                        '测速',
                        style: TextStyle(color: Color(0xFF22C55E)),
                      ),
                      onPressed: _testAllSources,
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () {
                        setState(() {
                          _showSourceSheet = false;
                        });
                      },
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12, height: 1),
              Expanded(
                child: ListView.separated(
                  itemCount: _sourceResults.length,
                  separatorBuilder: (_, __) =>
                      const Divider(color: Colors.white12, height: 1),
                  itemBuilder: (context, i) {
                    final r = _sourceResults[i];
                    final selected = _selectedSource?.source == r.source;
                    final ms = _pingCache[r.episodes.isNotEmpty
                        ? r.episodes.first
                        : ''];
                    return ListTile(
                      leading: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFF22C55E)
                              : Colors.white12,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          selected
                              ? Icons.check_rounded
                              : Icons.movie_outlined,
                          color: selected ? Colors.white : Colors.white70,
                          size: 18,
                        ),
                      ),
                      title: Text(
                        r.sourceName.isNotEmpty ? r.sourceName : r.source,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        '共 ${r.episodes.length} 集'
                        '${ms != null ? '  ·  ${ms}ms' : ''}',
                        style: TextStyle(
                          color: ms != null
                              ? (ms < 500
                                  ? const Color(0xFF22C55E)
                                  : ms < 1500
                                      ? const Color(0xFFF59E0B)
                                      : Colors.redAccent)
                              : Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                      trailing: TextButton(
                        onPressed: r.episodes.isNotEmpty
                            ? () => _pingSource(r.episodes.first).then((_) {
                                  if (mounted) setState(() {});
                                })
                            : null,
                        child: const Text(
                          '测速',
                          style:
                              TextStyle(color: Color(0xFF22C55E), fontSize: 12),
                        ),
                      ),
                      onTap: () {
                        _selectSource(r);
                        setState(() {
                          _showSourceSheet = false;
                        });
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
