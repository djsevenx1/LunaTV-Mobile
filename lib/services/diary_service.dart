import 'package:flutter/foundation.dart';

/// v2.0.99.2: 应用内「日记」服务 — 维护一个内存 List<String> 日志, 失败 / 关键事件
///   都打进去, 用户菜单「日记」行跳到 DiaryScreen 看到全流程. 跟 adb logcat
///   互补: adb logcat 是开发者视角, 日记是普通用户视角 (不用接电脑). 跟
///   v2.0.91 删的「log UI」区别: 那个是开发者 log 实时浮层 ([VideoProxy] xxx 一直
///   滚), 这次是独立日记页面 (按时间序, 用户主动点开, 不打扰).
///
/// 用法 (调用方):
///   - `DiaryService.add('[TMDB] search: title="X" year=2025')` — 成功路径
///   - `DiaryService.add('[TMDB] error: $e')` — 失败路径
///   - `DiaryService.add('[Network] timeout after 10s')` — 网络错
///
/// 设计取舍:
///   - **单例 + 内存 List<String>**: 简单, 不存盘 (失败排查是会话内的事, 退出 app
///     清空合理). 如果想存盘加 SharedPreferences, 跟 v2.0.93 TMDB 缓存命名空间一致
///   - **容量 500 条 FIFO**: 够用, 多了会撑爆内存. 跟 adb logcat buffer 类似
///   - **格式 '[分类] 描述'**: 跟 v2.0.95 debugPrint `[TMDB] xxx` 风格一致, 日记
///     里直接看, 不用前端加分类列
///   - **同时打 debugPrint**: 跟 v2.0.95 行为一致, adb logcat 仍能看到全流程
///   - **不存盘避免隐私问题**: TMDB search title 可能是用户私人观影记录, 不应该
///     存到 SharedPreferences 跨会话保留. 内存里退出 app 就清
class DiaryService {
  static final List<String> _entries = <String>[];
  static const int _maxEntries = 500;

  /// 加一条日记, 自动 prepend 时间戳, FIFO 容量限制.
  /// 调用方写 `[分类] 描述` (e.g. `[TMDB] search: title="X" year=2025`).
  static void add(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 19); // HH:mm:ss
    final entry = '[$ts] $message';
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    // 跟 v2.0.95 行为一致, debugPrint 保留给 adb 开发者
    debugPrint('[Diary] $message');
  }

  /// 清空日记 (UI 上有「清空」按钮调这个).
  static void clear() {
    _entries.clear();
  }

  /// 拿全部日记 (UI 上 ListView 显示).
  /// 返回 copy, 调用方不能改内部 List.
  static List<String> getAll() {
    return List<String>.from(_entries);
  }

  /// 当前条数 (UI 顶部显示「共 N 条」).
  static int get length => _entries.length;
}
