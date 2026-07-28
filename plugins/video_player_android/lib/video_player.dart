// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as platform_interface;

export 'package:video_player_platform_interface/video_player_platform_interface.dart'
    show
        DataSourceType,
        DurationRange,
        VideoFormat,
        VideoPlayerOptions,
        VideoViewType;

/// The duration, current position, buffering state, error state and settings
/// of a [VideoPlayerController].
@immutable
class VideoPlayerValue {
  const VideoPlayerValue({
    required this.duration,
    this.size = Size.zero,
    this.position = Duration.zero,
    this.buffered = const <platform_interface.DurationRange>[],
    this.isInitialized = false,
    this.isPlaying = false,
    this.isLooping = false,
    this.isBuffering = false,
    this.volume = 1.0,
    this.playbackSpeed = 1.0,
    this.rotationCorrection = 0,
    this.errorDescription,
    this.isCompleted = false,
    this.preventsDisplaySleepDuringVideoPlayback = true,
  });

  const VideoPlayerValue.uninitialized()
      : this(duration: Duration.zero, isInitialized: false);

  const VideoPlayerValue.erroneous(String errorDescription)
      : this(
            duration: Duration.zero,
            isInitialized: false,
            errorDescription: errorDescription);

  static const String _defaultErrorDescription = 'defaultErrorDescription';

  final Duration duration;
  final Duration position;
  final List<platform_interface.DurationRange> buffered;
  final bool isPlaying;
  final bool isLooping;
  final bool isBuffering;
  final double volume;
  final double playbackSpeed;
  final String? errorDescription;
  final bool isCompleted;
  final bool preventsDisplaySleepDuringVideoPlayback;
  final Size size;
  final int rotationCorrection;
  final bool isInitialized;

  bool get hasError => errorDescription != null;

  double get aspectRatio {
    if (!isInitialized || size.width == 0 || size.height == 0) {
      return 1.0;
    }
    final double aspectRatio = size.width / size.height;
    if (aspectRatio <= 0) {
      return 1.0;
    }
    return aspectRatio;
  }

  VideoPlayerValue copyWith({
    Duration? duration,
    Size? size,
    Duration? position,
    List<platform_interface.DurationRange>? buffered,
    bool? isInitialized,
    bool? isPlaying,
    bool? isLooping,
    bool? isBuffering,
    double? volume,
    double? playbackSpeed,
    int? rotationCorrection,
    String? errorDescription = _defaultErrorDescription,
    bool? isCompleted,
    bool? preventsDisplaySleepDuringVideoPlayback,
  }) {
    return VideoPlayerValue(
      duration: duration ?? this.duration,
      size: size ?? this.size,
      position: position ?? this.position,
      buffered: buffered ?? this.buffered,
      isInitialized: isInitialized ?? this.isInitialized,
      isPlaying: isPlaying ?? this.isPlaying,
      isLooping: isLooping ?? this.isLooping,
      isBuffering: isBuffering ?? this.isBuffering,
      volume: volume ?? this.volume,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      rotationCorrection: rotationCorrection ?? this.rotationCorrection,
      errorDescription: errorDescription != _defaultErrorDescription
          ? errorDescription
          : this.errorDescription,
      isCompleted: isCompleted ?? this.isCompleted,
      preventsDisplaySleepDuringVideoPlayback:
          preventsDisplaySleepDuringVideoPlayback ??
              this.preventsDisplaySleepDuringVideoPlayback,
    );
  }

