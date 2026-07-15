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
import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/douban_service.dart';
import 'package:luna_tv/services/page_cache_service.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/m3u8_service.dart';
import 'package:luna_tv/services/video_proxy_server.dart';
import 'package:luna_tv/services/mpv_ffi.dart';
import 'package:luna_tv/models/douban_movie.dart';
import 'package:luna_tv/models/play_record.dart';
import 'package:luna_tv/models/search_result.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/cf_optimizer.dart';
import 'package:luna_tv/services/luna_cache_manager.dart';
import 'package:luna_tv/utils/image_url.dart';
import 'package:luna_tv/widgets/douban_detail_header.dart';
import 'package:luna_tv/services/tmdb_service.dart';
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

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  // 播放器
  late final Player _player;
  late final VideoController _controller;
  // v2.0.16: 视频代理 (让 libmpv 走优选 IP)
  VideoProxyServer? _videoProxy;
  // v2.0.34: 顶部「加速状态」指示器用, 视频代理实际在跑时为 true
  bool _videoProxyActive = false;
  // v2.0.34: 实时下载速度 (Bytes/s), 1Hz 采样 libmpv demuxer-bytes 算 delta
  double _downloadSpeedBps = 0;
  Timer? _speedSampleTimer;
  int _lastDemuxerBytes = 0;
  int _lastSampleMs = 0;
  // v2.0.34: 「加速链路」弹层用, 保存当前播放 URL (buildProxiedUrl 之后的最终 URL)
  String _currentPlayUrl = '';
  // v2.0.93: TMDB 精准识别的 w1280 backdrop URL, 传给 DoubanDetailHeader
  //   替代豆瓣 coverUrl. 加载完成后 setState 触发 rebuild, 没加载完
  //   / 加载失败 / 没配 key = null, DoubanDetailHeader 走 coverUrl 兜底.
  String? _tmdbBackdropUrl;
  // v2.1.7: 豆瓣剧情简介 — 通过 DoubanService.getDoubanDetails 拉 doubanId
  //   详情, 取 summary 字段. 用户反馈"海报多的地方放上电影简介", 在选集
  //   section 跟源 section 之间插一个简介 card. 没 doubanId / 拉不到 / 字段空
  //   = 不渲染, 行为不变 (不占空白).
  String? _summary;
  // v2.1.17: TMDB 卡司 (演员) — 平板大头部背景图下半部展示横向滚动的
  //   演员头像 + 名字. 用户反馈"海报内好多空白的地方看到没 / 放上演员吧
  //   怎么样 / 或者海报那个好 / 都在一行要有演员图片那种 / 不够排就滑动".
  //   跟 _summary / _tmdbBackdropUrl 同模式: TMDB search → credits 接口,
  //   不依赖 doubanId, 主页/历史/收藏页都能拉到. null = 没配 key / 拉不到.
  List<TmdbCast>? _cast;
  bool _summaryExpanded = false; // 用户点击"展开"切换

  // 状态
  String _phase = 'detail'; // detail | playing
  bool _isBuffering = false;
  String? _error;

  // 多源结果
  List<SearchResult> _sourceResults = [];
  bool _sourcesLoading = true;
  final Map<String, int> _pingCache = {}; // 兼容旧 fallback 测速 (v1.0.69 暂留, 不再写入)
  final Map<String, PingState> _pingState = {};
  // v1.0.45: 完整测速信息 (分辨率 + 下载速度 + ping), 用 M3U8Service
  final Map<String, _SourceSpeedInfo> _sourceSpeeds = {};
  String? _autoSelectedSource;

  // 当前选中的源 / 集
  SearchResult? _selectedSource;
  int _currentEpisodeIndex = 0;
  // v2.0.51: 选集 PageView 控制器 + notifier (给翻页 badge "1/2" 用,
  //   滑动 PageView 时 badge 数字跟着变)
  late final PageController _episodesPageController;
  final ValueNotifier<PageController> _pageControllerNotifier =
      ValueNotifier<PageController>(_EmptyPageController.instance);

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
  // v1.0.58: 默认手动, 有的源没片头/片尾, 自动跳会跳错
  // 用户在设置弹窗里能切到自动模式
  bool _autoSkipIntro = false;
  bool _autoSkipOutro = false;
  Duration _currentPosition = Duration.zero;
  Duration _currentDuration = Duration.zero;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  // 控制跳过按钮显示（避免反复触发）
  bool _showSkipIntro = false;
  bool _showSkipOutro = false;
  // v2.1.18: 广告重置检测 — 锁定整段播放期不再触发跳过片头.
  //   触发条件: currentTime 从正片位置 (>60s) 突然倒退到接近 0 (<10s),
  //   而 _currentDuration 不变 (广告跟正片在同一条流里, 总时长不变).
  //   触发后整个 _State 生命周期不再重置, 后续 3-4 次广告都不会再被误判.
  //   用户拖进度条 (前跳) 不会触发, 因为不满足"倒退到 0".
  bool _adResetDetected = false;
  // 上一帧 position (秒), 用来算 delta 检测倒退. -1 表示未初始化.
  int _lastPosForAdDetect = -1;

  // _lastKnownPosition: position stream 每帧更新, 记"上一次非 0 位置".
  // 用于进度同步兜底 (libmpv m3u8 reload 期间 state.position=0,
  // _currentPosition 也被重置, 用 _lastKnownPosition 拿 reload 前的位置,
  // 避免 10s 定时器存 0 覆盖云端进度).
  // v2.1.13: 删掉广告自动跳过逻辑 (duration 跳变 + position 倒退检测 +
  //   _skipAd helper). 用户反馈反复卡同一广告位 / seek 错乱, 决定移除
  //   runtime 兜底, 改靠 m3u8 重写层 (视频代理开关) 物理删广告段.
  Duration _lastKnownPosition = Duration.zero;

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

  // 快进/快退提示文字 (点击后短暂显示, 如 "快进6s")
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
    // v2.0.96: 给 libmpv 配播放调优 (hwdec/cache/framedrop).
    //   修复用户反馈「播放一有事卡住, 声音还有, 然后突然快速播放一段」:
    //   Player() 默认无任何 mpv 配置 → 软解 + framedrop=vo → 复杂片段丢视频帧
    //   保音频同步 → 音还在画面卡 → 解码追上后 burst = "快速播放一段".
    //   调优内容见 MpvFFI.applyPlaybackTuning 注释. fire-and-forget, 失败静默
    //   回退默认行为 (不影响播放, 只是没有调优效果).
    unawaited(() async {
      if (!MpvFFI.isAvailable) return;
      try {
        final handle = await _player.handle;
        MpvFFI.applyPlaybackTuning(handle);
      } catch (_) {}
    }());
    // v2.0.51: 选集 PageView 初始化
    _episodesPageController = PageController();
    _pageControllerNotifier.value = _episodesPageController;
    // v1.0.50: 监听 AppLifecycleState, 进后台 (home 键) 时立即保存一次,
    // 避免 10s progressTimer 还没触发就被上滑/杀进程, 进度丢
    WidgetsBinding.instance.addObserver(this);
    // v1.0.54: 关闭系统音量弹窗, 自己接管音量 UI (右侧指示器)
    // volume_controller 2.0.2+ Android / 2.0.6+ iOS 都支持 showSystemUI 静态字段
    // 默认 true, 每次 setVolume 都会弹系统音量窗口遮挡视频
    // mobile_player_controls.dart:110 同模板, 但 player_screen 是另一个 widget
    // 自己的 _onVolumeSwipeUpdate → setVolume 路径没人设过这个字段, 所以会弹
    VolumeController().showSystemUI = false;
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
    // v2.0.93: 后台调 TMDB search + fetchArt 拿 w1280 backdrop, 完成后
    //   setState 触发 DoubanDetailHeader rebuild 用 TMDB backdrop 替
    //   代豆瓣 coverUrl. 没配 key / 搜索失败 / 抓不到 backdrop = null,
    //   DoubanDetailHeader 走 coverUrl 兜底, 行为完全不变.
    //   不 await — fire-and-forget, 用户不卡, 加载完 DoubanDetailHeader
    //   自动切到更清的 TMDB backdrop.
    _loadTmdbBackdrop();
    // v2.1.7: 拉豆瓣剧情简介 (跟 _loadTmdbBackdrop 同样静默 fallback)
    _loadDoubanSummary();
    // v2.1.17: 拉 TMDB 演员 (跟 _loadTmdbBackdrop 同样静默 fallback)
    _loadTmdbCast();
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
      if (!mounted) return;
      if (_scrubbingValue == null) {
        _currentPosition = pos;
        // 记"上一次非 0 位置" — 用于进度同步兜底 (见 _onPlayerPeriodicSave).
        // 任何非 0 position 都更新, 包括用户拖进度条. pos=0 不更新
        // (m3u8 reload 期间保持 reload 前的位置).
        if (pos > Duration.zero) {
          _lastKnownPosition = pos;
        }
        // v1.0.52: 实时刷新时间文字 + 进度条
        // 之前只更新 _currentPosition 但不 setState, 底部栏的
        // "${pos} / ${dur}" 时间文字 + 进度条 thumb 永远停在打开时那一帧,
        // 只有 _updateSkipButtonVisibility 命中 visibility 变化时才会 setState
        // (而且只切 skip 按钮, 不会重算时间文字)
        if (_isControlsVisible) {
          setState(() {});
        }
        _updateSkipButtonVisibility();
        // 自动播下一集: 距离结尾 < 1.5s 且还没自动切过
        _maybeAutoPlayNext();
      }
    });
    _durationSub = _player.streams.duration.listen((dur) {
      if (!mounted) return;
      _currentDuration = dur;
      // v2.1.13: 删掉广告自动跳过逻辑 (duration 跳变检测 + _skipAd).
      //   用户反馈反复卡同一广告位 / seek 错乱, 决定移除 runtime 兜底,
      //   改靠 m3u8 重写层 (视频代理开关) 物理删广告段. 这里只保留
      //   _currentDuration 更新, 供 _updateSkipButtonVisibility 用.
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
    // v2.0.58: 缓冲状态转换日志, 分析 "优选 IP 4s 卡顿" — 卡顿时会反复
    //   buffering true/false, 跟时长变化日志配合能看出是哪一帧挂的.
    _player.streams.buffering.listen((b) {
      if (!mounted) return;
    });
    // v2.0.58: 播放错误日志 (mpv 报错时立刻记到日记, 用户能看到真因)
    _player.streams.error.listen((e) {
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
    // v1.0.50: 退出时最后一次保存, 改成 await 真的完成再 dispose _player
    // 之前是 fire-and-forget, _player.stop() 同步把 state.position 重置成 0,
    // saveCurrentProgress 那个 fire-and-forget 没机会拿到正确 position 就被 super.dispose 切断
    // (虽然 _currentPosition 兜底有值, 但 PageCacheService().savePlayRecord 走网络
    //  没 await 完进程被上滑/杀就丢, playTime 没写盘)
    // 现在: unawaited + 内部 await 串行 (save → stop → dispose),
    // 进程上滑杀时 OS 给 grace period, 大概率能完成网络写盘
    unawaited(_disposeAndSave());
    _progressTimer?.cancel();
    _hideControlsTimer?.cancel();
    _seekHintTimer?.cancel();
    _videoParamsSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    // v2.0.51: 释放选集 PageView 控制器
    _episodesPageController.dispose();
    _pageControllerNotifier.dispose();
    WidgetsBinding.instance.removeObserver(this);
    // 恢复系统UI,方向交由系统控制
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    // v1.0.54: 还原 volume_controller 的 showSystemUI 标志
    // initState 设了 false 屏蔽系统音量弹窗, dispose 要还原成 true
    // 跟 mobile_player_controls.dart:160 同模板, 否则其他场景 (detail 页面
    // 之类) 再调 setVolume 也不会弹系统 UI
    VolumeController().showSystemUI = true;
    // v2.0.16: 关本地视频代理 (释放 127.0.0.1:PORT)
    unawaited(_videoProxy?.stop());
    _videoProxy = null;
    _videoProxyActive = false;
    _speedSampleTimer?.cancel();
    _speedSampleTimer = null;
    super.dispose();
  }

  /// 退出时串行: save → stop → dispose
  /// dispose 不能 await, 所以用 unawaited 在 dispose 末尾启动
  ///
  /// v1.0.50.1: 加 _phase == 'playing' 守门, 防止 phase=detail 时用
  /// playTime=0 覆盖之前存的真实进度 (根因 3)
  /// 正常流程: 用户看 → 返回键 → onPopInvoked(phase=playing) 已经 save 12 min
  ///   + stop player → phase=detail → 用户再返回 → onPopInvoked(phase=detail)
  ///   走空分支 → widget 销毁 → dispose 调本方法
  ///   此时 player 已经被 stop, state.position=0, _currentPosition=0
  ///   (stop 后 position stream 也会发射 0), 再 save 一次会写 playTime=0,
  ///   覆盖掉 onPopInvoked 存的 12 分钟
  /// 修法: phase=detail 说明 onPopInvoked 已经存过, 这里不再重复 save
  ///       phase=playing 才是上滑杀 App / 系统回收等异常退出, 还要 save
  ///       (最后一次救命机会, 走本地双写兜底)
  Future<void> _disposeAndSave() async {
    if (_phase == 'playing') {
      // v1.0.65: 先等 _currentPosition > 0 再 save, 避免刚 play 就被 kill
      // 时存 0 覆盖之前的真进度
      await _waitForValidPosition();
      if (_currentPosition > Duration.zero) {
        try {
          await _saveCurrentProgress(force: true);
        } catch (_) {}
      }
    }
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _player.dispose();
    } catch (_) {}
  }

  /// v1.0.50: App 进后台 (home 键) 时立即保存一次, 防止 10s progressTimer
  /// 还没触发就被上滑/杀进程丢进度
  ///
  /// v1.0.53: 加 `if (_phase != 'playing') return;` 守门
  /// 之前没守门, onPopInvoked 已经 stop player + _phase='detail' 之后
  /// (用户从播放页按返回键回到详情页), 这时再按 home 键 / 切后台 →
  /// didChangeAppLifecycleState(paused) → _saveCurrentProgress(force=true) →
  /// player 已 stop, state.position=0, _currentPosition 已经被 stream 发射 0 重置,
  /// state.playing=false → 条件 `state.playing || (pos > 0 && !state.completed)`
  /// 不满足 → playTime=0 → force=true 跳过 return 守门 → 存一条 playTime=0
  /// **覆盖掉 onPopInvoked 已经存的 12 分钟** → 下次重开从 0 开始
  /// 守门同 _disposeAndSave (v1.0.50.1), 是同模式 bug 的另一条触发路径:
  ///   _disposeAndSave 守了 dispose 路径
  ///   didChangeAppLifecycleState 漏了 paused 路径
  /// 两条路径都会在 player 已 stop 时触发 save, 都会覆盖 0
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // v1.0.53: 守门同 _disposeAndSave. phase!=playing 说明 player 已经被
    // onPopInvoked 停过, 此时 save 必出 0, 必覆盖之前存的真进度
    if (_phase != 'playing') return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      // v1.0.65: 先等 _currentPosition > 0 再 save, 避免刚 play 就 home
      // 键时存 0 覆盖之前的真进度. 仍然 0 就跳过 (10s 定时器下次兜底)
      _waitForValidPosition().then((_) {
        if (_currentPosition > Duration.zero) {
          // 进后台时立即保存, 走 _saveCurrentProgress 的 force 分支,
          // _currentPosition 兜底能拿到最后一帧有效 position
          unawaited(_saveCurrentProgress(force: true));
        }
      });
    }
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
      // v1.0.58: 加载自动/手动开关, 默认 false (手动)
      final autoIntro = prefs.getBool('${_skipPrefKey}_auto_intro') ?? false;
      final autoOutro = prefs.getBool('${_skipPrefKey}_auto_outro') ?? false;
      if (mounted) {
        setState(() {
          _skipIntroEnd = intro;
          _skipOutroStart = outro;
          _autoSkipIntro = autoIntro;
          _autoSkipOutro = autoOutro;
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
      // v1.0.58: 持久化自动/手动开关
      await prefs.setBool('${_skipPrefKey}_auto_intro', _autoSkipIntro);
      await prefs.setBool('${_skipPrefKey}_auto_outro', _autoSkipOutro);
    } catch (_) {}
  }

  /// 根据当前位置更新跳过按钮的显示状态 / v1.0.57 自动 seek / v1.0.58 自动手动二选一
  ///
  /// - 自动模式 (_autoSkipIntro/_autoSkipOutro = true): shouldShowIntro/Outro 时自动 seek
  /// - 手动模式 (默认): shouldShowIntro/Outro 时显示右下角浮层按钮让用户点
  ///
  /// v1.0.58 加自动/手动开关: 之前 v1.0.57 强制自动, 但有的源没片头/片尾,
  /// 自动跳会跳到 _skipIntroEnd / durSec-_skipOutroStart 错误位置
  /// 默认手动 (跟 v1.0.57 之前一样), 用户主动开自动
  ///
  /// v1.0.63 修片尾逻辑: 之前 v1.0.58 seek 到 durSec-_skipOutroStart
  /// (片尾**开始**位置), 这跟"跳过片尾"语义相反 — 是**倒回**片头不是跳过.
  /// 正确行为: 在片尾区间触发时, **直接播下一集** (有下集) / 不做任何事
  /// (最后一集让 _maybeAutoPlayNext 自然触发).
  ///
  /// 用户拖动进度条时不自动跳 (避免抢用户操作), 靠 _scrubbingValue 守门
  void _updateSkipButtonVisibility() {
    final posSec = _currentPosition.inSeconds;
    final durSec = _currentDuration.inSeconds;
    // v2.1.18: 广告重置检测 (一次触发, 整段播放期锁死).
    //   特征: currentTime 从正片位置 (>60s) 突然倒退到接近 0 (<10s).
    //   用户场景: 一集里有 4-5 次广告, 每次广告都从 0 开始播完跳回原位置.
    //   总时长不变 (广告跟正片在同一条流里, durSec 不变), 跟 v2.1.13/v1.0.77
    //   处理的"切流时 durSec 跳变"不同 — 这次 durSec 不动, 单纯 position 倒退.
    //   触发后 _adResetDetected = true, shouldShowIntro 短路, 整个 _State
    //   生命周期不再重置, 后续 3-4 次广告都不会再被误判跳过.
    //   排除: 用户拖进度条是前跳 (不满足"倒退到 0"), 不会误判.
    if (!_adResetDetected &&
        _lastPosForAdDetect > 60 &&
        posSec < 10 &&
        durSec > 60) {
      // v2.1.18: 倒退到接近 0 → 判定为广告重置, 锁定.
      //   没用 (posSec - _lastPos) < -X, 因为源切流时可能一次 stream
      //   跳变给一个 0, 下一帧又到 50, 中间没"delta 帧"被捕获. 直接用
      //   "上次 > 60 + 这次 < 10" 两个绝对值判断, 跨帧跳变也能覆盖.
      _adResetDetected = true;
      // v2.1.18 debug: 记录一次, adb logcat | grep AD_RESET 能看到
      debugPrint('[AD_RESET] detected: ${_lastPosForAdDetect}s -> ${posSec}s '
          '(dur=${durSec}s) — 整段播放期禁用跳过片头');
    }
    _lastPosForAdDetect = posSec;
    // v1.0.77: 加 durSec > _skipIntroEnd 守门
    // 防止广告流 (durSec=30s) 切流时, position 跳 0 还没等 duration stream
    // 检测到跳变先触发, 这里误判成"还在片头"自动 seek 到 90s, 90s 超出
    // 广告流 duration 30s, 跟 v1.0.76 报告的死循环根因同模式.
    // 守门后: 广告流 durSec=30 < 90 不会触发, 不会 seek 错乱.
    // 主片 durSec=2700 > 90 正常判断.
    // v2.1.13: 加 durSec > 60 守门 — 影片总时长低于 60s 不跳过片头.
    //   防止广告 (典型 30s) / m3u8 短段被误认为"影片重新播放"而触发
    //   跳过片头. 主片通常 > 60s, 正常判断不受影响.
    // v2.1.18: 加 !_adResetDetected 守门 — 整段播放期检测到广告重置后
    //   跳过片头直接短路, 不再 seek, 后续 3-4 次广告都不会再被误判.
    final shouldShowIntro = _skipIntroEnd > 0 &&
        posSec < _skipIntroEnd &&
        posSec > 1 &&
        durSec > _skipIntroEnd &&
        durSec > 60 &&
        !_adResetDetected;
    final hasNextEpisode = _selectedSource != null &&
        _currentEpisodeIndex < _selectedSource!.episodes.length - 1;
    // v1.0.77: shouldShowOutro 同样加 durSec 守门 (广告流 durSec=30
    // 不可能满足"接近片尾"的条件, 但保险起见加 durSec > 60 兜底, 防止
    // duration stream 还没更新 _currentDuration 时 _currentPosition 已
    // 经在广告流上, 算出 (30 - 25) = 5 < _skipOutroStart 误触发)
    final shouldShowOutro = _skipOutroStart > 0 &&
        durSec > 60 &&
        posSec > 0 &&
        (durSec - posSec) < _skipOutroStart &&
        (durSec - posSec) > 1;

    // v1.0.58: 自动模式才自动 seek, 手动模式显示按钮让用户点
    if (_scrubbingValue == null) {
      if (_autoSkipIntro && shouldShowIntro) {
        _player.seek(Duration(seconds: _skipIntroEnd));
        // v1.0.58: 立即隐藏按钮, 避免按钮在 seek 完前闪烁
        if (_showSkipIntro) {
          setState(() { _showSkipIntro = false; });
        }
        return;
      }
      if (_autoSkipOutro && shouldShowOutro) {
        // v1.0.63: 跳过片尾 = 播下一集 (有下集) / 不做事 (最后一集让
        // _maybeAutoPlayNext 自然触发 end→next 流程)
        if (hasNextEpisode) {
          _autoPlayedThisEpisode = true; // 防止 _maybeAutoPlayNext 再触发
          _playEpisode(_currentEpisodeIndex + 1);
        }
        if (_showSkipOutro) {
          setState(() { _showSkipOutro = false; });
        }
        return;
      }
    }

    // 手动模式显示按钮 (自动模式 seek 后 shouldShow=false, 按钮自然不显示)
    // _showSkipIntro/Outro 字段保留, UI 里根据它显隐按钮
    if (shouldShowIntro != _showSkipIntro ||
        shouldShowOutro != _showSkipOutro) {
      setState(() {
        _showSkipIntro = shouldShowIntro;
        _showSkipOutro = shouldShowOutro;
      });
    }
  }
  // v1.0.58: 恢复 _skipIntro / _skipOutro, 手动模式按钮调用
  // v1.0.57 删了, v1.0.58 加了自动/手动开关, 手动模式需要这两个函数

  /// v1.0.63: 把秒数格式化成 "X 分钟" / "X 分 Y 秒" / "X 秒" 给人看
  /// slider 内部仍存秒 (0~300), 只换显示文案
  ///   30 → "30 秒"
  ///   60 → "1 分钟"
  ///   90 → "1 分 30 秒"
  ///   180 → "3 分钟"
  String _formatSkipTime(int seconds) {
    if (seconds <= 0) return '关闭';
    if (seconds < 60) return '$seconds 秒';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (s == 0) return '$m 分钟';
    return '$m 分 $s 秒';
  }

  /// 手动跳过片头
  void _skipIntro() {
    if (_skipIntroEnd > 0) {
      _player.seek(Duration(seconds: _skipIntroEnd));
    }
  }

  /// 手动跳过片尾 — v1.0.63 修: 之前是 seek 到 durSec-_skipOutroStart
  /// (片尾开始位置, 等于倒回), 正确行为是播下一集
  void _skipOutro() {
    final hasNextEpisode = _selectedSource != null &&
        _currentEpisodeIndex < _selectedSource!.episodes.length - 1;
    if (!hasNextEpisode) return; // 最后一集, 让 _maybeAutoPlayNext 自然触发
    _autoPlayedThisEpisode = true; // 防止 _maybeAutoPlayNext 再触发
    _playEpisode(_currentEpisodeIndex + 1);
  }

  /// 打开跳过片头片尾设置弹窗
  Future<void> _showSkipSettingsDialog() async {
    int intro = _skipIntroEnd;
    int outro = _skipOutroStart;
    // v1.0.58: 加自动/手动开关
    bool autoIntro = _autoSkipIntro;
    bool autoOutro = _autoSkipOutro;
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
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // v1.0.58: 自动/手动开关
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '自动跳过片头',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      subtitle: Text(
                        autoIntro
                            ? '自动: 播到片头结束时间自动 seek 跳过'
                            : '手动: 显示"跳过片头"按钮, 用户点才跳',
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      value: autoIntro,
                      activeColor: const Color(0xFF22C55E),
                      onChanged: (v) => setDialogState(() => autoIntro = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '自动跳过片尾',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      subtitle: Text(
                        autoOutro
                            ? '自动: 距结尾 < 提前时间自动 seek 跳过'
                            : '手动: 显示"跳过片尾"按钮, 用户点才跳',
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      value: autoOutro,
                      activeColor: const Color(0xFF22C55E),
                      onChanged: (v) => setDialogState(() => autoOutro = v),
                    ),
                    const Divider(color: Colors.white24, height: 24),
                    // v1.0.64: slider 旁加 "使用当前时间" 按钮, 一键取当前播放
                    // 位置作为片头结束/片尾提前秒数. 流程: 暂停在边界 → 开弹窗 →
                    // 点按钮. 弹窗显示当前秒数方便核对.
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '片头结束时间: ${intro > 0 ? _formatSkipTime(intro) : "未设置"}',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 14),
                          ),
                        ),
                        Text(
                          '当前 ${_formatSkipTime(_currentPosition.inSeconds)}',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11),
                        ),
                        const SizedBox(width: 4),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 0),
                            minimumSize: const Size(0, 28),
                            tapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: const Color(0xFF22C55E),
                          ),
                          onPressed: () {
                            setDialogState(() {
                              intro =
                                  _currentPosition.inSeconds.clamp(0, 300);
                            });
                          },
                          child: const Text('使用当前时间',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                    Slider(
                      value: intro.toDouble(),
                      min: 0,
                      max: 300,
                      divisions: 300,
                      activeColor: const Color(0xFF22C55E),
                      label: intro > 0 ? _formatSkipTime(intro) : '关闭',
                      onChanged: (v) =>
                          setDialogState(() => intro = v.round()),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '片尾提前时间: ${outro > 0 ? _formatSkipTime(outro) : "未设置"}',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 14),
                          ),
                        ),
                        Text(
                          '当前剩 ${_formatSkipTime(_currentDuration.inSeconds - _currentPosition.inSeconds)}',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11),
                        ),
                        const SizedBox(width: 4),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 0),
                            minimumSize: const Size(0, 28),
                            tapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: const Color(0xFF3B82F6),
                          ),
                          onPressed: () {
                            setDialogState(() {
                              // 片尾提前 = 距结尾还剩多少秒
                              final remain = _currentDuration.inSeconds -
                                  _currentPosition.inSeconds;
                              outro = remain.clamp(0, 300);
                            });
                          },
                          child: const Text('使用当前时间',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                    Slider(
                      value: outro.toDouble(),
                      min: 0,
                      max: 300,
                      divisions: 300,
                      activeColor: const Color(0xFF3B82F6),
                      label: outro > 0 ? _formatSkipTime(outro) : '关闭',
                      onChanged: (v) =>
                          setDialogState(() => outro = v.round()),
                    ),
                    // v1.0.63: 60s=1分钟, 提示文案同步用分钟单位
                    // v1.0.64: 补一行"如何用使用当前时间按钮"的提示
                    const SizedBox(height: 8),
                    const Text(
                      '提示: 有的源没有片头/片尾, 建议先关掉自动, 看到按钮再点, 确认有片头再开自动\n'
                      '单位: 60 秒 = 1 分钟 (0~5 分钟可调)\n'
                      '用法: 暂停在片头结束 / 片尾开始位置 → 开此弹窗 → 点"使用当前时间"',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
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
                      // v1.0.58: 持久化自动/手动开关
                      _autoSkipIntro = autoIntro;
                      _autoSkipOutro = autoOutro;
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
    // v1.0.44: v0.2.2 / 2.0.8 API 是 VolumeController() 实例
    // v1.0.54: 走全局 showSystemUI=false (initState 开关), 不走方法参数,
    // 因为滑动频繁调 setVolume, 每次传参也累赘
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

  /// v2.0.58: 截短 URL 用于日志输出 (避免 worker 长 query 撑爆 200 行 buffer).
  /// 保留 scheme+host+path, query 只保留前 60 字符并标 …
  String _shortenUrl(String url) {
    if (url.length <= 120) return url;
    final qIdx = url.indexOf('?');
    if (qIdx < 0) return url.substring(0, 120) + '…';
    final base = url.substring(0, qIdx);
    final query = url.substring(qIdx, qIdx + 61);
    return '$base$query…';
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
      Duration pos = state.position;
      // v1.0.49 兜底: state.position 在 stop/pause 后可能回 0 或 stream 还没回传,
      // 用本地 _currentPosition (stream 一直在跟) 兜底, 保证退出前最后一帧
      // 还有效的 position 能写盘
      if (pos < _currentPosition) pos = _currentPosition;
      // v1.0.75 兜底: libmpv m3u8 reload 期间, state.completed=true 且
      // state.position=0, _currentPosition 也被 stream 发射 0 重置, 三者都是 0.
      // 此时用 _lastKnownPosition 拿"上次的非 0 position", 避免 10s 定时器存 0
      // 覆盖云端进度. _lastKnownPosition 只在 streams.position 收到 pos > 0 时
      // 才更新, reload 完 libmpv 重新播时 pos 会从 0 涨, 兜底期间它还停在原值.
      if (pos < _lastKnownPosition) pos = _lastKnownPosition;

      // 正在播放 或 有进度且未播完 (用 !completed 表示)
      if (state.playing || (pos > Duration.zero && !state.completed)) {
        playTime = pos.inMilliseconds;
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

    DiaryService.add(
        '[History] _saveCurrentProgress: key="$key" index=${record.index} playTime=${playTime}ms totalTime=${totalTime}ms searchTitle="${record.searchTitle}" force=$force');

    try {
      await PageCacheService().savePlayRecord(record, context);
      DiaryService.add('[History] save ok: key="$key"');
    } catch (e) {
      DiaryService.add('[History] save err: $e');
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

  /// v1.0.65: 等 position stream 至少回一次 _currentPosition > 0
  /// (带 timeout). 防止"刚 open player 就 back / home 键 / 杀 App" 等
  /// 场景下 state.position 和 _currentPosition 都还是 0 时,
  /// 走 force=true 的 save 路径存 0, **覆盖了之前的真进度**
  /// (云端 + local 双写都会被覆盖), 下次重开从 0 开始
  ///
  /// 三处会用到: onPopInvoked (playing→detail) / didChangeAppLifecycleState
  /// (paused) / _disposeAndSave. 这三处都用 force=true 跳过 _firstRecordSaved
  /// 守门, 没办法靠守门保护, 只能等 stream.
  Future<void> _waitForValidPosition({
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    if (_currentPosition > Duration.zero) return;
    // player 都没在播, 等也是白等, 直接 return
    if (!_player.state.playing) return;
    final completer = Completer<void>();
    late StreamSubscription<Duration> sub;
    sub = _player.streams.position.listen((pos) {
      if (pos > Duration.zero && !completer.isCompleted) {
        completer.complete();
      }
    });
    try {
      await completer.future.timeout(timeout);
    } catch (_) {}
    try {
      await sub.cancel();
    } catch (_) {}
  }

  // 加载多源并自动测速
  Future<void> _loadSources() async {
    final title = widget.videoInfo.searchTitle.isNotEmpty
        ? widget.videoInfo.searchTitle
        : widget.videoInfo.title;
    DiaryService.add(
        '[History] _loadSources begin: title="$title" videoInfo.source="${widget.videoInfo.source}" videoInfo.index=${widget.videoInfo.index} videoInfo.playTime=${widget.videoInfo.playTime}ms videoInfo.searchTitle="${widget.videoInfo.searchTitle}"');
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
    DiaryService.add(
        '[History] resume: ${resume == null ? "null (跳过云端)" : "source=${resume.source} index=${resume.index} playTime=${resume.playTime}ms"}');
    final resumeSourceKey = resume?.source ?? widget.videoInfo.source;
    final resumeIndex = resume != null
        ? (resume.index - 1).clamp(0, 1 << 30)
        : (widget.videoInfo.index - 1).clamp(0, 1 << 30);
    DiaryService.add(
        '[History] resume computed: resumeSourceKey="$resumeSourceKey" resumeIndex=$resumeIndex (0-based)');
    if (resume != null && resume.playTime > 0) {
      _pendingResumeAt = Duration(milliseconds: resume.playTime);
    } else if (widget.videoInfo.playTime > 0) {
      _pendingResumeAt = Duration(milliseconds: widget.videoInfo.playTime);
    }
    DiaryService.add(
        '[History] _pendingResumeAt: ${_pendingResumeAt?.inMilliseconds ?? "null"}ms');

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
      DiaryService.add(
          '[History] _selectSource done: toSelect.source="${toSelect.source}" toSelect.id="${toSelect.id}" resumeIndex=$resumeIndex → _currentEpisodeIndex=$_currentEpisodeIndex');

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
    // v2.0.51: 切源后 PageView 跳到当前 episode 所在页
    final newPage = (clampedIndex ~/ _episodesPerPage).clamp(0, 999);
    if (_episodesPageController.hasClients &&
        _episodesPageController.page?.round() != newPage) {
      _episodesPageController.jumpToPage(newPage);
    }
    // v2.1.20: 切源时重置广告重置检测 — 之前一源 (可能带广告) 触发的
    //   _adResetDetected 不该污染新源. _State 不重建 (还是 player_screen),
    //   必须手动重置, 否则新源/新一集片头也不跳 (用户反馈 "改完片头
    //   都不跳过了").
    _adResetDetected = false;
    _lastPosForAdDetect = -1;
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

  /// 测单个源: 走 M3U8Service 完整测速, 失败 fallback 到轻量测速 (HEAD + Range)
  ///
  /// v1.0.69: 测速 URL 跟 CF 加速开关走 (回到 v1.0.66 思路, 但 fallback 升级).
  ///
  /// 之前 v1.0.68 改成测原始 URL, 理由是"测速是挑源, 不该跟 CF 耦合".
  /// 用户反馈"打开加速要通过加速地址测速不然不准":
  ///   - 测原始 URL 看到的 ms/KB/s 是源本身的物理速度
  ///   - 但用户实际播放走的是 worker, 体验跟直连测速不一致
  ///   - 例: 源 A 直连 100ms 但 worker 转发卡 2000ms, 测速显示 100ms (快)
  ///         实际播放却卡 → "不准"
  ///   - 测 worker URL 才是用户真实播放体验
  ///
  /// v1.0.69 修法:
  ///   1. URL 走 `buildProxiedUrl`: 视频代理 on 拿 worker URL, 视频代理 off 拿原 URL
  ///      (buildProxiedUrl 内部 `_isCfWorkerUsableSync` 已经按「视频代理」开关处理,
  ///       开关没开就原样返回, 不需要外部 if/else)
  ///      v2.0.76: 改用「视频代理」开关 (之前是「总开关」, 新语义下总开关没了)
  ///   2. 外层 timeout 4s → 8s, 让 worker 代理下 \`getStreamInfo\` 有时间跑完
  ///   3. **fallback 升级**: 之前 \`_fallbackHeadPing\` 只 HEAD 测一次 ms,
  ///      loadSpeedKBps 永远 0 → UI 只显示 ms 看不到 KB/s (用户上条反馈的现象)
  ///      现在改成 \`_fallbackLightSpeed\`: HEAD 测 ms + Range 测 KB/s 并发,
  ///      即使 getStreamInfo 全失败 fallback 也能给出完整测速结果
  ///
  /// v1.0.74 修法: 解决 CF 测速时 segment URL 解析错位 + segment 测速不走 worker
  ///   - 根因: v1.0.69 测 worker URL 时, [M3U8Service.getStreamInfo] 内部
  ///     \`_resolveUrl\` 用 worker URL 作 base 解析 m3u8 里的相对 segment
  ///     → segment 拼成 \`https://<worker>/seg.ts\` (worker 不认识) → 404
  ///     → KB/s 永远 0, UI 只显示 "Xms" (用户 v1.0.73 反馈的现象)
  ///   - 修法: 调用 [M3U8Service.getStreamInfo] 时
  ///     1. 传 \`originalUrl\`: 原始 m3u8 URL, 让它用 upstream base 解析 segment
  ///     2. 传 \`urlWrapper\`: 测速时把 segment URL 也走 worker 包装
  ///        → segment 走 worker / 端点, 真实测 worker 加速后的段速度
  Future<_SourceSpeedInfo> _testSourceSpeed(M3U8Service m3u8, SearchResult s) async {
    if (s.episodes.isEmpty) return _SourceSpeedInfo.unavailable();
    final originalUrl = s.episodes.first;
    // v1.0.74: 测速 URL 跟 CF 开关走 (跟 v1.0.69 一致), 但传 originalUrl 给
    // m3u8_service 让它解析 segment 时用 upstream base, 并传 urlWrapper 让
    // segment 测速也走 worker. 修 v1.0.69 引入的 segment 解析错位 bug.
    final url = UserDataService.buildProxiedUrl(originalUrl);
    return _testOneUrl(m3u8, url, originalUrl: originalUrl);
  }

  /// 单 URL 测速, 内部走 m3u8.getStreamInfo + 轻量 fallback (HEAD+Range), 8s 超时
  ///
  /// v1.0.74 新增 \`originalUrl\`: 测 worker URL 时传原始 m3u8 URL,
  /// m3u8_service 解析 segment 时用 upstream base 避免 segment URL 错位
  Future<_SourceSpeedInfo> _testOneUrl(
    M3U8Service m3u8,
    String url, {
    String? originalUrl,
  }) async {
    try {
      // v1.0.69: 4s → 8s. worker 代理下 getStreamInfo 要过 3~4 次转发,
      // 直连 0.5~1.5s 够, worker 转发单次 1~3s 不等, 8s 留足余量.
      // v1.0.74: 传 originalUrl + urlWrapper, 让 m3u8_service 解析 segment
      // 时用 upstream base, 测速时走 worker 包装.
      final result = await m3u8.getStreamInfo(
        url,
        originalUrl: originalUrl,
        urlWrapper: (segUrl) => UserDataService.buildProxiedUrl(segUrl),
      ).timeout(
        const Duration(seconds: 8),
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
    // v1.0.74 fallback: 优先用 originalUrl (原始 m3u8 URL) 测, 避免 worker
    // 配错时 fallback 也撞 worker 限制拿到 0. 跟 v1.0.66 修法精神一致:
    // CF 配对时 fallback 不用 (getStreamInfo 已经拿到真 KB/s), CF 配错时
    // fallback 测原始 URL 至少能给个真实数字, 不至于显示 0 让用户以为是源挂了.
    //
    // v2.1.34: fallback 加 altUrl (worker URL), 优先用 worker URL 测 latency
    //   (走 CDN 加速, 国内稳), 测不到再退 originalUrl. 修 "打开 CF 加速后
    //   测速没了 (连延迟都没有)" bug.
    final fallbackUrl = originalUrl ?? url;
    return await _fallbackLightSpeed(fallbackUrl, altUrl: url);
  }

  String _formatResolution(int h) {
    if (h <= 0) return '';
    if (h >= 2160) return '4K';
    return '${h}p';
  }

  /// v1.0.69: fallback 升级 — HEAD 测 ms + Range 测 KB/s 并发
  ///
  /// 之前 \`_fallbackHeadPing\` 只 HEAD 测一次 ms, loadSpeedKBps 永远 0,
  /// UI 走 success 分支但 KB/s 段为空, 只显示 "Xms" 看不到速度 (用户上条反馈).
  /// 现在 HEAD + Range 并发, 即使 getStreamInfo 全失败, fallback 也能给
  /// 完整 ms + KB/s 数据, UI 拼成 "Xms · YMB/s".
  ///
  /// 行为细节:
  ///   - HEAD: 测 worker 转发到 upstream 的"首字节延迟" (worker URL 下)
  ///           测 client 到 upstream 的延迟 (原始 URL 下)
  ///   - Range bytes=0-65535: 取前 64KB 算下载速度
  ///     跟 [m3u8_service.dart] 的 \`_measureDownloadSpeedFast\` 同思路
  ///   - 两者都 1.5s 超时, 失败分别返回 3000ms / 0KB/s
  ///   - 用一个共享 http.Client, 测完 finally 关闭避免泄漏
  ///
  /// v1.0.74: 调 [_testOneUrl] 时传的 url 改成 originalUrl (上游 m3u8 URL),
  /// 这样 worker 配错时 fallback 测的是源真实速度, 不是 worker 限制撞墙.
  Future<_SourceSpeedInfo> _fallbackLightSpeed(String url, {String? altUrl}) async {
    final httpClient = http.Client();
    // v2.1.34: 优先用 altUrl (worker URL) 测 latency, 因为 worker URL 走
    //   CDN 加速 + 跨域代理, 在国内网络上更稳, 不容易被 upstream 拦
    //   (e.g. 某些 m3u8 upstream 拒直连). 测不到再退到 originalUrl.
    final latencyTarget = altUrl ?? url;
    try {
      final results = await Future.wait([
        _fallbackMeasureLatency(httpClient, latencyTarget),
        _fallbackMeasureDownloadSpeed(httpClient, url),
      ]).timeout(const Duration(milliseconds: 2500));
      final ms = (results[0] as num).toInt();
      final kbps = (results[1] as num).toDouble();
      // v2.1.34: ms < 5000 就算 success (ms=3000 是 fallback 失败默认值)
      return _SourceSpeedInfo(
        resolution: '',
        loadSpeedKBps: kbps,
        pingMs: ms,
        success: ms > 0 && ms < 5000,
      );
    } catch (_) {
      // v2.1.34: 兜底再试一次 originalUrl (如果 altUrl 失败)
      if (altUrl != null && altUrl != url) {
        try {
          final ms = await _fallbackMeasureLatency(httpClient, url)
              .timeout(const Duration(milliseconds: 1500));
          if (ms > 0 && ms < 5000) {
            return _SourceSpeedInfo(
              resolution: '',
              loadSpeedKBps: 0,
              pingMs: ms,
              success: true,
            );
          }
        } catch (_) {}
      }
      return _SourceSpeedInfo.unavailable();
    } finally {
      httpClient.close();
    }
  }

  /// v2.1.38: 改用 GET 测延迟 + 失败返回 -1 哨兵 (不再用 3000 模糊值)
  ///   - 旧版本用 HEAD 测, 但 m3u8 源很多不支持 HEAD (405/501), 走到 catch
  ///     返回 3000, 外面 success 检查 `ms > 0 && ms < 5000` 居然把 3000 当成
  ///     成功, UI 显示假数据 "0KB/s · 3000ms" / "38KB/s · 3000ms".
  ///   - 改用 GET Range: 0-0 拿 1 字节, 强制 drain stream 拿真实首字节延迟.
  ///   - 失败返回 -1 (跟 m3u8_service._measureLatency 保持一致), success 改
  ///     `ms > 0` 严格过滤.
  Future<int> _fallbackMeasureLatency(http.Client client, String url) async {
    final start = DateTime.now();
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..followRedirects = true
        ..maxRedirects = 2
        ..headers['Range'] = 'bytes=0-0';
      final resp = await client.send(req).timeout(const Duration(milliseconds: 2000));
      // 关掉 stream 释放连接 (Range: 0-0 拿 0~1 字节, 读完就 OK)
      try {
        await resp.stream.drain<void>().timeout(const Duration(milliseconds: 300));
      } catch (_) {}
      return DateTime.now().difference(start).inMilliseconds;
    } catch (_) {
      return -1; // v2.1.38: 失败明确返回 -1, 不再用 3000 模糊
    }
  }

  Future<double> _fallbackMeasureDownloadSpeed(http.Client client, String url) async {
    try {
      final stopwatch = Stopwatch()..start();
      final req = http.Request('GET', Uri.parse(url))
        ..followRedirects = true
        ..maxRedirects = 2
        ..headers['Range'] = 'bytes=0-65535';
      final resp = await client.send(req).timeout(const Duration(milliseconds: 1500));
      // 把 body 读完才能算下载速度
      final bytes = <int>[];
      await for (final chunk in resp.stream) {
        bytes.addAll(chunk);
        if (bytes.length >= 65536) break; // Range 只取 64KB, 收够就停
        if (stopwatch.elapsedMilliseconds > 1400) break; // 兜底
      }
      stopwatch.stop();
      final n = bytes.length;
      if (n == 0) return 0.0;
      final sec = stopwatch.elapsedMilliseconds / 1000.0;
      if (sec <= 0) return 0.0;
      return (n / 1024) / sec; // KB/s
    } catch (_) {
      return 0.0;
    }
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
  ///
  /// v1.0.55: 加 pos + dur 兜底守门
  /// 之前没守门, 走 streams.completed listener 直接调本函数时
  /// (line 198 `streams.completed.listen((_) { _autoPlayNextEpisode(); })`)
  /// 不经过 _maybeAutoPlayNext 的 remainMs > 1500 守门, 一发就切
  /// 用户场景: 播放第2集没看完, 重开第2集 → video open 后 m3u8 源立刻发
  /// streams.completed=true (直播流 / 解析失败 / seek 到 duration 附近) →
  /// _autoPlayNextEpisode → 切第3集
  /// 修法: pos 必须 ≥ dur - 1.5s 才允许切 (跟 _maybeAutoPlayNext 同阈值),
  ///       dur < 30s 也跳过 (直播流 / 异常源)
  void _autoPlayNextEpisode() {
    if (_autoPlayedThisEpisode) return;
    if (_phase != 'playing') return;
    final source = _selectedSource;
    if (source == null) return;
    final nextIndex = _currentEpisodeIndex + 1;
    if (nextIndex >= source.episodes.length) return; // 最后一集
    if (source.episodes[nextIndex].isEmpty) return; // 下一集没 url

    // v1.0.55: 兜底守门 (堵 streams.completed 误触发)
    final dur = _currentDuration;
    if (dur <= Duration.zero) return; // 时长还没拿到
    if (dur < const Duration(seconds: 30)) return; // 时长太短, 直播流/异常
    if (_currentPosition < dur - const Duration(milliseconds: 1500)) {
      // pos 还没到结尾附近, completed 误触发, 不切
      return;
    }

    _autoPlayedThisEpisode = true; // 立刻上锁, 防止 position/completed 双触发
    _playEpisode(nextIndex);
  }

  /// v2.0.33: 手动「下一集」— 用户主动点播控上的 skip_next 按钮.
  /// 跟 _autoPlayNextEpisode 区别: 不要 pos / dur 守门, 用户点的时候
  /// 不管看到哪里都直接切. 也用 _autoPlayedThisEpisode 锁防止后续
  /// streams.completed 误触.
  void _playNextEpisode() {
    if (_autoPlayedThisEpisode) return;
    if (_phase != 'playing') return;
    final source = _selectedSource;
    if (source == null) return;
    final nextIndex = _currentEpisodeIndex + 1;
    if (nextIndex >= source.episodes.length) return; // 最后一集
    if (source.episodes[nextIndex].isEmpty) return; // 下一集没 url
    _autoPlayedThisEpisode = true;
    _playEpisode(nextIndex);
    // 给个轻提示 (主路是控制栏图标变了, 提示只是兜底)
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('正在切换下一集…'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  /// v2.0.16: 启本地代理 + 给 libmpv 配 --http-proxy (如果条件满足)
  /// v2.0.20: media_kit 1.2.6 Player 类没有 setProperty / command 方法,
  ///   改用 dart:ffi 直接调 libmpv 的 mpv_set_property_string (MpvFFI).
  ///
  /// 条件 (v2.0.34):
  ///   - 用户在设置里开了 "视频代理加速" (v2.0.27 起默认关, 避免 Dart 代理不稳定)
  ///   - VideoProxyServer.tryStart() 内部检查 CF Worker 加速 + 域名 + 手动优选 IP
  /// 任一不满足 → 代理不起, 播放走原 URL
  ///
  /// v2.0.34: tryStart 门从 4 个砍到 3 个
  ///   之前依赖 v2.0.30 砍掉的"优选测速"开关 + bestIps 缓存, 等于视频代理
  ///   永远起不来. 现在改用 v2.0.32 手动优选 IP / 域名 字段, 配上就能起.
  ///
  /// 失败 / 异常 → 代理不起, 行为跟 v2.0.14 一模一样
  Future<void> _ensureVideoProxy() async {
    // v2.0.76: 守门改成 getVideoProxyEnabled() — 该开关现在是「视频代理」,
    //   关 = 视频不走代理, libmpv 直连视频源; 开 = 视频走 VideoProxyServer.
    final videoProxyOn = await UserDataService.getVideoProxyEnabled();
    if (!videoProxyOn) {
      return;
    }
    if (_videoProxy != null && _videoProxy!.isRunning) {
      return;
    }
    // v2.0.58: 记录优选 IP 状态, 帮助分析 "4s 卡顿" 跟 manual IP 的关系
    // v2.0.76: 优选 IP 启用 开关名 → getCfWorkerEnabled()
    final manualIp = CfOptimizerHttpOverrides.getResolvedManualIp();
    final preferIpEnabled = await UserDataService.getCfWorkerEnabled();
    // v2.0.67: 优选 IP 不再是必须条件, tryStart 一次就行 (不再 retry 等 _resolvedManualIp)
    //   v2.0.76: 守门已改成「视频代理」开关, 这里 tryStart 一定成功 (除非域名没配)
    //   - 视频代理开关开 + worker 域名配了 → tryStart 成功 (优选 IP 可选)
    //   - 视频代理开关关 → 上面已 return, 不会到这
    final proxy = await VideoProxyServer.tryStart();
    if (proxy == null) {
      return;
    }
    // v2.0.65: 不再设 libmpv --http-proxy!
    //   之前设 --http-proxy 让 libmpv 走 CONNECT 隧道, 但 libmpv 的 CONNECT
    //   实现有 bug (ffmpeg 通过同一代理能播, libmpv 不能 → "Failed to
    //   recognize file format"). 现在 v2.0.65 改成本地 HTTP 反向代理:
    //   播放 URL 改成 http://127.0.0.1:PORT/m3u8?url=..., 代理自己 fetch
    //   worker 返回. libmpv 直接 HTTP 连本地代理, 不走 CONNECT 隧道.
    //   代理服务器还是要启动 (VideoProxyServer._handleLocalHttp 处理).
    _videoProxy = proxy;
    // v2.0.34: 通知顶部「加速状态」指示器重算 + 启动下载速度采样
    setState(() {
      _videoProxyActive = true;
    });
    _startSpeedSampling();
  }

  /// v2.0.88: 1Hz 采样 libmpv 各种 property, 算实时下载速度
  ///
  /// 演化 (4 轮迭代):
  ///   v2.0.34: 用 getPropertyString 读 demuxer-bytes → 永远 null (libmpv 文档
  ///            明说对 Number 类型返 NULL) → 永远 0 B/s
  ///   v2.0.86: 改用 getPropertyI64 走专用 API → 还是 0 B/s (装上还是 0)
  ///   v2.0.87: 改用 mpv_get_property 通用 API (走 void* union) + 加诊断 tile
  ///            → 用户装上打开诊断 tile, 看到 `mpv_get_property(input-bitrate, DOUBLE)
  ///            返 rc=-8` (PROPERTY_UNAVAILABLE). 说明 libmpv 内部没在播, 加上
  ///            input-bitrate 在 libmpv 0.36 是 int64 不是 double (v2.0.86 写错 format)
  ///   v2.0.88: 扩 fallback 链 + 加播放状态文本 fallback
  ///
  /// 修法 (v2.0.88):
  ///   1. demuxer-bytes 改成走通用 getPropertyAny (INT64 format), 跟 v2.0.87 一致
  ///   2. 加 demuxer-cache-bytes fallback (跟 demuxer-bytes 类似但走 cache layer)
  ///   3. input-bitrate 改用 INT64 format (v2.0.86 写错用 DOUBLE, libmpv 实际是 int64)
  ///   4. 加 video-bitrate + audio-bitrate + sub-bitrate (DOUBLE, bps) 兜底
  ///   5. 加播放状态 fallback: idle-active / pause → 显示「缓冲中 / 暂停 / 未开播」
  ///      文本状态, 不再永远 0 B/s 骗用户
  ///
  /// 字段类型映射 (libmpv 0.36 文档, 单位都是 **bits per second**):
  ///   - demuxer-bytes: int64 (累计字节)
  ///   - demuxer-cache-bytes: int64 (累计 cache 字节)
  ///   - cache-size: int64 (累计 cache 字节, 同上但不同名)
  ///   - input-bitrate: int64 (输入 bitrate, bps)
  ///   - video-bitrate: double (bps)
  ///   - audio-bitrate: double (bps)
  ///   - sub-bitrate: double (bps)
  ///   - idle-active: bool (player 是否闲置)
  ///   - pause: bool (是否暂停)
  void _startSpeedSampling() {
    _speedSampleTimer?.cancel();
    _lastDemuxerBytes = 0;
    _lastSampleMs = 0;
    _downloadSpeedBps = 0;
    _playbackStateText = ''; // v2.0.88: 文本状态 fallback
    _speedSampleTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      if (!MpvFFI.isAvailable) return;
      try {
        final handle = await _player.handle;
        if (handle == 0) return;

        // 1. 主路径: 读累计下载字节 (demuxer-bytes)
        //   v2.0.87 改用通用 mpv_get_property (INT64 format). 拿到后算 delta = bps.
        int? cur = MpvFFI.getPropertyI64(handle, 'demuxer-bytes');
        cur ??= MpvFFI.getPropertyI64(handle, 'demuxer-cache-bytes');
        cur ??= MpvFFI.getPropertyI64(handle, 'cache-size');
        if (cur != null) {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (_lastSampleMs == 0 || cur < _lastDemuxerBytes) {
            // 首次采样 / demuxer 重置 (切集), 只记基线, 不算速度
            _lastDemuxerBytes = cur;
            _lastSampleMs = now;
            return;
          }
          final deltaBytes = cur - _lastDemuxerBytes;
          final deltaMs = now - _lastSampleMs;
          if (deltaMs <= 0) return;
          final bps = deltaBytes * 1000.0 / deltaMs;
          _lastDemuxerBytes = cur;
          _lastSampleMs = now;
          if (mounted) {
            setState(() {
              _downloadSpeedBps = bps;
              _playbackStateText = ''; // 有速度, 清掉文本
            });
          }
          return;
        }

        // 2. v2.0.90 兜底: input-bitrate 瞬时码率 (int64, bps)
        //   v2.0.88 错用 `* 1024 / 8` (按 kibit/s 算), 实际 libmpv 0.36 文档明说
        //   input-bitrate 单位是 **bits per second (bps)**, 1024-based 是错的.
        //   用户装 v2.0.89 后显示 414.51 MB/s (反推真实值 ≈ 3.4 Mbit/s, 1080p HLS 合理),
        //   我 * 1024 / 8 多乘 1024 倍. 改 `/ 8` (bit → Byte).
        final inputBps = MpvFFI.getPropertyI64(handle, 'input-bitrate');
        if (inputBps != null && inputBps > 0 && mounted) {
          // input-bitrate 是 bps (bits per second), 直接 / 8 = Bytes/s
          final bps = inputBps / 8;
          setState(() {
            _downloadSpeedBps = bps.toDouble();
            _playbackStateText = '';
          });
          return;
        }

        // 3. v2.0.90 兜底: video + audio + sub bitrate 加起来 (DOUBLE, bps)
        //   同样修 v2.0.88 的 `* 1024 / 8` 错, 实际是 bps, 改 `/ 8`.
        final v = MpvFFI.getPropertyDouble(handle, 'video-bitrate') ?? 0;
        final a = MpvFFI.getPropertyDouble(handle, 'audio-bitrate') ?? 0;
        final s = MpvFFI.getPropertyDouble(handle, 'sub-bitrate') ?? 0;
        final totalBps = v + a + s;
        if (totalBps > 0 && mounted) {
          final bps = totalBps / 8; // bps (bits per second) → Bytes/s
          setState(() {
            _downloadSpeedBps = bps;
            _playbackStateText = '';
          });
          return;
        }

        // 4. v2.0.88 文本状态 fallback: 显示「缓冲中 / 暂停 / 未开播」, 不再永远 0 B/s 骗用户
        final idle = MpvFFI.getPropertyAny(handle, 'idle-active', kMpvFormatBool);
        final paused = MpvFFI.getPropertyAny(handle, 'pause', kMpvFormatBool);
        String stateText = '';
        if (paused == true) {
          stateText = '已暂停';
        } else if (idle == true) {
          stateText = '未开播 / 缓冲中';
        } else {
          // player 在播但所有 property 都拿不到 (拿不到 demuxer-bytes 也拿不到 bitrate)
          // 罕见情况, 显示「测量中...」让用户知道在采
          stateText = '测量中...';
        }
        if (mounted && stateText != _playbackStateText) {
          setState(() {
            _playbackStateText = stateText;
            _downloadSpeedBps = 0; // 文本状态时不算速度, 避免跳数
          });
        }
      } catch (_) {}
    });
  }

  /// v2.0.88: 播放状态文本 fallback (在拿不到 demuxer-bytes / bitrate 时显示)
  ///   - "已暂停" (paused == true)
  ///   - "未开播 / 缓冲中" (idle == true)
  ///   - "测量中..." (player 在播但 property 都拿不到, 罕见)
  String _playbackStateText = '';

  /// v2.0.64: 解析分享页 HTML 提取真实视频 URL.
  ///
  /// 上游 CMS API 有时返回 /share/xxx 分享页 (HTML), 里面 JS 变量 url
  /// 才是真正的 m3u8 流. libmpv 不执行 JS, 直接 open 分享页 → 拿到 HTML
  /// → "Failed to recognize file format".
  ///
  /// 策略:
  ///   1. URL 看起来已经是视频流 (.m3u8/.mp4/.ts/.flv 后缀) → 直接返回, 不 fetch
  ///   2. fetch URL (带 5s 超时), 看 Content-Type:
  ///      - 是 text/html → 在 HTML 里找 m3u8/mp4 链接 (JS 变量 url / iframe / source)
  ///      - 不是 HTML → 直接返回原 URL (可能是二进制流, 别动)
  ///   3. 找到链接是相对路径 → 拼成绝对 URL (用 fetch 的最终 URL 作 base)
  ///   4. 找不到 → 返回原 URL, 让 libmpv 自己处理
  ///
  /// 失败 (超时/网络错) 不抛异常, 返回原 URL — 不影响播放, 最多就是
  /// 分享页解析失败退化成原来的"播不了"行为, 跟修之前一样.
  Future<String> _resolveSharePageUrl(String originalUrl) async {
    if (originalUrl.isEmpty) return originalUrl;

    // 1. 已经是视频流后缀 → 不解析
    final lower = originalUrl.toLowerCase();
    final videoExts = ['.m3u8', '.mp4', '.ts', '.flv', '.mkv', '.avi', '.mov'];
    // 去掉 query string 再判断后缀 (index.m3u8?sign=xxx 也要认)
    final pathPart = lower.split('?').first;
    if (videoExts.any((ext) => pathPart.endsWith(ext))) {
      return originalUrl;
    }

    // 2. fetch 看是不是 HTML
    try {
      final resp = await http.get(Uri.parse(originalUrl)).timeout(
        const Duration(seconds: 5),
      );
      final contentType = resp.headers['content-type'] ?? '';
      if (!contentType.toLowerCase().contains('text/html')) {
        // 不是 HTML, 原样返回 (可能是二进制视频流)
        return originalUrl;
      }

      final html = resp.body;

      // 3. 在 HTML 里找 m3u8/mp4 链接
      //   常见模式 (dytt-tvs 实测):
      //     const url = "/20260627/.../index.m3u8?sign=xxx";
      //     var url = "https://.../video.m3u8";
      //   优先找带 .m3u8 / .mp4 的字符串
      final m3u8Regex = RegExp(
        r'''url\s*=\s*["']([^"']+\.(?:m3u8|mp4)[^"']*)["']''',
        caseSensitive: false,
      );
      final match = m3u8Regex.firstMatch(html);
      // base Uri 用来解析相对路径 (用 fetch 的最终 URL, 已跟过 302)
      final baseUri = resp.request?.url ?? Uri.parse(originalUrl);
      if (match == null) {
        // 没找到 JS url 变量, 退而求其次找任何 .m3u8 链接
        final anyM3u8 = RegExp(
          r'''["']([^"']+\.(?:m3u8|mp4)[^"']*)["']''',
          caseSensitive: false,
        ).firstMatch(html);
        if (anyM3u8 == null) {
          return originalUrl; // HTML 里没视频链接, 原样返回
        }
        final extracted = anyM3u8.group(1)!;
        final resolved = _resolveAbsoluteUrl(extracted, baseUri);
        return resolved;
      }
      final extracted = match.group(1)!;
      final resolved = _resolveAbsoluteUrl(extracted, baseUri);
      return resolved;
    } catch (e) {
      // 超时/网络错, 不影响播放, 原样返回
      return originalUrl;
    }
  }

  /// 把相对 URL 拼成绝对 URL.
  /// [relative] 可能是绝对 URL (http://...) 也可能是相对路径 (/path/...).
  /// [baseUrl] 是 fetch 的最终 URL (跟过 302 后的), 用来解析相对路径.
  String _resolveAbsoluteUrl(String relative, Uri baseUrl) {
    if (relative.startsWith('http://') || relative.startsWith('https://')) {
      return relative;
    }
    if (relative.startsWith('//')) {
      return '${baseUrl.scheme}:$relative';
    }
    // 相对路径 — 用 Uri.resolve 拼接 (会正确处理 /path 和 path 两种情况)
    return baseUrl.resolve(relative).toString();
  }

  /// 播放指定集数
  Future<void> _playEpisode(int index) async {
    final source = _selectedSource;
    if (source == null) return;
    if (index < 0 || index >= source.episodes.length) return;
    final originalUrl = source.episodes[index];
    if (originalUrl.isEmpty) return;
    // v2.0.23: 播放 URL 不再走 buildProxiedUrl 包 worker
    //   v2.0.14 把播放 URL 包了一层 CF Worker (https://<worker>/m3u8?url=...),
    //   导致"从 v2.0.14 开始没速度, 关掉 CF 加速就正常".
    //   根因: CF Worker 做视频流代理时, 每个 .ts 段都要 worker fetch 再返回,
    //   worker 有 CPU 时间限制 + subrequest 限制 + 不能高效流式转发大 body,
    //   长 HLS 几百段累计后视频流就断了 → "没速度" (不是慢, 是断了)
    //   v1.0.77 时播放走原 URL 直连 (worker 只给测速用), 所以没问题.
    //
    //   现在的加速方案:
    //   - VideoProxyServer (v2.0.16+, v2.0.22 修好) 通过 --http-proxy 让
    //     libmpv 走本地代理 → 竞速拨号优选 IP → CF edge, 不经过 worker
    //   - 代理没起 (条件不满足) → 直连原 URL, 用户反馈直连正常
    //   - 测速 (_testSourceSpeed) 继续走 buildProxiedUrl, 不受影响
    // v2.0.64: 解析分享页 HTML 提取真实视频 URL.
    //   上游 CMS API 有时返回 /share/xxx 分享页 (HTML), 里面 JS 变量 url 才是
    //   真正的 m3u8 流. libmpv 不执行 JS, 直接 open 分享页 → 拿到 HTML →
    //   "Failed to recognize file format". 修法: 检测是 HTML 就提取 m3u8.
    //   只对明显不是视频流 (非 .m3u8/.mp4/.ts/.flv 后缀) 的 URL 做 fetch,
    //   避免对正常视频流多一次 HTTP 请求.
    final url = await _resolveSharePageUrl(originalUrl);

    // 切集时先把自动切下一集标志重置, 让新一集播完时能再次触发
    _autoPlayedThisEpisode = false;
    // 切集时清零 _lastKnownPosition, 避免上一集的"主片位置"被新一集沿用
    // 导致进度同步兜底用错位置 (v2.1.13 起 _lastKnownPosition 只用于进度
    // 同步兜底, 广告跳过逻辑已移除, 不需要清其他字段).
    _lastKnownPosition = Duration.zero;
    // v2.1.20: 切集时重置广告重置检测 — _State 不重建 (还在 player_screen
    //   同一个 widget), _adResetDetected 状态不自动清零. 上一集检测到广告
    //   重置 (4-5 次广告的源) → _adResetDetected=true → 切到新一集片头也
    //   不跳 (用户反馈). 新一集可能没广告, 必须重新检测.
    _adResetDetected = false;
    _lastPosForAdDetect = -1;

    // 记住这次要 seek 到的位置, 等 player 缓冲到可以 seek 时用
    // 仅在用户主动开新集时且和云记忆吻合的那次才用
    Duration? resumeAt;
    if (_pendingResumeAt != null && index == _currentEpisodeIndex) {
      resumeAt = _pendingResumeAt;
    }
    // 用完清掉, 避免切下一集时还 seek 回去
    _pendingResumeAt = null;

    // 切集时先保存上一条的进度
    //
    // v1.0.56: 必须在 setState 之前调! 之前是 setState 之后调,
    // setState 改了 _currentEpisodeIndex 成新集, _saveCurrentProgress
    // 内部 `index: _currentEpisodeIndex + 1` 算出的是**新集 index**,
    // 但此时 _player.stop() 还没调, pos / _currentPosition / state.duration
    // 都还是**旧集**的值 — 错配 (playTime=旧集, index=新集)
    //
    // 用户场景 (v1.0.54 之前 streams.completed 误触发):
    //   1. 用户看第2集 30 分钟, 10s 定时器存 {index:2, playTime:30min} ✓
    //   2. streams.completed 误触发 → 切第3集 (v1.0.55 已修误触发)
    //   3. setState _currentEpisodeIndex=2 (第3集 0-based)
    //   4. _saveCurrentProgress(force:true) 存 {index:2+1=3, playTime:30min}
    //      ← 错误! 应该是 {index:2, playTime:30min}
    //   5. 覆盖云端 index=2 那条! 下次重开历史显示第3集
    //   6. 而且 playTime=30min 还是第2集的位置, 跟第3集 index 错配
    //      (用户报告"进度条记忆问题我也怀疑存的问题"就是这个)
    //
    // 修法: 把 setState 挪到 _saveCurrentProgress 之后, 让
    //       _currentEpisodeIndex 在 save 时还是旧值, 自动得到旧集 index
    if (_firstRecordSaved) {
      _saveCurrentProgress(force: true);
    }

    setState(() {
      _currentEpisodeIndex = index;
      _isBuffering = true;
      _phase = 'playing';
    });
    // v2.0.51: 切集后 PageView 跳到当前 episode 所在页 (用 jumpToPage, 静默切)
    final newPage = (index ~/ _episodesPerPage).clamp(0, 999);
    if (_episodesPageController.hasClients &&
        _episodesPageController.page?.round() != newPage) {
      _episodesPageController.jumpToPage(newPage);
    }

    // v2.0.65: 先 await _ensureVideoProxy (以前是 unawaited), 拿到代理端口
    //   再构造播放 URL. 代理起成功 → 播放 URL 走 http://127.0.0.1:PORT/m3u8?url=...
    //   代理没起 → 播放 URL 走原来的 buildProxiedUrl (https://worker/m3u8?url=...)
    await _ensureVideoProxy();
    final proxyOn = _videoProxy?.isRunning == true;
    final proxyPort = _videoProxy?.port ?? 0;

    // v2.0.65: 代理起成功时, 播放 URL 走本地 HTTP 代理 (不走 CONNECT 隧道).
    //   代理没起时, 走原来的 buildProxiedUrl (libmpv 直连 worker).
    final String playUrl;
    if (proxyOn && proxyPort > 0) {
      // 播放 URL = http://127.0.0.1:PORT/m3u8?url=原URL
      // 代理收到 GET /m3u8?url=原URL 后, fetch https://worker/m3u8?url=原URL 返回
      playUrl = 'http://127.0.0.1:$proxyPort/m3u8?url=${Uri.encodeComponent(url)}';
    } else {
      playUrl = await UserDataService.buildProxiedUrlAsync(url, forceM3u8: true);
    }

    // v2.0.34: 保存最终播放 URL 给「加速链路」弹层用
    _currentPlayUrl = playUrl;

    // v2.0.58: 记录实际播放 URL + 代理状态, 分析 "4s/6s 时长" bug 的关键信号.
    //   原 URL vs playUrl (buildProxiedUrl 之后) 能看出 CF Worker 是否介入;
    //   代理是否起能看出 .ts 段是否走优选 IP.
    try {
      await _player.stop();
      await _player.open(Media(playUrl));
      // 云记忆恢复
      //
      // v1.0.61 fix: v1.0.60 等了 position stream, 但根因是 player 在
      // `open()` 后没进入 playing 状态 (某些 libmpv / 网络场景下不 auto-play),
      // 停在 stopped. 在 stopped 状态下:
      //   1. position stream 不会回 (因为没在播)
      //   2. _player.seek() 被 libmpv 静默丢, state.position 仍是 0
      //   3. v1.0.60 的 "250ms 后检查 position, 不对就重试" 也救不回来,
      //      因为 state.position 永远 0, 重试的 seek 同样被丢
      // 表现: 用户装 v1.0.60 后还是从 0 开始播
      // 修法:
      //   1. 显式 _player.play() 强制 player 进入 playing 状态
      //   2. 监听 streams.buffering, 等 buffering 完成 (从 true→false)
      //   3. 再 seek
      //   4. 用 streams.position 验证 (而不是 state.position, state 是
      //      快照可能没更新), 验证失败重试一次
      if (resumeAt != null) {
        // 1. 显式 play 强制进入 playing 状态
        try {
          await _player.play();
        } catch (_) {}
        // 2. 等 buffering 完成
        await _waitForBufferingComplete(timeout: const Duration(seconds: 5));
        // 3. seek
        try {
          await _player.seek(resumeAt);
        } catch (_) {}
        // 4. 验证: 用 position stream 检查 position 是否到 resumeAt 附近,
        // 250ms 内没到就重试一次
        await Future.delayed(const Duration(milliseconds: 250));
        final ok = await _verifySeekByStream(resumeAt);
        if (!ok) {
          try {
            await _player.seek(resumeAt);
          } catch (_) {}
          // 再验证一次
          await Future.delayed(const Duration(milliseconds: 250));
          await _verifySeekByStream(resumeAt);
        }
      }
      if (!mounted) return;
      setState(() => _isBuffering = false);
      // 启动定时器, 并立即保存一条 (标记已开始)
      _startProgressTimer();
      if (resumeAt == null) {
        // 非 resume 场景 (新集/切集): 重置 flag 让定时器先存一次, 然后立即 save
        // 标记已开始. playTime=0 是预期的 (用户刚点开)
        _firstRecordSaved = false;
        _saveCurrentProgress();
      } else {
        // v1.0.59: resume 场景下 player 刚 open + seek, position stream 可能
        // 还没回传, _currentPosition / state.position 都还是 0. 此时若
        // _firstRecordSaved=false, 10s 定时器第一次 tick 时 (假定此时 stream
        // 已回但 pos 偶尔还是 0) 命中 state.playing=true 分支存一条
        // playTime=0 的记录, **把云端 12 分钟那条覆盖掉**, 下次重开云端
        // 拉到 playTime=0 就从 0 开始.
        //
        // v1.0.50 修法是跳过立即 save, 但没处理 10s 定时器这次 — 假设 10s
        // 内 position stream 一定回传 > 0. 慢网络 / 大视频下不一定.
        //
        // 修法: 设 _firstRecordSaved=true, 让 10s 定时器存 0 时命中
        //   if (!force && _lastSavedKey == key && playTime == 0
        //       && _firstRecordSaved) { return; }
        // 早返跳过. 等下一个 tick (再 10s 后) stream 肯定回了, 正常存.
        // 用户多看 10s 不影响体验, 但避免误覆盖云端记录.
        _firstRecordSaved = true;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isBuffering = false;
        _error = '播放失败: $e';
      });
    }
  }

  /// 等待 player 真正开始解码 (position stream 第一次回传)
  ///
  /// v1.0.60: media_kit 的 `Player.open()` 返回时 player 还在初始化,
  /// 立即 seek 经常被丢. 等 position stream 第一次回传 (说明 player 已
  /// ready) 再 seek, 可以让 resume 100% 生效. 带 timeout, 超时后
  /// 也继续 (fallback 到直接 seek).
  ///
  /// v1.0.61: 这个函数在新流程里被 _waitForBufferingComplete 替代,
  /// 但保留作为兜底 (万一 buffering 监测失败).
  Future<void> _waitForPlayerReady({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final completer = Completer<void>();
    late StreamSubscription<Duration> sub;
    sub = _player.streams.position.listen((_) {
      if (!completer.isCompleted) {
        completer.complete();
      }
      sub.cancel();
    });
    try {
      await completer.future.timeout(timeout);
    } catch (_) {
      // 超时, 继续 (后续会再 seek 一次兜底)
      try {
        await sub.cancel();
      } catch (_) {}
    }
  }

  /// 等待 buffering 完成 (从 true→false)
  ///
  /// v1.0.61: media_kit 在某些 libmpv 场景下 Player.open() 不 auto-play,
  /// player 停在 stopped, 此时 seek 被丢. 修法: 显式 play + 等
  /// streams.buffering 从 true 变 false (说明 player 已开始解码). 比
  /// v1.0.60 的 position stream 等待更可靠 (position stream 可能在
  /// buffering 期间也回 0, 容易误判 ready).
  Future<void> _waitForBufferingComplete({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // 先看一下当前 buffering 状态, 如果本来就是 false, 立即返回
    try {
      if (!_player.state.buffering) {
        return;
      }
    } catch (_) {}
    final completer = Completer<void>();
    late StreamSubscription<bool> sub;
    sub = _player.streams.buffering.listen((isBuffering) {
      if (!isBuffering && !completer.isCompleted) {
        completer.complete();
      }
    });
    try {
      await completer.future.timeout(timeout);
    } catch (_) {
      // 超时, 继续 (后续会再 seek 一次兜底)
    }
    try {
      await sub.cancel();
    } catch (_) {}
  }

  /// 用 position stream 验证 seek 是否生效
  ///
  /// v1.0.61: \_player.state.position 是快照, libmpv 在某些场景下不会
  /// 及时更新 state, 但 streams.position 会在 buffer decode 完成后
  /// 立即回新位置. 用 stream 验证比用 state 可靠.
  ///
  /// 返回 true 表示 seek 生效 (position 到了 resumeAt 附近), false
  /// 表示没生效需要重试.
  Future<bool> _verifySeekByStream(
    Duration resumeAt, {
    Duration window = const Duration(milliseconds: 800),
  }) async {
    final completer = Completer<bool>();
    late StreamSubscription<Duration> sub;
    var hit = false;
    sub = _player.streams.position.listen((pos) {
      if (!hit && pos >= resumeAt - const Duration(seconds: 1)) {
        hit = true;
        if (!completer.isCompleted) completer.complete(true);
      }
    });
    try {
      // 给 [window] 时间, 看 stream 是否回 ≥ resumeAt-1s 的位置
      await Future.delayed(window);
    } catch (_) {}
    try {
      await sub.cancel();
    } catch (_) {}
    if (!completer.isCompleted) completer.complete(false);
    return await completer.future;
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
              // v1.0.65: 先等 _currentPosition > 0 再 save, 避免刚 play 就
              // back 时存 0 覆盖之前的真进度. 仍然 0 就跳过
              await _waitForValidPosition();
              if (_currentPosition > Duration.zero) {
                // v1.0.49: 必须先 save 再 stop, 否则 stop 把 state.position 重置成 0,
                // _saveCurrentProgress 读到的就是 0, 退出后下次打开从 0 开始.
                // (之前的顺序是先 stop 再 save, 写盘的 playTime 一直是 0)
                await _saveCurrentProgress(force: true);
              }
              // 从播放页返回详情页: 恢复竖屏, 暂停播放
              try {
                await _player.stop();
              } catch (_) {}
              await _onExitFullscreen();
              if (mounted) {
                setState(() {
                  _phase = 'detail';
                });
              }
            } else if (didPop && _phase == 'detail') {
              // v1.0.50: 真正退出页面时不再 save.
              // 之前这里调 _saveCurrentProgress(force: true), 但 player 在
              // playing→detail 那次已经 stop 了, state.position 和 _currentPosition
              // 都是 0, 这次 save 会存 playTime=0 覆盖掉之前存的 12 分钟,
              // 下次打开云端拉到 playTime=0 又从 0 开始.
              // 进度已经在 playing→detail 转换时存过了, 这里不需要再存.
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

  /// v2.0.38: 推断 kind: 多集 → tv (剧集/综艺/番剧), 1 集 → movie
  /// 兜底: sourceName 含 bangumi → tv, 其他 → movie
  String get _kind {
    if (widget.videoInfo.totalEpisodes > 1) return 'tv';
    if (widget.videoInfo.sourceName.toLowerCase().contains('bangumi')) {
      return 'tv';
    }
    return 'movie';
  }

  // v2.0.95/96: TMDB 精准识别 — 后台拉 w1280 backdrop, 拿到后 setState
  //   触发 DoubanDetailHeader rebuild 切到 TMDB backdrop. 失败 / 没
  //   配 key / 搜索无结果 = _tmdbBackdropUrl 保持 null, 走豆瓣 coverUrl.
  //
  // v2.0.95: 失败时 debugPrint + SnackBar 弹错 (用户反馈"key 没问题 +
  //   还是豆瓣海报"需要知道原因, 弹错让用户能行动).
  // v2.0.96: 失败时改回静默 fallback (SnackBar 删), debugPrint 保留.
  //   原因: TMDB 数据覆盖不全 (e.g. 2025 中文新片没入库), 频繁弹
  //   SnackBar 反而打扰用户, 跟 v2.0.91 删 log UI 精神一致 — 失败
  //   静默, 让 DoubanDetailHeader 走豆瓣 coverUrl 兜底. 开发者仍能
  //   `adb logcat | grep TMDB` 看全流程.
  //
  // 守门:
  //   - 配了 TMDB key (UserDataService.isTmdbConfigured)
  //   - title 非空 (没标题搜不到)
  //   - year 解析成功 (4 位数字; "2024-01-01" 截前 4 位, "2024" 直接用)
  //
  // 异常: 任何一步 throw / 网络超时 / 解析失败 = debugPrint 静默, 用户
  //   感知不到 (DoubanDetailHeader 继续走 coverUrl).
  Future<void> _loadTmdbBackdrop() async {
    if (!UserDataService.isTmdbConfigured()) {
      debugPrint('[TMDB] skip: key not configured');
      DiaryService.add('[TMDB] skip: key not configured');
      return;
    }
    final title = widget.videoInfo.title.trim();
    if (title.isEmpty) {
      debugPrint('[TMDB] skip: title empty');
      DiaryService.add('[TMDB] skip: title empty');
      return;
    }

    // year 解析: "2024" 或 "2024-01-01" → 2024
    int? year;
    final y = widget.videoInfo.year;
    if (y != null && y.isNotEmpty) {
      final m = RegExp(r'^(\d{4})').firstMatch(y);
      if (m != null) year = int.tryParse(m.group(1)!);
    }

    debugPrint('[TMDB] search: title="$title" year=$year');
    DiaryService.add('[TMDB] search: title="$title" year=$year');

    try {
      final ref = await TmdbService.search(title: title, year: year);
      if (!mounted) return;
      if (ref == null) {
        debugPrint(
            '[TMDB] search: no result (key 失效 / 剧名无匹配 / year 不匹配)');
        DiaryService.add(
            '[TMDB] search: no result (key 失效 / 剧名无匹配 / year 不匹配)');
        // v2.0.96: 静默 fallback — SnackBar 删了, 不打扰用户
        // v2.0.99.2: 但写进日记, 用户主动点开「日记」页能看到
        return;
      }
      debugPrint('[TMDB] search hit: ${ref.mediaType}#${ref.id}');
      DiaryService.add('[TMDB] search hit: ${ref.mediaType}#${ref.id}');
      final art = await TmdbService.fetchArt(
          id: ref.id, mediaType: ref.mediaType);
      if (!mounted) return;
      if (art == null || art.backdropUrl == null) {
        debugPrint(
            '[TMDB] fetchArt: no backdrop (art=${art == null ? "null" : "empty"})');
        DiaryService.add(
            '[TMDB] fetchArt: no backdrop (art=${art == null ? "null" : "empty"})');
        return;
      }
      debugPrint('[TMDB] backdrop: ${art.backdropUrl}');
      DiaryService.add('[TMDB] backdrop: ${art.backdropUrl}');
      setState(() {
        _tmdbBackdropUrl = art.backdropUrl;
      });
    } catch (e, st) {
      debugPrint('[TMDB] error: $e\n$st');
      DiaryService.add('[TMDB] error: $e');
      // v2.0.96: 静默 fallback
    }
  }

  // v2.1.7: 拉豆瓣剧情简介 — 跟 _loadTmdbBackdrop 同样的静默 fallback 模式
  //
  // 流程:
  //   1. 检查 widget.videoInfo.doubanId (源 API 拉的剧集都有)
  //   2. 调 DoubanService.getDoubanDetails (m.douban.com rexxar JSON, 不需登录)
  //   3. 成功: 拿 DoubanMovieDetails.summary, setState 触发 _buildSummarySection
  //   4. 失败 / 没 doubanId / summary 字段空: 不渲染, 不打扰用户
  //
  // 跟 _loadTmdbBackdrop 区别: 没配 "summary" 之类的用户配置, doubanId 必来自源,
  //   所以只检查 doubanId + summary 字段是否非空.
  Future<void> _loadDoubanSummary() async {
    final doubanId = widget.videoInfo.doubanId;
    // v2.1.12: 豆瓣拉不到 (没 doubanId / rexxar 失败 / summary 空) 时
    //   fallback 到 TMDB overview. 用户反馈"历史影片/主页影片都不显示简介"
    //   根因: 历史记录 PlayRecord 不存 doubanId, 主页某些源也没 doubanId,
    //   导致 _loadDoubanSummary 直接 return. TMDB 靠标题搜索, 不依赖 doubanId.
    if (doubanId != null && doubanId.isNotEmpty) {
      debugPrint('[Douban summary] fetch: doubanId=$doubanId');
      DiaryService.add('[Douban summary] fetch: doubanId=$doubanId');
      try {
        final resp = await DoubanService.getDoubanDetails(
          context,
          doubanId: doubanId,
        );
        if (!mounted) return;
        if (resp.success && resp.data != null) {
          final s = resp.data!.summary;
          if (s != null && s.trim().isNotEmpty) {
            debugPrint('[Douban summary] hit: ${s.length} chars');
            DiaryService.add('[Douban summary] hit: ${s.length} chars');
            if (mounted) {
              setState(() {
                _summary = s.trim();
              });
            }
            return; // 豆瓣成功, 不走 TMDB fallback
          }
        }
        debugPrint('[Douban summary] failed/empty, fallback TMDB overview');
        DiaryService.add('[Douban summary] failed/empty, fallback TMDB overview');
      } catch (e, st) {
        debugPrint('[Douban summary] error: $e\n$st, fallback TMDB overview');
        DiaryService.add('[Douban summary] error: $e, fallback TMDB overview');
      }
    } else {
      debugPrint('[Douban summary] skip: no doubanId, fallback TMDB overview');
      DiaryService.add('[Douban summary] skip: no doubanId, fallback TMDB overview');
    }
    // v2.1.12: TMDB overview fallback — 靠标题搜索, 不依赖 doubanId
    if (_summary != null) return; // 已有豆瓣简介就不重复拉
    final title = widget.videoInfo.title.trim();
    if (title.isEmpty) return;
    int? year;
    final y = widget.videoInfo.year;
    if (y != null && y.isNotEmpty) {
      final m = RegExp(r'^(\d{4})').firstMatch(y);
      if (m != null) year = int.tryParse(m.group(1)!);
    }
    try {
      final overview = await TmdbService.fetchOverview(
        title: title,
        year: year,
      );
      if (!mounted) return;
      if (overview != null && overview.isNotEmpty) {
        setState(() {
          _summary = overview;
        });
      }
    } catch (e) {
      debugPrint('[TMDB overview] error: $e');
      DiaryService.add('[TMDB overview] error: $e');
      // 静默 fallback — 不打扰用户
    }
  }

  // v2.1.17: 拉 TMDB 演员 — 跟 _loadTmdbBackdrop / _loadDoubanSummary 同样
  //   静默 fire-and-forget 模式. 平板大头部背景图下半部显示用.
  Future<void> _loadTmdbCast() async {
    if (!UserDataService.isTmdbConfigured()) {
      return;
    }
    final title = widget.videoInfo.title.trim();
    if (title.isEmpty) return;
    int? year;
    final y = widget.videoInfo.year;
    if (y != null && y.isNotEmpty) {
      final m = RegExp(r'^(\d{4})').firstMatch(y);
      if (m != null) year = int.tryParse(m.group(1)!);
    }
    try {
      final cast = await TmdbService.fetchCredits(title: title, year: year);
      if (!mounted) return;
      if (cast != null && cast.isNotEmpty) {
        setState(() {
          _cast = cast;
        });
      }
    } catch (e) {
      debugPrint('[TMDB credits] error: $e');
      DiaryService.add('[TMDB credits] error: $e');
      // 静默 fallback
    }
  }

  Widget _buildDetailView(bool isDark) {
    // v2.1.17: 平板判定 — DoubanDetailHeader 用同一标准 (>=600), 用来
    //   决定要不要传 castOverlay (演员横向滚动 ListView).
    final isTablet = MediaQuery.of(context).size.width >= 600;
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
                // v2.0.38: 配了 TMDB key → 大头部 (TMDB backdrop + 海报 + 简介),
                //            没配 → 原 110x150 小海报 + 标题/年份
                // v2.0.78: 登录豆瓣 → 大头部 (DoubanDetailHeader)
                //   - 手机: 2:3 竖版海报当背景 + 渐变压暗 + 底部标题
                //   - 平板: 21:9 横版 + 左侧 150x225 大竖海报 + 右侧标题
                // v2.0.77 (之前): 走 _buildPosterHeader (110x150 小海报)
                //   只升了图片质量, 没大头部布局. 用户反馈"豆瓣大海报在
                //   哪和 tmdb 一样啊" → 加这个.
                //   海报 URL 通过 getImageUrl 自动升 l_ratio_poster
                //   (登录态, 见 image_url.dart).
                // 没登录 = 走 _buildPosterHeader (现有 110x150 小海报,
                //   行为完全不变, 跟用户要求一致).
                // v2.0.99 fix: 去 isDoubanLoggedIn() 条件 — TMDB backdrop
                //   不该跟豆瓣登录绑. v2.0.93 我把 TMDB 写进 DoubanDetailHeader
                //   (大头部), 大头部又在 v2.0.78 跟豆瓣登录绑 (DoubanDetailHeader
                //   加的时候没 TMDB, 大头部 = 豆瓣登录态, 当时合理). v2.0.93 加
                //   TMDB 时保留 isDoubanLoggedIn 条件, 错了 — TMDB 是独立数据源,
                //   跟登录无关. 用户反馈 "tmdb 还是没显示海报" + 截图显示豆瓣未
                //   登录 → 走 _buildPosterHeader (小头部) → TMDB 永远不显示.
                //   改成: 只要 cover 不空 (豆瓣/番剧源都给) 就走大头部, TMDB
                //   backdrop 独立生效. 没豆瓣登录 = 大头部走 coverUrl/cover 兜底
                //   (跟 v2.0.84/v2.0.85 行为一致, 跟 v2.0.78 没 DoubanDetailHeader
                //   之前的 110x150 小海报完全不一样 — 现在是大头部视觉, 只是
                //   背景图走豆瓣兜底).
                if (widget.videoInfo.cover.isNotEmpty)
                  // v2.0.84: 传 coverUrl (16:9 横版剧照 l_cover 1280x720)
                  //   给详情页大头部背景. 平板/横屏缩到 2K 宽不糊.
                  // v2.0.93: 传 tmdbBackdropUrl (TMDB w1280 16:9 backdrop, 优
                  //   先级最高, 精准识别结果). 配了 TMDB key + 搜索成功 = 用
                  //   TMDB backdrop; 否则 = null, 走 coverUrl 兜底 (v2.0.84).
                  // v2.0.99: tmdbBackdropUrl 不依赖豆瓣登录, 配了 TMDB key 就生效.
                  DoubanDetailHeader(
                    title: widget.videoInfo.title,
                    year: widget.videoInfo.year,
                    cover: widget.videoInfo.cover,
                    source: widget.videoInfo.source,
                    sourceName: widget.videoInfo.sourceName,
                    coverUrl: widget.videoInfo.coverUrl,
                    tmdbBackdropUrl: _tmdbBackdropUrl,
                    // v2.1.8: 传 summary, 平板 header 右侧显示简介填满空白.
                    // v2.1.10: 手机 header 右侧也显示简介 (上面不够写可左滑),
                    //   下方不再渲染独立 section.
                    summary: _summary,
                    // v2.1.17: 平板传演员横向滚动 ListView (浮在背景图下半部
                    //   空白处). 手机不传 — DoubanDetailHeader 内部忽略, 跟
                    //   v2.1.16 视觉一致. _cast 为空 (没配 TMDB key / 拉不到
                    //   演员) 时不传, header 不渲染演员区.
                    castOverlay: isTablet && _cast != null
                        ? _buildCastOverlay(_cast!)
                        : null,
                  )
                else
                  _buildPosterHeader(isDark),
                // v2.1.10: 下方独立剧情简介 section 删除 — 手机/平板
                //   header 右侧都已显示简介 (上面不够写可左滑). 用户反馈
                //   "下面画圈的剧情简介去掉, 上面不够写的左滑动".
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

  // v2.1.17: 平板大头部背景图下半部浮层 — 横向滚动演员头像 + 名字.
  //   只在平板 (isTablet) + _cast 非空时由 _buildDetailView 调用. 一行
  //   排列, 不够就滑动. 头像用 TMDB w185 圆图, 名字 1 行省略号, 跟背景
  //   图对比 + 阴影保持可读. 跟 v2.1.18 删掉的 episodesOverlay 同位置模式
  //   (DoubanDetailHeader 内部 Positioned 浮在 left:180 right:16 bottom:14).
  //   尺寸 (v2.1.17 微调): 头像 70 + 名字 12pt + 总高 100 — 21:9 大背景图
  //   下半部比例协调, 比 v2.1.17 首发 50/10pt/80 显大 40%.
  Widget _buildCastOverlay(List<TmdbCast> cast) {
    return SizedBox(
      height: 100,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: cast.length,
        itemBuilder: (context, i) {
          final c = cast[i];
          final url = c.fullProfileUrl;
          return Container(
            margin: const EdgeInsets.only(right: 14),
            child: Column(
              children: [
                ClipOval(
                  child: SizedBox(
                    width: 70,
                    height: 70,
                    child: url != null
                        ? CachedNetworkImage(
                            imageUrl: url,
                            // v2.1.33: 走 OkHttp (强制 TLS 1.2), 避开 dart:io TLS 1.3
                            //   cipher 跟 CF edge zone 协商失败 (走 cacheManager 注入)
                            cacheManager: LunaCacheManager.instance,
                            fit: BoxFit.cover,
                            placeholder: (ctx, u) => Container(
                              color: Colors.white12,
                            ),
                            errorWidget: (ctx, u, e) => Container(
                              color: Colors.white12,
                              child: const Icon(Icons.person,
                                  color: Colors.white54, size: 36),
                            ),
                          )
                        : Container(
                            color: Colors.white12,
                            child: const Icon(Icons.person,
                                color: Colors.white54, size: 36),
                          ),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: 80,
                  child: Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.9),
                      shadows: const [
                        Shadow(
                            color: Colors.black54,
                            offset: Offset(0, 1),
                            blurRadius: 3),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
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
                          // v2.1.33: 走 OkHttp (强制 TLS 1.2), 避开 dart:io TLS 1.3
                          //   cipher 跟 CF edge zone 协商失败 (走 cacheManager 注入)
                          cacheManager: LunaCacheManager.instance,
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

  // v2.1.7: 剧情简介 section
  //
  // 视觉: 跟 _buildEpisodeSection / _buildSourceSection 一致 (圆角背景 +
  //   16 horizontal padding), 标题 "剧情简介" + 简介文本 (maxLines 5 默认,
  //   点击"展开"切到无 maxLines).
  //
  // 数据流: _summary 由 _loadDoubanSummary() 异步填充, 这里是纯渲染.
  //   _summary == null (没 doubanId / 拉不到 / 字段空) → 上层 if 不渲染这
  //   段, 这里只是用 _summary! 解 null 安全.
  Widget _buildSummarySection(bool isDark) {
    final summary = _summary!;
    // 简介超过 5 行默认折叠, 短的全部显示
    final isLong = summary.length > 120; // 阈值简单按字符数算
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle('剧情简介', isDark),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: isLong
                ? () => setState(() => _summaryExpanded = !_summaryExpanded)
                : null,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF1F2937)
                    : const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: Text(
                      summary,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.55,
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.85)
                            : Colors.black87,
                      ),
                      maxLines: isLong && !_summaryExpanded ? 5 : null,
                      overflow: isLong && !_summaryExpanded
                          ? TextOverflow.ellipsis
                          : TextOverflow.visible,
                    ),
                  ),
                  if (isLong) ...[
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          _summaryExpanded ? '收起' : '展开',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? const Color(0xFF93C5FD)
                                : const Color(0xFF2563EB),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Icon(
                          _summaryExpanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          size: 16,
                          color: isDark
                              ? const Color(0xFF93C5FD)
                              : const Color(0xFF2563EB),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

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

  /// v2.0.51: 选集面板 — 30 集一页, PageView 左右滑翻页
  ///
  /// 用户反馈 (平板模式): 单 GridView 一页铺 60+ 集, 平板上列数拉到 12,
  /// 卡片巨大 (cardW ~100dp), 视觉上"卡片大但内容少, 看着空". 同时
  /// 30 集往上就滚不动 (GridView 嵌在 SingleChildScrollView 里, 不会
  /// 自己滚, 要滚整页), 长剧 (60 / 80 / 100 集) 用户要一直滑滚轮.
  ///
  /// 改法:
  ///   - 拆成 PageView, 每页最多 30 集, 默认显示当前 episode 所在页
  ///   - 页数 = ceil(episodes.length / 30), 60 集 → 2 页, 100 集 → 4 页
  ///   - 标题旁加翻页指示器 "1/2" + PageView 底部小圆点 (current page 高亮)
  ///   - 每页内还是 GridView (列数按宽度动态, 跟旧版一致),
  ///     shrinkWrap + NeverScrollableScrollPhysics, 不会跟外层
  ///     SingleChildScrollView 抢手势
  ///   - 左右滑切页, 不影响外层上下滚 (Flutter PageView 默认 PageScrollPhysics
  ///     只接水平, vertical 由外层 SingleChildScrollView 处理)
  ///
  /// 兼容性: 卡片样式 / 选中渐变 / 点击 _playEpisode 逻辑全部保留.
  /// 列数 / 卡片宽 / 字号策略跟 v2.0.43 一样, 没动.
  static const int _episodesPerPage = 30;

  Widget _buildEpisodeSection(bool isDark) {
    final source = _selectedSource;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildSectionTitle('选集', isDark),
              const Spacer(),
              // v2.0.51: 翻页指示器 (1/2) — 用户滑动 PageView 时实时更新
              if (source != null && source.episodes.isNotEmpty)
                _buildEpisodePageBadge(
                  source.episodes.length,
                  isDark,
                ),
            ],
          ),
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
            _buildEpisodesPageView(source, isDark),
        ],
      ),
    );
  }

  /// v2.0.51: 翻页 badge "1/2", 显示在 "选集" 标题右侧
  Widget _buildEpisodePageBadge(int totalEpisodes, bool isDark) {
    final pageCount =
        (totalEpisodes + _episodesPerPage - 1) ~/ _episodesPerPage;
    final currentPage =
        (_currentEpisodeIndex ~/ _episodesPerPage).clamp(0, pageCount - 1);
    if (pageCount <= 1) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ValueListenableBuilder<PageController>(
        // v2.0.51: PageController 变化时 badge "1/2" 数字跟着变
        valueListenable: _pageControllerNotifier,
        builder: (context, controller, _) {
          final page = controller.hasClients
              ? (controller.page?.round() ?? currentPage)
              : currentPage;
          return Text(
            '${page + 1} / $pageCount',
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white60 : Colors.black54,
              fontWeight: FontWeight.w600,
            ),
          );
        },
      ),
    );
  }

  /// v2.0.51: 选集 PageView (30 集/页)
  Widget _buildEpisodesPageView(SearchResult source, bool isDark) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 列数策略: 跟 v2.0.43 一致 (手机 6 / 小平板 8 / 中平板 10 / 大平板 12)
        final width = constraints.maxWidth;
        int crossAxisCount;
        if (width < 600) {
          crossAxisCount = 6;
        } else if (width < 900) {
          crossAxisCount = 8;
        } else if (width < 1200) {
          crossAxisCount = 10;
        } else {
          crossAxisCount = 12;
        }
        const spacing = 6.0;
        final cardW =
            (width - spacing * (crossAxisCount - 1)) / crossAxisCount;
        final childAspectRatio = cardW < 80 ? 1.2 : 1.0;
        final fontSize = cardW < 80 ? 11.0 : 12.0;

        // 每页最多 30 集, 算行数
        final rows =
            ((_episodesPerPage + crossAxisCount - 1) ~/ crossAxisCount);
        final cardH = cardW / childAspectRatio;
        // 网格高度 = rows * cardH + (rows-1) * spacing
        final gridHeight = rows * cardH + (rows - 1) * spacing;
        // 加上底部翻页小圆点的高度 (16dp + 4dp marginTop)
        final sectionHeight = gridHeight + 20;

        final totalEpisodes = source.episodes.length;
        final pageCount =
            (totalEpisodes + _episodesPerPage - 1) ~/ _episodesPerPage;
        final initialPage =
            (_currentEpisodeIndex ~/ _episodesPerPage).clamp(0, pageCount - 1);

        return SizedBox(
          height: sectionHeight,
          child: Column(
            children: [
              SizedBox(
                height: gridHeight,
                child: PageView.builder(
                  // v2.0.51: PageController 跟着 episode 切换 + 用户滑动更新
                  controller: _episodesPageController,
                  onPageChanged: (page) {
                    // 通知 badge 数字更新 (ValueListenableBuilder)
                    _pageControllerNotifier.value = _episodesPageController;
                  },
                  itemCount: pageCount,
                  itemBuilder: (context, pageIndex) {
                    final start = pageIndex * _episodesPerPage;
                    final end = (start + _episodesPerPage).clamp(0, totalEpisodes);
                    return _buildEpisodesGridPage(
                      source,
                      start,
                      end,
                      isDark,
                      crossAxisCount,
                      childAspectRatio,
                      spacing,
                      cardW,
                      fontSize,
                    );
                  },
                ),
              ),
              // v2.0.51: 翻页小圆点 (跟 badge 同步)
              if (pageCount > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(pageCount, (i) {
                      final isActive = i == initialPage;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: isActive ? 16 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: isActive
                              ? const Color(0xFF22C55E)
                              : (isDark
                                  ? Colors.white24
                                  : Colors.black26),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      );
                    }),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// v2.0.51: 单页 GridView (30 集以内), 卡片样式跟 v2.0.43 一致
  Widget _buildEpisodesGridPage(
    SearchResult source,
    int start,
    int end,
    bool isDark,
    int crossAxisCount,
    double childAspectRatio,
    double spacing,
    double cardW,
    double fontSize,
  ) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: childAspectRatio,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
      ),
      itemCount: end - start,
      itemBuilder: (context, offset) {
        final index = start + offset;
        return _buildEpisodeCard(
          source,
          index,
          isDark,
          cardW,
          fontSize,
        );
      },
    );
  }

  /// v2.0.51: 抽出来的单集卡片 (PageView 每页 itemBuilder 复用)
  Widget _buildEpisodeCard(
    SearchResult source,
    int index,
    bool isDark,
    double cardW,
    double fontSize,
  ) {
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
                    Color(0xFF10B981),
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
                  : (isDark ? Colors.white70 : Colors.black87),
            ),
          ),
        ),
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
              // v2.0.34: 加速状态指示器 (CF Worker + 优选 IP)
              //   颜色编码: 绿=都启用 / 黄=只 CF Worker / 灰=都没开
              //   点击弹出 dialog 显示详细状态 (是否走优选 IP / CF 加速)
              _buildAccelStatusIcon(),
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

  /// 中央控制区: 左右快退/快进6s 按钮 + 中间播放/暂停
  /// 跟控件一起显隐, 点击后短暂显示提示文字
  Widget _buildSideSeekButtons() {
    if (!_isControlsVisible) return const SizedBox.shrink();
    final size = _isFullscreen ? 64.0 : 48.0;
    // v1.0.50: 竖屏 sideOffset 110 → 90, size 56 → 48
    // 110 时竖屏 360px 三个 56 按钮挤一起, 缩到 90 + 48 给中间留出空间
    // 90 仍 > 浮窗右边 88 (left=32 width=56), 不挡亮度/音量浮窗
    final sideOffset = _isFullscreen ? 140.0 : 90.0;
    return Positioned.fill(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 左: 快退6s 按钮(文字 -6) (v1.0.49: 60 → 6, 60秒跳过太多)
          Positioned(
            left: sideOffset,
            top: 0,
            bottom: 0,
            child: Center(
              child: _buildSeekCircleButton(
                size: size,
                onTap: () => _seekBySeconds(-6, '快退6s'),
                child: const _SeekLabel(label: '-6'),
              ),
            ),
          ),
          // 右: 快进6s 按钮(文字 +6) (v1.0.49: 60 → 6, 60秒跳过太多)
          Positioned(
            right: sideOffset,
            top: 0,
            bottom: 0,
            child: Center(
              child: _buildSeekCircleButton(
                size: size,
                onTap: () => _seekBySeconds(6, '快进6s'),
                child: const _SeekLabel(label: '+6'),
              ),
            ),
          ),
          // 中间: 播放/暂停按钮 (v1.0.49: 颜色跟底部 _iconBtn 播控按钮一致用 Colors.white)
          _buildSeekCircleButton(
            size: size,
            onTap: _togglePlayPause,
            child: Icon(
              _isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
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
    // v1.0.50: 修毛玻璃没生效的问题
    // 之前 BackdropFilter 在 Container 内部, 只模糊了 child 没模糊背景,
    // Container 的 color 画在 BackdropFilter 下面被遮住, 毛玻璃没效果
    // 正确做法: 外层 Container 负责阴影, ClipOval + BackdropFilter 模糊背景,
    // 内层 Container 半透明白色叠加 + border
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
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // 半透明白色叠在模糊背景上, 形成毛玻璃质感
                  color: Colors.white.withOpacity(0.15),
                ),
                child: Center(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 圆弧箭头图标 (已废弃, 快进/快退按钮改用 _SeekLabel 文字)
  // ignore: unused_element
  Widget _buildSeekIcon({required bool forward}) {
    return _SeekLabel(label: forward ? '+6' : '-6');
  }

  /// 圆形小按钮 (40x40, LunaTV Web 控制按钮)
  /// v2.0.33: 加 [iconColor] 可选参数, 「下一集」按钮用绿色突出
  Widget _iconBtn({
    required IconData icon,
    required VoidCallback? onTap,
    Color? iconColor,
  }) {
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
            color: iconColor ??
                (onTap == null ? Colors.white.withOpacity(0.3) : Colors.white),
            size: 22,
          ),
        ),
      ),
    );
  }

  /// v2.0.34: 顶部「加速状态」指示器
  ///
  /// 颜色编码 (用户一眼能看出当前是否真在用加速):
  ///   - 绿色 (0xFF10b981): CF Worker + 优选 IP 都启用 + 视频流走代理 (全加速)
  ///   - 黄色 (0xFFf59e0b): 只 CF Worker 启用 (m3u8/图片走 worker, 视频直连)
  ///   - 灰色 (0xFF9ca3af): 都没开 (完全直连原源)
  ///
  /// 注意: 颜色根据「配置 + 当前代理实际状态」实时算, 不依赖 fixed state.
  /// 配置变了 (用户开/关 CF Worker 加速、优选 IP) 下次 build 自然反映.
  Widget _buildAccelStatusIcon() {
    // 颜色逻辑 (不需要读 prefs, 每次 build 现算, 配置变时 build 自然刷新)
    // 简化: 只根据 _videoProxyActive + 已知 UI 状态决定颜色
    //   视频走代理 (绿) / 视频直连 (灰) — CF Worker 跟这个指示器
    //   关系不大, 因为 m3u8/图片走 worker 视频不一定走 worker
    //   重点是「当前视频流是不是真的被加速」
    final Color dotColor = _videoProxyActive
        ? const Color(0xFF10b981) // 绿: 视频走优选 IP 代理
        : const Color(0xFF9ca3af); // 灰: 直连
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _showAccelStatusDialog,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  Icons.bolt,
                  color: Colors.white.withOpacity(0.9),
                  size: 22,
                ),
                // 状态点: 绿/灰
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF1F2937),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// v2.0.34: 弹「加速链路」详情 dialog
  ///
  /// 设计目标 (用户原话): "要体现出是怎么加速的, 让人一眼看上去就是在加速"
  ///
  /// 改成**链路流程图**而不是 4 行状态, 3 个节点 + 2 条箭头:
  ///
  ///   ┌─────────────┐    ┌──────────────┐    ┌──────────────┐    ┌────────┐
  ///   │  📺 源播放   │ →  │  ☁️ CF Worker │ →  │  ⚡ 优选 IP   │ →  │  📱 手机│
  ///   │  原 m3u8    │    │  worker 域名  │    │  优选 IP     │    │ libmpv │
  ///   └─────────────┘    └──────────────┘    └──────────────┘    └────────┘
  ///      (灰/亮)             (灰/亮)             (灰/亮)
  ///
  /// 哪个节点没启用 → 那个节点灰色 + 该段箭头虚线
  /// 哪个节点启用 → 那个节点高亮 (蓝/绿) + 箭头实线
  ///
  /// 底部额外:
  ///   - 当前视频流实际走的是哪条路径 (✅ 全加速 / ⚠️ 半加速 / ❌ 直连)
  ///   - 实时下载速度
  ///   - 任何一个值 (IP/域名/URL) 都能点击复制
  Future<void> _showAccelStatusDialog() async {
    // v2.0.76: getCfWorkerEnabled() 现在是「优选 IP 启用」开关
    final preferIpEnabled = await UserDataService.getCfWorkerEnabled();
    final cfWorkerDomain = await UserDataService.getCfWorkerDomain();
    final cfBestIp = (await UserDataService.getCfBestIp()) ?? '';
    // v2.0.76: getVideoProxyEnabled() 现在是「视频代理」开关
    final videoProxyOn = await UserDataService.getVideoProxyEnabled();
    final hasResolvedIp = CfOptimizerHttpOverrides.getResolvedManualIp() != null;
    if (!mounted) return;

    // 节点启用状态
    // v2.0.76: CF Worker 代理本身不再有总开关, 域名配了就视为 worker 链路可用
    final cfWorkerOn = cfWorkerDomain.isNotEmpty;
    // v2.0.76: 优选 IP 启用 = 优选 IP 开关开 + IP 填了 + 已解析
    final bestIpOn = preferIpEnabled && cfBestIp.isNotEmpty && hasResolvedIp;
    final videoStreamViaProxy = _videoProxyActive;

    // 加速等级 (v2.0.76 语义):
    //   full: 域名配了 + 优选 IP 启用 + 视频流走代理 (理想, 走优选 IP + worker)
    //   half: 域名配了 + 视频流走代理 但没走优选 IP (走 worker 系统 DNS)
    //         或 优选 IP 启用 但 视频代理关 (视频直连, 其他仍走优选 IP + worker)
    //   none: 视频直连 (视频代理关, 没有任何代理加速)
    final accelLevel = (cfWorkerOn && bestIpOn && videoStreamViaProxy)
        ? 'full'
        : (cfWorkerOn && (videoStreamViaProxy || bestIpOn))
            ? 'half'
            : 'none';

    // 解析出来的优选 IP (域名模式才有意义)
    final resolvedIp = CfOptimizerHttpOverrides.getResolvedManualIp() ?? cfBestIp;

    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF1F2937),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题 + 当前等级徽章
              Row(
                children: [
                  const Icon(Icons.bolt, color: Color(0xFFfbbf24), size: 22),
                  const SizedBox(width: 8),
                  const Text(
                    '加速链路',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  _buildAccelBadge(accelLevel),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _accelLevelDescription(accelLevel),
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              // 4 节点链路图 (源 / CF Worker / 优选 IP / 手机)
              _buildLinkNode(
                icon: Icons.video_library,
                label: '源播放地址',
                value: _currentPlayUrl.isEmpty
                    ? '（无）'
                    : _stripUrlQuery(_currentPlayUrl),
                enabled: true, // 源永远有
                accent: const Color(0xFF94a3b8),
              ),
              _buildLinkArrow(enabled: true),
              _buildLinkNode(
                icon: Icons.cloud_outlined,
                label: 'CF Worker 加速域名',
                value: cfWorkerDomain.isEmpty
                    ? '（未配置）'
                    : cfWorkerDomain,
                enabled: cfWorkerOn,
                accent: const Color(0xFF60a5fa),
                subtitle: cfWorkerOn ? '视频源经过 CF edge' : '未启用',
              ),
              _buildLinkArrow(enabled: bestIpOn),
              _buildLinkNode(
                icon: Icons.bolt,
                label: '优选 IP',
                value: cfBestIp.isEmpty
                    ? '（未配置）'
                    : (cfBestIp.contains('.') && _isIpv4Strict(cfBestIp)
                        ? cfBestIp
                        : '$cfBestIp\n  →  $resolvedIp'),
                enabled: bestIpOn,
                accent: const Color(0xFF10b981),
                subtitle: bestIpOn
                    ? (videoStreamViaProxy
                        ? '视频流强制走这个 IP'
                        : 'HTTP 请求走这个 IP (m3u8/图片)')
                    : '未配置',
              ),
              _buildLinkArrow(enabled: videoStreamViaProxy),
              _buildLinkNode(
                icon: Icons.smartphone,
                label: '手机',
                value: '本机 libmpv',
                enabled: true,
                accent: const Color(0xFFa78bfa),
                subtitle: videoStreamViaProxy
                    ? '经本地代理 → 优选 IP'
                    : '直连上游节点',
              ),
              const SizedBox(height: 16),
              const Divider(color: Color(0xFF374151), height: 1),
              const SizedBox(height: 12),
              // 实时下载速度
              Row(
                children: [
                  const Icon(Icons.speed,
                      color: Color(0xFF60a5fa), size: 18),
                  const SizedBox(width: 10),
                  const Text(
                    '下载速度',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                    ),
                  ),
                  const Spacer(),
                  // v2.0.88: 文本状态 fallback 优先 (拿不到 demuxer-bytes /
                  //   bitrate 时显示「已暂停 / 未开播 / 缓冲中 / 测量中」)
                  Text(
                    _playbackStateText.isNotEmpty
                        ? _playbackStateText
                        : _formatSpeed(_downloadSpeedBps),
                    style: TextStyle(
                      color: _playbackStateText.isNotEmpty
                          ? const Color(0xFF9ca3af) // 文本状态灰
                          : const Color(0xFF60a5fa), // 速度蓝
                      fontSize: _playbackStateText.isNotEmpty ? 13 : 16,
                      fontWeight: _playbackStateText.isNotEmpty
                          ? FontWeight.w400
                          : FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              // 提示
              if (accelLevel != 'full')
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _buildAccelHint(accelLevel, cfWorkerOn, bestIpOn,
                      videoProxyOn, videoStreamViaProxy),
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('关闭',
                      style: TextStyle(color: Color(0xFF60a5fa))),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// v2.0.34: 加速等级徽章 (右上角小 chip)
  /// full = 绿色 ✅ 全加速 / half = 黄色 ⚠️ 半加速 / none = 灰色 ❌ 未加速
  Widget _buildAccelBadge(String level) {
    final config = switch (level) {
      'full' => (
        bg: const Color(0xFF064e3b),
        fg: const Color(0xFF10b981),
        text: '✅ 全加速',
      ),
      'half' => (
        bg: const Color(0xFF78350f),
        fg: const Color(0xFFfbbf24),
        text: '⚠️ 半加速',
      ),
      _ => (
        bg: const Color(0xFF374151),
        fg: const Color(0xFF9ca3af),
        text: '❌ 未加速',
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: config.bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        config.text,
        style: TextStyle(
          color: config.fg,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _accelLevelDescription(String level) {
    return switch (level) {
      'full' => '视频源经 CF Worker 域名重写, libmpv 强制走优选 IP 连 CF edge',
      'half' => '加速链路部分启用, 视频流可能未走优选 IP',
      _ => '加速链路未启用, 视频流直连原源',
    };
  }

  /// v2.0.34: 加速链路里的一个节点 (圆角卡片)
  ///
  /// enabled = true: 高亮 + 实色边框
  /// enabled = false: 灰色 + 暗淡 (说明该节点被跳过)
  Widget _buildLinkNode({
    required IconData icon,
    required String label,
    required String value,
    required bool enabled,
    required Color accent,
    String? subtitle,
  }) {
    final color = enabled ? accent : const Color(0xFF6b7280);
    final borderColor =
        enabled ? accent.withOpacity(0.6) : const Color(0xFF374151);
    final valueColor =
        enabled ? Colors.white : Colors.white.withOpacity(0.4);
    final labelColor =
        enabled ? Colors.white.withOpacity(0.85) : Colors.white.withOpacity(0.4);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 1.2),
      ),
      child: InkWell(
        onTap: value.isNotEmpty && value != '（无）' && value != '本机 libmpv'
            ? () => _copyToClipboard(value, label)
            : null,
        borderRadius: BorderRadius.circular(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 左侧图标圆
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 10),
            // 右侧文字
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: labelColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const Spacer(),
                      if (enabled && subtitle != null)
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: accent.withOpacity(0.85),
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: TextStyle(
                      color: valueColor,
                      fontSize: 12,
                      fontFamily: 'monospace',
                      fontFamilyFallback: const ['Courier', 'monospace'],
                      height: 1.3,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // 复制图标 (鼠标手势)
            if (value.isNotEmpty && value != '（无）' && value != '本机 libmpv')
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 6),
                child: Icon(
                  Icons.content_copy,
                  color: Colors.white.withOpacity(0.3),
                  size: 14,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// v2.0.34: 节点之间的箭头 (竖向)
  ///
  /// enabled = true: 实线 + 高亮色
  /// enabled = false: 虚线 + 灰色 (表示该段链路被跳过)
  Widget _buildLinkArrow({required bool enabled}) {
    final color =
        enabled ? const Color(0xFF10b981) : const Color(0xFF4b5563);
    return Container(
      width: 2,
      height: 18,
      margin: const EdgeInsets.only(left: 28),
      decoration: BoxDecoration(
        color: color.withOpacity(enabled ? 0.8 : 0.4),
        borderRadius: BorderRadius.circular(1),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (enabled)
            Positioned(
              bottom: -2,
              child: Icon(
                Icons.arrow_drop_down,
                color: color,
                size: 12,
              ),
            ),
        ],
      ),
    );
  }

  /// v2.0.34: 加速等级非 full 时的提示
  Widget _buildAccelHint(String level, bool cfWorkerOn, bool bestIpOn,
      bool videoProxyOn, bool videoStreamViaProxy) {
    if (level == 'none') {
      return Text(
        '在 设置 → CF Worker 加速 里打开 视频代理 + 填域名 + 优选 IP',
        style: TextStyle(
          color: Colors.white.withOpacity(0.55),
          fontSize: 11,
          height: 1.4,
        ),
      );
    }
    // half
    if (cfWorkerOn && bestIpOn && !videoStreamViaProxy) {
      // 配齐了但视频流没走代理
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CF Worker + 优选 IP 都配了, 但视频流没走代理.',
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 11,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            videoProxyOn
                ? '「视频代理」开关开了, 但 tryStart 失败, 查 logcat [VideoProxy] 看原因.'
                : '去 设置 → CF Worker 加速 → 视频代理 打开开关.',
            style: TextStyle(
              color: const Color(0xFFfbbf24).withOpacity(0.9),
              fontSize: 11,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
        ],
      );
    }
    return Text(
      '配置不完整, 见上方节点 (灰色 = 跳过).',
      style: TextStyle(
        color: Colors.white.withOpacity(0.55),
        fontSize: 11,
      ),
    );
  }

  /// v2.0.34: 复制到剪贴板 + 短 SnackBar 提示
  void _copyToClipboard(String text, String label) {
    // 把多行值扁平化 (节点值可能含 \n)
    final flat = text.replaceAll('\n', ' ').trim();
    Clipboard.setData(ClipboardData(text: flat));
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label 已复制'),
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// v2.0.34: 把 URL 截短显示 (去 query, 防太长撑爆卡片)
  String _stripUrlQuery(String url) {
    final qIdx = url.indexOf('?');
    if (qIdx < 0) return url;
    final stripped = url.substring(0, qIdx);
    return '$stripped?...';
  }

  /// v2.0.34: IPv4 严格校验 (比 _isIpv4 更严, 防 cf.877774.xyz 走错分支)
  static bool _isIpv4Strict(String s) {
    final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
        .firstMatch(s);
    if (m == null) return false;
    for (var i = 1; i <= 4; i++) {
      final n = int.parse(m.group(i)!);
      if (n < 0 || n > 255) return false;
    }
    return true;
  }

  /// v2.0.34: 格式化下载速度 (Bytes/s → 人类可读)

  /// < 1 KB/s → "0 B/s" (避免跳 0 误差)
  /// 1-1024 B/s → "512 B/s"
  /// 1-1024 KB/s → "256 KB/s"
  /// >= 1 MB/s → "1.2 MB/s"
  static String _formatSpeed(double bps) {
    if (bps < 1) return '0 B/s';
    if (bps < 1024) return '${bps.toStringAsFixed(0)} B/s';
    if (bps < 1024 * 1024) {
      return '${(bps / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bps / 1024 / 1024).toStringAsFixed(2)} MB/s';
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
                          // v2.0.33: 手动「下一集」按钮 — 跟自动播下一集用同一播放逻辑
                          // 只在「还有下一集」时显示, 最后一集隐藏
                          if (_selectedSource != null &&
                              _currentEpisodeIndex <
                                  _selectedSource!.episodes.length - 1)
                            _iconBtn(
                              icon: Icons.skip_next,
                              iconColor: const Color(0xFF10b981),
                              onTap: _playNextEpisode,
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
        // v1.0.58: 恢复跳过片头/片尾浮层按钮 (手动模式)
        // 之前 v1.0.57 强制自动跳删了按钮, v1.0.58 加了自动/手动开关,
        // 手动模式 (默认) 仍需要按钮让用户点
        // 自动模式 _showSkipIntro/_showSkipOutro=false, 按钮不显示
        if (_showSkipIntro && _isControlsVisible)
          Positioned(
            right: 16,
            bottom: 100,
            child: _skipButton('跳过片头', kLunaTheme, _skipIntro),
          ),
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

  /// 跳过片头/片尾的浮层按钮 (手动模式用)
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

/// 快进/快退 6s 按钮的文字标签 (替代原先的自绘圆弧箭头, 视觉更直接)
class _SeekLabel extends StatelessWidget {
  final String label;
  const _SeekLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
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

/// v2.0.51: 空 PageController placeholder (initState 之前给 notifier 占位用)
class _EmptyPageController extends PageController {
  _EmptyPageController._() : super();
  static final _EmptyPageController instance = _EmptyPageController._();
}
