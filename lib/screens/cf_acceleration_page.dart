import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:luna_tv/services/cf_optimizer.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/utils/font_utils.dart';

/// v2.0.17: CF 加速与优选 独立子页面
///
/// 把之前塞在 user_menu 里的 3 块 (Worker 加速 / 域名 / 优选测速) 整体
/// 搬到一个独立页面, user_menu 里只留一行可点击的入口 + 状态摘要.
///
/// 行为完全等价 v2.0.16: 共享 [UserDataService] / [CfOptimizer] 持久化,
/// 改完即时生效, 关闭页面不需要保存.
class CfAccelerationPage extends StatefulWidget {
  const CfAccelerationPage({super.key});

  @override
  State<CfAccelerationPage> createState() => _CfAccelerationPageState();
}

class _CfAccelerationPageState extends State<CfAccelerationPage> {
  bool _cfWorkerEnabled = false;
  String _cfWorkerDomain = '';
  bool _cfOptimizerEnabled = true;
  List<String> _cfBestIps = const [];
  String _cfLastTestHuman = '从未测速';
  bool _cfOptimizing = false;
  int _cfProgressDone = 0;
  int _cfProgressTotal = 0;
  bool _loading = true;
  // v2.0.27: 视频代理开关 (默认关, 用户手动开)
  bool _videoProxyEnabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfWorkerEnabled = await UserDataService.getCfWorkerEnabled();
    final cfWorkerDomain = await UserDataService.getCfWorkerDomain();
    final cfOptimizerEnabled = await CfOptimizer.getEnabled();
    final cfBestIps = await CfOptimizer.getBestIps();
    final cfLastTestHuman = await CfOptimizer.lastTestHuman();
    final videoProxyEnabled = await UserDataService.getVideoProxyEnabled();
    if (mounted) {
      setState(() {
        _cfWorkerEnabled = cfWorkerEnabled;
        _cfWorkerDomain = cfWorkerDomain;
        _cfOptimizerEnabled = cfOptimizerEnabled;
        _cfBestIps = cfBestIps;
        _cfLastTestHuman = cfLastTestHuman;
        _videoProxyEnabled = videoProxyEnabled;
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

  Future<void> _setOptimizerEnabled(bool v) async {
    await CfOptimizer.setEnabled(v);
    if (!mounted) return;
    setState(() {
      _cfOptimizerEnabled = v;
    });
    if (!v) {
      await CfOptimizer.clear();
      CfOptimizerHttpOverrides.disable();
      if (mounted) {
        setState(() {
          _cfBestIps = const [];
          _cfLastTestHuman = '从未测速';
        });
      }
    }
  }

  /// v2.0.11: 跑一次 CF 优选测速
  Future<void> _runOptimization() async {
    if (_cfOptimizing) return;
    if (_cfWorkerDomain.isEmpty) return;
    setState(() {
      _cfOptimizing = true;
      _cfProgressDone = 0;
      _cfProgressTotal = 0;
    });
    try {
      final ips = await CfOptimizer.runOptimization(
        targetDomain: _cfWorkerDomain,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _cfProgressDone = done;
              _cfProgressTotal = total;
            });
          }
        },
      );
      if (!mounted) return;
      if (ips.isNotEmpty) {
        CfOptimizerHttpOverrides.refresh(
          bestIps: ips,
          targetDomain: _cfWorkerDomain,
        );
        setState(() {
          _cfBestIps = ips;
          _cfLastTestHuman = '刚刚';
        });
      }
    } catch (_) {
      // 静默失败
    } finally {
      if (mounted) {
        setState(() {
          _cfOptimizing = false;
        });
      } else {
        _cfOptimizing = false;
      }
    }
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
              color: isDark
                  ? const Color(0xFF27ae60)
                  : const Color(0xFF27ae60)),
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
              '通过自定义域名的 CF Worker 中转请求 / 视频；可选开启 IP 优选'
              '测速让请求走国内更快的 CF Anycast 节点。需要先准备一个 Cloudflare '
              'Worker，参考 CORSAPI 项目。',
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

  Widget _buildOptimizerStatus(bool isDark) {
    final ipText = _cfOptimizerEnabled
        ? '已选 IP: ${_cfBestIps.isEmpty ? '尚未测速' : _cfBestIps.join(', ')}'
        : '优选已关闭';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.signal,
                  size: 14,
                  color: isDark
                      ? const Color(0xFF9ca3af)
                      : const Color(0xFF6b7280)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(ipText,
                    style: FontUtils.sourceCodePro(context,
                        fontSize: 12,
                        color: isDark
                            ? const Color(0xFFd1d5db)
                            : const Color(0xFF374151)),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(LucideIcons.clock,
                  size: 14,
                  color: isDark
                      ? const Color(0xFF9ca3af)
                      : const Color(0xFF6b7280)),
              const SizedBox(width: 6),
              Text('上次测速: $_cfLastTestHuman',
                  style: FontUtils.sourceCodePro(context,
                      fontSize: 12,
                      color: isDark
                          ? const Color(0xFF9ca3af)
                          : const Color(0xFF6b7280))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressOrButton(bool isDark) {
    if (_cfOptimizing) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(
              value: _cfProgressTotal == 0
                  ? null
                  : _cfProgressDone / _cfProgressTotal,
              backgroundColor: isDark
                  ? const Color(0xFF374151)
                  : const Color(0xFFe5e7eb),
              valueColor:
                  const AlwaysStoppedAnimation(Color(0xFF27ae60)),
            ),
            const SizedBox(height: 6),
            Text('测速中: $_cfProgressDone / $_cfProgressTotal',
                style: FontUtils.sourceCodePro(context,
                    fontSize: 12,
                    color: isDark
                        ? const Color(0xFF9ca3af)
                        : const Color(0xFF6b7280))),
          ],
        ),
      );
    }
    final canRun = _cfWorkerEnabled && _cfWorkerDomain.isNotEmpty;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      width: double.infinity,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: canRun ? _runOptimization : null,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: canRun
                  ? const Color(0xFF27ae60).withOpacity(0.12)
                  : (isDark
                      ? Colors.white.withOpacity(0.05)
                      : Colors.grey.withOpacity(0.1)),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: canRun
                    ? const Color(0xFF27ae60).withOpacity(0.4)
                    : Colors.transparent,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(LucideIcons.zap,
                    size: 18,
                    color: canRun
                        ? const Color(0xFF27ae60)
                        : (isDark
                            ? Colors.white.withOpacity(0.3)
                            : Colors.grey)),
                const SizedBox(width: 8),
                Text(
                  canRun ? '立即优选测速' : '需打开 CF Worker 加速 + 配置域名',
                  style: FontUtils.poppins(context,
                      fontSize: 14,
                      color: canRun
                          ? const Color(0xFF27ae60)
                          : (isDark
                              ? Colors.white.withOpacity(0.3)
                              : Colors.grey),
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
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
            title: Text('CF 加速与优选',
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
                          '通过自定义域名的 CF Worker 中转请求 / 视频',
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
                    if (_cfWorkerEnabled && _cfWorkerDomain.isNotEmpty) ...[
                      _buildSectionHeader(
                          'IP 优选测速', LucideIcons.zap, isDark),
                      _buildToggleTile(
                        title: 'CF 优选测速',
                        subtitle: '测 110 个 CF IP 找最快的, 视频/图片都走它',
                        value: _cfOptimizerEnabled,
                        onChanged: _setOptimizerEnabled,
                        icon: LucideIcons.zap,
                        isDark: isDark,
                      ),
                      const SizedBox(height: 8),
                      _buildOptimizerStatus(isDark),
                      _buildProgressOrButton(isDark),
                      // v2.0.27: 视频代理加速开关
                      _buildSectionHeader(
                          '视频代理加速', LucideIcons.video, isDark),
                      _buildToggleTile(
                        title: '视频走优选 IP 代理',
                        subtitle: '通过本地代理让视频流走优选 IP (实验性, 可能不兼容部分源)',
                        value: _videoProxyEnabled,
                        onChanged: (v) async {
                          await UserDataService.saveVideoProxyEnabled(v);
                          if (!mounted) return;
                          setState(() {
                            _videoProxyEnabled = v;
                          });
                        },
                        icon: LucideIcons.video,
                        isDark: isDark,
                      ),
                    ],
                  ],
                ),
        );
      },
    );
  }
}