  @override
  String toString() {
    return '${objectRuntimeType(this, 'VideoPlayerValue')}('
        'duration: $duration, '
        'size: $size, '
        'position: $position, '
        'buffered: [${buffered.join(', ')}], '
        'isInitialized: $isInitialized, '
        'isPlaying: $isPlaying, '
        'isLooping: $isLooping, '
        'isBuffering: $isBuffering, '
        'volume: $volume, '
        'playbackSpeed: $playbackSpeed, '
        'errorDescription: $errorDescription, '
        'isCompleted: $isCompleted, '
        'preventsDisplaySleepDuringVideoPlayback: $preventsDisplaySleepDuringVideoPlayback)';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoPlayerValue &&
          runtimeType == other.runtimeType &&
          duration == other.duration &&
          position == other.position &&
          listEquals(buffered, other.buffered) &&
          isPlaying == other.isPlaying &&
          isLooping == other.isLooping &&
          isBuffering == other.isBuffering &&
          volume == other.volume &&
          playbackSpeed == other.playbackSpeed &&
          errorDescription == other.errorDescription &&
          size == other.size &&
          rotationCorrection == other.rotationCorrection &&
          isInitialized == other.isInitialized &&
          isCompleted == other.isCompleted &&
          preventsDisplaySleepDuringVideoPlayback ==
              other.preventsDisplaySleepDuringVideoPlayback;

  @override
  int get hashCode => Object.hash(
        duration,
        position,
        buffered,
        isPlaying,
        isLooping,
        isBuffering,
        volume,
        playbackSpeed,
        errorDescription,
        size,
        rotationCorrection,
        isInitialized,
        isCompleted,
        preventsDisplaySleepDuringVideoPlayback,
      );
}

platform_interface.VideoPlayerPlatform? _lastVideoPlayerPlatform;

platform_interface.VideoPlayerPlatform get _videoPlayerPlatform {
  final platform_interface.VideoPlayerPlatform currentInstance =
      platform_interface.VideoPlayerPlatform.instance;
  if (_lastVideoPlayerPlatform != currentInstance) {
    currentInstance.init();
    _lastVideoPlayerPlatform = currentInstance;
  }
  return currentInstance;
}

/// Controls a platform video player, and provides updates when the state is
/// changing.
///
/// Instances must be initialized with [initialize].
///
/// The video is displayed in a Flutter app by creating a [VideoPlayer] widget.
///
/// To reclaim the resources used by the player, call [dispose].
///
/// After [dispose] all further calls are ignored.
class VideoPlayerController extends ValueNotifier<VideoPlayerValue> {
  /// Constructs a [VideoPlayerController] playing a network video.
  VideoPlayerController.networkUrl(
    Uri url, {
    this.formatHint,
    this.videoPlayerOptions,
    this.httpHeaders = const <String, String>{},
    this.viewType = platform_interface.VideoViewType.textureView,
  })  : dataSource = url.toString(),
        dataSourceType = platform_interface.DataSourceType.network,
        super(VideoPlayerValue(
          duration: Duration.zero,
          preventsDisplaySleepDuringVideoPlayback:
              videoPlayerOptions?.preventsDisplaySleepDuringVideoPlayback ?? true,
        ));

  final String dataSource;
  final platform_interface.DataSourceType dataSourceType;
  final platform_interface.VideoFormat? formatHint;
  final Map<String, String> httpHeaders;
  final platform_interface.VideoPlayerOptions? videoPlayerOptions;
  final platform_interface.VideoViewType viewType;

  int? _playerId;
  StreamSubscription<platform_interface.VideoEvent>? _eventSubscription;
  bool _isDisposed = false;
  Completer<void>? _creatingCompleter;
  Completer<void>? _initializingCompleter;

  /// The id of a video player.
  int? get playerId => _playerId;

  /// This is just exposed for testing. It shouldn't be used by anyone depending
  /// on the plugin.
  @visibleForTesting
  platform_interface.VideoPlayerPlatform get platform => _videoPlayerPlatform;

  Future<void> _create() async {
    _creatingCompleter = Completer<void>();
    final Map<String, String> httpHeaders = this.httpHeaders;
    _playerId = await _videoPlayerPlatform.createWithOptions(
      platform_interface.VideoCreationOptions(
        dataSource: platform_interface.DataSource(
          sourceType: dataSourceType,
          uri: dataSource,
          formatHint: formatHint,
          httpHeaders: httpHeaders,
        ),
        viewType: viewType,
        videoPlayerOptions: videoPlayerOptions,
      ),
    );
    _creatingCompleter!.complete();

    if (videoPlayerOptions?.mixWithOthers ?? false) {
      await _videoPlayerPlatform.setMixWithOthers(true);
    }
  }

