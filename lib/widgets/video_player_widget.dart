import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:luna_tv/services/video_proxy_server.dart';
import 'package:luna_tv/services/mpv_ffi.dart';
import 'package:luna_tv/widgets/mobile_player_controls.dart';
import 'package:luna_tv/widgets/pc_player_controls.dart';
import 'package:luna_tv/widgets/video_player_surface.dart';

class VideoPlayerWidget extends StatefulWidget {
  final VideoPlayerSurface surface;
  final String? url;
  final Map<String, String>? headers;
  final VoidCallback? onBackPressed;
  final Function(VideoPlayerWidgetController)? onControllerCreated;
  final VoidCallback? onReady;
  final VoidCallback? onNextEpisode;
  final VoidCallback? onVideoCompleted;
  final VoidCallback? onPause;
  final bool isLastEpisode;
  final Function(dynamic)? onCastStarted;
  final String? videoTitle;
  final int? currentEpisodeIndex;
  final int? totalEpisodes;
  final String? sourceName;
  final Function(bool isWebFullscreen)? onWebFullscreenChanged;
  final VoidCallback? onExitFullScreen;
  final bool live;
  final Function(bool isPipMode)? onPipModeChanged;

  const VideoPlayerWidget({
    super.key,
    this.surface = VideoPlayerSurface.mobile,
    this.url,
    this.headers,
    this.onBackPressed,
    this.onControllerCreated,
    this.onReady,
    this.onNextEpisode,
    this.onVideoCompleted,
    this.onPause,
    this.isLastEpisode = false,
    this.onCastStarted,
    this.videoTitle,
    this.currentEpisodeIndex,
    this.totalEpisodes,
    this.sourceName,
    this.onWebFullscreenChanged,
    this.onExitFullScreen,
    this.live = false,
    this.onPipModeChanged,
  });

  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class VideoPlayerWidgetController {
  VideoPlayerWidgetController._(this._state);
  final _VideoPlayerWidgetState _state;

  Future<void> updateDataSource(
    String url, {
    Duration? startAt,
    Map<String, String>? headers,
  }) async {
    await _state._updateDataSource(
      url,
      startAt: startAt,
      headers: headers,
    );
  }

  Future<void> seekTo(Duration position) async {
    await _state._player?.seek(position);
  }

  Duration? get currentPosition => _state._player?.state.position;
  Duration? get duration => _state._player?.state.duration;
  bool get isPlaying => _state._player?.state.playing ?? false;

  Future<void> pause() async {
    await _state._player?.pause();
  }

  Future<void> play() async {
    await _state._player?.play();
  }

  void addProgressListener(VoidCallback listener) {
    _state._addProgressListener(listener);
  }

  void removeProgressListener(VoidCallback listener) {
    _state._removeProgressListener(listener);
  }

  Future<void> setSpeed(double speed) async {
    await _state._setPlaybackSpeed(speed);
  }

  double get playbackSpeed => _state._playbackSpeed.value;

  Future<void> setVolume(double volume) async {
    await _state._player?.setVolume(volume);
  }

  double? get volume => _state._player?.state.volume;

  void exitWebFullscreen() {
    _state._exitWebFullscreen();
  }

  Future<void> dispose() async {
    await _state._externalDispose();
  }

  bool get isPipMode => _state._isPipMode;
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> with WidgetsBindingObserver {
  Player? _player;
  VideoController? _videoController;
  bool _isInitialized = false;
  bool _hasCompleted = false;
  bool _isLoadingVideo = false;
  String? _currentUrl;
  Map<String, String>? _currentHeaders;
  // v2.0.16: 视频代理
  VideoProxyServer? _videoProxy;
  final List<VoidCallback> _progressListeners = [];
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  final ValueNotifier<double> _playbackSpeed = ValueNotifier<double>(1.0);
  bool _playerDisposed = false;
  VoidCallback? _exitWebFullscreenCallback;
  bool _isPipMode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentUrl = widget.url;
    _currentHeaders = widget.headers;
    _initializePlayer();
    widget.onControllerCreated?.call(VideoPlayerWidgetController._(this));
  }

  @override
  void didUpdateWidget(covariant VideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.headers != oldWidget.headers && widget.headers != null) {
      _currentHeaders = widget.headers;
    }
    if (widget.url != oldWidget.url && widget.url != null) {
      unawaited(_updateDataSource(widget.url!));
    }
  }

