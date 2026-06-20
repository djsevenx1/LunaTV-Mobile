import 'package:flutter/material.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:provider/provider.dart';

/// 通用渐变色枚举
enum SectionColor {
  amber, // 电影:琥珀→橙
  blue, // 剧集:蓝→青
  pink, // 番剧:粉→玫瑰
  purple, // 综艺:紫→粉
  green, // 即将上映:绿→翠
  red, // 短剧:红→粉
}

extension SectionColorExtension on SectionColor {
  List<Color> get colors {
    switch (this) {
      case SectionColor.amber:
        return const [Color(0xFFF59E0B), Color(0xFFF97316)];
      case SectionColor.blue:
        return const [Color(0xFF3B82F6), Color(0xFF06B6D4)];
      case SectionColor.pink:
        return const [Color(0xFFEC4899), Color(0xFFF43F5E)];
      case SectionColor.purple:
        return const [Color(0xFFA855F7), Color(0xFFEC4899)];
      case SectionColor.green:
        return const [Color(0xFF22C55E), Color(0xFF10B981)];
      case SectionColor.red:
        return const [Color(0xFFEF4444), Color(0xFFF43F5E)];
    }
  }
}

/// LunaTV 风格的 Section 标题
/// 渐变图标 + 标题 + 副标题 + 右侧"查看全部"链接
class SectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final SectionColor color;
  final String? moreText;
  final VoidCallback? onMore;
  final EdgeInsetsGeometry padding;

  const SectionTitle({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    this.color = SectionColor.amber,
    this.moreText = '查看全部',
    this.onMore,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 12),
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        final isDarkMode = themeService.isDarkMode;
        return Padding(
          padding: padding,
          child: Row(
            children: [
              // 图标徽章
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: color.colors,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: color.colors.first.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              // 标题文字
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isDarkMode
                            ? const Color(0xFFE5E7EB)
                            : const Color(0xFF1F2937),
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDarkMode
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF6B7280),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // 查看全部
              if (onMore != null && moreText != null)
                TextButton(
                  onPressed: onMore,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    foregroundColor: isDarkMode
                        ? const Color(0xFF9CA3AF)
                        : const Color(0xFF6B7280),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        moreText!,
                        style: const TextStyle(fontSize: 13),
                      ),
                      const Icon(Icons.chevron_right, size: 16),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
