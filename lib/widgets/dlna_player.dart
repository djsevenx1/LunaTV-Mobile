import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dlna_dart/dlna.dart';
import 'package:dlna_dart/xmlParser.dart';
import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/widgets/dlna_player_controls.dart';

/// DLNAPlayer 的控制器，用于外部控制播放器
class DLNAPlayerController {
  final _DLNAPlayerState _state;

  DLNAPlayerController._(this._state);

  /// 更新视频 URL
  void updateVideoUrl(String url, String title, {Duration? startAt}) {
    startAt ??= const Duration();
    _state.updateVideoUrl(url, title, startAt: startAt);
  }

  /// 获取当前播放位置
  Duration get currentPosition => _state._position;
}

class DLNAPlayer extends StatefulWidget {
  final DLNADevice device;
  final VoidCallback? onBackPressed;
  final VoidCallback? onNextEpisode;
  final bool isLastEpisode;
  final VoidCallback? onChangeDevice;
  final Duration? resumePosition;
  final Function(Duration)? onStopCasting;
  final Function(Duration position, Duration duration)? onProgressUpdate;
  final VoidCallback? onPause;
  final VoidCallback? onReady;
  final Function(DLNAPlayerController)? onControllerCreated;
  final VoidCallback? onVideoCompleted;

  const DLNAPlayer({
    super.key,
    required this.device,
    this.onBackPressed,
    this.onNextEpisode,
    this.isLastEpisode = false,
    this.onChangeDevice,
    this.resumePosition,
    this.onStopCasting,
    this.onProgressUpdate,
    this.onPause,
    this.onReady,
    this.onControllerCreated,
    this.onVideoCompleted,
  });

  @override
  State<DLNAPlayer> createState() => _DLNAPlayerState();
}

class _DLNAPlayerState extends State<DLNAPlayer> {
  Timer? _statusTimer;
  PositionParser? position;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _isLoading = true;
  Duration _resumePosition = Duration.zero;

  Future<void> _runDlnaCommand(FutureOr<dynamic> Function() command) async {
    final result = command();
    if (result is Future) {
      await result.timeout(const Duration(seconds: 8));
    }
  }

  @override
  void initState() {
    super.initState();
    _resumePosition = widget.resumePosition ?? Duration.zero;
    _setPortraitOrientation();
    _startStatusPolling();
    widget.onControllerCreated?.call(DLNAPlayerController._(this));
  }