  /// Initializes the video player.
  Future<void> initialize() async {
    if (_isDisposed) {
      return;
    }
    await _create();
    _eventSubscription =
        _videoPlayerPlatform.videoEventsFor(_playerId!).listen(_videoEventListener);
    _initializingCompleter = Completer<void>();
    await _initializingCompleter!.future;
  }

  /// Starts playing the video.
  Future<void> play() async {
    if (_isDisposed || _playerId == null) {
      return;
    }
    await _videoPlayerPlatform.play(_playerId!);
  }

  /// Pauses the video.
  Future<void> pause() async {
    if (_isDisposed || _playerId == null) {
      return;
    }
    await _videoPlayerPlatform.pause(_playerId!);
  }

  /// Sets the video position to [position].
  Future<void> seekTo(Duration position) async {
    if (_isDisposed || _playerId == null) {
      return;
    }
    value = value.copyWith(position: position);
    await _videoPlayerPlatform.seekTo(_playerId!, position);
  }

  /// Sets the volume to [volume], which should be between 0.0 and 1.0.
  Future<void> setVolume(double volume) async {
    if (_isDisposed || _playerId == null) {
      return;
    }
    value = value.copyWith(volume: volume.clamp(0.0, 1.0));
    await _videoPlayerPlatform.setVolume(_playerId!, volume);
  }

  /// Sets the playback speed to [speed].
  Future<void> setPlaybackSpeed(double speed) async {
    if (_isDisposed || _playerId == null) {
      return;
    }
    value = value.copyWith(playbackSpeed: speed);
    await _videoPlayerPlatform.setPlaybackSpeed(_playerId!, speed);
  }

  /// Sets the looping attribute of the video.
  Future<void> setLooping(bool looping) async {
    if (_isDisposed || _playerId == null) {
      return;
    }
    value = value.copyWith(isLooping: looping);
    await _videoPlayerPlatform.setLooping(_playerId!, looping);
  }

  /// Disposes the video player.
  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    await _eventSubscription?.cancel();
    if (_playerId != null) {
      await _videoPlayerPlatform.dispose(_playerId!);
    }
    _isDisposed = true;
    super.dispose();
  }

  /// Returns the widget displaying the video.
  Widget buildView() {
    return _videoPlayerPlatform.buildViewWithOptions(
      platform_interface.VideoViewOptions(playerId: _playerId!),
    );
  }

  void _videoEventListener(platform_interface.VideoEvent event) {
    if (_isDisposed) {
      return;
    }
    switch (event.eventType) {
      case platform_interface.VideoEventType.initialized:
        value = value.copyWith(
          duration: event.duration,
          size: event.size,
          rotationCorrection: event.rotationCorrection,
          isInitialized: true,
        );
        _initializingCompleter?.complete();
        break;
      case platform_interface.VideoEventType.completed:
        value = value.copyWith(
          isCompleted: true,
          position: value.duration,
          isPlaying: false,
        );
        break;
      case platform_interface.VideoEventType.bufferingUpdate:
        value = value.copyWith(buffered: event.buffered);
        break;
      case platform_interface.VideoEventType.bufferingStart:
        value = value.copyWith(isBuffering: true);
        break;
      case platform_interface.VideoEventType.bufferingEnd:
        value = value.copyWith(isBuffering: false);
        break;
      case platform_interface.VideoEventType.isPlayingStateUpdate:
        value = value.copyWith(isPlaying: event.isPlaying ?? false);
        break;
      case platform_interface.VideoEventType.unknown:
        break;
    }
  }
}

/// Widget that displays the video controlled by [controller].
class VideoPlayer extends StatelessWidget {
  /// Uses the given [controller] to render the video.
  const VideoPlayer(this.controller, {super.key});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return controller.buildView();
  }
}