  Future<void> _initializePlayer() async {
    if (_playerDisposed) {
      return;
    }
    _player = Player();
    // v2.0.16: 启本地代理给 libmpv 走优选 IP (条件满足才启, 失败不阻塞)
    // v2.0.20: media_kit 1.2.6 Player 没 setProperty/command, 改用 dart:ffi
    final proxy = await VideoProxyServer.tryStart();
    if (proxy != null) {
      try {
        if (MpvFFI.isAvailable) {
          final handle = await _player!.handle;
          final rc = MpvFFI.setPropertyString(
              handle, 'http-proxy', proxy.proxyUrl);
          if (rc >= 0) {
            _videoProxy = proxy;
          } else {
            // ignore: avoid_print
            print('[VideoProxy] mpv_set_property_string 返 $rc, 停代理走原 URL');
            await proxy.stop();
          }
        } else {
          // ignore: avoid_print
          print('[VideoProxy] FFI libmpv 不可用: ${MpvFFI.loadError ?? "unknown"}');
          await proxy.stop();
        }
      } catch (e) {
        // ignore: avoid_print
        print('[VideoProxy] 设 http-proxy 异常: $e');
        await proxy.stop();
      }
    }
    _videoController = VideoController(_player!);
    _setupPlayerListeners();
    if (_currentUrl != null) {
      await _openCurrentMedia();
    }
    if (!mounted || _playerDisposed) return;
    setState(() {
      _isInitialized = true;
    });
  }

  Future<void> _openCurrentMedia({Duration? startAt}) async {
    if (_playerDisposed || _player == null || _currentUrl == null) {
      return;
    }
    setState(() {
      _isLoadingVideo = true;
    });
    try {
      await _player!.open(
        Media(
          _currentUrl!,
          start: startAt,
          httpHeaders: _currentHeaders ?? const <String, String>{},
        ),
        play: true,
      );
      if (!mounted || _playerDisposed || _player == null) return;
      await _player!.setRate(_playbackSpeed.value);
      if (!mounted || _playerDisposed) return;
      setState(() {
        _hasCompleted = false;
        // _isLoadingVideo = false;
      });
      // widget.onReady?.call();
    } catch (error) {
      debugPrint('VideoPlayerWidget: failed to open media $error');
      if (mounted) {
        setState(() {
          _isLoadingVideo = false;
        });
      }
    }
  }

  void _setupPlayerListeners() {
    if (_player == null) {
      return;
    }
    _positionSubscription?.cancel();
    _playingSubscription?.cancel();
    _completedSubscription?.cancel();
    _durationSubscription?.cancel();
    _positionSubscription = _player!.stream.position.listen((_) {
      for (final listener in List<VoidCallback>.from(_progressListeners)) {
        try {
          listener();
        } catch (error) {
          debugPrint('VideoPlayerWidget: progress listener error $error');
        }
      }
    });
    _playingSubscription = _player!.stream.playing.listen((playing) {
      if (!mounted) return;
      if (!playing) {
        setState(() {
          _hasCompleted = false;
        });
      } else {
        setState(() {
          _hasCompleted = false;
        });
      }
    });
    if (!widget.live) {
      _completedSubscription = _player!.stream.completed.listen((completed) {
        if (!mounted) return;
        if (completed && !_hasCompleted) {
          _hasCompleted = true;
          widget.onVideoCompleted?.call();
        }
      });
    }
    _durationSubscription = _player!.stream.duration.listen((duration) {
      if (!mounted) return;
      if (duration != Duration.zero) {
        if (_isLoadingVideo) {
          setState(() {
            _isLoadingVideo = false;
          });
        }
        widget.onReady?.call();
      }
    });
  }

