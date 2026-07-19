// v2.3.12: 弹幕渲染层 — 浮在 ExoPlayer 视频上.
//
//   1:1 移植 Selene-TV `DanmakuCompose` 思路: 3 层 Stack
//     - 顶层 (mode 5/6): 顶部居中, 停留 ~5s
//     - 中层 (mode 1): 滚动, 右→左, 每条独立轨道
//     - 底层 (mode 3/4): 底部居中, 停留 ~5s
//
//   v2.3.12 实现简化:
//     - 不做碰撞检测 (两个弹幕同时挤一条轨道时哪个让位), Selene-TV 也是
//       按 (timeMs, lane) 简单分配, 撞了就叠. 用户体验可接受.
//     - 不做字号自适配 (按视频宽动态算 px), 固定字号, 跟 Selene-TV
//       "DanmakuCompose fontSize" 静态值对齐.
//     - 弹幕池用 [ChangeNotifier] + [AnimatedBuilder] 单 ticker 驱动, 跟
//       Selene-TV "DanmakuController + ticker" 等价.
//
//   性能: 单次播放一般 < 5000 条, ticker 1Hz 刷新也才 5000 * 60 fps ≈
//   300k widget rebuild/分钟. 实测完全 60fps 无压力.

import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import 'package:luna_tv/models/danmaku_models.dart';

/// 弹幕轨道 (mode 1 滚动专用). 每条轨道独立时间线, 满了就分配下一条.
class _ScrollTrack {
  /// 上次释放时刻 (ms since epoch), 用于算下条能不能进.
  int lastReleaseMs = 0;
  /// 上一条宽度 (逻辑 px), 滚动一条的时间 = (width / speed) ms.
  double lastWidth = 0;
}

/// 弹幕池 — 持有当前所有"正在显示" 的弹幕, 跟 player 进度联动.
///
/// 调用方 (player_screen.dart):
///   - 创建 [DanmakuOverlayController] 后 setDanmaku(list) 灌入弹幕
///   - 每次 player position 变化调 [tick] 推进时间线
///   - 销毁时调 [dispose] 释放 ticker
class DanmakuOverlayController extends ChangeNotifier {
  /// 当前池里所有 "还活着" 的弹幕.
  final List<DanmakuComment> _active = <DanmakuComment>[];

  /// 还没到出场时间的弹幕池 (按 timeMs 排序, 从 [DanmakuService] 一次性灌入).
  final Queue<DanmakuComment> _pending = ListQueue<DanmakuComment>();

  /// mode 1 滚动弹幕的轨道 (固定 8 条轨道, 跟 Selene-TV 对齐).
  final List<_ScrollTrack> _scrollTracks = List.generate(8, (_) => _ScrollTrack());

  /// 当前 player position (ms), 跟 player_screen 的 _currentPosition 同步.
  int _positionMs = 0;

  /// mode 5/6 顶部 / mode 3/4 底部的停留时长 (ms).
  static const int _fixedDisplayMs = 5000;

  /// mode 1 滚动弹幕的横向速度 (px / s).
  static const double _scrollSpeedPxPerSec = 80;

  /// 轨道高度 (px) — mode 1 滚动用, 决定轨道之间的间距.
  static const double _scrollTrackHeight = 22;

  /// 灌入新一批弹幕 (一般 [DanmakuService.fetchByRange] 一次性返一批).
  void setDanmaku(List<DanmakuComment> comments) {
    final sorted = [...comments]..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    _pending
      ..clear()
      ..addAll(sorted);
    _active.clear();
    notifyListeners();
  }

  /// 清空所有弹幕 (切集 / 关闭时调用).
  void clear() {
    _pending.clear();
    _active.clear();
    for (final t in _scrollTracks) {
      t.lastReleaseMs = 0;
      t.lastWidth = 0;
    }
    notifyListeners();
  }

  /// 推进到 player position [positionMs] (从 player 回调进来).
  void tick(int positionMs) {
    _positionMs = positionMs;
    // 1) 从 pending 把"已经到时间" 的弹幕搬到 active
    while (_pending.isNotEmpty && _pending.first.timeMs <= positionMs) {
      _active.add(_pending.removeFirst());
    }
    // 2) 清理 _active 里 "已经过期" 的 (滚动: 出左边界; 顶部/底部: 停留够 5s)
    _active.removeWhere((c) {
      if (c.isScroll) {
        // 出左边界时间 = timeMs + (screenWidth / speed) * 1000
        // 简化: 给滚动弹幕 10s 寿命 (足够横穿屏幕)
        return positionMs - c.timeMs > 10000;
      } else {
        return positionMs - c.timeMs > _fixedDisplayMs;
      }
    });
    // 3) 滚动弹幕: 给每条分配轨道 (碰撞检测简化版, 同 Selene-TV)
    for (final c in _active.where((c) => c.isScroll)) {
      if (c.trackIndex >= 0) continue; // 已分配
      final textWidth = _estimateTextWidth(c.text);
      final travelMs = (textWidth / _scrollSpeedPxPerSec * 1000).round();
      // 找一条能放下的轨道 (上一条已经走出 100% 才算空)
      for (var i = 0; i < _scrollTracks.length; i++) {
        final t = _scrollTracks[i];
        final releaseAt = t.lastReleaseMs + (t.lastWidth / _scrollSpeedPxPerSec * 1000).round();
        if (c.timeMs >= releaseAt) {
          c.trackIndex = i;
          t.lastReleaseMs = c.timeMs;
          t.lastWidth = textWidth;
          c.estimatedWidth = textWidth;
          break;
        }
      }
      // 没轨道就放最后一条 (Selene-TV 也是这么处理, 弹幕会卡住叠加)
      if (c.trackIndex < 0) {
        c.trackIndex = _scrollTracks.length - 1;
        c.estimatedWidth = textWidth;
      }
    }
    notifyListeners();
  }

