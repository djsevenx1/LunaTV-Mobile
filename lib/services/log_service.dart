import 'dart:async';

/// 调试日志服务 (单例, 内存循环缓冲)
///
/// 用于在调试界面 (DebugLogScreen) 显示关键事件, 方便排查
/// 视频 resume / seek / buffering 等问题.
///
/// v1.0.62 新增. 调用 [log] / [info] / [warn] / [error] 即可写入,
/// 最多保留 [maxEntries] 条 (默认 500), 超出从头覆盖.
class LogService {
  LogService._();
  static final LogService instance = LogService._();

  /// 最大保留条数
  static const int maxEntries = 500;

  final List<LogEntry> _entries = <LogEntry>[];
  final _controller = StreamController<List<LogEntry>>.broadcast();

  /// 所有日志条目 (新到旧, 最新的在前). 每次写入后触发 stream.
  List<LogEntry> get entries => List.unmodifiable(_entries.reversed);

  /// 订阅日志变化, 用于 UI 实时刷新
  Stream<List<LogEntry>> get stream => _controller.stream;

  void log(String tag, String message) =>
      _add(LogEntry(level: LogLevel.info, tag: tag, message: message));

  void info(String tag, String message) =>
      _add(LogEntry(level: LogLevel.info, tag: tag, message: message));

  void warn(String tag, String message) =>
      _add(LogEntry(level: LogLevel.warn, tag: tag, message: message));

  void error(String tag, String message) =>
      _add(LogEntry(level: LogLevel.error, tag: tag, message: message));

  void _add(LogEntry entry) {
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    _controller.add(entries);
  }

  void clear() {
    _entries.clear();
    _controller.add(entries);
  }
}

enum LogLevel { info, warn, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  LogEntry({
    required this.level,
    required this.tag,
    required this.message,
  }) : time = DateTime.now();

  String get formattedTime =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}.'
      '${time.millisecond.toString().padLeft(3, '0')}';

  String get levelLabel {
    switch (level) {
      case LogLevel.info:
        return 'INFO';
      case LogLevel.warn:
        return 'WARN';
      case LogLevel.error:
        return 'ERROR';
    }
  }
}
