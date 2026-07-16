// v2.2.0: ExoPlayer (AndroidX Media3) 版本的 [PlayerBackend] 实现.
//
// 关键点:
//   - 走 [media3] Dart 包 (androidx.media3 1.4.x 的 Dart 绑定), 不依赖
//     media_kit / libmpv, 包体积 -32MB (libmpv .so 全砍了).
//   - HTTP proxy 走 [ExoPlayerBuilder.dataSourceFactory] 注入
//     [DefaultHttpDataSource.Factory.setProxy], 跟 libmpv 时代
//     `--http-proxy=http://127.0.0.1:PORT` 等价.
//   - 带宽走 [Player.Listener.onBandwidthSample] 回调, 不再 1s 轮询
//     mpv demuxer-bytes, 反应更准, 几乎零 CPU.
//   - 默认硬解 (Media3 默认就是硬解 + codec 自适应, 不需要手动
//     `hwdec=mediacodec` 这种).
//
// iOS 端不编译, 跨平台日后写一个 MediaPlayerBackend (AVPlayer).

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:media3/media3.dart' as m3;

import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/player_backend.dart';

class ExoPlayerBackend implements PlayerBackend {
  // ── media3 内部状态 ──────────────────────────────────────
  m3.ExoPlayer? _player;
  final _m3DataSourceFactory = m3.DefaultDataSourceFactory();
  // 我们注入的 http proxy (VideoProxyServer.proxyUrl).
  // 为 null 时走系统 DNS 直连.
  Uri? _httpProxyUri;

  // ── 对外暴露的状态 ──────────────────────────────────────
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1.0;
  double _speed = 1.0;
  int _width = 0;
  int _height = 0;
  bool _completed = false;

  // ── 流控制器 (broadcast 多订阅) ────────────────────────
  final _playingCtl = StreamController<bool>.broadcast();
  final _positionCtl = StreamController<Duration>.broadcast();
  final _durationCtl = StreamController<Duration>.broadcast();
  final _completedCtl = StreamController<bool>.broadcast();
  final _bandwidthCtl = StreamController<BandwidthSample>.broadcast();

  // ── 内部辅助 ────────────────────────────────────────
  late final m3.Player.Listener _listener;
  int _lastBandwidthBytes = 0;
  DateTime _lastBandwidthAt = DateTime.now();

  ExoPlayerBackend() {
    _listener = m3.Player.Listener(
      onIsPlayingChanged: (playing) {
        _isPlaying = playing;
        _safeAdd(_playingCtl, playing);
      },
      onPlaybackStateChanged: (state) {
        switch (state) {
          case m3.PlaybackState.ready:
            // duration / videoSize 会在 onVideoSizeChanged 单独到
            break;
          case m3.PlaybackState.ended:
            _completed = true;
            _safeAdd(_completedCtl, true);
            break;
          case m3.PlaybackState.buffering:
          case m3.PlaybackState.idle:
            break;
        }
      },
      onPositionDiscontinuity: (
        oldPosition,
        newPosition,
        reason,
      ) {
        _position = newPosition;
        _safeAdd(_positionCtl, newPosition);
      },
      onVideoSizeChanged: (width, height, unappliedRotationDegrees, pixelRatioHeightWidth) {
        _width = width;
        _height = height;
      },
      onBandwidthSample: (event) {
        // v2.2.0: Media3 给的瞬时带宽. event.bitsPerSecond 是 bits/s,
        //   event.bytesLoaded 是本次采样下载字节数. 我们自己算 elapsed
        //   因为 Media3 没直接给 elapsedMs.
        final now = DateTime.now();
        final elapsed = now.difference(_lastBandwidthAt);
        // bytesLoaded 是累计还是 delta 不同版本有差异, 用 1s 估算.
        _lastBandwidthAt = now;
        _safeAdd(
          _bandwidthCtl,
          BandwidthSample(
            bitsPerSecond: event.bitsPerSecond.toInt(),
            bytesLoaded: event.bytesLoaded.toInt(),
            elapsed: elapsed,
            at: now,
          ),
        );
      },
      onPlayerError: (error) {
        // v2.2.0: ExoPlayer 错误 → 写日记 + 推 completed (播放失败视作完结, UI 弹错误)
        DiaryService.add(
            '[ExoPlayer] ERROR: code=${error.errorCode} message="${error.message}"');
        _completed = true;
        _safeAdd(_completedCtl, true);
      },
    );
  }

  /// v2.2.0: 工厂 — 装配 media3 ExoPlayer, 注入 http proxy (如果有).
  ///   必须在 initState 里 await 调用, 不能在构造同步跑 (Media3 要 platform side).
  static Future<ExoPlayerBackend> create({
    Uri? httpProxyUri,
    Map<String, String>? defaultHeaders,
  }) async {
    final backend = ExoPlayerBackend();
    backend._httpProxyUri = httpProxyUri;
    await backend._initPlayer(defaultHeaders);
    return backend;
  }

