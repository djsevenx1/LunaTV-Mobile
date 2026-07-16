// v2.2.0: 播放器抽象层. 之前 UI 直接吃 media_kit.Player, 把 libmpv 耦合死.
//   现在统一走 PlayerBackend, 任何后端 (ExoPlayer / AVPlayer / 自研) 只要
//   实现这层就能 plug-in, 控件 / widget / 加速逻辑零改动.
//
// 关键不变量 (跟 libmpv 时代对齐):
//   - 异步操作都返 Future<void>, 跟 media_kit 一致
//   - stream.* 是 broadcast (或 single-subscription 但 widget 自己 .listen)
//   - state.* 是同步读, 但内部值会在 stream 之后一拍再更新 (ExoPlayer listener
//     异步回调, 跟 mpv_property 同步轮询不一致, UI 要容忍这个)

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 单帧带宽采样 — ExoPlayer [Player.Listener.onBandwidthSample] 回调拿到的数据.
class BandwidthSample {
  final int bitsPerSecond; // 实时瞬时带宽 (bits/s), ExoPlayer 直接给
  final int bytesLoaded; // 本次采样期间累计下载字节
  final Duration elapsed; // 距上次采样的时间间隔 (我们 app 算)
  final DateTime at;
  const BandwidthSample({
    required this.bitsPerSecond,
    required this.bytesLoaded,
    required this.elapsed,
    required this.at,
  });
}

/// 后端当前可枚举的轨道 (音频 / 字幕). v2.2.0 先支持 list + select.
class MediaTrackInfo {
  final String id;            // 内部 ID, 给 selectXxxTrack 用
  final String label;         // UI 显示, 如 "English", "Default"
  final String language;      // BCP 47 (e.g. "en", "zh-Hans")
  final bool isDefault;
  final bool isSelected;
  const MediaTrackInfo({
    required this.id,
    required this.label,
    required this.language,
    required this.isDefault,
    required this.isSelected,
  });
}

/// 播放器抽象.
abstract class PlayerBackend {
  // ── 状态 (同步读) ───────────────────────────────────────────
  bool get isPlaying;
  bool get isBuffering;     // v2.2.0: 替代 media_kit 的 state.buffering
  bool get isCompleted;     // v2.2.0: 替代 media_kit 的 state.completed
  Duration get position;
  Duration get duration;
  double get volume;     // 0.0-1.0
  double get speed;      // 0.25-4.0
  int get width;         // 视频原始宽 (0 = 还没好)
  int get height;

  // ── 流 (异步订阅) ──────────────────────────────────────────
  Stream<bool> get playingStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get completedStream;
  /// 带宽采样流 — 替换原来 mpv 时代 1s 轮询 demuxer-bytes 的做法.
  /// 频率: ExoPlayer 默认 1 sample/秒, 后端按需节流.
  Stream<BandwidthSample> get bandwidthStream;

  // ── 控制 ────────────────────────────────────────────────
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Duration? startAt,
  });
  Future<void> play();
  Future<void> pause();
  /// v2.2.0: 替代 media_kit 的 Player.stop() — 停播放但保留 player 实例
  ///   (下一集可以重新 open). 跟 dispose() 不同, dispose 会 release 整个 player.
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume); // 0.0-1.0
  Future<void> setSpeed(double speed);   // 0.25-4.0
  Future<void> dispose();

  // ── 高级 (v2.2.0 占位, 给未来 track 切换用) ────────────
  List<MediaTrackInfo> get audioTracks;
  List<MediaTrackInfo> get subtitleTracks;
  Future<void> selectAudioTrack(String id);
  Future<void> selectSubtitleTrack(String id);
  Future<void> setSubtitleTrackEnabled(bool enabled);
}

/// 全屏控制器 — 替换原来 media_kit_video.VideoState. 控件需要 isFullscreen()
///   / enterFullscreen() / exitFullscreen() 三个 API, 之前是 media_kit 包给的,
///   现在 widget 自己实现 (走 Navigator + overlay).
abstract class FullscreenController {
  bool isFullscreen();
  void enterFullscreen();
  void exitFullscreen();
}

/// 播放器跟 Flutter 视图桥接的 widget — 之前是 `Video(controller: VideoController(player))`,
///   后端不同 widget 也不同 (ExoPlayer 用 ExoPlayerWidget / media3 包给的,
///   mpv 用 Video), 所以抽一个工厂.
///
/// v2.2.0 修复: build() 跟 [StatelessWidget.build] 签名冲突 (后者只接
///   BuildContext), Dart 报 "more required arguments than those of overridden
///   method 'StatelessWidget.build'". 抽象方法改名 buildView() 避开
///   framework 的同名方法. 现在并没有子类 extends 它, 留着只是为了
///   给未来 mpv 后端留扩展位, 因此 extends StatelessWidget 也暂时不删.
abstract class PlayerView extends StatelessWidget {
  const PlayerView({super.key});
  /// 拿到跟 PlayerBackend 绑定的实际播放器 View, widget 透传 controls builder.
  Widget buildView(BuildContext context, FullscreenController fullscreenCtl);
}
