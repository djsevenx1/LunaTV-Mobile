// lib/danmaku/danmaku_settings.dart
// 弹幕设置模型 + SharedPreferences 持久化
//
// 移植自 SeleneTV 反编译代码:
//   Ldh0; (DanmakuRenderSettings) — opacity/speed/fontScale/densityPct/antiOverlap
//   Lhi0; (DanmakuAreaOption list) — off/third/half/full
//   Llj; (Settings holder) — danmaku_mode / danmaku_area / danmaku_last_area
//
// SharedPreferences key 名称与 SeleneTV 完全一致:
//   danmaku_opacity      (float)
//   danmaku_speed        (float)
//   danmaku_font_scale   (float)
//   danmaku_density_pct  (int)
//   danmaku_anti_overlap (bool)
//   danmaku_area         (String: off/third/half/full)
//   danmaku_last_area    (String)
//   danmaku_mode         (String: all/scroll/top/bottom)

import 'package:shared_preferences/shared_preferences.dart';

/// 弹幕渲染设置 — 对应 SeleneTV Ldh0; (DanmakuRenderSettings)
///
/// 字段 a~e 对应反编译:
///   a F  = opacity        透明度
///   b F  = speed          速度倍率
///   c F  = fontScale      字体缩放
///   d I  = densityPct     密度百分比
///   e Z  = antiOverlap    防重叠
class DanmakuRenderSettings {
  final double opacity;
  final double speed;
  final double fontScale;
  final int densityPct;
  final bool antiOverlap;

  const DanmakuRenderSettings({
    this.opacity = 1.0,
    this.speed = 1.0,
    this.fontScale = 1.0,
    this.densityPct = 100,
    this.antiOverlap = false,
  });

  /// copyWith — 对应 SeleneTV Ldh0;.a() (copy with bitmask)
  DanmakuRenderSettings copyWith({
    double? opacity,
    double? speed,
    double? fontScale,
    int? densityPct,
    bool? antiOverlap,
  }) {
    return DanmakuRenderSettings(
      opacity: opacity ?? this.opacity,
      speed: speed ?? this.speed,
      fontScale: fontScale ?? this.fontScale,
      densityPct: densityPct ?? this.densityPct,
      antiOverlap: antiOverlap ?? this.antiOverlap,
    );
  }

  @override
  String toString() =>
      'DanmakuRenderSettings(opacity=$opacity, speed=$speed, '
      'fontScale=$fontScale, densityPct=$densityPct, antiOverlap=$antiOverlap)';
}

/// 弹幕区域选项 — 对应 SeleneTV Lqg0; (DanmakuAreaOption)
class DanmakuAreaOption {
  final String key;
  final String label;
  final double ratio; // 屏幕高度占比

  const DanmakuAreaOption(this.key, this.label, this.ratio);

  static const off = DanmakuAreaOption('off', '关闭', 0.0);
  static const third = DanmakuAreaOption('third', '1/3 屏', 1.0 / 3.0);
  static const half = DanmakuAreaOption('half', '半屏', 0.5);
  static const full = DanmakuAreaOption('full', '全屏', 1.0);

  /// 对应 SeleneTV Lhi0;.a (DanmakuAreaOption list)
  static const List<DanmakuAreaOption> all = [off, third, half, full];

  static DanmakuAreaOption fromKey(String? key) {
    switch (key) {
      case 'off':
        return off;
      case 'third':
        return third;
      case 'half':
        return half;
      case 'full':
      default:
        return full;
    }
  }
}

/// 弹幕显示模式 — danmaku_mode (String)
enum DanmakuMode {
  all('all', '全部'),
  scroll('scroll', '仅滚动'),
  top('top', '仅顶部'),
  bottom('bottom', '仅底部');

  final String key;
  final String label;
  const DanmakuMode(this.key, this.label);

  static DanmakuMode fromKey(String? key) {
    switch (key) {
      case 'scroll':
        return scroll;
      case 'top':
        return top;
      case 'bottom':
        return bottom;
      case 'all':
      default:
        return all;
    }
  }
}

/// 设置档位常量 — 对应 SeleneTV Ldh0; <clinit> 静态列表 f/g/h/i
class DanmakuSettingOptions {
  /// Ldh0;.f — 透明度档位
  static const List<double> opacitySteps = [0.4, 0.55, 0.7, 0.85, 1.0];

