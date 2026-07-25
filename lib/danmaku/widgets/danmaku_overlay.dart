// lib/danmaku/widgets/danmaku_overlay.dart
// 弹幕浮层 — 视频上层透明 Stack, 用 CustomPainter 滚动画
//
// v2.5.53: 修复两大 bug:
//   1. 1/3屏重叠: _spawn 和 painter 行数计算不一致
//      - spawn 用 availH/lineH 算滚动行数 (13行)
//      - painter 先扣 top/bottom 各一半, scrollH 只剩 24px (1行)
//      - spawn 分配 13 行, painter 按 1 行画 → 行间距错 → 重叠
//      修法: 统一用 _DanmakuLayout 算, spawn 和 painter 共享同一套行数
//   2. 仅顶部不显示: 模式感知空间分配
//      - 旧: 不管什么模式, top/bottom 各占 availH/2 → 顶部只有 6 行
//      - 新: 仅顶部时全部空间给 top → 顶部有 13 行, 更容易显示

import 'package:flutter/material.dart';

import '../danmaku_settings.dart';
import '../models/danmaku_comment.dart';

class DanmakuOverlay extends StatefulWidget {
  final List<DanmakuComment> comments;
  final bool enabled;
  final double opacity;
  final double fontSize;
  final double speed;
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

  List<DanmakuComment> _sorted = const [];
  final Set<int> _spawnedHashes = {};
  bool _commentsChanged = false;
  bool _needsBackfill = true;

  static const int _maxScrollRows = 20;
  final List<_TrackState> _scrollTracks = List.generate(_maxScrollRows, (_) => _TrackState());
  static const int _maxFixedRows = 8;
  final List<_TrackState> _topTracks = List.generate(_maxFixedRows, (_) => _TrackState());
  final List<_TrackState> _bottomTracks = List.generate(_maxFixedRows, (_) => _TrackState());

  Duration _mediaPos = Duration.zero;
  DateTime _lastWall = DateTime.now();
  bool _paused = false;

  DanmakuRenderSettings _settings = const DanmakuRenderSettings();
  DanmakuAreaOption _area = DanmakuAreaOption.full;
  DanmakuMode _mode = DanmakuMode.all;

  int _densityCounter = 0;

