// lib/danmaku/widgets/danmaku_settings_sheet.dart
// 弹幕设置面板 — 底部弹出 Sheet
//
// 移植自 SeleneTV 反编译的 Composable (Lo9; + Ldh0;):
//   - 透明度 Slider  (5 档: 0.4/0.55/0.7/0.85/1.0)
//   - 速度    Slider  (5 档: 0.5/0.75/1.0/1.5/2.0)
//   - 字体    Slider  (5 档: 0.7/0.85/1.0/1.2/1.4)
//   - 密度    Slider  (4 档: 25/50/75/100)
//   - 防重叠  Switch
//   - 显示区域  4 选 (关闭/1/3/半屏/全屏)
//   - 显示模式  4 选 (全部/仅滚动/仅顶部/仅底部)
//
// 每次改动立即写 SharedPreferences (同名 key), 关闭 Sheet 后
// 通过 onChanged 回调通知 player 刷新 overlay.

import 'package:flutter/material.dart';

import '../danmaku_settings.dart';

class DanmakuSettingsSheet extends StatefulWidget {
  final VoidCallback? onChanged;

  const DanmakuSettingsSheet({super.key, this.onChanged});

  /// 弹出设置面板
  static Future<void> show(BuildContext context, {VoidCallback? onChanged}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DanmakuSettingsSheet(onChanged: onChanged),
    );
  }

  @override
  State<DanmakuSettingsSheet> createState() => _DanmakuSettingsSheetState();
}

class _DanmakuSettingsSheetState extends State<DanmakuSettingsSheet> {
  late DanmakuRenderSettings _render;
  late DanmakuAreaOption _area;
  late DanmakuMode _mode;

  @override
  void initState() {
    super.initState();
    final s = DanmakuSettings.instance;
    _render = s.render;
    _area = s.area;
    _mode = s.mode;
  }

  void _notifyChanged() {
    widget.onChanged?.call();
  }

  // === 档位 Slider helper ===
  // SeleneTV 用离散档位 (List), 不是连续 Slider.
  // 用 Slider + divisions 实现, label 显示当前值.

  Widget _buildStepSlider({
    required String title,
    required String subtitle,
    required List<double> steps,
    required double value,
    required String Function(double) labelBuilder,
    required ValueChanged<double> onChanged,
  }) {
    final idx = _closestIndex(steps, value);
    return _SettingTile(
      title: title,
      subtitle: subtitle,
      trailing: Text(
        labelBuilder(steps[idx]),
        style: TextStyle(
          fontSize: 13,
          color: Colors.grey[400],
          fontWeight: FontWeight.w500,
        ),
      ),
      child: Slider(
        value: idx.toDouble(),
        min: 0,
        max: (steps.length - 1).toDouble(),
        divisions: steps.length - 1,
        activeColor: const Color(0xFF22C55E),
        label: labelBuilder(steps[idx]),
        onChanged: (v) {
          final newIdx = v.round();
          onChanged(steps[newIdx]);
        },
      ),
    );
  }

  Widget _buildIntStepSlider({
    required String title,
    required String subtitle,
    required List<int> steps,
    required int value,
    required String Function(int) labelBuilder,
    required ValueChanged<int> onChanged,
  }) {
    final idx = _closestIntIndex(steps, value);
    return _SettingTile(
      title: title,
      subtitle: subtitle,
      trailing: Text(
        labelBuilder(steps[idx]),
        style: TextStyle(
          fontSize: 13,
          color: Colors.grey[400],
          fontWeight: FontWeight.w500,
        ),
      ),
      child: Slider(
        value: idx.toDouble(),
        min: 0,
        max: (steps.length - 1).toDouble(),
        divisions: steps.length - 1,
        activeColor: const Color(0xFF22C55E),
        label: labelBuilder(steps[idx]),
        onChanged: (v) {
          final newIdx = v.round();
          onChanged(steps[newIdx]);
        },
      ),
    );
  }

