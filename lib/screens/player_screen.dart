import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/services/page_cache_service.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/m3u8_service.dart';
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
  final Map<String, int> _pingCache = {}; // 兼容旧 fallback 测速
  final Map<String, PingState> _pingState = {};
  // v1.0.45: 完整测速信息 (分辨率 + 下载速度 + ping), 用 M3U8Service
  final Map<String, _SourceSpeedInfo> _sourceSpeeds = {};
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

  // 自动播下一集: 防止 position/completed 重复触发
  bool _autoPlayedThisEpisode = false;

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

  // 全屏状态
  bool _isFullscreen = false;

  // 快进/快退提示文字 (点击后短暂显示, 如 "快进60s")
  String? _seekHintText;
  Timer? _seekHintTimer;

  // 亮度/音量手势 (v1.0.40 修复: 主播放器之前根本没接手势层)
  double _currentVolume = 0.5; // 0.0 ~ 1.0
  double _currentBrightness = 0.5;
  bool _showVolumeIndicator = false;
  bool _showBrightnessIndicator = false;
  Timer? _volumeHideTimer;
  Timer? _brightnessHideTimer;
  double? _dragStartVolume; // 拖动开始时的音量基线
  double? _dragStartBrightness;
  // v1.0.45: 累计拖动 delta, 解决 v1.0.40 "每事件用 baseline + 单帧 delta 覆盖" 的 bug
  // (以前 5 帧累计拖 100px, 每帧只算自己 20px, 实际只反映最后 1 帧的 delta)
  double _totalDragVolumeDelta = 0;
  double _totalDragBrightnessDelta = 0;

  // LunaTV Web 主题色
  static const Color kLunaTheme = Color(0xFF22C55E);
  static const Color kLunaLoadingColor = Color(0xFF009688);
  static const Color kLunaFloatBtnBg = Color(0x26FFFFFF);

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    // v1.0.41: 读系统初始亮度/音量, 进入播放器时同步到 UI
    // 注意: volume_controller v2.x / screen_brightness v0.2.x 都是单例 .instance API
    () async {
      try {
        final vol = await VolumeController().getVolume();
        if (mounted && vol != null) setState(() => _currentVolume = vol);
      } catch (_) {}
      try {
        final br = await ScreenBrightness().current;
        if (mounted && br != null) setState(() => _currentBrightness = br);
      } catch (_) {}
    }();
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
    // 监听播放位置和总时长，用于跳过片头片尾 / 自动播下一集
    _positionSub = _player.streams.position.listen((pos) {
      if (_scrubbingValue == null) {
        _currentPosition = pos;
        _updateSkipButtonVisibility();
        // 自动播下一集: 距离结尾 < 1.5s 且还没自动切过
        _maybeAutoPlayNext();
      }
    });
    _durationSub = _player.streams.duration.listen((dur) {
      _currentDuration = dur;
    });
    // streams.completed 兜底: 部分源 position 不走完会直接发 completed
    _player.streams.completed.listen((_) {
      _autoPlayNextEpisode();
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
    // 一集播完自动播下一集 (避免用户点下一集的繁琐)
    _loadSources();
  }

  @override
  void dispose() {
    // 退出时最后一次保存
    _saveCurrentProgress(force: true);
    _progressTimer?.cancel();
    _hideControlsTimer?.cancel();
    _seekHintTimer?.cancel();
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
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      // 底部抽屉选集: 跟 detail 选集同样的列数策略, 平板上避免卡片过大
                      final w = constraints.maxWidth;
                      int crossAxisCount;
                      if (w < 500) {
                        crossAxisCount = 5;
                      } else if (w < 800) {
                        crossAxisCount = 8;
                      } else if (w < 1100) {
                        crossAxisCount = 10;
                      } else {
                        crossAxisCount = 12;
                      }
                      return GridView.builder(
                        shrinkWrap: true,
                        itemCount: source.episodes.length,
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          childAspectRatio: 1.2,
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
    setState(() => _isFullscreen = true);
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
    setState(() => _isFullscreen = false);
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

  // ==================== 亮度/音量手势 (v1.0.40) ====================

  void _onVolumeSwipeStart(DragStartDetails details) {
    _volumeHideTimer?.cancel();
    _hideControlsTimer?.cancel();
    _dragStartVolume = _currentVolume;
    _totalDragVolumeDelta = 0; // v1.0.49: 重置累计 delta
    setState(() {
      _isControlsVisible = true;
      _showVolumeIndicator = true;
    });
  }

  void _onVolumeSwipeUpdate(DragUpdateDetails details) {
    // v1.0.49: 同亮度手势, 用累计 delta + 1.0 灵敏度
    // 旧版用单帧 delta + 固定基线, 慢滑会"抖" (每帧 dy 小, 音量来回跳)
    _totalDragVolumeDelta += -details.delta.dy; // 上滑增音量
    final screenHeight = MediaQuery.of(context).size.height;
    final normalized = (_totalDragVolumeDelta / screenHeight) * 1.0;
    setState(() {
      _currentVolume =
          (_dragStartVolume! + normalized).clamp(0.0, 1.0);
      _showVolumeIndicator = true;
    });
    // v1.0.44: v0.2.2 / 2.0.8 API 是 VolumeController() 实例, setVolume 不带 showSystemUI 参数
    VolumeController().setVolume(_currentVolume);
  }

  void _onVolumeSwipeEnd(DragEndDetails details) {
    _dragStartVolume = null;
    _volumeHideTimer?.cancel();
    _volumeHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showVolumeIndicator = false);
    });
    _scheduleHideControls();
  }

  void _onBrightnessSwipeStart(DragStartDetails details) {
    _brightnessHideTimer?.cancel();
    _hideControlsTimer?.cancel();
    _dragStartBrightness = _currentBrightness;
    _totalDragBrightnessDelta = 0; // v1.0.45: 重置累计 delta
    setState(() {
      _isControlsVisible = true;
      _showBrightnessIndicator = true;
    });
  }

  void _onBrightnessSwipeUpdate(DragUpdateDetails details) {
    // v1.0.45: 同音量手势, 用累计 delta + 1.0 灵敏度
    _totalDragBrightnessDelta += -details.delta.dy; // 上滑增亮
    final screenHeight = MediaQuery.of(context).size.height;
    final normalized = (_totalDragBrightnessDelta / screenHeight) * 1.0;
    setState(() {
      _currentBrightness = (_dragStartBrightness! + normalized).clamp(0.0, 1.0);
      _showBrightnessIndicator = true;
    });
    // v1.0.44: v0.2.2 / 2.0.8 API 是 ScreenBrightness() 实例, setScreenBrightness 而非 setApplicationScreenBrightness
    ScreenBrightness().setScreenBrightness(_currentBrightness);
  }

  void _onBrightnessSwipeEnd(DragEndDetails details) {
    _dragStartBrightness = null;
    _brightnessHideTimer?.cancel();
    _brightnessHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showBrightnessIndicator = false);
    });
    _scheduleHideControls();
  }

  // 单击中央 = 切显隐
  void _onCenterTap() {
    _toggleControls();
  }

  // 中间区域水平拖动 = 快进快退
  void _onCenterSwipeUpdate(DragUpdateDetails details) {
    final screenWidth = MediaQuery.of(context).size.width;
    // 整屏 1:1 映射, 60s/半屏
    final deltaMs = (details.delta.dx / screenWidth * 60000).round();
    final newMs = (_currentPosition.inMilliseconds + deltaMs)
        .clamp(0, _currentDuration.inMilliseconds)
        .toInt();
    _player.seek(Duration(milliseconds: newMs));
    final isForward = deltaMs >= 0;
    setState(() {
      _seekHintText = isForward ? '快进${(deltaMs / 1000).round()}s' : '快退${(-deltaMs / 1000).round()}s';
    });
    _seekHintTimer?.cancel();
    _seekHintTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _seekHintText = null);
    });
  }

  // ==================== 进度条拖动 ====================

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

  /// 启动后云记忆里查到的 episode, 准备在 _playEpisode 时 seek 过去
  Duration? _pendingResumeAt;

  // 加载多源并自动测速
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

    // 先尝试从云端拉一次播放记录, 防止 videoInfo 没带 source/index
    // (比如从搜索结果直接点进来, 但云端其实有别的源在播)
    final resume = widget.videoInfo.source.isEmpty || widget.videoInfo.index <= 0
        ? await _tryLoadResumeFromCloud(title)
        : null;
    final resumeSourceKey = resume?.source ?? widget.videoInfo.source;
    final resumeIndex = resume != null
        ? (resume.index - 1).clamp(0, 1 << 30)
        : (widget.videoInfo.index - 1).clamp(0, 1 << 30);
    if (resume != null && resume.playTime > 0) {
      _pendingResumeAt = Duration(milliseconds: resume.playTime);
    } else if (widget.videoInfo.playTime > 0) {
      _pendingResumeAt = Duration(milliseconds: widget.videoInfo.playTime);
    }

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

      // (按 source key 去重已经在 ApiService.fetchSourcesData 里做了,
      // 这里不用再 dedupe)
      setState(() {
        _sourceResults = results;
        _sourcesLoading = false;
      });

      // 选源优先级:
      // 1. 云记忆里有这个 video 的源 (resume.source)
      // 2. 入口传过来的 preferredSource
      // 3. 第一个
      SearchResult toSelect = results.first;
      if (resumeSourceKey.isNotEmpty) {
        for (final r in results) {
          if (r.source == resumeSourceKey) {
            toSelect = r;
            break;
          }
        }
      }
      if (widget.preferredSource != null && widget.preferredSource!.isNotEmpty) {
        for (final r in results) {
          if (r.source == widget.preferredSource) {
            toSelect = r;
            break;
          }
        }
      }
      _selectSource(toSelect, episodeIndex: resumeIndex);

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

  /// 从云端拉播放记录, 按 searchTitle 找最近一条
  /// 用于 videoInfo 没带 source 信息时兜底
  Future<PlayRecord?> _tryLoadResumeFromCloud(String searchTitle) async {
    try {
      final result =
          await PageCacheService().getPlayRecords(context);
      if (!result.success || result.data == null) return null;
      // 优先 searchTitle 完全匹配, 没有再退化到 title
      final matches = result.data!
          .where((r) => r.searchTitle == searchTitle || r.title == searchTitle)
          .toList();
      if (matches.isEmpty) return null;
      matches.sort((a, b) => b.saveTime.compareTo(a.saveTime));
      return matches.first;
    } catch (_) {
      return null;
    }
  }

  /// v1.0.47: episodeIndex 默认值改成 _currentEpisodeIndex 而不是 0
  /// 之前默认值是 0, 导致用户手动切源时 episode 被静默重置 (明明看到第 3 集,
  /// 点切源就被弹回第 1 集, 因为新源默认从 0 开始播)
  void _selectSource(SearchResult result, {int? episodeIndex}) {
    // 不传 episodeIndex: 尽量保留当前 episode
    //   - 切到的就是当前源 (罕见, 防呆): 不动 episode
    //   - 切到新源: 尽量用当前 episode (新源可能有这么多集)
    final int target = episodeIndex ?? _currentEpisodeIndex;
    final maxIdx = result.episodes.isEmpty ? 0 : result.episodes.length - 1;
    final clampedIndex = target.clamp(0, maxIdx);
    setState(() {
      _selectedSource = result;
      _currentEpisodeIndex = clampedIndex;
    });
  }

  /// 后台测速所有源：并发用 M3U8Service 测速, 并按综合分从高到低排序源列表
  /// v1.0.45: 完整测速 (分辨率 + 下载速度 + ping) 替代 v1.0.40 之前的简单 HEAD ping
  Future<void> _testAllSourcesInBackground() async {
    // 先标记所有源为测速中
    final pending = <_SourcePingItem>[];
    for (final s in _sourceResults) {
      if (s.episodes.isEmpty) continue;
      _pingState[s.source] = PingState.testing;
      pending.add(_SourcePingItem(s));
    }
    if (mounted) setState(() {});

    // 并发测速 (最多同时 6 个, 避免瞬时连接太多)
    // 跟 Selene 不同: 我们不等所有源都完, 每个源完成立即更新 UI
    // (testSourcesWithCallback 自带 5s 超时, 单源最多 5s)
    const maxConcurrent = 6;
    final m3u8 = M3U8Service();
    for (var i = 0; i < pending.length; i += maxConcurrent) {
      final batch = pending.skip(i).take(maxConcurrent);
      await Future.wait(batch.map((item) async {
        final speed = await _testSourceSpeed(m3u8, item.source);
        if (!mounted) return;
        _sourceSpeeds[item.source.source] = speed;
        _pingState[item.source.source] = _stateFromSpeed(speed);
        if (mounted) setState(() {});
      }));
    }

    if (!mounted) return;
    if (mounted) setState(() {});

    // 自动选最快源 (除非用户已经主动选过, 或从历史点进来明确指定了源)
    // v1.0.46 fix: 之前从历史进来也会被自动改源, 因为 _selectSource 不传 episodeIndex
    //   会重置到 0, 导致每次历史播放都从第 1 集开始
    final cameFromHistory = widget.videoInfo.source.isNotEmpty && widget.videoInfo.index > 0;
    if (!cameFromHistory && _autoSelectedSource == null && _sourceResults.isNotEmpty) {
      _SourceSpeedInfo? bestSpeed;
      String? bestSource;
      for (final s in _sourceResults) {
        final sp = _sourceSpeeds[s.source];
        if (sp == null) continue;
        if (bestSpeed == null || sp.score < bestSpeed.score) {
          bestSpeed = sp;
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
    } else if (cameFromHistory) {
      // 从历史进来的: 标记自动已选 (用历史源), 防止后续逻辑再触发自动切源
      _autoSelectedSource = _selectedSource?.source ?? widget.videoInfo.source;
    }

    // 按综合分从高到低重排源列表 (历史模式也排, 让用户能直观看到哪个源更快)
    _sortSourcesBySpeed();
  }

  /// 测单个源: 走 M3U8Service 完整测速, 失败 fallback 到 HEAD ping
  Future<_SourceSpeedInfo> _testSourceSpeed(M3U8Service m3u8, SearchResult s) async {
    if (s.episodes.isEmpty) return _SourceSpeedInfo.unavailable();
    final url = UserDataService.buildProxiedUrl(s.episodes.first, forceM3u8: true);
    try {
      // v1.0.45: 优化后单源测速 0.5~1.5s, 给 4s 超时足够
      final result = await m3u8.getStreamInfo(url).timeout(
        const Duration(seconds: 4),
        onTimeout: () => <String, dynamic>{
          'resolution': {'width': 0, 'height': 0},
          'downloadSpeed': 0.0,
          'latency': 0,
          'success': false,
          'error': 'timeout',
        },
      );
      if (result['success'] == true) {
        final res = (result['resolution'] as Map).cast<String, int>();
        final h = res['height'] ?? 0;
        return _SourceSpeedInfo(
          resolution: _formatResolution(h),
          loadSpeedKBps: (result['downloadSpeed'] as num).toDouble(),
          pingMs: (result['latency'] as num).toInt(),
          success: true,
        );
      }
    } catch (_) {}
    // fallback: HEAD ping (1.5s)
    return await _fallbackHeadPing(url);
  }

  String _formatResolution(int h) {
    if (h <= 0) return '';
    if (h >= 2160) return '4K';
    return '${h}p';
  }

  Future<_SourceSpeedInfo> _fallbackHeadPing(String url) async {
    if (_pingCache.containsKey(url)) {
      final ms = _pingCache[url]!;
      return _SourceSpeedInfo(
        resolution: '', loadSpeedKBps: 0, pingMs: ms,
        success: ms < 3000,
      );
    }
    final start = DateTime.now();
    final httpClient = http.Client();
    try {
      final req = http.Request('HEAD', Uri.parse(url))
        ..followRedirects = true
        ..maxRedirects = 2;
      await httpClient.send(req).timeout(const Duration(milliseconds: 1500));
    } catch (_) {
      _pingCache[url] = 3000;
      return _SourceSpeedInfo(resolution: '', loadSpeedKBps: 0, pingMs: 3000, success: false);
    }
    final ms = DateTime.now().difference(start).inMilliseconds;
    _pingCache[url] = ms;
    return _SourceSpeedInfo(
      resolution: '', loadSpeedKBps: 0, pingMs: ms,
      success: ms < 3000,
    );
  }

  PingState _stateFromSpeed(_SourceSpeedInfo s) {
    if (!s.success) return PingState.unavailable;
    // 速度 > 500KB/s 且 ping < 1000ms = fast
    // 速度 < 100KB/s 或 ping > 2000ms = slow
    if (s.loadSpeedKBps >= 500 && s.pingMs < 1000) return PingState.fast;
    if (s.loadSpeedKBps >= 200 && s.pingMs < 2000) return PingState.medium;
    return PingState.slow;
  }

  /// 按测速综合分从高到低排序源列表
  void _sortSourcesBySpeed() {
    setState(() {
      _sourceResults.sort((a, b) {
        final sa = _sourceSpeeds[a.source];
        final sb = _sourceSpeeds[b.source];
        if (sa == null && sb == null) return 0;
        if (sa == null) return 1; // 未测的排后面
        if (sb == null) return -1;
        return sa.score.compareTo(sb.score);
      });
    });
  }

  // v1.0.45: 删了 v1.0.40 之前的 _pingSource (简单 HEAD ping) 和 _stateFromMs,
  // 改用 M3U8Service 测速 + _stateFromSpeed. 老方法没人调, 留在这里只是 dead code.
  // 如需 HEAD ping fallback, 看 _fallbackHeadPing.

  /// position stream 触发的检查: 距离结尾 < 1.5s 时尝试自动切下一集
  void _maybeAutoPlayNext() {
    if (_autoPlayedThisEpisode) return;
    final dur = _currentDuration;
    if (dur <= Duration.zero) return; // 时长还没拿到, 不要误判
    final remainMs = dur.inMilliseconds - _currentPosition.inMilliseconds;
    if (remainMs > 1500) return; // 还没到结尾附近
    _autoPlayNextEpisode();
  }

  /// 切到下一集: 只有在「还有下一集」时才自动播放
  /// 最后一集播完就停在播放页, 不再继续
  void _autoPlayNextEpisode() {
    if (_autoPlayedThisEpisode) return;
    if (_phase != 'playing') return;
    final source = _selectedSource;
    if (source == null) return;
    final nextIndex = _currentEpisodeIndex + 1;
    if (nextIndex >= source.episodes.length) return; // 最后一集
    if (source.episodes[nextIndex].isEmpty) return; // 下一集没 url
    _autoPlayedThisEpisode = true; // 立刻上锁, 防止 position/completed 双触发
    _playEpisode(nextIndex);
  }

  /// 播放指定集数
  Future<void> _playEpisode(int index) async {
    final source = _selectedSource;
    if (source == null) return;
    if (index < 0 || index >= source.episodes.length) return;
    final url = source.episodes[index];
    if (url.isEmpty) return;

    // 切集时先把自动切下一集标志重置, 让新一集播完时能再次触发
    _autoPlayedThisEpisode = false;

    // 记住这次要 seek 到的位置, 等 player 缓冲到可以 seek 时用
    // 仅在用户主动开新集时且和云记忆吻合的那次才用
    Duration? resumeAt;
    if (_pendingResumeAt != null && index == _currentEpisodeIndex) {
      resumeAt = _pendingResumeAt;
    }
    // 用完清掉, 避免切下一集时还 seek 回去
    _pendingResumeAt = null;

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
      // 云记忆恢复: 缓冲到能播后 seek 到上次的位置
      if (resumeAt != null) {
        try {
          await _player.seek(resumeAt);
        } catch (_) {}
      }
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
              // 从播放页返回详情页: 先保存一次, 恢复竖屏, 暂停播放
              // (重点:必须先 stop/pause,否则 detail 视图上 player 还在后台继续播)
              try {
                await _player.stop();
              } catch (_) {}
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
    // v1.0.45: 取完整测速信息 (分辨率 + 速度 + ping)
    final speed = _sourceSpeeds[s.source];
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
            // v1.0.45: 显示完整测速信息 (分辨率 + 速度 + ping)
            _buildSpeedLabel(state, speed, ms),
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

  /// v1.0.45: 显示完整测速结果
  ///   - 测试中: "测速中"
  ///   - idle: "待测"
  ///   - 失败: "不可用"
  ///   - 成功: "720p · 1.2MB/s · 85ms" (直链没分辨率时省略)
  Widget _buildSpeedLabel(PingState state, _SourceSpeedInfo? speed, int? ms) {
    String text;
    Color color;
    if (state == PingState.testing) {
      text = '测速中';
      color = const Color(0xFFF59E0B);
    } else if (state == PingState.idle) {
      text = '待测';
      color = const Color(0xFF9CA3AF);
    } else if (state == PingState.unavailable || speed == null || !speed.success) {
      // 测失败时如果还有旧 ms (来自 fallback HEAD ping), 显示 ms
      text = (ms != null && ms < 3000) ? '${ms}ms' : '不可用';
      color = (ms != null && ms < 3000) ? const Color(0xFFEF4444) : const Color(0xFF9CA3AF);
    } else {
      // 成功: 拼 "分辨率 · 速度 · ping" (缺哪个就省哪个)
      final parts = <String>[];
      if (speed.resolution.isNotEmpty) parts.add(speed.resolution);
      final speedStr = speed.formatLoadSpeed();
      if (speedStr.isNotEmpty) parts.add(speedStr);
      if (speed.pingMs > 0) parts.add('${speed.pingMs}ms');
      text = parts.isEmpty ? (ms != null ? '${ms}ms' : 'OK') : parts.join(' · ');
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
            LayoutBuilder(
              builder: (context, constraints) {
                // 平板上宽度很大, 写死 6 列会让每张卡片巨大、文字居中显空,
                // 按宽度动态算列数: 手机 6 列(卡片~50dp), 平板 8~12 列
                final width = constraints.maxWidth;
                int crossAxisCount;
                if (width < 600) {
                  crossAxisCount = 6; // 手机
                } else if (width < 900) {
                  crossAxisCount = 8; // 小平板
                } else if (width < 1200) {
                  crossAxisCount = 10; // 中平板
                } else {
                  crossAxisCount = 12; // 大平板/PC
                }
                // 卡片宽度 = (width - spacing*(cols-1)) / cols
                const spacing = 6.0;
                final cardW =
                    (width - spacing * (crossAxisCount - 1)) / crossAxisCount;
                // 卡片高度按宽度等比例: 宽 < 80dp 的按 1.2 比例(略宽), 否则接近方形
                final childAspectRatio = cardW < 80 ? 1.2 : 1.0;
                // 字号也按卡片宽度微调: 小卡片 11, 大卡片 12
                final fontSize = cardW < 80 ? 11.0 : 12.0;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  gridDelegate:
                      SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    childAspectRatio: childAspectRatio,
                    mainAxisSpacing: spacing,
                    crossAxisSpacing: spacing,
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
                        if (index != _currentEpisodeIndex ||
                            _phase != 'playing') {
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
                              fontSize: fontSize,
                              fontWeight: FontWeight.w600,
                              color: isCurrent
                                  ? Colors.white
                                  : (isDark
                                      ? Colors.white70
                                      : Colors.black87),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
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

  /// 顶部栏: 80px 黑色渐变 + 片名 + 集数胶囊 (LunaTV Web 风格)
  Widget _buildLunaTopBar() {
    if (!_isControlsVisible) return const SizedBox.shrink();
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
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              // 返回箭头
              _iconBtn(
                icon: Icons.arrow_back,
                onTap: () {
                  // 重点:从播放视图点返回箭头时也要先 stop,否则 player
                  // 还在后台继续播,detail 视图上还能听到声音
                  () async {
                    try {
                      await _player.stop();
                    } catch (_) {}
                    if (!mounted) return;
                    await _onExitFullscreen();
                    if (!mounted) return;
                    setState(() => _phase = 'detail');
                  }();
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
              // 收藏
              _iconBtn(
                icon: _isFavorite ? Icons.favorite : Icons.favorite_border,
                onTap: _toggleFavorite,
              ),
              // 设置
              _iconBtn(
                icon: Icons.settings_outlined,
                onTap: _showSettingsSheet,
              ),
              // 集数胶囊徽章 (灰白主题)
              if (totalEps > 0)
                Container(
                  margin: const EdgeInsets.only(left: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.3),
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    totalEps > 1 ? '$currentEp/$totalEps' : '第$currentEp集',
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

  /// 中央控制区: 左右快退/快进60s 按钮 + 中间播放/暂停
  /// 跟控件一起显隐, 点击后短暂显示提示文字
  Widget _buildSideSeekButtons() {
    if (!_isControlsVisible) return const SizedBox.shrink();
    final size = _isFullscreen ? 64.0 : 56.0;
    // v1.0.49: 离边 60/80 → 40/60, 按钮往中间挪一点 (与中央播放按钮的间距从 88/112px 缩到 68/92px)
    final sideOffset = _isFullscreen ? 60.0 : 40.0;
    return Positioned.fill(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 左: 快退60s 按钮(文字 -60)
          Positioned(
            left: sideOffset,
            top: 0,
            bottom: 0,
            child: Center(
              child: _buildSeekCircleButton(
                size: size,
                onTap: () => _seekBySeconds(-60, '快退60s'),
                child: const _SeekLabel(label: '-60'),
              ),
            ),
          ),
          // 右: 快进60s 按钮(文字 +60)
          Positioned(
            right: sideOffset,
            top: 0,
            bottom: 0,
            child: Center(
              child: _buildSeekCircleButton(
                size: size,
                onTap: () => _seekBySeconds(60, '快进60s'),
                child: const _SeekLabel(label: '+60'),
              ),
            ),
          ),
          // 中间: 播放/暂停按钮 (v1.0.49: 颜色跟播控进度条一致用 kLunaTheme)
          _buildSeekCircleButton(
            size: size,
            onTap: _togglePlayPause,
            child: Icon(
              _isPlaying ? Icons.pause : Icons.play_arrow,
              color: kLunaTheme,
              size: 32,
            ),
          ),
          // 快进/快退提示文字 (点击后短暂显示)
          if (_seekHintText != null)
            Positioned(
              bottom: 120,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _seekHintText!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 快进/快退指定秒数, 并显示提示文字
  void _seekBySeconds(int seconds, String hint) {
    final newPos = _currentPosition + Duration(seconds: seconds);
    if (seconds < 0) {
      _player.seek(newPos < Duration.zero ? Duration.zero : newPos);
    } else {
      final max = _currentDuration;
      _player.seek(newPos > max ? max : newPos);
    }
    // 显示提示文字, 1秒后消失
    _seekHintTimer?.cancel();
    setState(() => _seekHintText = hint);
    _seekHintTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _seekHintText = null);
    });
    _scheduleHideControls();
  }

  /// 圆形毛玻璃快进/快退按钮
  Widget _buildSeekCircleButton({
    required VoidCallback onTap,
    required Widget child,
    required double size,
  }) {
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
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }

  /// 圆弧箭头图标 (已废弃, 快进/快退按钮改用 _SeekLabel 文字)
  // ignore: unused_element
  Widget _buildSeekIcon({required bool forward}) {
    return _SeekLabel(label: forward ? '+60' : '-60');
  }

  /// 圆形小按钮 (40x40, LunaTV Web 控制按钮)
  Widget _iconBtn({required IconData icon, required VoidCallback? onTap}) {
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
            color:
                onTap == null ? Colors.white.withOpacity(0.3) : Colors.white,
            size: 22,
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

  /// 底部控制栏 (毛玻璃容器 + 5px进度条 + 按钮行, LunaTV Web 风格)
  /// 横屏时底部栏改短 (maxWidth 限制)
  Widget _buildLunaBottomBar() {
    if (!_isControlsVisible) return const SizedBox.shrink();
    final dur = _currentDuration.inMilliseconds.toDouble();
    final pos = _scrubbingValue != null
        ? (_scrubbingValue! * dur).toInt()
        : _currentPosition.inMilliseconds;
    // 底部栏宽度: 横屏全屏时缩短到 60%, 竖屏时 85% 宽度
    final screenWidth = MediaQuery.of(context).size.width;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final maxW = isLandscape ? screenWidth * 0.6 : screenWidth * 0.85;
    return Positioned(
      left: 12,
      right: 12,
      bottom: 12,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 顶部: 进度条 (5px 矩形, LunaTV Web 风格)
                    _buildLunaProgressBar(),
                    // 底部: 左中右按钮行
                    SizedBox(
                      height: 44,
                      child: Row(
                        children: [
                          // 左: 播放/暂停
                          _iconBtn(
                            icon: _isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            onTap: _togglePlayPause,
                          ),
                          // 时间
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 6),
                            child: Text(
                              '${_formatDuration(Duration(milliseconds: pos))} / ${_formatDuration(_currentDuration)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontFeatures: [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          ),
                          const Spacer(),
                          // 右: 倍速
                          _iconBtn(
                            icon: Icons.speed,
                            onTap: _showPlaybackRateSheet,
                          ),
                          // 选集
                          _iconBtn(
                            icon: Icons.format_list_bulleted,
                            onTap: _showEpisodeSelectorSheet,
                          ),
                          // 全屏
                          _iconBtn(
                            icon: _isFullscreen
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                            onTap: _isFullscreen
                                ? _onExitFullscreen
                                : _onEnterFullscreen,
                          ),
                        ],
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

  /// 进度条 (5px 矩形, 绿进度, LunaTV Web 风格)
  Widget _buildLunaProgressBar() {
    final dur = _currentDuration.inMilliseconds.toDouble();
    final pos = _scrubbingValue != null
        ? (_scrubbingValue! * dur).toInt()
        : _currentPosition.inMilliseconds;
    final progress = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
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
          // 进度条
          FractionallySizedBox(
            widthFactor: progress,
            child: Container(
              decoration: BoxDecoration(
                color: kLunaTheme,
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
          ),
          // 拖动手柄
          if (dur > 0)
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
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: progress,
                  onChangeStart: _onScrubStart,
                  onChanged: _onScrubChange,
                  onChangeEnd: _onScrubEnd,
                ),
              ),
            ),
        ],
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

  /// 主播放视图 (12ce29d 简单 Stack 结构 + LunaTV Web 风格控件)
  /// 不用 LayoutBuilder / GestureDetector, 避免 video 纹理被重建导致白屏
  Widget _buildPlayingView(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 视频 (12ce29d 结构: Container+AspectRatio+Stack+Video(NoVideoControls))
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
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                            color: kLunaLoadingColor, strokeWidth: 3),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 点击空白区切换控制栏显隐 (始终存在, 控件隐藏时也能点击调出)
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _toggleControls,
          ),
        ),
        // 亮度/音量/快进 快退 手势层 (v1.0.40 修复: 主播放器之前根本没接)
        // 左 1/4 上下 = 亮度, 右 1/4 上下 = 音量, 中间 1/2 左右 = 快进快退
        Positioned.fill(
          child: Row(
            children: [
              // 左: 亮度
              Expanded(
                flex: 1,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragStart: _onBrightnessSwipeStart,
                  onVerticalDragUpdate: _onBrightnessSwipeUpdate,
                  onVerticalDragEnd: _onBrightnessSwipeEnd,
                ),
              ),
              // 中: 快进快退
              Expanded(
                flex: 2,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: _onCenterSwipeUpdate,
                ),
              ),
              // 右: 音量
              Expanded(
                flex: 1,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragStart: _onVolumeSwipeStart,
                  onVerticalDragUpdate: _onVolumeSwipeUpdate,
                  onVerticalDragEnd: _onVolumeSwipeEnd,
                ),
              ),
            ],
          ),
        ),
        // 亮度浮窗指示器 (左侧, 竖屏横屏都显示)
        if (_showBrightnessIndicator) _buildBrightnessIndicator(),
        // 音量浮窗指示器 (右侧, 竖屏横屏都显示)
        if (_showVolumeIndicator) _buildVolumeIndicator(),
        // 顶部栏 (80px 渐变 + 集数胶囊)
        _buildLunaTopBar(),
        // 底部毛玻璃控制栏 (横屏改短)
        _buildLunaBottomBar(),
        // 跳过片头按钮(右下角浮层)
        if (_showSkipIntro && _isControlsVisible)
          Positioned(
            right: 16,
            bottom: 100,
            child: _skipButton('跳过片头', kLunaTheme, _skipIntro),
          ),
        // 跳过片尾按钮(右下角浮层)
        if (_showSkipOutro && _isControlsVisible)
          Positioned(
            right: 16,
            bottom: 100,
            child: _skipButton(
                '跳过片尾', const Color(0xFF3B82F6), _skipOutro),
          ),
        // 中央双圆快进/快退 (放在最上层, 避免被顶部栏/底部栏/跳过按钮遮挡)
        _buildSideSeekButtons(),
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

  /// 亮度浮窗 (左侧, v1.0.40 修复主播放器手势)
  Widget _buildBrightnessIndicator() {
    return Positioned(
      left: 32,
      top: 0,
      bottom: 0,
      child: Center(
        child: Container(
          width: 56,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.brightness_6, color: Colors.white, size: 28),
              const SizedBox(height: 10),
              SizedBox(
                width: 4,
                height: 120,
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: _currentBrightness,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${(_currentBrightness * 100).round()}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 音量浮窗 (右侧, v1.0.40 修复主播放器手势)
  Widget _buildVolumeIndicator() {
    return Positioned(
      right: 32,
      top: 0,
      bottom: 0,
      child: Center(
        child: Container(
          width: 56,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _currentVolume == 0
                    ? Icons.volume_off
                    : _currentVolume < 0.5
                        ? Icons.volume_down
                        : Icons.volume_up,
                color: Colors.white,
                size: 28,
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: 4,
                height: 120,
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: _currentVolume,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${(_currentVolume * 100).round()}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 快进/快退 60s 按钮的文字标签 (替代原先的自绘圆弧箭头, 视觉更直接)
class _SeekLabel extends StatelessWidget {
  final String label;
  const _SeekLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

enum PingState { idle, testing, fast, medium, slow, unavailable }

/// 源测速结果 (v1.0.45: 用 M3U8Service 测完整信息, 不再只 HEAD ping)
class _SourceSpeedInfo {
  final String resolution; // e.g. "720p" / "1080p" / "4K", 空 = 未知
  final double loadSpeedKBps; // 下载速度 KB/s
  final int pingMs; // 延迟 ms
  final bool success; // false = 测失败, 排到最后
  const _SourceSpeedInfo({
    required this.resolution,
    required this.loadSpeedKBps,
    required this.pingMs,
    required this.success,
  });
  static _SourceSpeedInfo unavailable() =>
      const _SourceSpeedInfo(resolution: '', loadSpeedKBps: 0, pingMs: 3000, success: false);

  /// 格式化下载速度 (KB/s → MB/s, 自动单位)
  String formatLoadSpeed() {
    if (loadSpeedKBps <= 0) return '';
    if (loadSpeedKBps >= 1024) {
      return '${(loadSpeedKBps / 1024).toStringAsFixed(1)}MB/s';
    }
    return '${loadSpeedKBps.toStringAsFixed(0)}KB/s';
  }

  /// 综合评分 (越小越好, 用作排序 key)
  /// 分辨率权重: 4K=2.0, 1080p=1.5, 720p=1.0, 标清=0.7
  /// 分数 = -(有效速度 * 分辨率权重) + ping
  ///   → 速度越快分数越低, 延迟越低分数越低, 排序时排前面
  ///   → 失败的给最大分数排最后
  int get score {
    if (!success) return 1 << 30;
    double resWeight;
    if (resolution.isEmpty) {
      resWeight = 1.0;
    } else {
      final p = int.tryParse(resolution.replaceAll('p', '').replaceAll('K', '000')) ?? 720;
      if (p >= 2160) {
        resWeight = 2.0;
      } else if (p >= 1080) {
        resWeight = 1.5;
      } else if (p >= 720) {
        resWeight = 1.0;
      } else {
        resWeight = 0.7;
      }
    }
    return -(loadSpeedKBps * resWeight).round() + pingMs;
  }
}