  Future<void> _updateDataSource(
    String url, {
    Duration? startAt,
    Map<String, String>? headers,
  }) async {
    if (_playerDisposed) {
      return;
    }
    _currentUrl = url;
    if (headers != null) {
      _currentHeaders = headers;
    }
    if (_player == null) {
      await _initializePlayer();
      return;
    }
    setState(() {
      _isLoadingVideo = true;
    });
    try {
      final currentSpeed = _player!.state.rate;
      await _player!.open(
        Media(
          url,
          start: startAt,
          httpHeaders: _currentHeaders ?? const <String, String>{},
        ),
        play: true,
      );
      _playbackSpeed.value = currentSpeed;
      await _player!.setRate(currentSpeed);
      if (mounted) {
        setState(() {
          _hasCompleted = false;
          // _isLoadingVideo = false;
        });
      }
      // widget.onReady?.call();
    } catch (error) {
      debugPrint('VideoPlayerWidget: error while changing source $error');
      if (mounted) {
        setState(() {
          _isLoadingVideo = false;
        });
      }
    }
  }

  void _addProgressListener(VoidCallback listener) {
    if (!_progressListeners.contains(listener)) {
      _progressListeners.add(listener);
    }
  }

  void _removeProgressListener(VoidCallback listener) {
    _progressListeners.remove(listener);
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    _playbackSpeed.value = speed;
    await _player?.setRate(speed);
  }

  void _exitWebFullscreen() {
    _exitWebFullscreenCallback?.call();
  }

  Future<void> _enterPipMode() async {
    debugPrint('_enterPipMode');
    // 当前 build 环境 `pip` 包 API 不兼容，先保持空壳，避免编译失败
  }

  Future<void> _externalDispose() async {
    if (!mounted || _playerDisposed) {
      return;
    }
    await _disposePlayer();
  }

  Future<void> _disposePlayer() async {
    if (_playerDisposed) {
      return;
    }
    _playerDisposed = true;
    _positionSubscription?.cancel();
    _playingSubscription?.cancel();
    _completedSubscription?.cancel();
    _durationSubscription?.cancel();
    _progressListeners.clear();
    // v2.0.16: 关本地视频代理
    unawaited(_videoProxy?.stop());
    _videoProxy = null;
    await _player?.dispose();
    _player = null;
    _videoController = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (_player == null) {
      return;
    }
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
      case AppLifecycleState.resumed:
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposePlayer();
    _playbackSpeed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: _isInitialized && _videoController != null
          ? Video(
              controller: _videoController!,
              controls: (state) {
                return widget.surface == VideoPlayerSurface.desktop
                    ? PCPlayerControls(
                        state: state,
                        player: _player!,
                        onBackPressed: widget.onBackPressed,
                        onNextEpisode: widget.onNextEpisode,
                        onPause: widget.onPause,
                        videoUrl: _currentUrl ?? '',
                        isLastEpisode: widget.isLastEpisode,
                        isLoadingVideo: _isLoadingVideo,
                        onCastStarted: widget.onCastStarted,
                        videoTitle: widget.videoTitle,
                        currentEpisodeIndex: widget.currentEpisodeIndex,
                        totalEpisodes: widget.totalEpisodes,
                        sourceName: widget.sourceName,
                        onWebFullscreenChanged: widget.onWebFullscreenChanged,
                        onExitWebFullscreenCallbackReady: (callback) {
                          _exitWebFullscreenCallback = callback;
                        },
                        onExitFullScreen: widget.onExitFullScreen,
                        live: widget.live,
                        playbackSpeedListenable: _playbackSpeed,
                        onSetSpeed: _setPlaybackSpeed,
                      )
                    : MobilePlayerControls(
                        player: _player!,
                        state: state,
                        onControlsVisibilityChanged: (_) {},
                        onBackPressed: widget.onBackPressed,
                        onFullscreenChange: (_) {},
                        onNextEpisode: widget.onNextEpisode,
                        onPause: widget.onPause,
                        videoUrl: _currentUrl ?? '',
                        isLastEpisode: widget.isLastEpisode,
                        isLoadingVideo: _isLoadingVideo,
                        onCastStarted: widget.onCastStarted,
                        videoTitle: widget.videoTitle,
                        currentEpisodeIndex: widget.currentEpisodeIndex,
                        totalEpisodes: widget.totalEpisodes,
                        sourceName: widget.sourceName,
                        onExitFullScreen: widget.onExitFullScreen,
                        live: widget.live,
                        playbackSpeedListenable: _playbackSpeed,
                        onSetSpeed: _setPlaybackSpeed,
                        onEnterPipMode: _enterPipMode,
                        isPipMode: _isPipMode,
                      );
              },
            )
          : const Center(
              child: CircularProgressIndicator(
                color: Colors.white,
              ),
            ),
    );
  }
}
