// v2.0.42: 视频代理日志缓冲 — 让玩家屏幕左上角"日记"按钮能看 [VideoProxy] 输出
//
// 背景: v2.0.40 加了 11 处 [VideoProxy] print 诊断, 让用户 logcat 抓 0 B/s 真因.
//   但用户反馈"我不会 logcat, 要不在播放器左上角搞个日记?"
//   v2.0.42 把 print 输出也同步到一个静态环形 buffer, 玩家屏幕顶部加个按钮
//   弹底部 sheet 显示 buffer 内容, 带复制 / 清空按钮, 用户截图或粘出来就能给开发者看.
//
// 设计:
//   - 静态 List<String>, 全局共享, 不依赖 widget 生命周期
//   - 上限 200 行, FIFO 滚动 (满了丢最早)
//   - 每行带时间戳 HH:MM:SS.mmm, 跟 adb logcat 时间精度一致
//   - append 同时打 print (开发者用 adb logcat 也能看到, 双通道)
//   - 线程安全: Dart 单线程 event loop, 不需要锁
//   - 静态 API 简单: append / lines / clear / linesAsString
//
// 跟 v2.0.40 + v2.0.41 兼容: print() 输出不变 (双写), 老的 logcat 抓法照样能用.
class VideoProxyLog {
  // v2.0.42: 静态环形 buffer, 上限 200 行
  static const int _maxLines = 200;
  static final List<String> _lines = <String>[];

  /// 加一行日志. 自动加 HH:MM:SS.mmm 时间戳, 同时打 print.
  ///
  /// 建议调用方传 `[VideoProxy] xxx` 前缀的字符串, 跟之前 print 一致, 方便
  /// adb logcat 抓 (filter `\\[VideoProxy\\]`).
  static void append(String line) {
    final now = DateTime.now();
    // ISO8601 substring: 1970-01-01T00:00:00.000 → 取 11..23 是 HH:MM:SS.mmm
    final ts = now.toIso8601String().substring(11, 23);
    final stamped = '[$ts] $line';
    _lines.add(stamped);
    if (_lines.length > _maxLines) {
      _lines.removeAt(0);
    }
    // 同步 print, adb logcat 还能抓 (跟 v2.0.40 行为一致)
    // ignore: avoid_print
    print(line);
  }

  /// 只读快照, UI 显示用.
  static List<String> get lines => List.unmodifiable(_lines);

  /// 拼成单个字符串, 复制按钮用. 行用 \n 拼.
  static String linesAsString() => _lines.join('\n');

  /// 清空 buffer. UI 上的"清空"按钮调这个.
  static void clear() => _lines.clear();
}
