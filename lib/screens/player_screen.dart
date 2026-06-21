import 'dart:async';
import 'dart:ui';
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
import 'package:luna_tv/utils/image_url.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// 测速用的临时包装
class _SourcePingItem {
  final SearchResult source;
  _SourcePingItem(this.source);
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

  // 跳过片头片尾
  int _skipIntroEnd = 0; // 片头结束时间（秒），0 表示不跳
  int _skipOutroStart = 0; // 片尾开始时间（秒，从结尾倒数），0 表示不跳
  Duration _currentPosition = Duration.zero;
  Duration _currentDuration = Duration.zero;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  // 控制跳过按钮显示（避免反复触发）
  bool _showSkipIntro = false;
  bool _showSkipOutro = false;

  // UI 控制
  bool _isPlaying = false;
  bool _isControlsVisible = true;
  bool _isFavorite = false;
  double _playbackRate = 1.0;
  // 用户拖动进度条时的临时值(避免 stream 把进度覆盖回去)
  double? _scrubbingValue;
  // 控制栏自动隐藏定时器
  Timer? _hideControlsTimer;

  // 倍速档位
  static const List<double> _playbackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

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
    // 监听播放位置和总时长，用于跳过片头片尾
    _positionSub = _player.streams.position.listen((pos) {
      if (_scrubbingValue == null) {
        _currentPosition = pos;
        _updateSkipButtonVisibility();
      }
    });
    _durationSub = _player.streams.duration.listen((dur) {
      _currentDuration = dur;
    });
    // 监听播放/暂停状态,用于控制栏图标
    _player.streams.playing.listen((playing) {
      if (!mounted) return;
      setState(() {
        _isPlaying = playing;
      });
      if (playing) {
        _scheduleHideControls();
      } else {
        // 暂停时保持控制栏显示
        _showControls();
      }
    });
    // 加载跳过片头片尾配置
    _loadSkipConfig();
    // 加载倍速持久化
    _loadPlaybackRate();
    // 加载收藏状态
    _loadFavorite();
    // 不再自动播下一集,由用户控制
    _loadSources();
  }

  @override
  void dispose() {
    // 退出时最后一次保存
    _saveCurrentProgress(force: true);
    _progressTimer?.cancel();
    _hideControlsTimer?.cancel();
    _videoParamsSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    // 强制停止播放器,避免关页面后还在后台继续播
    try {
      _player.stop();
    } catch (_) {}
    _player.dispose();
    // 恢复系统UI,方向交由系统控制
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  /// 判断视频是否为竖屏（高度 > 宽度）
  bool get _isPortraitVideo {
    if (_videoWidth > 0 && _videoHeight > 0) {
      return _videoHeight > _videoWidth;
    }
    return false; // 默认横屏
  }

  // ================= 跳过片头片尾 =================

  /// SharedPreferences 存储键（按视频标题区分）
  String get _skipPrefKey => 'skip_config_${widget.videoInfo.title}';

  /// 加载跳过片头片尾配置
  Future<void> _loadSkipConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final intro = prefs.getInt('${_skipPrefKey}_intro') ?? 0;
      final outro = prefs.getInt('${_skipPrefKey}_outro') ?? 0;
      if (mounted) {
        setState(() {
          _skipIntroEnd = intro;
          _skipOutroStart = outro;
        });
      }
    } catch (_) {}
  }

  /// 保存跳过片头片尾配置
  Future<void> _saveSkipConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('${_skipPrefKey}_intro', _skipIntroEnd);
      await prefs.setInt('${_skipPrefKey}_outro', _skipOutroStart);
    } catch (_) {}
  }

  /// 根据当前位置更新跳过按钮的显示状态
  void _updateSkipButtonVisibility() {
    final posSec = _currentPosition.inSeconds;
    final durSec = _currentDuration.inSeconds;
    final shouldShowIntro = _skipIntroEnd > 0 && posSec < _skipIntroEnd && posSec > 1;
    final shouldShowOutro = _skipOutroStart > 0 &&
        durSec > 0 &&
        posSec > 0 &&
        (durSec - posSec) < _skipOutroStart &&
        (durSec - posSec) > 1;
    if (shouldShowIntro != _showSkipIntro ||
        shouldShowOutro != _showSkipOutro) {
      setState(() {
        _showSkipIntro = shouldShowIntro;
        _showSkipOutro = shouldShowOutro;
      });
    }
  }

  /// 跳过片头
  void _skipIntro() {
    if (_skipIntroEnd > 0) {
      _player.seek(Duration(seconds: _skipIntroEnd));
    }
  }

  /// 跳过片尾
  void _skipOutro() {
    final durSec = _currentDuration.inSeconds;
    if (durSec > 0 && _skipOutroStart > 0) {
      _player.seek(Duration(seconds: durSec - _skipOutroStart));
    }
  }

  /// 打开跳过片头片尾设置弹窗
  Future<void> _showSkipSettingsDialog() async {
    int intro = _skipIntroEnd;
    int outro = _skipOutroStart;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1F2937),
              title: const Text(
                '跳过片头片尾',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '片头结束时间: ${intro > 0 ? "$intro 秒" : "未设置"}',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  Slider(
                    value: intro.toDouble(),
                    min: 0,
                    max: 300,
                    divisions: 300,
                    activeColor: const Color(0xFF22C55E),
                    label: intro > 0 ? '$intro 秒' : '关闭',
                    onChanged: (v) =>
                        setDialogState(() => intro = v.round()),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '片尾提前时间: ${outro > 0 ? "$outro 秒" : "未设置"}',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  Slider(
                    value: outro.toDouble(),
                    min: 0,
                    max: 300,
                    divisions: 300,
                    activeColor: const Color(0xFF22C55E),
                    label: outro > 0 ? '$outro 秒' : '关闭',
                    onChanged: (v) =>
                        setDialogState(() => outro = v.round()),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '片头: 播放到该时间点前显示"跳过片头"按钮\n片尾: 距离结尾该时间时显示"跳过片尾"按钮',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消',
                      style: TextStyle(color: Colors.white54)),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _skipIntroEnd = intro;
                      _skipOutroStart = outro;
                    });
                    _saveSkipConfig();
                    Navigator.pop(ctx);
                  },
                  child: const Text('保存',
                      style: TextStyle(color: Color(0xFF22C55E))),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 打开集数选择底部面板
  Future<void> _showEpisodeSelectorSheet() async {
    final source = _selectedSource;
    if (source == null || source.episodes.isEmpty) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1F2937),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.6,
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '选集 (${source.episodes.length}集)',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const Divider(color: Colors.white24, height: 1),
                const SizedBox(height: 12),
                Flexible(
                  child: GridView.builder(
                    shrinkWrap: true,
                    itemCount: source.episodes.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 5,
                      childAspectRatio: 1.4,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemBuilder: (ctx, index) {
                      final isCurrent = index == _currentEpisodeIndex;
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          _playEpisode(index);
                        },
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? const Color(0xFF22C55E)
                                : const Color(0xFF374151),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${index + 1}',
                            style: TextStyle(
                              color: isCurrent
                                  ? Colors.white
                                  : Colors.white70,
                              fontSize: 14,
                              fontWeight: isCurrent
                                  ? FontWeight.w700
                                  : FontWeight.w400,
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
        );
      },
    );
  }

  /// 进入全屏：隐藏系统UI + 根据视频宽高比设置屏幕方向
  Future<void> _onEnterFullscreen() async {
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

  /// 退出全屏：恢复系统UI + 解除方向锁定
  Future<void> _onExitFullscreen() async {
    // 恢复系统UI
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    // 解除方向锁定,让系统方向(横屏/竖屏)由系统决定
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  // ================= UI 控制 =================

  /// 切换播放/暂停
  void _togglePlayPause() {
    if (_isPlaying) {
      _player.pause();
    } else {
      _player.play();
    }
  }

  /// 设置倍速
  void _setPlaybackRate(double rate) {
    _player.setRate(rate);
    setState(() => _playbackRate = rate);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setDouble('player_playback_rate', rate);
    });
  }

  /// 加载倍速持久化
  Future<void> _loadPlaybackRate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rate = prefs.getDouble('player_playback_rate') ?? 1.0;
      if (mounted) {
        setState(() => _playbackRate = rate);
        _player.setRate(rate);
      }
    } catch (_) {}
  }

  /// 切换收藏
  void _toggleFavorite() {
    setState(() => _isFavorite = !_isFavorite);
    SharedPreferences.getInstance().then((prefs) {
      final key = 'fav_${widget.videoInfo.source}_${widget.videoInfo.id}';
      if (_isFavorite) {
        prefs.setBool(key, true);
      } else {
        prefs.remove(key);
      }
    });
  }

  /// 加载收藏状态
  Future<void> _loadFavorite() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'fav_${widget.videoInfo.source}_${widget.videoInfo.id}';
      if (mounted) {
        setState(() => _isFavorite = prefs.getBool(key) ?? false);
      }
    } catch (_) {}
  }

  /// 显示控制栏并启动自动隐藏定时器
  void _showControls() {
    _hideControlsTimer?.cancel();
    if (!mounted) return;
    setState(() => _isControlsVisible = true);
  }

  /// 调度自动隐藏控制栏
  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_isPlaying) {
        setState(() => _isControlsVisible = false);
      }
    });
  }

  /// 切换控制栏显隐
  void _toggleControls() {
    if (_isControlsVisible) {
      setState(() => _isControlsVisible = false);
    } else {
      _showControls();
      if (_isPlaying) _scheduleHideControls();
    }
  }

  /// 进度条拖动 - 开始
  void _onScrubStart(double value) {
    _hideControlsTimer?.cancel();
    setState(() {
      _scrubbingValue = value;
      _isControlsVisible = true;
    });
  }

  /// 进度条拖动 - 更新
  void _onScrubChange(double value) {
    setState(() => _scrubbingValue = value);
  }

  /// 进度条拖动 - 结束
  void _onScrubEnd(double value) {
    final dur = _currentDuration.inMilliseconds.toDouble();
    if (dur > 0) {
      final pos = (value.clamp(0.0, 1.0)) * dur;
      _player.seek(Duration(milliseconds: pos.toInt()));
    }
    setState(() {
      _scrubbingValue = null;
      _currentPosition = Duration(milliseconds: ((value.clamp(0.0, 1.0)) * dur).toInt());
    });
    if (_isPlaying) _scheduleHideControls();
  }

  /// 格式化时间为 mm:ss 或 hh:mm:ss
  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:$mm:$ss';
    return '$mm:$ss';
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

  /// 后台测速所有源：并发测速，并按速度从快到慢排序源列表
  Future<void> _testAllSourcesInBackground() async {
    // 先标记所有源为测速中
    final pending = <_SourcePingItem>[];
    for (final s in _sourceResults) {
      if (s.episodes.isEmpty) continue;
      _pingState[s.source] = PingState.testing;
      pending.add(_SourcePingItem(s));
    }
    if (mounted) setState(() {});

    // 并发测速（最多同时 6 个，避免瞬时连接太多）
    const maxConcurrent = 6;
    for (var i = 0; i < pending.length; i += maxConcurrent) {
      final batch = pending.skip(i).take(maxConcurrent);
      await Future.wait(batch.map((item) async {
        final ms = await _pingSource(item.source.episodes.first);
        if (!mounted) return;
        _pingState[item.source.source] = _stateFromMs(ms);
        if (mounted) setState(() {});
      }));
    }

    if (!mounted) return;
    if (mounted) setState(() {});

    // 自动选最快源 (除非用户已经主动选过)
    if (_autoSelectedSource == null && _sourceResults.isNotEmpty) {
      int bestMs = 1 << 30;
      String? bestSource;
      for (final s in _sourceResults) {
        final ms =
            _pingCache[s.episodes.isNotEmpty ? s.episodes.first : ''];
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

    // 按速度从快到慢重排源列表（已测速成功的排前面；测失败的放最后）
    _sortSourcesBySpeed();
  }

  /// 按测速速度从快到慢排序源列表
  void _sortSourcesBySpeed() {
    int scoreOf(SearchResult s) {
      if (s.episodes.isEmpty) return 1 << 30;
      final ms = _pingCache[s.episodes.first];
      if (ms == null) return 1 << 30;
      return ms;
    }

    setState(() {
      _sourceResults.sort((a, b) => scoreOf(a).compareTo(scoreOf(b)));
      // _selectedSource 是 SearchResult 引用，sort 后引用仍然指向同一对象，不需要调整
    });
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
    final httpClient = http.Client();
    try {
      final req = http.Request('HEAD', Uri.parse(url))
        ..followRedirects = true
        ..maxRedirects = 2;
      final response =
          await httpClient.send(req).timeout(const Duration(milliseconds: 1500));
      // 测首字节即可，不等响应体流
      response.stream.drain().catchError((_) {});
    } catch (_) {
      // 超时或失败统一记为 3000ms
      _pingCache[url] = 3000;
      httpClient.close();
      return 3000;
    }
    final ms = DateTime.now().difference(start).inMilliseconds;
    _pingCache[url] = ms;
    httpClient.close();
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
            body: _phase == 'playing'
                // 播放视图不套 SafeArea，让视频铺满整屏
                // 避免横屏时被 iOS 状态栏/HomeIndicator 推挤产生侧边黑/白条
                ? _buildPlayingView(isDark)
                : SafeArea(child: _buildDetailView(isDark)),
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
                  ? FutureBuilder<String>(
                      future: getImageUrl(
                          widget.videoInfo.cover, widget.videoInfo.source),
                      builder: (context, snapshot) {
                        final imageUrl =
                            snapshot.data ?? widget.videoInfo.cover;
                        final headers = getImageRequestHeaders(
                            imageUrl, widget.videoInfo.source);
                        return CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          width: 110,
                          height: 150,
                          httpHeaders: headers,
                          memCacheWidth: (110 *
                                  MediaQuery.of(context).devicePixelRatio)
                              .round(),
                          memCacheHeight: (150 *
                                  MediaQuery.of(context).devicePixelRatio)
                              .round(),
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
                        );
                      },
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

  // ================= 播放视图 =================

  /// 构建播放器顶部工具栏(LunaTV 风格: 毛玻璃黑底 + 圆角)
  Widget _buildPlayerTopBar() {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withOpacity(0.7),
                Colors.black.withOpacity(0.0),
              ],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
              child: Row(
                children: [
                  // 返回
                  Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () {
                        _onExitFullscreen();
                        setState(() {
                          _phase = 'detail';
                        });
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(Icons.arrow_back, color: Colors.white, size: 24),
                      ),
                    ),
                  ),
                  // 标题
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.videoInfo.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (_selectedSource != null)
                          Text(
                            '第 ${_currentEpisodeIndex + 1} 集',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  // 收藏
                  Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _toggleFavorite,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Icon(
                          _isFavorite ? Icons.favorite : Icons.favorite_border,
                          color: _isFavorite
                              ? const Color(0xFFEF4444)
                              : Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                  // 齿轮 (设置菜单: 跳过片头片尾 / 倍速 / 比例 等)
                  Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _showSettingsSheet,
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(Icons.settings_outlined,
                            color: Colors.white, size: 22),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 左侧/右侧 双圆 药丸悬浮 (快退10s / 快进10s, ArtPlayer mobile 风格)
  Widget _buildSideButtons() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // 左: 快退10s
              _circleSeekButton(
                onTap: () {
                  final newPos = _currentPosition -
                      const Duration(seconds: 10);
                  _player.seek(newPos < Duration.zero
                      ? Duration.zero
                      : newPos);
                },
                label: '-10',
              ),
              // 右: 快进10s
              _circleSeekButton(
                onTap: () {
                  final newPos = _currentPosition +
                      const Duration(seconds: 10);
                  final max = _currentDuration;
                  _player.seek(newPos > max ? max : newPos);
                },
                label: '+10',
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 药丸状圆形快进/快退按钮(ArtPlayer 双侧悬浮)
  Widget _circleSeekButton({required VoidCallback onTap, required String label}) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.18),
              border: Border.all(
                color: Colors.white.withOpacity(0.35),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 打开设置底部面板(齿轮菜单: 倍速 / 跳过片头片尾 / 比例 等)
  Future<void> _showSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1F2937),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部小横条
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '播放设置',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Divider(color: Colors.white12, height: 1),
              // 倍速
              ListTile(
                leading: const Icon(Icons.speed, color: Colors.white70),
                title: const Text('倍速',
                    style: TextStyle(color: Colors.white)),
                trailing: Text(
                  _playbackRate == 1.0 ? '1.0x' : '${_playbackRate}x',
                  style: const TextStyle(color: Color(0xFF22C55E)),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showPlaybackRateSheet();
                },
              ),
              // 跳过片头片尾
              ListTile(
                leading: const Icon(Icons.fast_forward, color: Colors.white70),
                title: const Text('跳过片头片尾',
                    style: TextStyle(color: Colors.white)),
                trailing: Text(
                  _skipIntroEnd > 0 || _skipOutroStart > 0
                      ? '已配置'
                      : '未设置',
                  style: TextStyle(
                    color: _skipIntroEnd > 0 || _skipOutroStart > 0
                        ? const Color(0xFF22C55E)
                        : Colors.white54,
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showSkipSettingsDialog();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 构建底部控制栏(ArtPlayer 药丸状悬浮: 顶部进度条 + 单个药丸栏)
  Widget _buildPlayerBottomBar() {
    final dur = _currentDuration.inMilliseconds.toDouble();
    final pos = _scrubbingValue != null
        ? (_scrubbingValue! * dur).toInt()
        : _currentPosition.inMilliseconds;
    final progress = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ===== 顶部进度条 (贴近屏幕上边缘) =====
        SizedBox(
          height: 26,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: const Color(0xFF22C55E),
              inactiveTrackColor: Colors.white30,
              thumbColor: Colors.white,
              overlayColor: const Color(0xFF22C55E).withOpacity(0.2),
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 7,
                elevation: 2,
              ),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: progress,
              onChangeStart: _onScrubStart,
              onChanged: _onScrubChange,
              onChangeEnd: _onScrubEnd,
            ),
          ),
        ),
        const SizedBox(height: 8),
        // ===== 药丸状悬浮控制栏 (ArtPlayer 风格) =====
        Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            isLandscape ? 8 : 12,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.15),
                    width: 0.6,
                  ),
                  borderRadius: BorderRadius.circular(32),
                ),
                child: Row(
                  children: [
                    // 左: 播放/暂停 (圆形药丸段)
                    _pillIcon(
                      icon: _isPlaying ? Icons.pause : Icons.play_arrow,
                      iconSize: 28,
                      onTap: _togglePlayPause,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                    ),
                    // 时间
                    Padding(
                      padding: const EdgeInsets.only(left: 4, right: 6),
                      child: Text(
                        '${_formatDuration(Duration(milliseconds: pos))} / ${_formatDuration(_currentDuration)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const Spacer(),
                    // 右: 倍速
                    _pillIcon(
                      icon: Icons.speed,
                      label: _playbackRate == 1.0
                          ? '1x'
                          : '${_playbackRate}x',
                      onTap: _showPlaybackRateSheet,
                    ),
                    // 选集
                    _pillIcon(
                      icon: Icons.format_list_bulleted,
                      label:
                          '${_currentEpisodeIndex + 1}/${_selectedSource?.episodes.length ?? 0}',
                      onTap: _showEpisodeSelectorSheet,
                    ),
                    // 全屏
                    _pillIcon(
                      icon: isLandscape
                          ? Icons.fullscreen_exit
                          : Icons.fullscreen,
                      iconSize: 24,
                      onTap: isLandscape
                          ? _onExitFullscreen
                          : _onEnterFullscreen,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 药丸栏内单个图标按钮(可选小标签)
  Widget _pillIcon({
    required IconData icon,
    required VoidCallback onTap,
    String? label,
    double iconSize = 22,
    EdgeInsetsGeometry padding =
        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: padding,
          constraints: const BoxConstraints(minHeight: 40),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: iconSize),
              if (label != null) ...[
                const SizedBox(width: 3),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 倍速选择底部面板
  Future<void> _showPlaybackRateSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1F2937),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Text(
                  '倍速',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ..._playbackRates.map((rate) {
                  final selected = (rate - _playbackRate).abs() < 0.001;
                  return ListTile(
                    title: Text(
                      rate == 1.0 ? '1.0x (正常)' : '${rate}x',
                      style: TextStyle(
                        color: selected
                            ? const Color(0xFF22C55E)
                            : Colors.white,
                        fontSize: 15,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    trailing: selected
                        ? const Icon(Icons.check_circle,
                            color: Color(0xFF22C55E), size: 20)
                        : null,
                    onTap: () {
                      _setPlaybackRate(rate);
                      Navigator.pop(ctx);
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 中间大播放/暂停按钮(点击视频空白区触发)
  Widget _buildCenterPlayButton() {
    if (_isPlaying) {
      // 播放中不显示中间按钮(避免遮挡)
      return const SizedBox.shrink();
    }
    return Center(
      child: Material(
        color: Colors.black.withOpacity(0.35),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: _togglePlayPause,
          customBorder: const CircleBorder(),
          child: Container(
            width: 88,
            height: 88,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withOpacity(0.7),
                width: 2,
              ),
            ),
            child: const Icon(
              Icons.play_arrow,
              color: Colors.white,
              size: 56,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayingView(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 视频 - 铺满整个 body
        Positioned.fill(
          child: Container(
            color: Colors.black,
            child: Center(
              child: AspectRatio(
                aspectRatio: (_videoWidth > 0 && _videoHeight > 0)
                    ? _videoWidth / _videoHeight
                    : 16 / 9,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Video(
                      controller: _controller,
                      controls: NoVideoControls,
                      onEnterFullscreen: _onEnterFullscreen,
                      onExitFullscreen: _onExitFullscreen,
                    ),
                    if (_isBuffering)
                      const SizedBox(
                        width: 40,
                        height: 40,
                        child: CircularProgressIndicator(
                            color: Color(0xFF22C55E), strokeWidth: 3),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 点击空白区切换控制栏显隐
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _toggleControls,
          ),
        ),
        // 动画层: 控制栏 / 中间按钮 / 跳过提示
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _isControlsVisible
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    // 半透明遮罩(让控制文字更清晰)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(color: Colors.black.withOpacity(0.15)),
                      ),
                    ),
                    // 顶部工具栏
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _buildPlayerTopBar(),
                    ),
                    // 左右双圆 药丸悬浮 (快退/快进10s)
                    _buildSideButtons(),
                    // 底部控制栏
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _buildPlayerBottomBar(),
                    ),
                    // 跳过片头按钮(右下角浮层)
                    if (_showSkipIntro)
                      Positioned(
                        right: 16,
                        bottom: 130,
                        child: _skipButton(
                          '跳过片头',
                          const Color(0xFF22C55E),
                          _skipIntro,
                        ),
                      ),
                    // 跳过片尾按钮(右下角浮层)
                    if (_showSkipOutro)
                      Positioned(
                        right: 16,
                        bottom: 130,
                        child: _skipButton(
                          '跳过片尾',
                          const Color(0xFF3B82F6),
                          _skipOutro,
                        ),
                      ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
        // 暂停时的中央播放按钮
        if (!_isPlaying && _isControlsVisible)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: true,
              child: _buildCenterPlayButton(),
            ),
          ),
      ],
    );
  }

  /// 跳过片头/片尾的浮层按钮
  Widget _skipButton(String label, Color color, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.92),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fast_forward, color: Colors.white, size: 18),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum PingState { idle, testing, fast, medium, slow, unavailable }
