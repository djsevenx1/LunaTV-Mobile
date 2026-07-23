// lib/danmaku/widgets/danmaku_overlay.dart
// 弹幕浮层 — 视频上层透明 Stack, 用 CustomPainter 滚动画
//
// 性能: 跟 video_player 解耦, 外部 push 当前位置. 我们用
// AnimationController 持续 tick, 按"当前播放时间"投屏.
// 渲染: 顶部/底部 固定行, 滚动弹幕按轨道行 + x 速度.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/danmaku_comment.dart';

class DanmakuOverlay extends StatefulWidget {
  final List<DanmakuComment> comments;
  final bool enabled;
  final double opacity;
  final double fontSize;
  final double speed;
  // 外部视频位置推流器 (Function 而不是 Stream 是为了简单)
  final Duration Function()? positionProvider;
  final bool Function()? pausedProvider;

  const DanmakuOverlay({
    super.key,
    required this.comments,
    this.enabled = true,
    this.opacity = 1.0,
    this.fontSize = 18,
    this.speed = 1.0,
    this.positionProvider,
    this.pausedProvider,
  });

  @override
  State<DanmakuOverlay> createState() => DanmakuOverlayState();
}

class DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final List<_LiveBullet> _live = [];
  int _lastTickMs = 0;

  // 滚动轨道行: 记录每行最后一颗结束时间, 避免堆叠
  // public 让同文件内 _DanmakuPainter (单独 class) 能读到
  static const int scrollRows = 14;
  final List<int> _scrollRowFreeAtMs = List.filled(scrollRows, 0);
  static const int topRows = 4;
  final List<int> _topRowFreeAtMs = List.filled(topRows, 0);
  static const int bottomRows = 4;
  final List<int> _bottomRowFreeAtMs = List.filled(bottomRows, 0);

  Duration _mediaPos = Duration.zero;
  DateTime _lastWall = DateTime.now();
  bool _paused = false;

  // 暴露给外部同步视频位置
  void syncPosition(Duration pos) {
    _mediaPos = pos;
  }

  void pause() {
    _paused = true;
  }

  void resume() {
    _paused = false;
  }

  // 当前还活着的弹幕数, 用于日志 / UI
  int get liveCount => _live.length;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(days: 1), // 不需要 stop
    )..addListener(_onTick);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTick);
    _ctrl.dispose();
    super.dispose();
  }

  void _onTick() {
    final now = DateTime.now();
    final dtMs = now.difference(_lastWall).inMilliseconds;
    _lastWall = now;

    final pausedExt = widget.pausedProvider?.call() ?? _paused;
    if (pausedExt || !widget.enabled) {
      return;
    }

    if (widget.positionProvider != null) {
      _mediaPos = widget.positionProvider!.call();
    } else {
      // 没有外部位置源, 内部推 (测试模式)
      _mediaPos = Duration(milliseconds: _mediaPos.inMilliseconds + dtMs);
    }

    _lastTickMs += dtMs;
    if (_lastTickMs >= 50) {
      // 20 fps
      _lastTickMs = 0;
      // 推进所有活弹丸
      for (final b in _live) {
        b.advance(_mediaPos.inMilliseconds);
      }
      // 清理已结束
      _live.removeWhere((b) => b.done);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        if (w <= 0 || h <= 0) return const SizedBox.shrink();
        _spawn(w);
        return IgnorePointer(
          child: CustomPaint(
            painter: _DanmakuPainter(
              bullets: _live,
              width: w,
              height: h,
              opacity: widget.opacity,
              fontSize: widget.fontSize,
            ),
            size: Size(w, h),
          ),
        );
      },
    );
  }

  void _spawn(double w) {
    final current = _mediaPos.inMilliseconds;
    for (final c in widget.comments) {
      // 在 ±8s 窗口内的弹幕, 已投过的跳过
      if (c.timeMs > current - 8000 && c.timeMs <= current + 200) {
        if (_live.any((b) => identical(b.comment, c))) continue;
        final track = _pickTrack(c.mode, current);
        if (track < 0) continue;
        _live.add(_LiveBullet(
          comment: c,
          row: track,
          spawnedAtMs: current,
          screenWidth: w,
        ));
      }
    }
  }

  int _pickTrack(int mode, int nowMs) {
    if (mode == 5) {
      // 顶部
      for (var i = 0; i < topRows; i++) {
        if (_topRowFreeAtMs[i] <= nowMs) {
          _topRowFreeAtMs[i] = nowMs + 4000;
          return i;
        }
      }
      return -1;
    }
    if (mode == 4) {
      // 底部
      for (var i = 0; i < bottomRows; i++) {
        if (_bottomRowFreeAtMs[i] <= nowMs) {
          _bottomRowFreeAtMs[i] = nowMs + 4000;
          return i;
        }
      }
      return -1;
    }
    // 滚动
    for (var i = 0; i < scrollRows; i++) {
      if (_scrollRowFreeAtMs[i] <= nowMs) {
        _scrollRowFreeAtMs[i] = nowMs + 4500;
        return i;
      }
    }
    return -1;
  }
}

