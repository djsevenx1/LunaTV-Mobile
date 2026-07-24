// lib/danmaku/widgets/danmaku_overlay.dart
// 弹幕浮层 — 视频上层透明 Stack, 用 CustomPainter 滚动画
//
// v2.5.36: 移植 SeleneTV Lhh0; (DanmakuRender) 渲染参数:
//   - danmaku_opacity      → Paint alpha
//   - danmaku_speed        → 滚动时长 = baseDuration / speed
//   - danmaku_font_scale   → fontSize = baseFontSize * fontScale
//   - danmaku_density_pct  → 按比例丢弃弹幕 (25% = 每4条取1条)
//   - danmaku_anti_overlap → 防重叠: 新弹幕投轨前检查前一条右边缘
//   - danmaku_area         → 渲染区域高度 = screenH * area.ratio
//   - danmaku_mode         → 过滤弹幕类型 (all/scroll/top/bottom)
//
// 性能: AnimationController 16ms tick (~60fps, 对齐 Choreographer),
//   每 tick 推进弹幕 x, 每 50ms setState 刷新画面 (20fps 足够).

import 'package:flutter/material.dart';

import '../danmaku_settings.dart';
import '../models/danmaku_comment.dart';

class DanmakuOverlay extends StatefulWidget {
  final List<DanmakuComment> comments;
  final bool enabled;
  final double opacity; // 覆盖: 若非 null 则用此值, 否则读 DanmakuSettings
  final double fontSize;
  final double speed;
  // 外部视频位置推流器
  final Duration Function()? positionProvider;
  final bool Function()? pausedProvider;

