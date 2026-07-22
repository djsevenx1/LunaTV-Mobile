// v2.2.0: ExoPlayer (AndroidX Media3) 版本的 [PlayerBackend] 实现.
//
//   走 Flutter 官方 [video_player] package, Android 端底层就是
//   androidx.media3 ExoPlayer 1.4.x (跟 build.gradle.kts 显式列的
//   media3-exoplayer 1.4.1 是同一份, video_player transitive 依赖).
//   iOS 端走 AVPlayer.
//
//   v2.3.11 ~ v2.3.13 卸了 video_player 改自研 [CustomExoPlayer]
//   (CustomExoPlayerChannel.kt + custom_exo_player.dart), 走自配
//   DefaultLoadControl (min=30s / max=90s). 用户反馈 "卡顿时
//   buffer 时间短, 频繁 rebuffer" 是这个根因.
//
//   v2.3.14: 卸自研 CustomExoPlayer, 回到 video_player Flutter package.
//   - 走 video_player 2.10.1 内部 ExoPlayer (1.4.x), DefaultLoadControl
//     用 video_player 默认值 (min=15s / max=50s / bufferForPlaybackMs=2.5s
//     / bufferForPlaybackAfterRebufferMs=5s).
//   - 视频输出走 video_player 的 [VideoPlayer] widget, 渲染逻辑跟 v2.3.0
//     一致, 详见 [exo_player_view.dart].
//   - 状态同步走 video_player [VideoPlayerController] 内部 listener
//     (VideoPlayerValue 推送 isPlaying / position / duration / size).
//
//   v2.3.0 视频加速 (VideoProxyServer / CfOptimizer) 整个删了, 跟现在无关.

import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:video_player/video_player.dart';

import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/player_backend.dart';

class ExoPlayerBackend implements PlayerBackend {
  // ── 内部 state ──────────────────────────────────────
  VideoPlayerController? _controller;
  // v2.3.15: video_player 2.10.1 的 addListener() 返回 void (没有
  //   StreamSubscription), 这里改成存 VoidCallback 自身, dispose 时
  //   调 removeListener. 之前 v2.3.0 用 StreamSubscription 包装是
  //   误用 API, 编译会报 "This expression has type 'void' and can't be used".
  VoidCallback? _valueListener;
  // 保留旧字段以兼容 (v2.3.14 的代码, 现在置空, dispose 兜底)

  // ── 缓存的状态 ────────────────────────────────────────
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isCompleted = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1.0;
  double _speed = 1.0;
  int _width = 0;
  int _height = 0;

  // ── 流控制器 (broadcast 多订阅) ────────────────────────
  final _playingCtl = StreamController<bool>.broadcast();
  final _bufferingCtl = StreamController<bool>.broadcast();
  final _completedCtl = StreamController<bool>.broadcast();
  final _positionCtl = StreamController<Duration>.broadcast();
  final _durationCtl = StreamController<Duration>.broadcast();
  final _bandwidthCtl = StreamController<BandwidthSample>.broadcast();

  // ── 内部辅助 ────────────────────────────────────────
  bool _disposed = false;
  // v2.5.24: Generation guard — prevents the "dual audio" bug.
  //   open() is re-entrant (fire-and-forget _playEpisode callers,
  //   DLNA stop-cast + episode tap overlap, etc). Without this,
  //   two concurrent open() calls each create a VideoPlayerController,
  //   one becomes an orphan that keeps playing audio but can never be
  //   paused/disposed (pause/stop/dispose only touch _controller).
  //   Each open() increments this counter; after initialize() completes,
  //   the loser checks gen != _openGeneration and disposes its controller.
  int _openGeneration = 0;

  ExoPlayerBackend();

  /// 工厂 — 创建空 backend, [open] 时再实际初始化 VideoPlayerController.
  ///  v2.3.0 行为: 不在工厂里就创建 controller, 因为 [open] 可能要
  ///  传不同 URL, 提前创建再 dispose 浪费资源. _PlayerScreenState
  ///  _initPlayerAsync 拿 backend 后调 [open] 才会实际建 controller.
  static Future<ExoPlayerBackend> create({
    Map<String, String>? defaultHeaders,
  }) async {
    final backend = ExoPlayerBackend();
    DiaryService.add(
        '[ExoPlayer] init OK: video_player=^2.10.1, headers=${defaultHeaders?.keys.join(",") ?? "none"}');
    return backend;
  }

