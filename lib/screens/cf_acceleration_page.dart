import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:luna_tv/services/cf_optimizer.dart';
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
  String _cfBestIp = ''; // v2.0.31: 手动优选 IP
  // v2.0.34: 视频代理加速开关 (UI 入口在 v2.0.30 砍优选测速时一起砍了,
  //   现在加回来). 后端存储键还在 user_data_service.dart, 默认 false.
  bool _videoProxyEnabled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfWorkerEnabled = await UserDataService.getCfWorkerEnabled();
    final cfWorkerDomain = await UserDataService.getCfWorkerDomain();
    final bestIp = await UserDataService.getCfBestIp();
    // v2.0.34: 读视频代理开关
    final videoProxyEnabled = await UserDataService.getVideoProxyEnabled();
    if (mounted) {
      setState(() {
        _cfWorkerEnabled = cfWorkerEnabled;
        _cfWorkerDomain = cfWorkerDomain;
        _cfBestIp = bestIp ?? '';
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

  // v2.0.34: 视频代理开关 setter
  Future<void> _setVideoProxyEnabled(bool v) async {
    await UserDataService.saveVideoProxyEnabled(v);
    if (!mounted) return;
    setState(() {
      _videoProxyEnabled = v;
    });
  }

  Future<void> _setBestIp(String ip) async {
    // v2.0.32: 返回清理后的字符串, null = 无效输入
    final cleaned = await UserDataService.saveCfBestIp(ip);
    if (!mounted) return;
    setState(() {
      _cfBestIp = cleaned ?? '';
    });
    // 立即生效 (不用重启 App), 把手动 IP 推到 override
    final effective = cleaned == null || cleaned.isEmpty ? null : cleaned;
    CfOptimizerHttpOverrides.setManualPreferredIp(effective);
    // v2.0.32: 如果是域名, 立刻解析一次 (不阻塞 UI, 解析中显示"待解析")
    if (effective != null && !_isIpv4(effective)) {
      // ignore: discarded_futures
      CfOptimizerHttpOverrides.resolveManualPreferred().then((_) {
        if (mounted) setState(() {});
      });
    } else {
      if (mounted) setState(() {});
    }
  }

  bool _isIpv4(String s) {
    final m =
        RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(s);
    if (m == null) return false;
    for (var i = 1; i <= 4; i++) {
      final n = int.parse(m.group(i)!);
      if (n < 0 || n > 255) return false;
    }
    return true;
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

  // v2.0.32: 手动优选 IP / 优选域名 输入弹窗
  void _showBestIpDialog(bool isDark) {
    final controller = TextEditingController(text: _cfBestIp);
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocalState) {
            // 弹窗里也显示当前解析状态, 解析完用户能立刻看到 IP
            final resolved = CfOptimizerHttpOverrides.getResolvedManualIp();
            final resolvedAt = CfOptimizerHttpOverrides.getResolvedAtHuman();
            final err = CfOptimizerHttpOverrides.getResolveError();
            return AlertDialog(
              backgroundColor: isDark ? const Color(0xFF2c2c2c) : Colors.white,
              title: Text(
                '优选 IP（可选）',
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
                    // v2.0.32: 不再限制 numberWithOptions, 因为支持域名
                    keyboardType: TextInputType.text,
                    style: FontUtils.poppins(ctx,
                        fontSize: 14,
                        color: isDark
                            ? const Color(0xFFffffff)
                            : const Color(0xFF1f2937)),
                    decoration: InputDecoration(
                      hintText: '104.16.123.45 或 cf.877774.xyz',
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
                  // v2.0.32: 显示当前解析状态 (实时)
                  if (_cfBestIp.isNotEmpty) ...[
                    Text(
                      _isIpv4(_cfBestIp)
                          ? '类型: IPv4 (静态)\n生效 IP: $_cfBestIp'
                          : '类型: 优选域名 (动态解析)\n'
                              '用户输入: $_cfBestIp\n'
                              '当前 IP: ${resolved ?? "解析中..."}\n'
                              '上次解析: $resolvedAt'
                              '${err != null ? "\n错误: $err" : ""}',
                      style: FontUtils.sourceCodePro(ctx,
                          fontSize: 11,
                          color: isDark
                              ? const Color(0xFF10b981)
                              : const Color(0xFF059669),
                          height: 1.4),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    '支持两种格式:\n'
                    '• IPv4: 104.16.123.45 (静态, 写死不刷新)\n'
                    '• 优选域名: cf.877774.xyz / cloudflare.182682.xyz 等 '
                    '(动态解析, App 启动 + 每 5 分钟自动重新解析, '
                    '每次拿到不同的 CF IP, 避开 DNS 污染)\n\n'
                    '留空 = 不使用, 走系统 DNS.\n\n'
                    '效果: App 内所有 HTTP 请求 (豆瓣 / Bangumi / 图片 / 元数据) '
                    '强制走解析出来的 IP, 跳过系统 DNS 解析.\n\n'
                    '⚠️ 视频走 libmpv (原生 C), 不受 Dart 优选 IP 影响. '
                    '视频加速靠 worker 自带的 CF edge cache.',
                    style: FontUtils.poppins(ctx,
                        fontSize: 11,
                        color: isDark
                            ? const Color(0xFF9ca3af)
                            : const Color(0xFF6b7280),
                        height: 1.5),
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
                    final input = controller.text.trim();
                    final cleaned = await UserDataService.saveCfBestIp(input);
                    if (cleaned == null && input.isNotEmpty) {
                      // 输入非空但格式错, 提示一下
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(
                            content: Text(
                              '格式无效, 必须是 IPv4 (104.16.123.45) '
                              '或域名 (cf.877774.xyz)',
                              style: FontUtils.poppins(ctx,
                                  color: Colors.white),
                            ),
                            backgroundColor: const Color(0xFFef4444),
                          ),
                        );
                      }
                      return; // 不关弹窗, 让用户改
                    }
                    if (!mounted) return;
                    setState(() {
                      _cfBestIp = cleaned ?? '';
                    });
                    final effective =
                        cleaned == null || cleaned.isEmpty ? null : cleaned;
                    CfOptimizerHttpOverrides.setManualPreferredIp(effective);
                    if (effective != null && !_isIpv4(effective)) {
                      // ignore: discarded_futures
                      CfOptimizerHttpOverrides.resolveManualPreferred()
                          .then((_) {
                        if (mounted) setState(() {});
                      });
                    }
                    if (ctx.mounted) Navigator.of(ctx).pop();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            cleaned == null || cleaned.isEmpty
                                ? '已清空优选'
                                : _isIpv4(cleaned)
                                    ? '已保存 IP $cleaned (静态)'
                                    : '已保存域名 $cleaned (动态解析, 5min 刷新)',
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

  /// v2.0.45: 静态 IP 优选 0KB 警告
  ///
  /// 场景: 用户填了 162.159.x.x 这种通用 CF IP, 但视频 host 是 worker
  ///   自定义域 (api.xx.fn0.qzz.io). 静态 IP 跟 host 不在同一个 CF zone,
  ///   TLS 握手失败但 TCP 拨上, race 已返回 → libmpv 拿到空 backend → 0KB.
  /// 修法: 把 host 加进 race 候选 + 推荐用优选域名 (自动 re-resolve).
  Widget _buildIpOptimizationWarning(bool isDark) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF3a2a1e)
            : const Color(0xFFfef3e8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: const Color(0xFFf59e0b).withOpacity(0.4),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertTriangle,
              size: 16,
              color: isDark
                  ? const Color(0xFFfcd34d)
                  : const Color(0xFFd97706)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '静态 IP 优选可能因 IP 跟目标 host 不在同一个 CF zone 而 0KB. '
              '建议改用优选域名 (cf.877774.xyz / cloudflare.182682.xyz), '
              'App 会每 5 分钟自动 re-resolve, 避开下线的 IP.',
              style: FontUtils.poppins(context,
                  fontSize: 11,
                  color: isDark
                      ? const Color(0xFFfcd34d)
                      : const Color(0xFF92400e),
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
            title: Text('代理加速',
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
                    _buildSectionHeader('代理总开关', LucideIcons.rocket, isDark),
                    _buildToggleTile(
                      title: 'CF Worker 加速（代理总开关）',
                      subtitle:
                          '打开后视频 / 图片 / TMDB 走 Worker; 关闭全部直连原源',
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
                    const SizedBox(height: 8),
                    _buildInputTile(
                      title: '优选 IP（可选）',
                      currentValue: _cfBestIp.isEmpty
                          ? ''
                          : _isIpv4(_cfBestIp)
                              ? _cfBestIp
                              // v2.0.32: 域名模式显示"域名 → 解析 IP"
                              : '${_cfBestIp} → '
                                  '${CfOptimizerHttpOverrides.getResolvedManualIp() ?? "解析中..."}',
                      emptyHint: '（未设置，使用 DNS 解析）',
                      onTap: () => _showBestIpDialog(isDark),
                      icon: LucideIcons.zap,
                      isDark: isDark,
                    ),
                    // v2.0.45: 单 IP 优选的 0KB 提示 — 静态 IP 跟目标 host
                    //   不在同一个 CF zone 时, TLS 握手失败但 TCP 拨上,
                    //   race 已返回 → libmpv 拿到一个空 backend → 0KB 死链.
                    //   race 内部已经加了 [manual_ip, original_host] 双候选,
                    //   但不是 100% 解决. 强烈建议改成优选域名 (cf.877774.xyz)
                    //   让系统 DNS 周期性 re-resolve, 避开下线的 IP.
                    if (_cfBestIp.isNotEmpty && _isIpv4(_cfBestIp)) ...[
                      const SizedBox(height: 8),
                      _buildIpOptimizationWarning(isDark),
                    ],
                    // v2.0.70: 视频代理加速开关 语义改成「优选 IP 启用开关」
                    //   - 代理总开关 (CF Worker 加速) 控制是否启代理 → worker
                    //   - 这个开关只控制视频流是否走优选 IP (图片/TMDB 不受影响)
                    //   行为:
                    //     代理总开关关 → 直连 (这个开关无效)
                    //     代理总开关开 + 这个开关关 → 视频走 worker (系统 DNS)
                    //     代理总开关开 + 这个开关开 + IP 填了 → 视频走优选 IP + worker
                    //     代理总开关开 + 这个开关开 + IP 没填 → 视频走 worker (系统 DNS)
                    const SizedBox(height: 8),
                    _buildToggleTile(
                      title: '优选 IP 启用（视频流）',
                      subtitle: _videoProxyEnabled
                          ? '视频流走优选 IP + Worker（需配优选 IP, 图片/TMDB 不受影响）'
                          : '视频流走 Worker (系统 DNS), 不走优选 IP',
                      value: _videoProxyEnabled,
                      onChanged: _setVideoProxyEnabled,
                      icon: LucideIcons.video,
                      isDark: isDark,
                    ),
                  ],
                ),
        );
      },
    );
  }
}