  int _closestIndex(List<double> steps, double v) {
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < steps.length; i++) {
      final d = (steps[i] - v).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  int _closestIntIndex(List<int> steps, int v) {
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < steps.length; i++) {
      final d = (steps[i] - v).abs().toDouble();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  // === 区域选择 (4 个 chip) ===
  Widget _buildAreaSelector() {
    return _SettingTile(
      title: '显示区域',
      subtitle: '弹幕占据屏幕高度',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: DanmakuAreaOption.all.map((a) {
          final selected = _area.key == a.key;
          return ChoiceChip(
            label: Text(a.label),
            selected: selected,
            selectedColor: const Color(0xFF22C55E),
            labelStyle: TextStyle(
              color: selected ? Colors.white : Colors.grey[300],
              fontSize: 13,
            ),
            onSelected: (_) {
              setState(() => _area = a);
              DanmakuSettings.instance.saveArea(a);
              _notifyChanged();
            },
          );
        }).toList(),
      ),
    );
  }

  // === 模式选择 (4 个 chip) ===
  Widget _buildModeSelector() {
    return _SettingTile(
      title: '显示模式',
      subtitle: '选择弹幕类型',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: DanmakuMode.values.map((m) {
          final selected = _mode.key == m.key;
          return ChoiceChip(
            label: Text(m.label),
            selected: selected,
            selectedColor: const Color(0xFF22C55E),
            labelStyle: TextStyle(
              color: selected ? Colors.white : Colors.grey[300],
              fontSize: 13,
            ),
            onSelected: (_) {
              setState(() => _mode = m);
              DanmakuSettings.instance.saveMode(m);
              _notifyChanged();
            },
          );
        }).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A2E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖拽条
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 标题栏
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.subtitles, color: Color(0xFF22C55E), size: 22),
                  const SizedBox(width: 8),
                  const Text(
                    '弹幕设置',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('完成', style: TextStyle(color: Color(0xFF22C55E))),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF2A2A4E), height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  // 透明度 — Ldh0;.f 档位
                  _buildStepSlider(
                    title: '透明度',
                    subtitle: '弹幕不透明度',
                    steps: DanmakuSettingOptions.opacitySteps,
                    value: _render.opacity,
                    labelBuilder: (v) => '${(v * 100).round()}%',
                    onChanged: (v) {
                      setState(() => _render = _render.copyWith(opacity: v));
                      DanmakuSettings.instance.saveRenderSettings(_render);
                      _notifyChanged();
                    },
                  ),
                  // 速度 — Ldh0;.g 档位
                  _buildStepSlider(
                    title: '滚动速度',
                    subtitle: '弹幕滚动速度倍率',
                    steps: DanmakuSettingOptions.speedSteps,
                    value: _render.speed,
                    labelBuilder: (v) => '${v}x',
                    onChanged: (v) {
                      setState(() => _render = _render.copyWith(speed: v));
                      DanmakuSettings.instance.saveRenderSettings(_render);
                      _notifyChanged();
                    },
                  ),
                  // 字体 — Ldh0;.h 档位
                  _buildStepSlider(
                    title: '字体大小',
                    subtitle: '弹幕字体缩放',
                    steps: DanmakuSettingOptions.fontScaleSteps,
                    value: _render.fontScale,
                    labelBuilder: (v) => '${(v * 100).round()}%',
                    onChanged: (v) {
                      setState(() => _render = _render.copyWith(fontScale: v));
                      DanmakuSettings.instance.saveRenderSettings(_render);
                      _notifyChanged();
                    },
                  ),
                  // 密度 — Ldh0;.i 档位
                  _buildIntStepSlider(
                    title: '弹幕密度',
                    subtitle: '同屏最大弹幕条数占比',
                    steps: DanmakuSettingOptions.densitySteps,
                    value: _render.densityPct,
                    labelBuilder: (v) => '$v%',
                    onChanged: (v) {
                      setState(() => _render = _render.copyWith(densityPct: v));
                      DanmakuSettings.instance.saveRenderSettings(_render);
                      _notifyChanged();
                    },
                  ),
                  // 防重叠 — Ldh0;.e (boolean)
                  _SettingTile(
                    title: '防重叠',
                    subtitle: '避免弹幕重叠在一起',
                    trailing: Switch(
                      value: _render.antiOverlap,
                      activeColor: const Color(0xFF22C55E),
                      onChanged: (v) {
                        setState(() => _render = _render.copyWith(antiOverlap: v));
                        DanmakuSettings.instance.saveRenderSettings(_render);
                        _notifyChanged();
                      },
                    ),
                  ),
                  const Divider(color: Color(0xFF2A2A4E), height: 1),
                  // 显示区域 — Lhi0;.a (DanmakuAreaOption list)
                  _buildAreaSelector(),
                  // 显示模式 — danmaku_mode
                  _buildModeSelector(),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设置项 tile — 标题 + 副标题 + 可选 trailing + 可选 child (slider)
class _SettingTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? trailing;
  final Widget? child;

  const _SettingTile({
    required this.title,
    required this.subtitle,
    this.trailing,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.grey[500],
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          if (child != null) ...[
            const SizedBox(height: 4),
            child!,
          ],
        ],
      ),
    );
  }
}
