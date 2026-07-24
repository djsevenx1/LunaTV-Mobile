// lib/danmaku/models/danmaku_comment.dart
// 弹幕统一数据模型 — 对应 SeleneTV DanmakuComment(timeMs, mode, color, content)
// 6 个源反编译后都返这种结构 (iqiyi/youku/bilibili/tencent/mgtv/le)
//
// mode:  1=滚动  4=底部  5=顶部
// color: RGB 十进制, 默认 0xFFFFFF = 16777215 白

class DanmakuComment {
  final int timeMs;
  final int mode;
  final int color;
  final String content;

  const DanmakuComment({
    required this.timeMs,
    required this.mode,
    required this.color,
    required this.content,
  });

  @override
  String toString() =>
      'DanmakuComment(timeMs=$timeMs, mode=$mode, color=$color, content=$content)';
}