  /// Ldh0;.g — 速度档位
  static const List<double> speedSteps = [0.5, 0.75, 1.0, 1.5, 2.0];

  /// Ldh0;.h — 字体缩放档位
  static const List<double> fontScaleSteps = [0.7, 0.85, 1.0, 1.2, 1.4];

  /// Ldh0;.i — 密度档位
  static const List<int> densitySteps = [25, 50, 75, 100];
}

/// 弹幕设置管理器 — 对应 SeleneTV Llj; (SharedPreferences 读写)
///
/// 读写与 SeleneTV 完全一致的 SharedPreferences key, 保证
/// 两个 app 互换时不丢设置.
class DanmakuSettings {
  DanmakuSettings._();
  static final DanmakuSettings instance = DanmakuSettings._();

  // === SharedPreferences key (与 SeleneTV Llj; 完全一致) ===
  static const _kOpacity = 'danmaku_opacity';
  static const _kSpeed = 'danmaku_speed';
  static const _kFontScale = 'danmaku_font_scale';
  static const _kDensityPct = 'danmaku_density_pct';
  static const _kAntiOverlap = 'danmaku_anti_overlap';
  static const _kArea = 'danmaku_area';
  static const _kLastArea = 'danmaku_last_area';
  static const _kMode = 'danmaku_mode';

  SharedPreferences? _prefs;
  DanmakuRenderSettings _render = const DanmakuRenderSettings();
  DanmakuAreaOption _area = DanmakuAreaOption.full;
  DanmakuAreaOption _lastArea = DanmakuAreaOption.full;
  DanmakuMode _mode = DanmakuMode.all;

  DanmakuRenderSettings get render => _render;
  DanmakuAreaOption get area => _area;
  DanmakuAreaOption get lastArea => _lastArea;
  DanmakuMode get mode => _mode;

  /// 初始化 — 从 SharedPreferences 读取全部设置
  /// 对应 SeleneTV Llj; 初始化逻辑
  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _render = DanmakuRenderSettings(
      opacity: _prefs!.getDouble(_kOpacity) ?? 1.0,
      speed: _prefs!.getDouble(_kSpeed) ?? 1.0,
      fontScale: _prefs!.getDouble(_kFontScale) ?? 1.0,
      densityPct: _prefs!.getInt(_kDensityPct) ?? 100,
      antiOverlap: _prefs!.getBool(_kAntiOverlap) ?? false,
    );
    _area = DanmakuAreaOption.fromKey(_prefs!.getString(_kArea));
    _lastArea = DanmakuAreaOption.fromKey(_prefs!.getString(_kLastArea));
    _mode = DanmakuMode.fromKey(_prefs!.getString(_kMode));
  }

  /// 保存渲染设置 — 对应 SeleneTV Lo9; 里 putFloat/putInt/putBoolean 全部5个key
  Future<void> saveRenderSettings(DanmakuRenderSettings s) async {
    _render = s;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setDouble(_kOpacity, s.opacity);
    await _prefs!.setDouble(_kSpeed, s.speed);
    await _prefs!.setDouble(_kFontScale, s.fontScale);
    await _prefs!.setInt(_kDensityPct, s.densityPct);
    await _prefs!.setBool(_kAntiOverlap, s.antiOverlap);
  }

  /// 保存区域 — 对应 SeleneTV Lij; case: putString("danmaku_area", ...)
  Future<void> saveArea(DanmakuAreaOption a) async {
    _area = a;
    if (a.key != 'off') _lastArea = a; // 记住上次的非关闭区域
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_kArea, a.key);
    if (a.key != 'off') {
      await _prefs!.setString(_kLastArea, a.key);
    }
  }

  /// 保存模式 — 对应 SeleneTV Lij; case: putString("danmaku_mode", ...)
  Future<void> saveMode(DanmakuMode m) async {
    _mode = m;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_kMode, m.key);
  }

  /// 快捷: 当 area=off 时, 恢复到上次的非关闭区域
  /// 对应 SeleneTV Llj;->d (danmaku_last_area) 的用途
  DanmakuAreaOption get restoreArea =>
      _lastArea.key != 'off' ? _lastArea : DanmakuAreaOption.full;
}