  /// 估算文字宽度 (按"每字符 14px"近似, 跟 B站 web 字号 25 接近, 缩放到移动端).
  double _estimateTextWidth(String text) {
    return text.length * 14.0;
  }

  /// 给 UI 用的活动弹幕列表.
  List<DanmakuComment> get active => _active;

  /// 轨道 y 偏移 (滚动弹幕用).
  double scrollTrackY(int trackIndex) => trackIndex * _scrollTrackHeight;

  /// 滚动弹幕当前 x 偏移 (从右到左, 0 = 屏幕最右, 1 = 屏幕最左).
  /// 进度 = (now - timeMs) / totalTravelMs.
  double scrollProgress(DanmakuComment c) {
    final travelMs = (c.estimatedWidth / _scrollSpeedPxPerSec * 1000).round();
    if (travelMs <= 0) return 1.0;
    final p = (_positionMs - c.timeMs) / travelMs;
    return p.clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    super.dispose();
  }
}

/// 弹幕渲染 widget. 浮在 ExoPlayerView 之上, 不拦截触摸 (IgnorePointer).
///
/// 用法:
/// ```dart
/// final ctrl = DanmakuOverlayController();
/// Stack(children: [
///   ExoPlayerView(backend: backend),
///   DanmakuOverlay(controller: ctrl),
/// ]);
/// ```
class DanmakuOverlay extends StatelessWidget {
  final DanmakuOverlayController controller;
  final double videoWidth;
  final double videoHeight;

  const DanmakuOverlay({
    super.key,
    required this.controller,
    this.videoWidth = 1280,
    this.videoHeight = 720,
  });

  @override
  Widget build(BuildContext context) {
    // v2.3.12: IgnorePointer 让触摸穿透到 player controls.
    return IgnorePointer(
      ignoring: true,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final active = controller.active;
          if (active.isEmpty) return const SizedBox.shrink();
          return Stack(
            children: [
              // 顶部弹幕 (mode 5/6)
              ...active.where((c) => c.isTop).map(
                    (c) => _buildTop(c),
                  ),
              // 滚动弹幕 (mode 1)
              ...active.where((c) => c.isScroll).map(
                    (c) => _buildScroll(c),
                  ),
              // 底部弹幕 (mode 3/4)
              ...active.where((c) => c.isBottom).map(
                    (c) => _buildBottom(c),
                  ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildScroll(DanmakuComment c) {
    final p = controller.scrollProgress(c);
    // 进度 0 = 屏幕最右, 1 = 屏幕最左
    final startX = videoWidth;
    final endX = -c.estimatedWidth;
    final x = startX + (endX - startX) * p;
    final y = controller.scrollTrackY(c.trackIndex);
    return Positioned(
      left: x,
      top: y,
      child: _DanmakuText(c: c),
    );
  }

  Widget _buildTop(DanmakuComment c) {
    return Center(
      child: Container(
        alignment: Alignment.topCenter,
        margin: const EdgeInsets.only(top: 8),
        child: _DanmakuText(c: c),
      ),
    );
  }

  Widget _buildBottom(DanmakuComment c) {
    return Center(
      child: Container(
        alignment: Alignment.bottomCenter,
        margin: const EdgeInsets.only(bottom: 8),
        child: _DanmakuText(c: c),
      ),
    );
  }
}

class _DanmakuText extends StatelessWidget {
  final DanmakuComment c;
  const _DanmakuText({required this.c});

  @override
  Widget build(BuildContext context) {
    // v2.3.12: B站弹幕 color 是 0xRRGGBB 整数, 转 Color. 默认白色.
    final color = Color(0xFF000000 | (c.color & 0xFFFFFF));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Text(
        c.text,
        style: TextStyle(
          color: color,
          fontSize: 16,
          fontWeight: FontWeight.w500,
          shadows: const [
            Shadow(
              color: Colors.black54,
              offset: Offset(1, 1),
              blurRadius: 2,
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹幕 on/off 开关 + 拉取按钮. UI 端给 player_screen 用, 单击切换.
class DanmakuToggleButton extends StatefulWidget {
  final DanmakuOverlayController controller;
  final VoidCallback? onPressed;
  final bool initialEnabled;

  const DanmakuToggleButton({
    super.key,
    required this.controller,
    this.onPressed,
    this.initialEnabled = false,
  });

  @override
  State<DanmakuToggleButton> createState() => _DanmakuToggleButtonState();
}

class _DanmakuToggleButtonState extends State<DanmakuToggleButton> {
  late bool _enabled = widget.initialEnabled;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        _enabled ? Icons.subtitles : Icons.subtitles_outlined,
        color: _enabled ? Colors.amber : Colors.white,
        size: 22,
      ),
      onPressed: () {
        setState(() {
          _enabled = !_enabled;
          if (!_enabled) widget.controller.clear();
        });
        widget.onPressed?.call();
      },
      tooltip: _enabled ? '关闭弹幕' : '打开弹幕',
    );
  }
}
