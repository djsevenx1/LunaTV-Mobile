import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import '../services/version_service.dart';
import '../services/theme_service.dart';
import '../utils/font_utils.dart';

class UpdateDialog extends StatelessWidget {
  final VersionInfo versionInfo;

  const UpdateDialog({
    super.key,
    required this.versionInfo,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
          backgroundColor: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            decoration: BoxDecoration(
              color: themeService.isDarkMode
                  ? const Color(0xFF2C2C2C)
                  : Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顶部装饰区域
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: themeService.isDarkMode
                        ? const Color(0xFF333333)
                        : const Color(0xFFF5F5F5),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(16),
                      topRight: Radius.circular(16),
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF27AE60).withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.rocket_launch_rounded,
                          size: 40,
                          color: Color(0xFF27AE60),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '发现新版本',
                        style: FontUtils.poppins(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: themeService.isDarkMode
                              ? const Color(0xFFFFFFFF)
                              : const Color(0xFF2C2C2C),
                        ),
                      ),
                    ],
                  ),
                ),

                // 内容区域
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 版本信息卡片
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: themeService.isDarkMode
                              ? const Color(0xFF333333)
                              : const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildVersionChip(
                              context,
                              themeService,
                              '当前版本',
                              versionInfo.currentVersion,
                              Icons.info_outline_rounded,
                              themeService.isDarkMode
                                  ? const Color(0xFF999999)
                                  : const Color(0xFF666666),
                            ),
                            Container(
                              width: 1,
                              height: 40,
                              color: themeService.isDarkMode
                                  ? const Color(0xFF444444)
                                  : const Color(0xFFDDDDDD),
                            ),
                            _buildVersionChip(
                              context,
                              themeService,
                              '最新版本',
                              versionInfo.latestVersion,
                              Icons.new_releases_rounded,
                              const Color(0xFF27AE60),
                            ),
                          ],
                        ),
                      ),

                      // 更新说明
                      if (versionInfo.releaseNotes.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Icon(
                              Icons.article_outlined,
                              size: 18,
                              color: Color(0xFF27AE60),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '更新内容',
                              style: FontUtils.poppins(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: themeService.isDarkMode
                                    ? const Color(0xFFFFFFFF)
                                    : const Color(0xFF2C2C2C),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          constraints: const BoxConstraints(maxHeight: 200),
                          decoration: BoxDecoration(
                            color: themeService.isDarkMode
                                ? const Color(0xFF333333)
                                : const Color(0xFFF5F5F5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: GptMarkdown(
                                versionInfo.releaseNotes,
                                style: FontUtils.poppins(
                                  fontSize: 14,
                                  height: 1.6,
                                  color: themeService.isDarkMode
                                      ? const Color(0xFFCCCCCC)
                                      : const Color(0xFF666666),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                // 底部按钮区域
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Column(
                    children: [
                      // 主要操作按钮
                      SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            final url = VersionService.getReleaseUrl(
                                versionInfo.latestVersion);
                            final uri = Uri.parse(url);
                            if (await canLaunchUrl(uri)) {
                              await launchUrl(uri,
                                  mode: LaunchMode.externalApplication);
                            }
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                          icon: const Icon(Icons.open_in_new_rounded, size: 18),
                          label: Text(
                            '查看新版本',
                            style: FontUtils.poppins(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF27AE60),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // 次要操作按钮
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () async {
                                await VersionService.dismissVersion(
                                    versionInfo.latestVersion);
                                if (context.mounted) {
                                  Navigator.of(context).pop();
                                }
                              },
                              style: TextButton.styleFrom(
                                foregroundColor: themeService.isDarkMode
                                    ? const Color(0xFF999999)
                                    : const Color(0xFF666666),
                              ),
                              child: Text(
                                '忽略',
                                style: FontUtils.poppins(fontSize: 14),
                              ),
                            ),
                          ),
                          Expanded(
                            child: TextButton(
                              onPressed: () {
                                Navigator.of(context).pop();
                              },
                              style: TextButton.styleFrom(
                                foregroundColor: const Color(0xFF27AE60),
                              ),
                              child: Text(
                                '稍后',
                                style: FontUtils.poppins(fontSize: 14),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildVersionChip(
    BuildContext context,
    ThemeService themeService,
    String label,
    String version,
    IconData icon,
    Color color,
  ) {
    return Column(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(height: 4),
        Text(
          label,
          style: FontUtils.poppins(
            fontSize: 12,
            color: themeService.isDarkMode
                ? const Color(0xFF999999)
                : const Color(0xFF666666),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          version,
          style: FontUtils.poppins(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  /// 显示更新对话框
  static Future<void> show(
      BuildContext context, VersionInfo versionInfo) async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => UpdateDialog(versionInfo: versionInfo),
    );
  }
}