class _LiveBullet {
  final DanmakuComment comment;
  final int row;
  final int spawnedAtMs;
  final double screenWidth;
  double x = 0;
  bool done = false;

  _LiveBullet({
    required this.comment,
    required this.row,
    required this.spawnedAtMs,
    required this.screenWidth,
  });

  void advance(int nowMs) {
    final elapsed = nowMs - spawnedAtMs;
    if (elapsed < 0) return;
    if (comment.mode == 1) {
      // 滚动: 8s 走过屏幕
      final t = (elapsed / 8000.0).clamp(0.0, 1.0);
      x = screenWidth * (1.0 - t);
      if (t >= 1.0) done = true;
    } else {
      // 固定 4s
      if (elapsed > 4000) done = true;
    }
  }
}

class _DanmakuPainter extends CustomPainter {
  final List<_LiveBullet> bullets;
  final double width;
  final double height;
  final double opacity;
  final double fontSize;

  _DanmakuPainter({
    required this.bullets,
    required this.width,
    required this.height,
    required this.opacity,
    required this.fontSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bullets.isEmpty) return;
    final lineH = fontSize + 6;
    final topH = DanmakuOverlayState.topRows * lineH;
    final bottomH = DanmakuOverlayState.bottomRows * lineH;
    final scrollH = (height - topH - bottomH).clamp(0, height);
    final scrollRows = DanmakuOverlayState.scrollRows;
    final rowH = scrollRows > 0 ? scrollH / scrollRows : 0;

    for (final b in bullets) {
      final text = b.comment.content;
      if (text.isEmpty) continue;
      final c = b.comment.color;
      final r = (c >> 16) & 0xFF;
      final g = (c >> 8) & 0xFF;
      final bv = c & 0xFF;
      final color = Color.fromARGB(
        (255 * opacity).round().clamp(0, 255),
        r,
        g,
        bv,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: fontSize,
            color: color,
            fontWeight: FontWeight.w500,
            shadows: const [
              Shadow(blurRadius: 3, color: Colors.black54, offset: Offset(0, 0)),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout(maxWidth: width);

      double y;
      if (b.comment.mode == 5) {
        y = 8 + b.row * lineH;
      } else if (b.comment.mode == 4) {
        y = height - bottomH + 8 + b.row * lineH;
      } else {
        y = topH + b.row * rowH;
      }
      final dx = b.comment.mode == 1 ? b.x : (width - tp.width) / 2;
      final offset = Offset(dx, y);
      tp.paint(canvas, offset);
    }
  }

  @override
  bool shouldRepaint(_DanmakuPainter old) =>
      old.bullets != bullets ||
      old.opacity != opacity ||
      old.fontSize != fontSize;
}
