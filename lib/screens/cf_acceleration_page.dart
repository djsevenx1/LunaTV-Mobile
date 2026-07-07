import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/utils/font_utils.dart';

/// v2.0.30: 砍掉「IP 优选测速」+「视频走优选 IP 代理」两块, 只留 CF Worker
/// 加速开关 + 域名配置. CORSAPI worker (v2.0.28b) 已自带 CF edge cache, 是
/// 当前的唯一加速通道.
class CfAccelerationPage extends StatefulWidget {
  const CfAccelerationPage({super.key});

  @override
  State<CfAccelerationPage> createState() => _CfAccelerationPageState();
}

class _CfAccelerationPageState extends State<CfAccelerationPage> {
  bool _cfWorkerEnabled = false;
  String _cfWorkerDomain = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfWorkerEnabled = await UserDataService.getCfWorkerEnabled();
    final cfWorkerDomain = await UserDataService.getCfWorkerDomain();
    if (mounted) {
      setState(() {
        _cfWorkerEnabled = cfWorkerEnabled;
        _cfWorkerDomain = cfWorkerDomain;
        _loading = false;
      });
    }
  }

  Future<void> _setWorkerEnabled(bool v) async {
    await UserDataService.saveCfWorkerEnabled(v);
    if (!mounted) return;
    setState(() {
      _cfWorkerEnabled = v;
    });
  }

  // ============== 弹窗 ==============

  void _showWorkerDomainDialog(bool isDark) {
    final controller = TextEditingController(text: _cfWorkerDomain);
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF2c2c2c) : Colors.white,
          title: Text(
            'CF Worker 加速域名',
            style: FontUtils.poppins(ctx,
                fontSize: 18,
                color: isDark
                    ? const Color(0xFFffffff)
                    : const Color(0xFF1f2937),
                fontWeight: FontWeight.w600),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                style: FontUtils.poppins(ctx,
                    fontSize: 14,
                    color: isDark
                        ? const Color(0xFFffffff)
                        : const Color(0xFF1f2937)),
                decoration: InputDecoration(
                  hintText: 'example.workers.dev',
                  hintStyle: FontUtils.poppins(ctx,
                      fontSize: 14,
                      color: isDark
                          ? const Color(0xFF9ca3af)
                          : const Color(0xFF6b7280)),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: isDark
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: isDark
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: Color(0xFF10b981),
                      width: 2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '填 Cloudflare Worker 自定义域名或 *.workers.dev 子域；\n'
                '仅域名，不要带 https://。\n\n'
                '此域名同时用于「源加速」和「Bangumi 代理」，配了即生效'
                '(后者不依赖开关)。',
                style: FontUtils.poppins(ctx,
                    fontSize: 11,
                    color: isDark
                        ? const Color(0xFF9ca3af)
                        : const Color(0xFF6b7280)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                '取消',
                style: FontUtils.poppins(ctx,
                    fontSize: 14,
                    color: isDark
                        ? const Color(0xFF9ca3af)
                        : const Color(0xFF6b7280)),
              ),
            ),
            TextButton(
              onPressed: () async {
                final domain = controller.text.trim();
                await UserDataService.saveCfWorkerDomain(domain);
                if (!mounted) return;
                setState(() {
                  _cfWorkerDomain = domain;
                });
                if (ctx.mounted) Navigator.of(ctx).pop();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        domain.isEmpty
                            ? '已清空 CF Worker 域名(仅保留开关无效)'
                            : '已保存 CF Worker 域名',
                        style:
                            FontUtils.poppins(ctx, color: Colors.white),
                      ),
                      backgroundColor: const Color(0xFF10b981),
                    ),
                  );
                }
              },
              child: Text(
                '保存',
                style: FontUtils.poppins(ctx,
                    fontSize: 14,
                    color: const Color(0xFF10b981),
                    fontWeight: FontWeight.w600),
              ),
            ),
          ],
        );
      },
    ).whenComplete(controller.dispose);
  }

  // ============== UI 组件 ==============

  Widget _buildSectionHeader(String text, IconData icon, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        children: [
          Icon(icon,
              size: 18,
              color: const Color(0xFF27ae60)),
          const SizedBox(width: 8),
          Text(
            text,
            style: FontUtils.poppins(context,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: isDark
                    ? const Color(0xFFffffff)
                    : const Color(0xFF1f2937)),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard(bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF1e3a2a)
            : const Color(0xFFeafaf1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFF27ae60).withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.info,
              size: 16,
              color: isDark
                  ? const Color(0xFFa3e4b9)
                  : const Color(0xFF1e8449)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '通过自定义域名的 CF Worker 中转请求 / 视频；Worker 走 CF '
              'backbone 加速, .ts 段被 CF edge 缓存, 重复拉取近瞬时. '
              '需要先准备一个 Cloudflare Worker, 参考 CORSAPI 项目.',
              style: FontUtils.poppins(context,
                  fontSize: 12,
                  color: isDark
                      ? const Color(0xFFa3e4b9)
                      : const Color(0xFF1e8449),
                  height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleTile({
    required String title,
    required String? subtitle,
    required bool value,
    required Future<void> Function(bool) onChanged,
    required IconData icon,
    required bool isDark,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon,
              size: 20,
              color: isDark
                  ? const Color(0xFF9ca3af)
                  : const Color(0xFF6b7280)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: FontUtils.poppins(context,
                        fontSize: 16,
                        color: isDark
                            ? const Color(0xFFffffff)
                            : const Color(0xFF1f2937),
                        fontWeight: FontWeight.w500)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: FontUtils.sourceCodePro(context,
                          fontSize: 11,
                          color: isDark
                              ? const Color(0xFF9ca3af)
                              : const Color(0xFF6b7280))),
                ],
              ],
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
                    : (isDark
                        ? const Color(0xFF374151)
                        : const Color(0xFFe5e7eb)),
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 200),
                alignment:
                    value ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 20,
                  height: 20,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputTile({
    required String title,
    required String currentValue,
    required String emptyHint,
    required VoidCallback onTap,
    required IconData icon,
    required bool isDark,
  }) {
    final display = currentValue.isEmpty ? emptyHint : currentValue;
    final isEmpty = currentValue.isEmpty;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 20,
                  color: isDark
                      ? const Color(0xFF9ca3af)
                      : const Color(0xFF6b7280)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: FontUtils.poppins(context,
                            fontSize: 14,
                            color: isDark
                                ? const Color(0xFFb0b0b0)
                                : const Color(0xFF7f8c8d),
                            fontWeight: FontWeight.w400)),
                    const SizedBox(height: 2),
                    Text(display,
                        style: FontUtils.sourceCodePro(context,
                            fontSize: 14,
                            color: isEmpty
                                ? (isDark
                                    ? const Color(0xFF6b7280)
                                    : const Color(0xFF9ca3af))
                                : (isDark
                                    ? const Color(0xFFffffff)
                                    : const Color(0xFF1f2937)),
                            fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              Icon(LucideIcons.chevronRight,
                  size: 16,
                  color: isDark
                      ? const Color(0xFF9ca3af)
                      : const Color(0xFF6b7280)),
            ],
          ),
        ),
      ),
    );
  }

  // ============== Build ==============

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, _) {
        final isDark = themeService.isDarkMode;
        final bg = isDark ? const Color(0xFF121212) : const Color(0xFFf3f4f6);
        return Scaffold(
          backgroundColor: bg,
          appBar: AppBar(
            backgroundColor: bg,
            elevation: 0,
            title: Text('CF Worker 加速',
                style: FontUtils.poppins(context,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? const Color(0xFFffffff)
                        : const Color(0xFF1f2937))),
            iconTheme: IconThemeData(
              color: isDark
                  ? const Color(0xFFffffff)
                  : const Color(0xFF1f2937),
            ),
          ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    _buildInfoCard(isDark),
                    _buildSectionHeader('Worker 加速', LucideIcons.rocket, isDark),
                    _buildToggleTile(
                      title: 'CF Worker 加速',
                      subtitle:
                          '打开后请求 / 视频走 Worker, .ts 段被 CF edge 缓存',
                      value: _cfWorkerEnabled,
                      onChanged: _setWorkerEnabled,
                      icon: LucideIcons.rocket,
                      isDark: isDark,
                    ),
                    const SizedBox(height: 8),
                    _buildInputTile(
                      title: 'CF Worker 加速源域名',
                      currentValue: _cfWorkerDomain,
                      emptyHint: '（点击配置）',
                      onTap: () => _showWorkerDomainDialog(isDark),
                      icon: LucideIcons.server,
                      isDark: isDark,
                    ),
                  ],
                ),
        );
      },
    );
  }
}
