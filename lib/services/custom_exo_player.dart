import 'package:flutter/services.dart';

/// v2.3.11: 自定义 ExoPlayer Dart 端 wrapper.
///
/// 跟原生 [CustomExoPlayerChannel.kt] (Kotlin) 对应. 这个 player 用
///   自定义 [DefaultLoadControl]:
///   - minBufferMs: 30s (video_player 默认 15s)
///   - maxBufferMs: 90s (video_player 默认 50s)
///   - bufferForPlaybackMs: 5s (video_player 默认 2.5s)
///   - bufferForPlaybackAfterRebufferMs: 8s (video_player 默认 5s)
///
/// 目的: 卡顿时 (isBuffering 反复 true/false) 给 ExoPlayer 更多时间
///   填 buffer, 减少 rebuffer 频率. 视频加速 (CF Worker 代理) 删了
///   之后, 源站 CDN 直连, 网络抖动比之前更明显, 大 buffer 有明显改善.
///
/// v2.3.10 单纯做 buffer prefetch 失败 (ExoPlayer 实例不共享 cache).
/// v2.3.11 真正替换 video_player — Channel 走 [FlutterEngine.renderer]
///   拿 [TextureRegistry.SurfaceTextureEntry], 把 ExoPlayer 的视频输出
///   接到 Flutter 端 [Texture] widget 渲染. video_player 整个包从
///   pubspec.yaml 移除, [VideoPlayerController] 不再被 [ExoPlayerBackend]
///   使用.
class CustomExoPlayer {
  CustomExoPlayer._();

  static const MethodChannel _methodChannel =
      MethodChannel('org.moontechlab.lunatv/custom_exo_player');

  static const EventChannel _eventChannel =
      EventChannel('org.moontechlab.lunatv/custom_exo_player_events');

  static Stream<Map<String, dynamic>>? _eventsStream;

  /// v2.3.10 默认 buffer 配置 (毫秒) — 跟 Kotlin 默认值同步.
  /// v2.3.11: 不能用 30_000 digit separator — Dart 3.8.1 还是实验特性,
  ///   编译需要 --enable-experiment=digit-separators, Flutter 3.32.5 不带.
  ///   改回普通数字 30000, Kotlin 那边的 const 不受影响.
  static const int defaultMinBufferMs = 30000;
  static const int defaultMaxBufferMs = 90000;
  static const int defaultBufferForPlaybackMs = 5000;
  static const int defaultBufferForPlaybackAfterRebufferMs = 8000;

  /// v2.3.11: 创建一个自定义 ExoPlayer 实例 + Flutter SurfaceTexture.
  ///
  /// - [minBufferMs] / [maxBufferMs] / [bufferForPlaybackMs] /
  ///   [bufferForPlaybackAfterRebufferMs]: DefaultLoadControl 参数, 跟
  ///   video_player 的 [DefaultLoadControl] 行为一致.
  /// - [withTexture]: 是否创建 Flutter SurfaceTexture 拿 video 输出.
  ///   视频播放必须 true. 隐藏 pre-buffer 可以 false (但 v2.3.10 那个
  ///   方案已经验证无效, 一般用不到 false 了).
  ///
  /// 返回 [CustomExoPlayerHandle] (playerId + textureId). 拿到 [textureId]
  ///   之后用 Flutter `Texture(textureId: ...)` widget 渲染视频.
  static Future<CustomExoPlayerHandle> create({
    int? minBufferMs,
    int? maxBufferMs,
    int? bufferForPlaybackMs,
    int? bufferForPlaybackAfterRebufferMs,
    bool withTexture = true,
  }) async {
    final result = await _methodChannel.invokeMapMethod<String, dynamic>(
      'create',
      <String, dynamic>{
        if (minBufferMs != null) 'minBufferMs': minBufferMs,
        if (maxBufferMs != null) 'maxBufferMs': maxBufferMs,
        if (bufferForPlaybackMs != null) 'bufferForPlaybackMs': bufferForPlaybackMs,
        if (bufferForPlaybackAfterRebufferMs != null)
          'bufferForPlaybackAfterRebufferMs': bufferForPlaybackAfterRebufferMs,
        'withTexture': withTexture,
      },
    );
    if (result == null) {
      throw StateError('CustomExoPlayer.create returned null');
    }
    return CustomExoPlayerHandle._fromMap(result);
  }

  static Future<void> setMediaItem(int playerId, String url) async {
    await _methodChannel.invokeMethod('setMediaItem', <String, dynamic>{
      'playerId': playerId,
      'url': url,
    });
  }

  static Future<void> prepare(int playerId) async {
    await _methodChannel.invokeMethod('prepare', <String, dynamic>{
      'playerId': playerId,
    });
  }

  static Future<void> play(int playerId) async {
    await _methodChannel.invokeMethod('play', <String, dynamic>{
      'playerId': playerId,
    });
  }

  static Future<void> pause(int playerId) async {
    await _methodChannel.invokeMethod('pause', <String, dynamic>{
      'playerId': playerId,
    });
  }