  static const double _baseFontSize = 16.0;
  static const int _scrollDurationMs = 8000;
  static const int _fixedDurationMs = 4000;
  static const double _trackGap = 4.0;
  static const double _antiOverlapGap = 12.0;

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
    _spawnedHashes.clear();
    _commentsChanged = true;
    _needsBackfill = true;
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.comments, widget.comments)) {
      _commentsChanged = true;
      reset();
    }
  }

  void refreshSettings() {
    final s = DanmakuSettings.instance;
    setState(() {
      _settings = s.render;
      _area = s.area;
      _mode = s.mode;
    });
    // v2.5.53: 切模式/区域时重置轨道, 让新布局立即生效
    reset();
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
    for (final b in _live) {
      b.advance(_mediaPos.inMilliseconds);
    }
    final beforeLen = _live.length;
    _live.removeWhere((b) => b.done);
    if (_live.length < beforeLen) {
      final liveHashes = _live.map((b) => identityHashCode(b.comment)).toSet();
      _spawnedHashes.removeWhere((h) => !liveHashes.contains(h));
    }

    if (_lastTickMs >= 50) {
      _lastTickMs = 0;
      if (mounted) setState(() {});
    }
  }

  double _effectiveSpeed() {
    return widget.speed != 1.0 ? widget.speed : _settings.speed;
  }

  double _effectiveOpacity() {
    return widget.opacity != 1.0 ? widget.opacity : _settings.opacity;
  }

  double _effectiveFontSize() {
    return _baseFontSize * _settings.fontScale;
  }

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

  bool _shouldShowByDensity() {
    if (_settings.densityPct >= 100) return true;
    _densityCounter = (_densityCounter + 1) % 100;
    return _densityCounter < _settings.densityPct;
  }

  // ★ v2.5.53: 统一布局计算 — spawn 和 painter 共用, 杜绝行数不一致
  //   模式感知:
  //     - 仅顶部: 全部空间给 top, scroll/bottom = 0
  //     - 仅底部: 全部空间给 bottom, scroll/top = 0
  //     - 仅滚动: 全部空间给 scroll, top/bottom = 0
  //     - 全部: top 和 bottom 各占 1/4, scroll 占 1/2
  static _DanmakuLayout _calcLayout(
    double availH,
    double lineH,
    DanmakuMode mode,
  ) {
    int maxScrollRows, maxTopRows, maxBottomRows;

    switch (mode) {
      case DanmakuMode.top:
        maxTopRows = (availH / lineH).floor().clamp(1, _maxFixedRows);
        maxScrollRows = 0;
        maxBottomRows = 0;
        break;
      case DanmakuMode.bottom:
        maxBottomRows = (availH / lineH).floor().clamp(1, _maxFixedRows);
        maxScrollRows = 0;
        maxTopRows = 0;
        break;
      case DanmakuMode.scroll:
        maxScrollRows = (availH / lineH).floor().clamp(1, _maxScrollRows);
        maxTopRows = 0;
        maxBottomRows = 0;
        break;
      case DanmakuMode.all:
        // top/bottom 各占 1/4, scroll 占 1/2
        final fixedH = availH * 0.25;
        maxTopRows = (fixedH / lineH).floor().clamp(1, _maxFixedRows);
        maxBottomRows = (fixedH / lineH).floor().clamp(1, _maxFixedRows);
        final scrollH = availH - maxTopRows * lineH - maxBottomRows * lineH;
        maxScrollRows = (scrollH / lineH).floor().clamp(1, _maxScrollRows);
        break;
    }

    final topH = maxTopRows * lineH;
    final bottomH = maxBottomRows * lineH;
    final scrollH = (availH - topH - bottomH).clamp(0.0, availH);
    final rowH = maxScrollRows > 0 ? scrollH / maxScrollRows : 0.0;

    return _DanmakuLayout(
      maxScrollRows: maxScrollRows,
      maxTopRows: maxTopRows,
      maxBottomRows: maxBottomRows,
      topH: topH,
      bottomH: bottomH,
      scrollH: scrollH,
      rowH: rowH,
      lineH: lineH,
    );
  }

  @override
  Widget build(BuildContext context) {
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
              mode: _mode,
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
    final availH = h * _area.ratio;

    // ★ v2.5.53: 用统一的布局计算 (跟 painter 一致)
    final layout = _calcLayout(availH, lineH, _mode);

    if (_commentsChanged) {
      _sorted = List.of(widget.comments)
        ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
      _commentsChanged = false;
    }
    if (_sorted.isEmpty) return;

    final windowEnd = current + 200;
    final int windowStart;
    if (_needsBackfill) {
      windowStart = 0;
      _needsBackfill = false;
    } else {
      windowStart = current - 30000;
    }

    int lo = 0, hi = _sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_sorted[mid].timeMs <= windowStart) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }

    for (var i = lo; i < _sorted.length; i++) {
      final c = _sorted[i];
      if (c.timeMs > windowEnd) break;

      final hash = identityHashCode(c);
      if (_spawnedHashes.contains(hash)) continue;
      if (_live.any((b) => identical(b.comment, c))) continue;

      if (!_shouldShowByMode(c.mode)) continue;
      if (!_shouldShowByDensity()) continue;

      final track = _pickTrack(c.mode, current, w, layout);
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
      _spawnedHashes.add(hash);

      if (c.mode == 1) {
        _scrollTracks[track].lastBullet = bullet;
      } else if (c.mode == 5) {
        _topTracks[track].lastBullet = bullet;
      } else if (c.mode == 4) {
        _bottomTracks[track].lastBullet = bullet;
      }
    }
  }

  // ★ v2.5.53: 用 layout 统一算行数, 不再各算各的
  int _pickTrack(
    int mode,
    int nowMs,
    double w,
    _DanmakuLayout layout,
  ) {
    if (mode == 5) {
      // 顶部固定
      for (var i = 0; i < layout.maxTopRows; i++) {
        if (_topTracks[i].freeAtMs <= nowMs) {
          _topTracks[i].freeAtMs = nowMs + _fixedDurationMs;
          return i;
        }
      }
      return -1;
    }
    if (mode == 4) {
      // 底部固定
      for (var i = 0; i < layout.maxBottomRows; i++) {
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
    for (var i = 0; i < layout.maxScrollRows; i++) {
      final track = _scrollTracks[i];
      if (track.freeAtMs <= nowMs) {
        if (_settings.antiOverlap && track.lastBullet != null) {
          final last = track.lastBullet!;
          final elapsed = nowMs - last.spawnedAtMs;
          if (elapsed >= 0 && elapsed < scrollMs) {
            final t = (elapsed / scrollMs).clamp(0.0, 1.0);
            final lastRightEdge = w * (1.0 - t) + last.textWidth;
            if (lastRightEdge > _antiOverlapGap) continue;
          }
        }
        track.freeAtMs = nowMs + (scrollMs * 0.5).round();
        return i;
      }
    }
    return -1;
  }
}

/// ★ v2.5.53: 统一布局计算结果 — spawn 和 painter 共用
class _DanmakuLayout {
  final int maxScrollRows;
  final int maxTopRows;
  final int maxBottomRows;
  final double topH;
  final double bottomH;
  final double scrollH;
  final double rowH;
  final double lineH;

  const _DanmakuLayout({
    required this.maxScrollRows,
    required this.maxTopRows,
    required this.maxBottomRows,
    required this.topH,
    required this.bottomH,
    required this.scrollH,
    required this.rowH,
    required this.lineH,
  });
}

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
  double textWidth = 0;
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
    if (elapsed < 0) {
      done = true;
      return;
    }
    if (comment.mode == 1) {
      final t = (elapsed / scrollDurationMs).clamp(0.0, 1.0);
      x = screenWidth * (1.0 - t);
      if (t >= 1.0) done = true;
    } else {
      if (elapsed > fixedDurationMs) done = true;
    }
  }

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
  final DanmakuMode mode; // ★ v2.5.53: 传入模式, 统一布局

  _DanmakuPainter({
    required this.bullets,
    required this.width,
    required this.height,
    required this.opacity,
    required this.fontSize,
    required this.areaRatio,
    required this.mode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bullets.isEmpty) return;
    final lineH = fontSize + 4;
    final availH = height * areaRatio;

    // ★ v2.5.53: 用跟 spawn 完全一致的布局计算
    final layout = DanmakuOverlayState._calcLayout(availH, lineH, mode);

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

      b.ensureTextWidth(tp);

      double y;
      if (b.comment.mode == 5) {
        // 顶部固定: 从顶部往下排
        y = 8 + b.row * lineH;
      } else if (b.comment.mode == 4) {
        // 底部固定: 从底部往上排
        y = availH - layout.bottomH + 8 + b.row * lineH;
      } else {
        // 滚动: 在 topH 和 bottomH 之间排
        y = layout.topH + b.row * layout.rowH;
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
      old.areaRatio != areaRatio ||
      old.mode != mode;
}