  void _onValue(VideoPlayerValue v) {
    if (_disposed) return;
    final c = _controller;
    if (c == null) return;

    if (v.isPlaying != _isPlaying) {
      _isPlaying = v.isPlaying;
      _safeAdd(_playingCtl, v.isPlaying);
    }
    if (v.isBuffering != _isBuffering) {
      _isBuffering = v.isBuffering;
      _safeAdd(_bufferingCtl, v.isBuffering);
    }
    final dur = v.duration;
    if (dur > Duration.zero && dur != _duration) {
      _duration = dur;
      _safeAdd(_durationCtl, dur);
    }
    final pos = v.position;
    if (pos != _position) {
      _position = pos;
      _safeAdd(_positionCtl, pos);
    }
    if (v.size.width > 0 && v.size.height > 0 &&
        (v.size.width.round() != _width || v.size.height.round() != _height)) {
      _width = v.size.width.round();
      _height = v.size.height.round();
    }
    if (v.isCompleted != _isCompleted) {
      _isCompleted = v.isCompleted;
      _safeAdd(_completedCtl, v.isCompleted);
    }
  }

  // ── PlayerBackend 实现 ────────────────────────────────────
  @override
  bool get isPlaying => _isPlaying;
  @override
  bool get isBuffering => _isBuffering;
  @override
  bool get isCompleted => _isCompleted;
  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  double get volume => _volume;
  @override
  double get speed => _speed;
  @override
  int get width => _width;
  @override
  int get height => _height;

  @override
  Stream<bool> get playingStream => _playingCtl.stream;
  @override
  Stream<bool> get bufferingStream => _bufferingCtl.stream;
  @override
  Stream<Duration> get positionStream => _positionCtl.stream;
  @override
  Stream<Duration> get durationStream => _durationCtl.stream;
  @override
  Stream<bool> get completedStream => _completedCtl.stream;
  @override
  Stream<BandwidthSample> get bandwidthStream => _bandwidthCtl.stream;

