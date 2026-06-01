import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../utils/font_utils.dart';
import '../services/theme_service.dart';

/// 自定义下拉刷新指示器
class CustomRefreshIndicator extends StatelessWidget {
  final Widget child;
  final Future<void> Function() onRefresh;
  final String? refreshText;

  const CustomRefreshIndicator({
    super.key,
    required this.child,
    required this.onRefresh,
    this.refreshText,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return RefreshIndicator(
          onRefresh: onRefresh,
          color: const Color(0xFF27AE60), // 绿色主题
          backgroundColor: themeService.isDarkMode 
              ? const Color(0xFF1e1e1e) 
              : Colors.white,
          strokeWidth: 2.5,
          displacement: 40,
          child: this.child,
        );
      },
    );
  }
}

/// 自定义刷新指示器内容
class CustomRefreshIndicatorContent extends StatelessWidget {
  final String? text;
  final IconData? icon;
  final Color? color;

  const CustomRefreshIndicatorContent({
    super.key,
    this.text,
    this.icon,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        final indicatorColor = color ?? const Color(0xFF27AE60); // 绿色主题
        
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: indicatorColor,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: indicatorColor.withOpacity(0.3),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 8),
              ],
              Text(
                text ?? '下拉刷新',
                style: FontUtils.poppins(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 带自定义样式的刷新指示器
class StyledRefreshIndicator extends StatelessWidget {
  final Widget child;
  final Future<void> Function() onRefresh;
  final String? refreshText;
  final Color? primaryColor;
  final Color? backgroundColor;

  const StyledRefreshIndicator({
    super.key,
    required this.child,
    required this.onRefresh,
    this.refreshText,
    this.primaryColor,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return RefreshIndicator(
          onRefresh: onRefresh,
          color: primaryColor ?? const Color(0xFF27AE60), // 默认绿色主题
          backgroundColor: backgroundColor ?? (themeService.isDarkMode 
              ? const Color(0xFF1e1e1e) 
              : Colors.white),
          strokeWidth: 2.5,
          displacement: 40,
          child: this.child,
        );
      },
    );
  }
}
