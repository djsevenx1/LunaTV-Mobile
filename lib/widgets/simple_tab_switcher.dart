import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import '../utils/device_utils.dart';
import '../utils/font_utils.dart';

class SimpleTabSwitcher extends StatelessWidget {
  final List<String> tabs;
  final String selectedTab;
  final Function(String) onTabChanged;

  const SimpleTabSwitcher({
    super.key,
    required this.tabs,
    required this.selectedTab,
    required this.onTabChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return Container(
          height: 32, // 与 CapsuleTabSwitcher 相同的高度
          margin: const EdgeInsets.symmetric(
              vertical: 4), // 与 CapsuleTabSwitcher 相同的 margin
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: tabs.map((tab) {
                final isSelected = tab == selectedTab;
                return _SimpleTabHover(
                  isPC: DeviceUtils.isPC(),
                  isSelected: isSelected,
                  label: tab,
                  themeService: themeService,
                  onTap: () => onTabChanged(tab),
                );
              }).toList(),
            ),
          ),
        );
      },
    );
  }
}

// Hover widget for SimpleTab on PC
class _SimpleTabHover extends StatefulWidget {
  final bool isPC;
  final bool isSelected;
  final String label;
  final ThemeService themeService;
  final VoidCallback onTap;

  const _SimpleTabHover({
    required this.isPC,
    required this.isSelected,
    required this.label,
    required this.themeService,
    required this.onTap,
  });

  @override
  State<_SimpleTabHover> createState() => _SimpleTabHoverState();
}

class _SimpleTabHoverState extends State<_SimpleTabHover> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    // 计算颜色
    Color color;
    if (widget.isSelected) {
      // 选中状态：绿色
      color = const Color(0xFF27AE60);
    } else if (widget.isPC && _isHovered) {
      // PC上未选中且hover：绿色
      color = const Color(0xFF27AE60);
    } else {
      // 未选中且未hover：默认颜色
      color = widget.themeService.isDarkMode
          ? const Color(0xFFb0b0b0)
          : const Color(0xFF7f8c8d);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.isSelected
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 32, // 确保与容器高度一致
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center, // 垂直居中
          child: Text(
            widget.label,
            style: FontUtils.poppins(
              fontSize: 13,
              fontWeight: widget.isSelected ? FontWeight.w600 : FontWeight.w400,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