  @override
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Duration? startAt,
  }) async {
    if (_disposed) {
      throw StateError('ExoPlayerBackend disposed');
    }
    if (url.isEmpty) {
      throw ArgumentError('url is empty');
    }
    _isCompleted = false;
    _safeAdd(_completedCtl, false);

    // v2.5.24: Generation guard. Each open() gets a unique generation
    //   number. After initialize() (multi-second network op), if a newer
    //   open() was called, we dispose our controller and bail — the newer
    //   one wins. This prevents orphan VideoPlayerControllers that produce
    //   "dual audio" (zombie audio that pause/stop/dispose can't reach).
    final myGen = ++_openGeneration;

    final c = VideoPlayerController.networkUrl(
      Uri.parse(url),
      // v2.3.15: video_player 2.10.1 的 httpHeaders 形参是
      //   Map<String, String> (非 nullable), open() 入参是
      //   Map<String, String>?. 用 ?? {} 兜底避免编译错
      //   "Map<String, String>? can't be assigned to Map<String, String>".
      httpHeaders: headers ?? const <String, String>{},
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await c.initialize();
    } catch (e) {
      DiaryService.add('[ExoPlayer] initialize($url) err: $e');
      try {
        await c.dispose();
      } catch (_) {}
      rethrow;
    }

    // Superseded by a newer open() or disposed during initialize → abandon.
    if (_disposed || myGen != _openGeneration) {
      try {
        await c.dispose();
      } catch (_) {}
      if (_disposed) {
        throw StateError('ExoPlayerBackend disposed during initialize');
      }
      DiaryService.add(
          '[ExoPlayer] open(gen=$myGen) superseded by gen=$_openGeneration, abandoning controller');
      return;
    }

    // We won the generation race. Dispose the old controller.
    // (Moved here from before create — old controller stays alive
    //  during initialize, which is fine: it's paused from stop() or
    //  still playing for DLNA resume, better UX than a black gap.)
    final old = _controller;
    if (old != null) {
      try {
        final listener = _valueListener;
        if (listener != null) {
          old.removeListener(listener);
        }
      } catch (_) {}
      _valueListener = null;
      try {
        await old.pause();
      } catch (_) {}
      try {
        await old.dispose();
      } catch (_) {}
    }

    // Re-check after dispose awaits — a newer open() may have
    // assigned its own controller during our old-dispose.
    if (myGen != _openGeneration) {
      try {
        await c.dispose();
      } catch (_) {}
      DiaryService.add(
          '[ExoPlayer] open(gen=$myGen) superseded during old-dispose, abandoning');
      return;
    }

    _controller = c;
    _width = c.value.size.width.round();
    _height = c.value.size.height.round();
    _duration = c.value.duration;
    _position = Duration.zero;
    _safeAdd(_durationCtl, _duration);
    _safeAdd(_positionCtl, _position);

    // 订阅 listener, 同步 isPlaying / isBuffering / position / size
    // v2.3.15: video_player 2.10.1 addListener 返回 void, 不能赋值给
    //   StreamSubscription. 存 VoidCallback 自身, dispose 时
    //   removeListener. 之前 v2.3.0/v2.3.14 写法编译就挂.
    _valueListener = () => _onValue(c.value);
    c.addListener(_valueListener!);

    if (startAt != null && startAt > Duration.zero) {
      try {
        await c.seekTo(startAt);
        _position = startAt;
        _safeAdd(_positionCtl, _position);
      } catch (e) {
        DiaryService.add('[ExoPlayer] initial seekTo($startAt) err: $e');
      }
    }

    try {
      await c.play();
    } catch (e) {
      DiaryService.add('[ExoPlayer] play err: $e');
    }
  }

  @override
  Future<void> play() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.play();
    } catch (_) {}
  }

  @override
  Future<void> pause() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.pause();
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.pause();
    } catch (_) {}
    try {
      await c.seekTo(Duration.zero);
    } catch (_) {}
    _isPlaying = false;
    _isBuffering = false;
    _isCompleted = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _safeAdd(_playingCtl, false);
    _safeAdd(_bufferingCtl, false);
    _safeAdd(_completedCtl, false);
    _safeAdd(_positionCtl, _position);
    _safeAdd(_durationCtl, _duration);
  }

  @override
  Future<void> seek(Duration position) async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.seekTo(position);
    } catch (e) {
      DiaryService.add('[ExoPlayer] seekTo($position) err: $e');
    }
    _position = position;
    _safeAdd(_positionCtl, position);
    if (_isCompleted) {
      _isCompleted = false;
      _safeAdd(_completedCtl, false);
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    final v = volume.clamp(0.0, 1.0);
    final c = _controller;
    if (c == null) {
      _volume = v;
      return;
    }
    try {
      await c.setVolume(v);
    } catch (_) {}
    _volume = v;
  }

  @override
  Future<void> setSpeed(double speed) async {
    final s = speed.clamp(0.25, 4.0);
    final c = _controller;
    if (c == null) {
      _speed = s;
      return;
    }
    try {
      await c.setPlaybackSpeed(s);
    } catch (e) {
      DiaryService.add('[ExoPlayer] setSpeed($s) err: $e');
    }
    _speed = s;
  }

  @override
  List<MediaTrackInfo> get audioTracks => const [];
  @override
  List<MediaTrackInfo> get subtitleTracks => const [];
  @override
  Future<void> selectAudioTrack(String id) async {}
  @override
  Future<void> selectSubtitleTrack(String id) async {}
  @override
  Future<void> setSubtitleTrackEnabled(bool enabled) async {}

  @override
  Future<void> dispose() async {
    _disposed = true;
    // v2.3.15: 用 removeListener 替代之前的 _valueSub?.cancel().
    //   addListener 返回 void, 不存 StreamSubscription, 改存
    //   VoidCallback 自身.
    final c = _controller;
    final listener = _valueListener;
    if (c != null && listener != null) {
      try {
        c.removeListener(listener);
      } catch (_) {}
    }
    _valueListener = null;
    if (c != null) {
      try {
        await c.pause();
      } catch (_) {}
      try {
        await c.dispose();
      } catch (_) {}
      _controller = null;
    }
    await _playingCtl.close();
    await _bufferingCtl.close();
    await _completedCtl.close();
    await _positionCtl.close();
    await _durationCtl.close();
    await _bandwidthCtl.close();
  }

  // ── 辅助 ──────────────────────────────────────────────
  /// 给 widget 层用, 拿到 VideoPlayerController 给 [VideoPlayer] widget.
  /// 没初始化完 (controller 还没 build) → null, widget 渲染黑屏兜底.
  VideoPlayerController? get controller => _controller;

  void _safeAdd<T>(StreamController<T> ctl, T value) {
    if (!ctl.isClosed) ctl.add(value);
  }
}