  const DanmakuOverlay({
    super.key,
    required this.comments,
    this.enabled = true,
    this.opacity = 1.0,
    this.fontSize = 16,
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

  // === 轨道管理 ===
  // 滚动弹幕: 按行排布, 每行记录 [freeAtMs, lastRightEdge]
  //   freeAtMs: 该行何时空闲 (时间预估)
  //   lastRightEdge: 上一条弹幕当前右边缘 x (用于防重叠)
  static const int _maxScrollRows = 20;
  final List<_TrackState> _scrollTracks = List.generate(_maxScrollRows, (_) => _TrackState());
  static const int _maxFixedRows = 8;
  final List<_TrackState> _topTracks = List.generate(_maxFixedRows, (_) => _TrackState());
  final List<_TrackState> _bottomTracks = List.generate(_maxFixedRows, (_) => _TrackState());

  Duration _mediaPos = Duration.zero;
  DateTime _lastWall = DateTime.now();
  bool _paused = false;

  // === 设置 (从 DanmakuSettings 读) ===
  DanmakuRenderSettings _settings = const DanmakuRenderSettings();
  DanmakuAreaOption _area = DanmakuAreaOption.full;
  DanmakuMode _mode = DanmakuMode.all;

  // 密度控制: 按比例丢弃弹幕
  // densityPct=100 → 全部显示, 25 → 每4条取1条
  int _densityCounter = 0;

  // 基础参数 (SeleneTV 默认值)
  static const double _baseFontSize = 16.0;
  static const int _scrollDurationMs = 8000; // 8s 走过屏幕宽
  static const int _fixedDurationMs = 4000; // 顶部/底部 4s
  static const double _trackGap = 4.0; // 行间距
  static const double _antiOverlapGap = 12.0; // 防重叠最小间距

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

  int get liveCount => _live.length;

  /// ★ 重置所有轨道状态 — 切集/换 comments 时调用
  ///   旧轨道 freeAtMs 保留旧集的大数值 (如 600000ms),
  ///   新集从 0ms 开始 → _pickTrack 全返回 -1 → 新弹幕投不上轨 → 屏幕空白
  void reset() {
    _live.clear();
    for (final t in _scrollTracks) {
      t.freeAtMs = 0;
      t.lastBullet = null;
    }
    for (final t in _topTracks) {
      t.freeAtMs = 0;
      t.lastBullet = null;
    }
    for (final t in _bottomTracks) {
      t.freeAtMs = 0;
      t.lastBullet = null;
    }
    _lastTickMs = 0;
    _densityCounter = 0;
    if (mounted) setState(() {});
  }

  /// ★ 检测 comments 列表变化 → 自动 reset
  @override
  void didUpdateWidget(DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // comments 引用变了 → 新一集的弹幕, 重置轨道
    if (!identical(oldWidget.comments, widget.comments)) {
      reset();
    }
  }

  /// 从 DanmakuSettings 刷新设置 (设置面板关闭后调用)
  void refreshSettings() {
    final s = DanmakuSettings.instance;
    setState(() {
      _settings = s.render;
      _area = s.area;
      _mode = s.mode;
    });
  }

  @override
  void initState() {
    super.initState();
    final s = DanmakuSettings.instance;
    _settings = s.render;
    _area = s.area;
    _mode = s.mode;
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(days: 1),
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
    if (pausedExt || !widget.enabled) return;

    if (widget.positionProvider != null) {
      _mediaPos = widget.positionProvider!.call();
    } else {
      _mediaPos = Duration(milliseconds: _mediaPos.inMilliseconds + dtMs);
    }

    _lastTickMs += dtMs;
    // 推进所有活弹丸 (每帧)
    for (final b in _live) {
      b.advance(_mediaPos.inMilliseconds);
    }
    _live.removeWhere((b) => b.done);

    if (_lastTickMs >= 50) {
      // 20fps 刷新 UI
      _lastTickMs = 0;
      if (mounted) setState(() {});
    }
  }

  double _effectiveSpeed() {
    // 优先用 widget.speed (外部覆盖), 否则用 settings
    return widget.speed != 1.0 ? widget.speed : _settings.speed;
  }

  double _effectiveOpacity() {
    return widget.opacity != 1.0 ? widget.opacity : _settings.opacity;
  }

  double _effectiveFontSize() {
    return _baseFontSize * _settings.fontScale;
  }

  /// 模式过滤 — danmaku_mode
  bool _shouldShowByMode(int mode) {
    switch (_mode) {
      case DanmakuMode.all:
        return true;
      case DanmakuMode.scroll:
        return mode == 1;
      case DanmakuMode.top:
        return mode == 5;
      case DanmakuMode.bottom:
        return mode == 4;
    }
  }

  /// 密度过滤 — danmaku_density_pct
  /// 25% → 25% 弹幕通过, 50% → 50% 通过, 75% → 75% 通过, 100% → 全通过
  bool _shouldShowByDensity() {
    if (_settings.densityPct >= 100) return true;
    // 模运算: densityPct% 的弹幕通过
    _densityCounter = (_densityCounter + 1) % 100;
    return _densityCounter < _settings.densityPct;
  }

  @override
  Widget build(BuildContext context) {
    // area=off → 不渲染
    if (_area.key == 'off') return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (ctx, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        if (w <= 0 || h <= 0) return const SizedBox.shrink();
        _spawn(w, h);
        return IgnorePointer(
          child: CustomPaint(
            painter: _DanmakuPainter(
              bullets: _live,
              width: w,
              height: h,
              opacity: _effectiveOpacity(),
              fontSize: _effectiveFontSize(),
              areaRatio: _area.ratio,
            ),
            size: Size(w, h),
          ),
        );
      },
    );
  }

  void _spawn(double w, double h) {
    final current = _mediaPos.inMilliseconds;
    final lineH = _effectiveFontSize() + _trackGap;

    // 计算可用行数 (受 area 限制)
    final availH = h * _area.ratio;
    final maxScrollRows = (availH / lineH).floor().clamp(1, _maxScrollRows);
    final maxFixedRows = (availH / lineH / 2).floor().clamp(1, _maxFixedRows); // 顶部底部各占一半

    for (final c in widget.comments) {
      // 时间窗口: ±8s
      if (c.timeMs > current - 8000 && c.timeMs <= current + 200) {
        if (_live.any((b) => identical(b.comment, c))) continue;

        // 模式过滤
        if (!_shouldShowByMode(c.mode)) continue;

        // 密度过滤
        if (!_shouldShowByDensity()) continue;

        final track = _pickTrack(c.mode, current, w, lineH, maxScrollRows, maxFixedRows);
        if (track < 0) continue;

        final speed = _effectiveSpeed();
        final scrollMs = (_scrollDurationMs / speed).round();

        final bullet = _LiveBullet(
          comment: c,
          row: track,
          spawnedAtMs: current,
          screenWidth: w,
          scrollDurationMs: scrollMs,
          fixedDurationMs: _fixedDurationMs,
          fontSize: _effectiveFontSize(),
        );
        _live.add(bullet);

        // 记录该轨道最后一条弹幕 (防重叠用)
        if (c.mode == 1) {
          _scrollTracks[track].lastBullet = bullet;
        } else if (c.mode == 5) {
          _topTracks[track].lastBullet = bullet;
        } else if (c.mode == 4) {
          _bottomTracks[track].lastBullet = bullet;
        }
      }
    }
  }

  int _pickTrack(
    int mode,
    int nowMs,
    double w,
    double lineH,
    int maxScrollRows,
    int maxFixedRows,
  ) {
    if (mode == 5) {
      // 顶部固定
      for (var i = 0; i < maxFixedRows; i++) {
        if (_topTracks[i].freeAtMs <= nowMs) {
          _topTracks[i].freeAtMs = nowMs + _fixedDurationMs;
          return i;
        }
      }
      return -1;
    }
    if (mode == 4) {
      // 底部固定
      for (var i = 0; i < maxFixedRows; i++) {
        if (_bottomTracks[i].freeAtMs <= nowMs) {
          _bottomTracks[i].freeAtMs = nowMs + _fixedDurationMs;
          return i;
        }
      }
      return -1;
    }
    // 滚动
    final speed = _effectiveSpeed();
    final scrollMs = (_scrollDurationMs / speed).round();
    for (var i = 0; i < maxScrollRows; i++) {
      final track = _scrollTracks[i];
      if (track.freeAtMs <= nowMs) {
        // 防重叠: 检查上一条弹幕右边缘是否已经离开屏幕右边足够远
        if (_settings.antiOverlap && track.lastBullet != null) {
          final last = track.lastBullet!;
          final elapsed = nowMs - last.spawnedAtMs;
          if (elapsed >= 0 && elapsed < scrollMs) {
            // 上一条还在屏幕上, 检查右边缘
            final t = (elapsed / scrollMs).clamp(0.0, 1.0);
            final lastRightEdge = w * (1.0 - t) + last.textWidth;
            // 右边缘还没离开屏幕左侧+gap → 跳过此行
            if (lastRightEdge > _antiOverlapGap) continue;
          }
        }
        track.freeAtMs = nowMs + (scrollMs * 0.5).round(); // 预估半程后可投
        return i;
      }
    }
    return -1;
  }
}

/// 轨道状态 — 记录每行的空闲时间和最后一条弹幕 (防重叠用)
class _TrackState {
  int freeAtMs = 0;
  _LiveBullet? lastBullet;
}

class _LiveBullet {
  final DanmakuComment comment;
  final int row;
  final int spawnedAtMs;
  final double screenWidth;
  final int scrollDurationMs;
  final int fixedDurationMs;
  final double fontSize;
  double x = 0;
  double textWidth = 0; // 文本宽度 (防重叠用, 延迟计算)
  bool done = false;
  bool _textWidthComputed = false;

