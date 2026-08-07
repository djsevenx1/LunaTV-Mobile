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
        return const [Color(0xFFF5B84B), Color(0xFFFF8A3D)];
      case SectionColor.blue:
        return const [Color(0xFF2BD9E8), Color(0xFF34B3F1)];
      case SectionColor.pink:
        return const [Color(0xFFE23B8E), Color(0xFFFF5C7A)];
      case SectionColor.purple:
        return const [Color(0xFF7C5CFF), Color(0xFFE23B8E)];
      case SectionColor.green:
        return const [Color(0xFF2BD9E8), Color(0xFF34B3F1)];
      case SectionColor.red:
        return const [Color(0xFFFF4D5E), Color(0xFFE23B8E)];
    }
  }
}

/// 「极光影院」风格的 Section 标题
/// 左侧渐变强调竖条 + 粗体大标题 + 副标题 + 右侧"查看全部"
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
        final titleColor = isDarkMode
            ? const Color(0xFFEDF0F7)
            : const Color(0xFF1A2133);
        final subtitleColor = isDarkMode
            ? const Color(0xFF9BA3B5)
            : const Color(0xFF6B7280);
        final moreColor = isDarkMode
            ? const Color(0xFF9BA3B5)
            : const Color(0xFF6B7280);

        return Padding(
          padding: padding,
          child: Row(
            children: [
              // 左侧渐变强调竖条
              Container(
                width: 4,
                height: 24,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: color.colors,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              // 标题文字
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                        color: titleColor,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 12,
                          color: subtitleColor,
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
                    foregroundColor: moreColor,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        moreText!,
                        style: const TextStyle(fontSize: 13),
                      ),
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: moreColor,
                      ),
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
