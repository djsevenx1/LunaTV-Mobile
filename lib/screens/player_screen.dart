import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/services/page_cache_service.dart';
import 'package:luna_tv/models/play_record.dart';
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

  // 播放进度上报
  Timer? _progressTimer;
  bool _firstRecordSaved = false;
  String? _lastSavedKey; // 避免重复保存同一条

  // 视频尺寸（用于判断横竖屏全屏）
  int _videoWidth = 0;
  int _videoHeight = 0;
  StreamSubscription<VideoParams>? _videoParamsSub;

  // 播放器控制状态 (1:1 LunaTV Web)
  bool _showControls = true;
  bool _controlsLocked = false;
  bool _isFullscreen = false;
  double _controlBarOpacity = 0.25; // 控制栏毛玻璃遮挡度 (0.0 - 1.0)
  String _aspectRatio = 'contain'; // contain / cover / fill
  bool _blockAdEnabled = true; // 去广告
  bool _externalDanmuEnabled = false; // 外部弹幕
  int _seekSeconds = 10; // 快进快退秒数
  String? _seekLayout; // both/left/right 留接口
  Timer? _hideControlsTimer;
  String _currentTimeText = '00:00';
  String _durationText = '00:00';
  Duration _currentPosition = Duration.zero;
  Duration _currentDuration = Duration.zero;
  bool _isPlaying = false;
  String _clockText = '';

  // LunaTV Web 主题色
  static const Color kLunaTheme = Color(0xFF22C55E); // #22c55e 绿-500
  static const Color kLunaEpisodeBadgeStart = Color(0xFF10B981); // #10b981
  static const Color kLunaEpisodeBadgeEnd = Color(0xFF059669); // #059669
  static const Color kLunaLoadingColor = Color(0xFF009688); // #009688
  static const Color kLunaGlassBg = Color(0x40000000); // rgba(0,0,0,0.25)
  static const Color kLunaFloatBtnBg = Color(0x26FFFFFF); // rgba(255,255,255,0.15)

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    // 监听视频参数，获取宽高用于全屏方向判断
    _videoParamsSub = _player.streams.videoParams.listen((params) {
      final w = params.dw ?? params.w ?? 0;
      final h = params.dh ?? params.h ?? 0;
      if (w > 0 && h > 0 && (w != _videoWidth || h != _videoHeight)) {
        setState(() {
          _videoWidth = w;
          _videoHeight = h;
        });
      }
    });
    // 不再自动播下一集,由用户控制
    _loadSources();
    // 启动播放状态监听 + 时钟
    _startPlayerStateListener();
  }

  @override
  void dispose() {
    // 退出时最后一次保存
    _saveCurrentProgress(force: true);
    _progressTimer?.cancel();
    _hideControlsTimer?.cancel();
    _videoParamsSub?.cancel();
    // 强制停止播放器,避免关页面后还在后台继续播
    try {
      _player.stop();
    } catch (_) {}
    _player.dispose();
    // 恢复系统UI和竖屏方向
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  /// 判断视频是否为竖屏（高度 > 宽度）
  bool get _isPortraitVideo {
    if (_videoWidth > 0 && _videoHeight > 0) {
      return _videoHeight > _videoWidth;
    }
    return false; // 默认横屏
  }

  /// 进入全屏：隐藏系统UI + 根据视频宽高比设置屏幕方向
  Future<void> _onEnterFullscreen() async {
    if (mounted) setState(() => _isFullscreen = true);
    // 隐藏系统UI（状态栏、导航栏）
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: [],
    );
    // 根据视频宽高比设置方向
    if (_isPortraitVideo) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  /// 退出全屏：恢复系统UI + 恢复竖屏
  Future<void> _onExitFullscreen() async {
    if (mounted) setState(() => _isFullscreen = false);
    // 恢复系统UI
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    // 恢复竖屏
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
  }

  /// 构造并保存当前播放记录
  Future<void> _saveCurrentProgress({bool force = false}) async {
    final source = _selectedSource;
    if (source == null) return;
    if (source.source.isEmpty) return;

    int playTime = 0;
    int totalTime = 0;
    try {
      final state = _player.state;
      // 正在播放 或 视频已加载但暂停 (用 !completed 表示)
      if (state.playing || (state.position > Duration.zero && !state.completed)) {
        playTime = state.position.inMilliseconds;
        totalTime = state.duration.inMilliseconds;
      }
    } catch (_) {}

    final key = '${source.source}+${source.id}';
    // 没播放过(skip) || 同一集还没开始播且已存过(避免启动时连发两条空)
    if (!force && _lastSavedKey == key && playTime == 0 && _firstRecordSaved) {
      return;
    }

    final record = PlayRecord(
      id: source.id,
      source: source.source,
      title: source.title.isNotEmpty
          ? source.title
          : widget.videoInfo.title,
      sourceName: source.sourceName,
      year: widget.videoInfo.year,
      cover: source.poster.isNotEmpty
          ? source.poster
          : widget.videoInfo.cover,
      index: _currentEpisodeIndex + 1,
      totalEpisodes: source.episodes.length,
      playTime: playTime,
      totalTime: totalTime,
      saveTime: DateTime.now().millisecondsSinceEpoch,
      searchTitle: widget.videoInfo.searchTitle.isNotEmpty
          ? widget.videoInfo.searchTitle
          : widget.videoInfo.title,
    );

    _lastSavedKey = key;
    _firstRecordSaved = true;

    try {
      await PageCacheService().savePlayRecord(record, context);
    } catch (_) {
      // 静默失败
    }
  }

  /// 启动进度上报定时器(每 10 秒)
  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _saveCurrentProgress();
    });
  }

  /// 启动播放状态监听 + 时钟定时器
  void _startPlayerStateListener() {
    // 1) 播放位置/时长监听
    _player.streams.position.listen((pos) {
      if (!mounted) return;
      setState(() {
        _currentPosition = pos;
        _currentTimeText = _formatTime(pos);
      });
    });
    _player.streams.duration.listen((dur) {
      if (!mounted) return;
      setState(() {
        _currentDuration = dur;
        _durationText = _formatTime(dur);
      });
    });
    _player.streams.playing.listen((playing) {
      if (!mounted) return;
      setState(() => _isPlaying = playing);
      if (playing) _scheduleHideControls();
    });
    // 2) 时钟定时器 (每秒)
    _updateClock();
    Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
  }

  void _updateClock() {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    if (mounted) setState(() => _clockText = '$hh:$mm');
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

      // 进入详情页不自动播放,等用户点"播放"按钮
      // (电视剧在第1集播完后会自动播第2集,可点暂停控制)

      // 启动后台测速,测完后自动切到最快源
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

    // 切集时先保存上一条的进度
    if (_firstRecordSaved) {
      _saveCurrentProgress(force: true);
    }

    try {
      await _player.stop();
      await _player.open(Media(url));
      if (!mounted) return;
      setState(() => _isBuffering = false);
      // 启动定时器,并立即保存一条(标记已开始)
      _startProgressTimer();
      _firstRecordSaved = false; // 重置,让定时器先存一次
      _saveCurrentProgress();
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
          onPopInvoked: (didPop) async {
            if (!didPop && _phase == 'playing') {
              // 从播放页返回详情页: 先保存一次, 恢复竖屏
              await _saveCurrentProgress(force: true);
              await _onExitFullscreen();
              if (mounted) {
                setState(() {
                  _phase = 'detail';
                });
              }
            } else if (didPop && _phase == 'detail') {
              // 真正退出页面: 最后保存一次
              await _saveCurrentProgress(force: true);
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
                // 集数 (放在源上面,LunaTV Web 风格)
                _buildEpisodeSection(isDark),
                // 源 + 测速
                _buildSourceSection(isDark),
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
      onTap: () {
        // 切源后只更新选中状态,不自动播放 (由用户点"播放"按钮或集数触发)
        _selectSource(s);
      },
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
                  onTap: () {
                    // 点击集数直接开始播放
                    if (index != _currentEpisodeIndex || _phase != 'playing') {
                      _playEpisode(index);
                    } else {
                      setState(() {
                        _currentEpisodeIndex = index;
                      });
                    }
                  },
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
    final isPlaying = _phase == 'playing';
    final btnText = source == null
        ? '请选择播放源'
        : (source.episodes.isEmpty
            ? '该源无集数'
            : (isPlaying
                ? '继续播放 第${_currentEpisodeIndex + 1}集'
                : '播放 第${_currentEpisodeIndex + 1}集'));
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
              onTap: canPlay ? () => _playEpisode(_currentEpisodeIndex) : null,
              borderRadius: BorderRadius.circular(12),
              child: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      isPlaying
                          ? Icons.play_circle_outline
                          : Icons.play_arrow,
                      color: Colors.white,
                      size: 22,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      btnText,
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

  // ================= 播放视图 (1:1 LunaTV Web) =================

  /// 格式化时间: mm:ss / h:mm:ss
  String _formatTime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    String two(int n) => n.toString().padLeft(2, '0');
    if (h > 0) return '$h:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}';
  }

  /// 启动自动隐藏控制栏定时器
  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  /// 切换控制栏显示
  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHideControls();
  }

  /// YouTube 风格圆弧箭头快进 SVG (字符串,内嵌在 CustomPaint)
  static const String _seekForwardSvg = '''
    M16 4C9.4 4 4 9.4 4 16s5.4 12 12 12 12-5.4 12-12h-2.5c0 5.2-4.3 9.5-9.5 9.5S6.5 21.2 6.5 16 10.8 6.5 16 6.5c2.9 0 5.4 1.3 7.2 3.3L20 13h8V5l-2.9 2.9C22.7 5.4 19.5 4 16 4z
  ''';
  static const String _seekBackwardSvg = '''
    M16 4C9.4 4 4 9.4 4 16s5.4 12 12 12 12-5.4 12-12h-2.5c0 5.2 4.3 9.5 9.5 9.5s9.5-4.3 9.5-9.5S21.2 6.5 16 6.5c-2.9 0-5.4 1.3-7.2 3.3L12 13H4V5l2.9 2.9C9.3 5.4 12.5 4 16 4z
  ''';

  /// 圆弧箭头 + 数字 "10" 图标 (类似 YouTube 快进/快退)
  Widget _buildSeekIcon({required bool forward}) {
    return SizedBox(
      width: 32,
      height: 32,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 圆弧箭头 (用 RotationDirection 控制方向)
          Transform(
            alignment: Alignment.center,
            transform: forward
                ? (Matrix4.identity())
                : (Matrix4.rotationY(3.14159)),
            child: CustomPaint(
              size: const Size(32, 32),
              painter: _ArcArrowPainter(
                color: Colors.white,
                forward: true,
              ),
            ),
          ),
          // 中心数字
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '$_seekSeconds',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.bold,
                fontFamily: 'Arial',
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 移动端双圆药丸悬浮按钮 (中线 ±40px)
  Widget _buildSideSeekButtons(BoxConstraints constraints) {
    if (_controlsLocked || !_showControls) return const SizedBox.shrink();
    final centerY = constraints.maxHeight / 2;
    final offset = _isFullscreen ? 60.0 : 40.0;
    return Stack(
      children: [
        // 左: 快退
        Positioned(
          left: (constraints.maxWidth / 2) - offset - 32,
          top: centerY - 32,
          child: _buildSeekCircleButton(
            onTap: () {
              final newPos = _currentPosition -
                  Duration(seconds: _seekSeconds);
              _player.seek(newPos < Duration.zero ? Duration.zero : newPos);
              _scheduleHideControls();
            },
            child: _buildSeekIcon(forward: false),
          ),
        ),
        // 右: 快进
        Positioned(
          left: (constraints.maxWidth / 2) + offset - 32,
          top: centerY - 32,
          child: _buildSeekCircleButton(
            onTap: () {
              final newPos = _currentPosition +
                  Duration(seconds: _seekSeconds);
              final max = _currentDuration;
              _player.seek(newPos > max ? max : newPos);
              _scheduleHideControls();
            },
            child: _buildSeekIcon(forward: true),
          ),
        ),
      ],
    );
  }

  /// 64x64 圆形毛玻璃按钮
  Widget _buildSeekCircleButton(
      {required VoidCallback onTap, required Widget child}) {
    final size = _isFullscreen ? 72.0 : 64.0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: kLunaFloatBtnBg,
            border: Border.all(
              color: Colors.white.withOpacity(0.2),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 32,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipOval(
            child: BackdropFilter(
              filter: _blurFilter(12),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }

  /// 顶部栏: 80px 黑色渐变 + 片名 + 集数胶囊 + 右上时钟
  Widget _buildLunaTopBar() {
    if (!_showControls) return const SizedBox.shrink();
    final totalEps = _selectedSource?.episodes.length ?? 0;
    final currentEp = _currentEpisodeIndex + 1;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: 80,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withOpacity(0.7),
              Colors.black.withOpacity(0.3),
              Colors.transparent,
            ],
            stops: const [0, 0.6, 1],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 0, 24, 0),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              // 返回箭头
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () {
                  _onExitFullscreen();
                  setState(() => _phase = 'detail');
                },
              ),
              const SizedBox(width: 4),
              // 片名
              Expanded(
                child: Text(
                  widget.videoInfo.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    shadows: [
                      Shadow(blurRadius: 4, color: Colors.black54),
                    ],
                  ),
                ),
              ),
              // 集数胶囊徽章
              if (totalEps > 0)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 3),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [
                        kLunaEpisodeBadgeStart,
                        kLunaEpisodeBadgeEnd,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: kLunaEpisodeBadgeStart.withOpacity(0.35),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    totalEps > 1
                        ? '第$currentEp集 / 共$totalEps集'
                        : '第$currentEp集',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 实时时钟 Widget
  Widget _buildClock() {
    return Text(
      _clockText,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        fontFeatures: const [ui.FontFeature.tabularFigures()],
      ),
    );
  }

  /// 毛玻璃滤镜
  ui.ImageFilter _blurFilter(double sigma) =>
      ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);

  /// 进度条 (1:1 LunaTV Web 风格: 矩形 5px,绿进度,白半透明缓冲)
  Widget _buildLunaProgressBar() {
    return Container(
      height: 5,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      child: Stack(
        children: [
          // 底色轨道
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(2.5),
            ),
          ),
          // 缓冲条 (Web 原生用 media_kit 的 buffered 显示)
          FractionallySizedBox(
            widthFactor: _currentDuration.inMilliseconds > 0
                ? (_currentPosition.inMilliseconds /
                        _currentDuration.inMilliseconds)
                    .clamp(0.0, 1.0)
                : 0.0,
            child: Container(
              decoration: BoxDecoration(
                color: kLunaTheme,
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
          ),
          // 拖动手柄 (进度过半时显示)
          if (_currentDuration.inMilliseconds > 0)
            Positioned(
              left: 0,
              right: 0,
              top: -2,
              bottom: -2,
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 5,
                  activeTrackColor: Colors.transparent,
                  inactiveTrackColor: Colors.transparent,
                  thumbColor: Colors.white,
                  overlayColor: kLunaTheme.withOpacity(0.2),
                  thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: _currentPosition.inMilliseconds.toDouble(),
                  min: 0,
                  max: _currentDuration.inMilliseconds
                      .toDouble()
                      .clamp(1, double.infinity),
                  onChanged: (v) {
                    _player.seek(Duration(milliseconds: v.toInt()));
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 底部控制栏 (毛玻璃容器,左中右布局)
  Widget _buildLunaBottomBar() {
    if (!_showControls) return const SizedBox.shrink();
    final totalEps = _selectedSource?.episodes.length ?? 0;
    return Positioned(
      left: 12,
      right: 12,
      bottom: 12,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: BackdropFilter(
          filter: _blurFilter(12),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(_controlBarOpacity),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顶部: 进度条
                _buildLunaProgressBar(),
                // 底部: 左中右分段按钮
                SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      // 左: 播放/暂停 + 上一集 + 时间
                      _iconBtn(
                        icon: _isPlaying ? Icons.pause : Icons.play_arrow,
                        onTap: () {
                          if (_isPlaying) {
                            _player.pause();
                          } else {
                            _player.play();
                          }
                          setState(() => _isPlaying = !_isPlaying);
                          _scheduleHideControls();
                        },
                      ),
                      _iconBtn(
                        icon: Icons.skip_previous,
                        onTap: _currentEpisodeIndex > 0
                            ? () => _playEpisode(_currentEpisodeIndex - 1)
                            : null,
                      ),
                      // 时间显示
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          '$_currentTimeText / $_durationText',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontFeatures: const [ui.FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      // 下一集 (右侧靠左)
                      const Spacer(),
                      _iconBtn(
                        icon: Icons.skip_next,
                        onTap: totalEps > 1 &&
                                _currentEpisodeIndex < totalEps - 1
                            ? () =>
                                _playEpisode(_currentEpisodeIndex + 1)
                            : null,
                      ),
                      // 音轨
                      if (totalEps > 0)
                        _iconBtn(
                          icon: Icons.queue_music,
                          onTap: () => _showEpisodePicker(),
                        ),
                      // 弹幕 (占位)
                      _iconBtn(
                        icon: Icons.comment_outlined,
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('弹幕功能开发中')),
                          );
                        },
                      ),
                      // 设置
                      _iconBtn(
                        icon: Icons.settings_outlined,
                        onTap: () => _showSettingsSheet(),
                      ),
                      // 全屏
                      _iconBtn(
                        icon: _isFullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        onTap: () {
                          if (_isFullscreen) {
                            _onExitFullscreen();
                          } else {
                            _onEnterFullscreen();
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 圆形小按钮 (40x40, 仿 ArtPlayer 控制按钮)
  Widget _iconBtn(
      {required IconData icon, required VoidCallback? onTap}) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            color: onTap == null
                ? Colors.white.withOpacity(0.3)
                : Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }

  /// 显示集数选择
  void _showEpisodePicker() {
    final src = _selectedSource;
    if (src == null || src.episodes.isEmpty) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.6,
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Text('选择集数',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                Expanded(
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 6,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.4,
                    ),
                    itemCount: src.episodes.length,
                    itemBuilder: (ctx, i) {
                      final selected = i == _currentEpisodeIndex;
                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            Navigator.pop(ctx);
                            _playEpisode(i);
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: selected
                                  ? kLunaTheme
                                  : Colors.white.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: selected
                                    ? kLunaTheme
                                    : Colors.white24,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '${i + 1}',
                              style: TextStyle(
                                color: selected
                                    ? Colors.white
                                    : Colors.white70,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
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
      ),
    );
  }

  /// 设置面板 (1:1 LunaTV Web: 去广告/外部弹幕/显示模式/控制栏遮挡度/快进快退秒数)
  void _showSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Text('设置',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                // 去广告
                _settingSwitch(
                  icon: 'AD',
                  label: '去广告',
                  value: _blockAdEnabled,
                  onChanged: (v) => setSheetState(
                      () => _blockAdEnabled = v),
                ),
                // 外部弹幕
                _settingSwitch(
                  icon: '外',
                  label: '外部弹幕',
                  value: _externalDanmuEnabled,
                  onChanged: (v) => setSheetState(
                      () => _externalDanmuEnabled = v),
                ),
                // 显示模式
                _settingSelector(
                  icon: Icons.aspect_ratio,
                  label: '显示模式',
                  value: _aspectRatio,
                  options: const ['contain', 'cover', 'fill'],
                  labels: const ['适应', '填充', '拉伸'],
                  onChanged: (v) => setSheetState(() {
                    _aspectRatio = v;
                    _applyAspectRatio();
                  }),
                ),
                // 快进快退秒数
                _settingSelector(
                  icon: Icons.fast_forward,
                  label: '快进快退秒数',
                  value: '$_seekSeconds',
                  options: const ['5', '10', '15', '30'],
                  labels: const ['5秒', '10秒', '15秒', '30秒'],
                  onChanged: (v) => setSheetState(
                      () => _seekSeconds = int.parse(v)),
                ),
                // 控制栏遮挡度
                _settingRange(
                  icon: Icons.opacity,
                  label: '控制栏遮挡度',
                  value: _controlBarOpacity,
                  min: 0.0,
                  max: 0.8,
                  divisions: 8,
                  onChanged: (v) => setSheetState(
                      () => _controlBarOpacity = v),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 设置项: 开关
  Widget _settingSwitch({
    required String icon,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: kLunaTheme.withOpacity(0.2),
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Text(
              icon,
              style: const TextStyle(
                color: kLunaTheme,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: kLunaTheme,
          ),
        ],
      ),
    );
  }

  /// 设置项: 单选 (selector)
  Widget _settingSelector({
    required IconData icon,
    required String label,
    required String value,
    required List<String> options,
    required List<String> labels,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
          ),
          DropdownButton<String>(
            value: value,
            dropdownColor: Colors.black87,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            underline: const SizedBox.shrink(),
            items: List.generate(options.length, (i) {
              return DropdownMenuItem<String>(
                value: options[i],
                child: Text(labels[i]),
              );
            }),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }

  /// 设置项: 范围滑块
  Widget _settingRange({
    required IconData icon,
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 22),
          const SizedBox(width: 12),
          SizedBox(
            width: 90,
            child: Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                activeTrackColor: kLunaTheme,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: kLunaTheme.withOpacity(0.2),
                trackHeight: 4,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 8),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 32,
            child: Text(
              '${(value * 100).toInt()}',
              textAlign: TextAlign.end,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// 应用显示模式
  void _applyAspectRatio() {
    final w = _videoWidth.toDouble();
    final h = _videoHeight.toDouble();
    if (w <= 0 || h <= 0) return;
    final srcAspect = w / h;
    switch (_aspectRatio) {
      case 'cover':
        _controller.setSize(
            Size(MediaQuery.of(context).size.width * srcAspect,
                MediaQuery.of(context).size.width));
        break;
      case 'fill':
        _controller.setSize(
            Size(MediaQuery.of(context).size.width,
                MediaQuery.of(context).size.width / srcAspect));
        break;
      case 'contain':
      default:
        _controller.setSize(
            Size(MediaQuery.of(context).size.width,
                MediaQuery.of(context).size.width / srcAspect));
        break;
    }
  }

  /// 主播放视图 (1:1 LunaTV Web)
  Widget _buildPlayingView(bool isDark) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onTap: _toggleControls,
          onDoubleTap: () {
            if (_isPlaying) {
              _player.pause();
            } else {
              _player.play();
            }
            setState(() => _isPlaying = !_isPlaying);
            _scheduleHideControls();
          },
          child: Stack(
            children: [
              // 视频
              Positioned.fill(
                child: Container(
                  color: Colors.black,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio:
                          (_videoWidth > 0 && _videoHeight > 0)
                              ? _videoWidth / _videoHeight
                              : 16 / 9,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Video(
                            controller: _controller,
                            onEnterFullscreen: _onEnterFullscreen,
                            onExitFullscreen: _onExitFullscreen,
                          ),
                          if (_isBuffering)
                            const SizedBox(
                              width: 36,
                              height: 36,
                              child: CircularProgressIndicator(
                                  color: kLunaLoadingColor,
                                  strokeWidth: 3),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // 中央双圆快进/快退按钮 (中线 ±40px/60px)
              _buildSideSeekButtons(constraints),
              // 顶部栏
              _buildLunaTopBar(),
              // 底部毛玻璃控制栏
              _buildLunaBottomBar(),
              // 锁定按钮 (全屏时显示)
              if (_isFullscreen)
                Positioned(
                  right: 16,
                  top: constraints.maxHeight / 2 - 20,
                  child: _iconBtn(
                    icon: _controlsLocked ? Icons.lock : Icons.lock_open,
                    onTap: () => setState(
                        () => _controlsLocked = !_controlsLocked),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 圆弧箭头绘制器 (YouTube 风格快进图标)
class _ArcArrowPainter extends CustomPainter {
  _ArcArrowPainter({required this.color, required this.forward});
  final Color color;
  final bool forward;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.42;

    // 圆弧 (3/4 圆)
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);
    canvas.drawArc(rect, -0.4, 5.0, false, paint..style = PaintingStyle.stroke);

    // 三角形箭头 (尾部)
    final tailPath = Path();
    if (forward) {
      tailPath.moveTo(cx - r * 0.95, cy - r * 0.05);
      tailPath.lineTo(cx - r * 0.65, cy - r * 0.4);
      tailPath.lineTo(cx - r * 0.5, cy + r * 0.05);
      tailPath.close();
    } else {
      tailPath.moveTo(cx + r * 0.95, cy - r * 0.05);
      tailPath.lineTo(cx + r * 0.65, cy - r * 0.4);
      tailPath.lineTo(cx + r * 0.5, cy + r * 0.05);
      tailPath.close();
    }
    canvas.drawPath(tailPath, paint);
  }

  @override
  bool shouldRepaint(covariant _ArcArrowPainter old) =>
      old.color != color || old.forward != forward;
}

enum PingState { idle, testing, fast, medium, slow, unavailable }