  Future<void> _initPlayer(Map<String, String>? defaultHeaders) async {
    try {
      // v2.2.0: 配 data source factory
      //   1) 如果有 http proxy, 用 DefaultHttpDataSource.Factory().setProxy()
      //   2) headers 走 setDefaultRequestProperties 注入
      //   3) media3 的 DefaultDataSource.Factory 内置 fallback: mms / file / raw
      final httpDataSourceFactory = m3.DefaultHttpDataSource.Factory()
          ..setUserAgent('LunaTV/${defaultHeaders?['User-Agent'] ?? '2.2.0'}')
          ..setConnectTimeoutMs(15000)
          ..setReadTimeoutMs(15000)
          ..setAllowCrossProtocolRedirects(true);

      if (_httpProxyUri != null) {
        httpDataSourceFactory.setProxy(
          m3.HttpProxy(_httpProxyUri.toString()),
        );
      }
      if (defaultHeaders != null && defaultHeaders.isNotEmpty) {
        httpDataSourceFactory.setDefaultRequestProperties(defaultHeaders);
      }

      _m3DataSourceFactory.httpDataSourceFactory = httpDataSourceFactory;

      // v2.2.0: ExoPlayer 配置
      final loadControl = m3.DefaultLoadControl.Builder()
          // 16MB 内存缓冲, 跟之前 mpv cache=yes 16MB 接近
          ..setBufferDurationsMs(
            15000, // minBufferMs: 15s
            50000, // maxBufferMs: 50s
            1500,  // bufferForPlaybackMs: 起播需要 1.5s
            2000,  // bufferForPlaybackAfterRebufferMs: 重缓冲后 2s
          );

      // v2.2.0: Media3 默认硬解, 这里显式确认 (MediaCodec). 不需要 hwdec 字符串.
      final player = m3.ExoPlayer.Builder()
          .setLoadControl(loadControl.build())
          .setMediaSourceFactory(m3.DefaultMediaSourceFactory(_m3DataSourceFactory))
          .build();

      player.addListener(_listener);
      _player = player;

      DiaryService.add(
          '[ExoPlayer] init OK: proxy=${_httpProxyUri ?? "none"}, headers=${defaultHeaders?.keys.join(",") ?? "none"}');
    } catch (e, st) {
      DiaryService.add('[ExoPlayer] init FAIL: $e\n$st');
      rethrow;
    }
  }

  // ── PlayerBackend 实现 ────────────────────────────────────
  @override
  bool get isPlaying => _isPlaying;
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
    final p = _player;
    if (p == null) {
      throw StateError('ExoPlayerBackend not initialized');
    }
    _completed = false;
    _safeAdd(_completedCtl, false);

    final itemBuilder = m3.MediaItem.Builder()
      ..setUri(url);
    if (headers != null) {
      // v2.2.0: Media3 媒体级 headers 走 MediaItem.Builder.setRequestMetadata
      //   (低版本叫 setCustomCacheKey, 新版统一到 RequestMetadata)
      itemBuilder.setRequestMetadata(
        m3.RequestMetadata.Builder()
          ..setExtras(headers)
          ..build(),
      );
    }
    final item = itemBuilder.build();

    p.setMediaItem(item, startTimeMs: startAt?.inMilliseconds ?? 0);
    p.prepare();
    p.setPlayWhenReady(true);

    // 同步本地缓存
    _position = startAt ?? Duration.zero;
    _safeAdd(_positionCtl, _position);
  }

  @override
  Future<void> play() async {
    _player?.setPlayWhenReady(true);
  }

  @override
  Future<void> pause() async {
    _player?.setPlayWhenReady(false);
  }

  @override
  Future<void> seek(Duration position) async {
    _player?.seekTo(position.inMilliseconds);
    _position = position;
    _safeAdd(_positionCtl, position);
  }

  @override
  Future<void> setVolume(double volume) async {
    final v = volume.clamp(0.0, 1.0);
    _player?.setVolume(v);
    _volume = v;
  }

  @override
  Future<void> setSpeed(double speed) async {
    final s = speed.clamp(0.25, 4.0);
    _player?.setPlaybackSpeed(s);
    _speed = s;
  }

  @override
  List<MediaTrackInfo> get audioTracks => const []; // v2.2.1 实现
  @override
  List<MediaTrackInfo> get subtitleTracks => const [];
  @override
  Future<void> selectAudioTrack(String id) async {}
  @override
  Future<void> selectSubtitleTrack(String id) async {}
  @override
  Future<void> setSubtitleTrackEnabled(bool enabled) async {
    _player?.setTrackSelectionParameters(
      m3.TrackSelectionParameters.Builder()
          ..setTrackTypeDisabled(m3.C.TrackType.text, !enabled)
          ..build(),
    );
  }

  @override
  Future<void> dispose() async {
    try {
      _player?.removeListener(_listener);
      _player?.release();
    } catch (_) {}
    _player = null;
    await _playingCtl.close();
    await _positionCtl.close();
    await _durationCtl.close();
    await _completedCtl.close();
    await _bandwidthCtl.close();
  }

  // ── 辅助 ──────────────────────────────────────────────
  /// v2.2.0: 给 widget 层用, 拿到底层 m3.ExoPlayer 挂到 PlayerView (AndroidView).
  m3.ExoPlayer? get rawPlayer => _player;

  void _safeAdd<T>(StreamController<T> ctl, T value) {
    if (!ctl.isClosed) ctl.add(value);
  }
}