  static Future<void> stop(int playerId) async {
    await _methodChannel.invokeMethod('stop', <String, dynamic>{
      'playerId': playerId,
    });
  }

  static Future<void> seekTo(int playerId, int positionMs) async {
    await _methodChannel.invokeMethod('seekTo', <String, dynamic>{
      'playerId': playerId,
      'positionMs': positionMs,
    });
  }

  static Future<void> setVolume(int playerId, double volume) async {
    await _methodChannel.invokeMethod('setVolume', <String, dynamic>{
      'playerId': playerId,
      'volume': volume,
    });
  }

  static Future<void> setSpeed(int playerId, double speed) async {
    await _methodChannel.invokeMethod('setSpeed', <String, dynamic>{
      'playerId': playerId,
      'speed': speed,
    });
  }

  static Future<CustomExoPlayerState?> getState(int playerId) async {
    try {
      final result = await _methodChannel.invokeMapMethod<String, dynamic>(
        'getState',
        <String, dynamic>{'playerId': playerId},
      );
      if (result == null) return null;
      return CustomExoPlayerState._fromMap(result);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> release(int playerId) async {
    try {
      await _methodChannel.invokeMethod('release', <String, dynamic>{
        'playerId': playerId,
      });
    } on PlatformException catch (_) {}
    on MissingPluginException catch (_) {}
  }

  static Future<void> releaseAll() async {
    try {
      await _methodChannel.invokeMethod('releaseAll');
    } on PlatformException catch (_) {}
    on MissingPluginException catch (_) {}
  }

  /// v2.3.10: 监听所有 player 的状态变化 (broadcast stream).
  /// 状态 map 包含 playerId, isPlaying, isBuffering, durationMs,
  ///   positionMs, playbackState, videoWidth, videoHeight.
  static Stream<Map<String, dynamic>> get events {
    _eventsStream ??= _eventChannel
        .receiveBroadcastStream()
        .map<Map<String, dynamic>>((event) {
      if (event is Map) {
        return event.map((k, v) => MapEntry(k.toString(), v));
      }
      return <String, dynamic>{};
    });
    return _eventsStream!;
  }
}

/// v2.3.11: [CustomExoPlayer.create] 返回的句柄.
///
/// - [playerId] 用于后续操作 (setMediaItem/play/pause/seek/release).
/// - [textureId] 用于 `Texture(textureId: ...)` widget 渲染视频输出.
class CustomExoPlayerHandle {
  final int playerId;
  final int? textureId;
  final int minBufferMs;
  final int maxBufferMs;
  final int bufferForPlaybackMs;
  final int bufferForPlaybackAfterRebufferMs;

  const CustomExoPlayerHandle({
    required this.playerId,
    required this.textureId,
    required this.minBufferMs,
    required this.maxBufferMs,
    required this.bufferForPlaybackMs,
    required this.bufferForPlaybackAfterRebufferMs,
  });

  factory CustomExoPlayerHandle._fromMap(Map m) {
    return CustomExoPlayerHandle(
      playerId: (m['playerId'] as num).toInt(),
      textureId: (m['textureId'] as num?)?.toInt(),
      minBufferMs: (m['minBufferMs'] as num?)?.toInt() ?? CustomExoPlayer.defaultMinBufferMs,
      maxBufferMs: (m['maxBufferMs'] as num?)?.toInt() ?? CustomExoPlayer.defaultMaxBufferMs,
      bufferForPlaybackMs: (m['bufferForPlaybackMs'] as num?)?.toInt() ??
          CustomExoPlayer.defaultBufferForPlaybackMs,
      bufferForPlaybackAfterRebufferMs:
          (m['bufferForPlaybackAfterRebufferMs'] as num?)?.toInt() ??
              CustomExoPlayer.defaultBufferForPlaybackAfterRebufferMs,
    );
  }
}

class CustomExoPlayerState {
  final bool isPlaying;
  final bool isBuffering;
  final int durationMs;
  final int positionMs;
  final int playbackState;
  final int videoWidth;
  final int videoHeight;
  final String error;

  const CustomExoPlayerState({
    required this.isPlaying,
    required this.isBuffering,
    required this.durationMs,
    required this.positionMs,
    required this.playbackState,
    required this.videoWidth,
    required this.videoHeight,
    required this.error,
  });

  factory CustomExoPlayerState._fromMap(Map m) {
    return CustomExoPlayerState(
      isPlaying: m['isPlaying'] == true,
      isBuffering: m['isBuffering'] == true,
      durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
      positionMs: (m['positionMs'] as num?)?.toInt() ?? 0,
      playbackState: (m['playbackState'] as num?)?.toInt() ?? 0,
      videoWidth: (m['videoWidth'] as num?)?.toInt() ?? 0,
      videoHeight: (m['videoHeight'] as num?)?.toInt() ?? 0,
      error: (m['error'] as String?) ?? '',
    );
  }
}