  void _setPortraitOrientation() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  void _restoreOrientation() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  void _startStatusPolling() {
    _statusTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
      _updateStatus();
    });
  }

  Future<void> _updateStatus() async {
    if (!mounted) return;

    try {
      // 获取播放位置
      final positionStr = await widget.device.position();
      if (!mounted) return;
      final p = PositionParser(positionStr);

      position = p;
      final newPosition = Duration(seconds: position?.RelTimeInt ?? 0);
      final newDuration = Duration(seconds: position?.TrackDurationInt ?? 0);

      final transportStr = await widget.device.getTransportInfo();
      if (!mounted) return;
      final t = TransportInfoParser(transportStr);

      _isPlaying = t.CurrentTransportState == "PLAYING";

      // 检查进度是否发生变化
      final positionChanged = newPosition != _position;
      final durationChanged = newDuration != _duration;

      _position = newPosition;
      _duration = newDuration;

      // 如果获取到有效的 duration，则不再是加载状态
      if (_duration.inMilliseconds > 0) {
        if (_isPlaying && _isLoading) {
          _isLoading = false;
          widget.onReady?.call();
          // 不再是加载状态时，检查 resumePosition，如果不为 0 则跳转并清空
          if (_resumePosition.inSeconds > 0) {
            debugPrint('DLNA加载完成，跳转到恢复位置: ${_resumePosition.inSeconds}秒');
            _seekTo(_resumePosition);
            _resumePosition = Duration.zero; // 清空 resumePosition
          }
        }

        // 如果进度发生变化，通知父组件
        if (!_isLoading && (positionChanged || durationChanged)) {
          widget.onProgressUpdate?.call(_position, _duration);
        }

        // 检查视频是否播放完成（当前位置 >= 总时长 - 1秒）
        if (!_isLoading &&
            _duration.inSeconds > 0 &&
            _position.inSeconds >= _duration.inSeconds - 1 &&
            _isPlaying) {
          debugPrint('DLNA视频播放完成');
          final dynamic dlnaDevice = widget.device;
          await _runDlnaCommand(() {
            return dlnaDevice.pause();
          });
          widget.onVideoCompleted?.call();
        }
      }

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('获取DLNA状态失败: $e');
    }
  }

  Future<void> _togglePlayPause() async {
    try {
      final dynamic dlnaDevice = widget.device;
      if (_isPlaying) {
        await _runDlnaCommand(() {
          return dlnaDevice.pause();
        });
        _isPlaying = false;
        // 暂停时保存进度
        widget.onPause?.call();
      } else {
        await _runDlnaCommand(() {
          return dlnaDevice.play();
        });
        _isPlaying = true;
      }
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      DiaryService.add('[DLNA] toggle play/pause failed: $e');
    }
  }

  void _stop() {
    // 通知父组件停止投屏，并传递当前播放位置
    widget.onStopCasting?.call(_position);
  }

  Future<void> _seekTo(Duration position) async {
    final hours = position.inHours;
    final minutes = position.inMinutes.remainder(60);
    final seconds = position.inSeconds.remainder(60);
    final timeStr =
        '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    try {
      final dynamic dlnaDevice = widget.device;
      await _runDlnaCommand(() {
        return dlnaDevice.seek(timeStr);
      });
    } catch (e) {
      DiaryService.add('[DLNA] seek failed: position=$timeStr, err=$e');
    }
  }

  Future<void> _setVolume(double volume) async {
    final volumeInt = (volume * 100).round();
    try {
      final dynamic dlnaDevice = widget.device;
      await _runDlnaCommand(() {
        return dlnaDevice.volume(volumeInt);
      });
    } catch (e) {
      DiaryService.add('[DLNA] volume failed: volume=$volumeInt, err=$e');
    }
  }

  /// 更新视频 URL
  Future<void> updateVideoUrl(String url, String title, {Duration? startAt}) async {
    if (!mounted) return;

    debugPrint('DLNA 更新视频 URL: $url, startAt: ${startAt?.inSeconds ?? 0}秒');

    try {
      final dynamic dlnaDevice = widget.device;
      await _runDlnaCommand(() {
        return dlnaDevice.pause();
      });
    } catch (e) {
      DiaryService.add('[DLNA] pause before update url failed: $e');
    }
    _isPlaying = false;

    // 关闭状态轮询
    _statusTimer?.cancel();

    setState(() {
      _isLoading = true;
      _resumePosition = startAt ?? Duration.zero;
    });

    try {
      final dynamic dlnaDevice = widget.device;
      // 设置新的 URL 并开始播放.
      await _runDlnaCommand(() {
        return dlnaDevice.setUrl(url, title: title);
      });
      await _runDlnaCommand(() {
        return dlnaDevice.play();
      });
      DiaryService.add('[DLNA] update url command sent: url=$url, title=$title');
      // 重新启动状态轮询
      _startStatusPolling();
    } catch (e) {
      DiaryService.add('[DLNA] update url failed: url=$url, err=$e');
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _restoreOrientation();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: DLNAPlayerControls(
        device: widget.device,
        position: _position,
        duration: _duration,
        isPlaying: _isPlaying,
        isLoading: _isLoading,
        onBackPressed: widget.onBackPressed,
        onNextEpisode: widget.onNextEpisode,
        isLastEpisode: widget.isLastEpisode,
        onPlayPause: () {
          _togglePlayPause();
        },
        onStop: _stop,
        onSeek: (position) {
          _seekTo(position);
        },
        onVolumeChange: (volume) {
          _setVolume(volume);
        },
        onChangeDevice: widget.onChangeDevice,
      ),
    );
  }
}