  _LiveBullet({
    required this.comment,
    required this.row,
    required this.spawnedAtMs,
    required this.screenWidth,
    required this.scrollDurationMs,
    required this.fixedDurationMs,
    required this.fontSize,
  });

  void advance(int nowMs) {
    final elapsed = nowMs - spawnedAtMs;
    // ★ elapsed < 0 = 切集后时钟回退, 旧子弹已过期 → 立即标记 done 清除
    if (elapsed < 0) {
      done = true;
      return;
    }
    if (comment.mode == 1) {
      // 滚动: scrollDurationMs 走过屏幕宽
      final t = (elapsed / scrollDurationMs).clamp(0.0, 1.0);
      x = screenWidth * (1.0 - t);
      if (t >= 1.0) done = true;
    } else {
      // 固定: fixedDurationMs
      if (elapsed > fixedDurationMs) done = true;
    }
  }

  /// 延迟计算文本宽度 (在 painter 里 layout 后调)
  void ensureTextWidth(TextPainter tp) {
    if (!_textWidthComputed) {
      textWidth = tp.width;
      _textWidthComputed = true;
    }
  }
}

class _DanmakuPainter extends CustomPainter {
  final List<_LiveBullet> bullets;
  final double width;
  final double height;
  final double opacity;
  final double fontSize;
  final double areaRatio;

  _DanmakuPainter({
    required this.bullets,
    required this.width,
    required this.height,
    required this.opacity,
    required this.fontSize,
    required this.areaRatio,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bullets.isEmpty) return;
    final lineH = fontSize + 4;
    final availH = height * areaRatio;

    // 顶部行从 0 开始, 底部行从 availH - bottomH 开始
    final maxFixedRows = (availH / lineH / 2).floor().clamp(1, 8);
    final topH = maxFixedRows * lineH;
    final bottomH = maxFixedRows * lineH;
    final scrollH = (availH - topH - bottomH).clamp(0.0, availH);
    final maxScrollRows = (scrollH / lineH).floor().clamp(1, 20);
    final rowH = maxScrollRows > 0 ? scrollH / maxScrollRows : 0.0;

    final alpha = (255 * opacity).round().clamp(0, 255);

    for (final b in bullets) {
      final text = b.comment.content;
      if (text.isEmpty) continue;

      final c = b.comment.color;
      final r = (c >> 16) & 0xFF;
      final g = (c >> 8) & 0xFF;
      final bv = c & 0xFF;
      final color = Color.fromARGB(alpha, r, g, bv);

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

      // 延迟计算 textWidth (防重叠用)
      b.ensureTextWidth(tp);

      double y;
      if (b.comment.mode == 5) {
        y = 8 + b.row * lineH;
      } else if (b.comment.mode == 4) {
        y = availH - bottomH + 8 + b.row * lineH;
      } else {
        y = topH + b.row * rowH;
      }

      final dx = b.comment.mode == 1 ? b.x : (width - tp.width) / 2;
      tp.paint(canvas, Offset(dx, y));
    }
  }

  @override
  bool shouldRepaint(_DanmakuPainter old) =>
      old.bullets != bullets ||
      old.opacity != opacity ||
      old.fontSize != fontSize ||
      old.areaRatio != areaRatio;
}
