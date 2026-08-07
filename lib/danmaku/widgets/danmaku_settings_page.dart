// lib/danmaku/widgets/danmaku_settings_page.dart
// 弹幕设置子页面 — 从设置页点「弹幕设置」进入
//   包含: 弹幕源开关 (6源) + 弹幕显示设置 (透明度/速度/字体/密度/防重叠/区域/模式)
//   v2.5.48: 从 user_menu 内联展开改为独立子页面, 节省设置页空间

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../utils/font_utils.dart';
import '../danmaku_settings.dart';
import '../models/danmaku_media.dart';
import 'danmaku_settings_sheet.dart';

class DanmakuSettingsPage extends StatefulWidget {
  final bool isDarkMode;

  const DanmakuSettingsPage({super.key, required this.isDarkMode});

  @override
  State<DanmakuSettingsPage> createState() => _DanmakuSettingsPageState();
}

class _DanmakuSettingsPageState extends State<DanmakuSettingsPage> {
  @override
  void initState() {
    super.initState();
    DanmakuSettings.instance.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  Widget _buildIconContainer(IconData icon, Color iconColor) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: iconColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 18, color: iconColor),
    );
  }

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.only(left: 60),
      child: Container(
        height: 0.5,
        color: widget.isDarkMode
            ? const Color(0xFF374151)
            : const Color(0xFFe5e7eb),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      child: Text(
        title,
        style: FontUtils.poppins(
          context,
          fontSize: 13,
          color: widget.isDarkMode
              ? const Color(0xFF9ca3af)
              : const Color(0xFF6b7280),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildCard({required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? const Color(0xFF1F2937) : Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  Widget _buildToggleOption({
    required String title,
    required bool value,
    required Future<void> Function(bool) onChanged,
    required IconData icon,
    required Color iconColor,
  }) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            _buildIconContainer(icon, iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: FontUtils.poppins(
                  context,
                  fontSize: 16,
                  color: widget.isDarkMode
                      ? const Color(0xFFffffff)
                      : const Color(0xFF1f2937),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            GestureDetector(
              onTap: () async {
                await onChanged(!value);
                if (mounted) setState(() {});
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 44,
                height: 24,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: value
                      ? const Color(0xFF10b981)
                      : (widget.isDarkMode
                          ? const Color(0xFF374151)
                          : const Color(0xFFd1d5db)),
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 200),
                  alignment:
                      value ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: 20,
                    height: 20,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.15),
                          blurRadius: 2,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionItem({
    required String title,
    required IconData icon,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              _buildIconContainer(icon, iconColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: FontUtils.poppins(
                    context,
                    fontSize: 16,
                    color: widget.isDarkMode
                        ? const Color(0xFFffffff)
                        : const Color(0xFF1f2937),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          widget.isDarkMode ? const Color(0xFF111827) : const Color(0xFFf3f4f6),
      appBar: AppBar(
        title: Text(
          '弹幕设置',
          style: FontUtils.poppins(
            context,
            fontSize: 18,
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor:
            widget.isDarkMode ? const Color(0xFF1F2937) : const Color(0xFF10b981),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        children: [
          // 弹幕源开关
          _buildSectionHeader('弹幕源'),
          _buildCard(
            children: [
              ...DanmakuSource.values.map((s) {
                final enabled = DanmakuSettings.instance.isSourceEnabled(s);
                return Column(
                  children: [
                    _buildToggleOption(
                      title: s.displayName,
                      value: enabled,
                      onChanged: (value) async {
                        await DanmakuSettings.instance.toggleSource(s, value);
                      },
                      icon: Icons.dns_rounded,
                      iconColor: const Color(0xFF22C55E),
                    ),
                    if (s != DanmakuSource.values.last) _buildDivider(),
                  ],
                );
              }),
            ],
          ),
          // 显示设置
          _buildSectionHeader('显示'),
          _buildCard(
            children: [
              _buildActionItem(
                title: '弹幕显示设置',
                icon: Icons.tune_rounded,
                iconColor: const Color(0xFF3b82f6),
                onTap: () {
                  DanmakuSettingsSheet.show(context);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
