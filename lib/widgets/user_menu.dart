import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:luna_tv/services/cf_optimizer.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/screens/cf_acceleration_page.dart';
import 'package:luna_tv/screens/login_screen.dart';
import 'package:luna_tv/services/douban_cache_service.dart';
import 'package:luna_tv/services/page_cache_service.dart';
import 'package:luna_tv/services/live_service.dart';
import 'package:luna_tv/services/local_search_cache_service.dart';
import 'package:luna_tv/services/version_service.dart';
import 'package:luna_tv/utils/device_utils.dart';
import 'package:luna_tv/utils/font_utils.dart';
import 'package:luna_tv/widgets/update_dialog.dart';

class UserMenu extends StatefulWidget {
  final bool isDarkMode;

  const UserMenu({
    super.key,
    required this.isDarkMode,
  });

  @override
  State<UserMenu> createState() => _UserMenuState();
}

class _UserMenuState extends State<UserMenu> {
  String? _username;
  String _role = 'user';
  String _doubanDataSource = '直连';
  String _doubanImageSource = '直连';
  String _bangumiDataSource = '直连';
  String _bangumiImageSource = '直连';
  String _m3u8ProxyUrl = '';
  String _version = '';
  bool _preferSpeedTest = true;
  bool _localSearch = false;
  bool _isLocalMode = false;
  bool _cfWorkerEnabled = false;
  String _cfWorkerDomain = '';
  // v2.0.17: CF 优选 / 测速详情都搬到 CfAccelerationPage 子页面,
  // 这边只留一行可点击的入口, 用 _cfSummary 显示一行状态摘要
  String _cfSummary = '未配置';

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _version = packageInfo.version;
      });
    }
  }

  Future<void> _loadUserInfo() async {
    final isLocalMode = await UserDataService.getIsLocalMode();
    final username = await UserDataService.getUsername();
    final cookies = await UserDataService.getCookies();
    final doubanDataSource =
        await UserDataService.getDoubanDataSourceDisplayName();
    final doubanImageSource =
        await UserDataService.getDoubanImageSourceDisplayName();
    final bangumiDataSource =
        await UserDataService.getBangumiDataSourceDisplayNameAsync();
    final bangumiImageSource =
        await UserDataService.getBangumiImageSourceDisplayNameAsync();
    final m3u8ProxyUrl = await UserDataService.getM3u8ProxyUrl();
    final preferSpeedTest = await UserDataService.getPreferSpeedTest();
    final localSearch = await UserDataService.getLocalSearch();
    final cfWorkerEnabled = await UserDataService.getCfWorkerEnabled();
    final cfWorkerDomain = await UserDataService.getCfWorkerDomain();
    final cfOptimizerEnabled = await CfOptimizer.getEnabled();
    final cfBestIps = await CfOptimizer.getBestIps();
    final cfLastTestHuman = await CfOptimizer.lastTestHuman();

    if (mounted) {
      setState(() {
        _isLocalMode = isLocalMode;
        _username = username;
        _role = _parseRoleFromCookies(cookies);
        _doubanDataSource = doubanDataSource;
        _doubanImageSource = doubanImageSource;
        _bangumiDataSource = bangumiDataSource;
        _bangumiImageSource = bangumiImageSource;
        _m3u8ProxyUrl = m3u8ProxyUrl;
        _preferSpeedTest = preferSpeedTest;
        _localSearch = localSearch;
        _cfWorkerEnabled = cfWorkerEnabled;
        _cfWorkerDomain = cfWorkerDomain;
        _cfSummary = _computeCfSummary(
          domain: cfWorkerDomain,
          enabled: cfWorkerEnabled,
          optEnabled: cfOptimizerEnabled,
          bestIps: cfBestIps,
          lastTest: cfLastTestHuman,
        );
      });
    }
  }

  /// v2.0.17: 给 user_menu 入口行用的一行状态摘要
  String _computeCfSummary({
    required String domain,
    required bool enabled,
    required bool optEnabled,
    required List<String> bestIps,
    required String lastTest,
  }) {
    if (domain.isEmpty) return '未配置';
    if (!enabled) return '$domain · 开关未开';
    if (!optEnabled) return '$domain · 优选关';
    if (bestIps.isEmpty) return '$domain · 待测速';
    return '$domain · ${bestIps.length} IP · $lastTest';
  }

  /// v2.0.17: push CF 加速与优选 子页面, 返回时刷新一行摘要
  Future<void> _openCfAccelerationPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CfAccelerationPage()),
    );
    if (!mounted) return;
    // 从子页面返回后, 重新读 CF 状态, 刷新入口行的一行摘要
    final cfWorkerEnabled = await UserDataService.getCfWorkerEnabled();
    final cfWorkerDomain = await UserDataService.getCfWorkerDomain();
    final cfOptimizerEnabled = await CfOptimizer.getEnabled();
    final cfBestIps = await CfOptimizer.getBestIps();
    final cfLastTestHuman = await CfOptimizer.lastTestHuman();
    if (!mounted) return;
    setState(() {
      _cfWorkerEnabled = cfWorkerEnabled;
      _cfWorkerDomain = cfWorkerDomain;
      _cfSummary = _computeCfSummary(
        domain: cfWorkerDomain,
        enabled: cfWorkerEnabled,
        optEnabled: cfOptimizerEnabled,
        bestIps: cfBestIps,
        lastTest: cfLastTestHuman,
      );
    });
  }

  String _parseRoleFromCookies(String? cookies) {
    if (cookies == null || cookies.isEmpty) {
      return 'user';
    }

    try {
      // 解析cookies字符串
      final cookieMap = <String, String>{};
      final cookiePairs = cookies.split(';');

      for (final cookie in cookiePairs) {
        final trimmed = cookie.trim();
        final firstEqualIndex = trimmed.indexOf('=');

        if (firstEqualIndex > 0) {
          final key = trimmed.substring(0, firstEqualIndex);
          final value = trimmed.substring(firstEqualIndex + 1);
          if (key.isNotEmpty && value.isNotEmpty) {
            cookieMap[key] = value;
          }
        }
      }

      final authCookie = cookieMap['auth'];
      if (authCookie == null) {
        return 'user';
      }

      // 处理可能的双重编码
      String decoded = Uri.decodeComponent(authCookie);

      // 如果解码后仍然包含 %，说明是双重编码，需要再次解码
      if (decoded.contains('%')) {
        decoded = Uri.decodeComponent(decoded);
      }

      final authData = json.decode(decoded);
      final role = authData['role'] as String?;

      return role ?? 'user';
    } catch (e) {
      // 解析失败时默认为user
      return 'user';
    }
  }

  Future<void> _handleLogout() async {
    // 清空所有缓存
    LiveService.clearAllCache();
    LocalSearchCacheService().clearCache();
    PageCacheService().clearAllCache();

    // 只清除密码和cookies，保留服务器地址和用户名
    await UserDataService.clearPasswordAndCookies();

    await UserDataService.saveIsLocalMode(false);

    // 跳转到登录页，并移除所有之前的路由（强制销毁所有页面）
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  Future<void> _handleClearDoubanCache() async {
    try {
      await DoubanCacheService().clearAll();
      // 同时清空 Bangumi 的函数级与内存级缓存
      PageCacheService().clearCache('bangumi_calendar');
      if (mounted) {
        // v2.0.26: 清除缓存后留在设置页显示 SnackBar, 不自动 pop
        // (原来 pop 后 ScaffoldMessenger 销毁, SnackBar 看不到)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已清除豆瓣缓存')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('清除豆瓣缓存失败')),
        );
      }
    }
  }

  Future<void> _handleCheckUpdate() async {
    try {
      // 显示加载提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '正在检查更新...',
              style: FontUtils.poppins(context, color: Colors.white),
            ),
            backgroundColor: Colors.black,
            duration: const Duration(seconds: 2),
          ),
        );
      }

      final versionInfo = await VersionService.checkForUpdate();

      if (!mounted) return;

      if (versionInfo != null) {
        // 有新版本，显示更新对话框
        await UpdateDialog.show(context, versionInfo);
      } else {
        // 已是最新版本
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '当前已是最新版本',
              style: FontUtils.poppins(context, color: Colors.white),
            ),
            backgroundColor: const Color(0xFF27AE60),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '检查更新失败: ${e.toString()}',
              style: FontUtils.poppins(context, color: Colors.white),
            ),
            backgroundColor: const Color(0xFFef4444),
          ),
        );
      }
    }
  }

  Widget _buildRoleTag() {
    String label;
    Color color;

    switch (_role) {
      case 'admin':
        label = '管理员';
        color = const Color(0xFFf59e0b); // 橙黄色
        break;
      case 'owner':
        label = '站长';
        color = const Color(0xFF8b5cf6); // 紫色
        break;
      case 'user':
      default:
        label = '用户';
        color = const Color(0xFF10b981); // 绿色
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: FontUtils.poppins(context,
                    fontSize: 10,
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildOptionSelector({
    required String title,
    required String currentValue,
    required List<String> options,
    required Future<void> Function(String) onChanged,
    required IconData icon,
    required Color iconColor,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showOptionDialog(title, currentValue, options, onChanged),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          child: Row(
            children: [
              _buildIconContainer(icon, iconColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: FontUtils.poppins(context,
                        fontSize: 16,
                        color: widget.isDarkMode
                            ? const Color(0xFFffffff)
                            : const Color(0xFF1f2937),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      currentValue,
                      style: FontUtils.poppins(context,
                        fontSize: 12,
                        color: widget.isDarkMode
                            ? const Color(0xFF9ca3af)
                            : const Color(0xFF6b7280),
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
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

  void _showOptionDialog(String title, String currentValue,
      List<String> options, Future<void> Function(String) onChanged) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor:
              widget.isDarkMode ? const Color(0xFF2c2c2c) : Colors.white,
          title: Text(
            title,
            style: FontUtils.poppins(context,
                            fontSize: 18,
              color: widget.isDarkMode
                  ? const Color(0xFFffffff)
                  : const Color(0xFF1f2937),
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: options.map((option) {
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () async {
                    await onChanged(option);
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 16,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          currentValue == option
                              ? LucideIcons.check
                              : LucideIcons.circle,
                          size: 20,
                          color: currentValue == option
                              ? const Color(0xFF10b981)
                              : (widget.isDarkMode
                                  ? const Color(0xFF9ca3af)
                                  : const Color(0xFF6b7280)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            option,
                            style: FontUtils.poppins(context,
                                                            fontSize: 16,
                              color: widget.isDarkMode
                                  ? const Color(0xFFffffff)
                                  : const Color(0xFF1f2937),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }

  void _showM3u8ProxyUrlDialog() {
    final controller = TextEditingController(text: _m3u8ProxyUrl);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor:
              widget.isDarkMode ? const Color(0xFF2c2c2c) : Colors.white,
          title: Text(
            'M3U8 代理 URL',
            style: FontUtils.poppins(context,
                            fontSize: 18,
              color: widget.isDarkMode
                  ? const Color(0xFFffffff)
                  : const Color(0xFF1f2937),
              fontWeight: FontWeight.w600,
            ),
          ),
          content: TextField(
            controller: controller,
            style: FontUtils.poppins(context,
                            fontSize: 14,
              color: widget.isDarkMode
                  ? const Color(0xFFffffff)
                  : const Color(0xFF1f2937),
            ),
            decoration: InputDecoration(
              hintText: '输入代理 URL（可选）',
              hintStyle: FontUtils.poppins(context,
                                fontSize: 14,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                  color: widget.isDarkMode
                      ? const Color(0xFF374151)
                      : const Color(0xFFe5e7eb),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                  color: widget.isDarkMode
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
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(
                '取消',
                style: FontUtils.poppins(context,
                                    fontSize: 14,
                  color: widget.isDarkMode
                      ? const Color(0xFF9ca3af)
                      : const Color(0xFF6b7280),
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                final url = controller.text.trim();
                await UserDataService.saveM3u8ProxyUrl(url);
                if (!mounted) return;
                setState(() {
                  _m3u8ProxyUrl = url;
                });
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: Text(
                '保存',
                style: FontUtils.poppins(context,
                                    fontSize: 14,
                  color: const Color(0xFF10b981),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    ).whenComplete(controller.dispose);
  }

  Widget _buildInputOption({
    required String title,
    required String currentValue,
    required VoidCallback onTap,
    required IconData icon,
    required Color iconColor,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          child: Row(
            children: [
              _buildIconContainer(icon, iconColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: FontUtils.poppins(context,
                        fontSize: 16,
                        color: widget.isDarkMode
                            ? const Color(0xFFffffff)
                            : const Color(0xFF1f2937),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      currentValue.isEmpty ? '未设置' : currentValue,
                      style: FontUtils.poppins(context,
                        fontSize: 12,
                        color: widget.isDarkMode
                            ? const Color(0xFF9ca3af)
                            : const Color(0xFF6b7280),
                        fontWeight: FontWeight.w400,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
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

  Widget _buildToggleOption({
    required String title,
    required bool value,
    required Future<void> Function(bool) onChanged,
    required IconData icon,
    required Color iconColor,
    String? subtitle,
  }) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        child: Row(
          children: [
            _buildIconContainer(icon, iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: FontUtils.poppins(context,
                      fontSize: 16,
                      color: widget.isDarkMode
                          ? const Color(0xFFffffff)
                          : const Color(0xFF1f2937),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: FontUtils.sourceCodePro(
                        context,
                        fontSize: 11,
                        color: widget.isDarkMode
                            ? const Color(0xFF9ca3af)
                            : const Color(0xFF6b7280),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            GestureDetector(
              onTap: () async {
                await onChanged(!value);
                if (!mounted) return;
                setState(() {});
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
      ),
    );
  }

  /// 设置页分组标题: 小号、带颜色色条强调的标签
  Widget _buildSectionHeader(String title) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: const Color(0xFF6366f1),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: FontUtils.poppins(
              context,
              fontSize: 13,
              color: widget.isDarkMode
                  ? const Color(0xFF9ca3af)
                  : const Color(0xFF6b7280),
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }

  /// 卡片内列表项之间的细分隔线: 带 indent, 不贴边
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

  /// iOS 设置风格的彩色图标圆角方块背景
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

  /// iOS 设置风格的圆角分组卡片: 12px 左右 margin, 圆角裁剪子项
  Widget _buildCard({required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color:
            widget.isDarkMode ? const Color(0xFF1F2937) : Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  /// 卡片内的普通操作项 (清除缓存 / 检查更新 等)
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

  /// 用户信息头部卡片: 渐变背景 + 首字母头像圆 + 角色标签
  Widget _buildUserHeader() {
    final String avatarText;
    final String displayName;
    if (_isLocalMode) {
      avatarText = '本';
      displayName = '本地模式';
    } else {
      final name = _username ?? '未知用户';
      displayName = name;
      avatarText = name.isNotEmpty ? name[0].toUpperCase() : '?';
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF6366f1),
            Color(0xFF8b5cf6),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6366f1).withOpacity(0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.25),
                border: Border.all(
                  color: Colors.white.withOpacity(0.4),
                  width: 2,
                ),
              ),
              child: Center(
                child: Text(
                  avatarText,
                  style: FontUtils.poppins(
                    context,
                    fontSize: 24,
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: FontUtils.poppins(
                      context,
                      fontSize: 18,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!_isLocalMode) ...[
                    const SizedBox(height: 6),
                    _buildRoleTag(),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 登出: 底部独立的红色卡片, 居中文字
  Widget _buildLogoutCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? const Color(0xFF1F2937) : Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _handleLogout,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  LucideIcons.logOut,
                  size: 18,
                  color: Color(0xFFef4444),
                ),
                const SizedBox(width: 8),
                Text(
                  '登出',
                  style: FontUtils.poppins(
                    context,
                    fontSize: 16,
                    color: const Color(0xFFef4444),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 版本号: 底部居中, 弱化颜色, 可点击打开 GitHub
  Widget _buildVersionNumber() {
    return MouseRegion(
      cursor: DeviceUtils.isPC()
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      child: GestureDetector(
        onTap: () async {
          final url =
              Uri.parse('https://github.com/MoonTechLab/LunaTV');
          if (await canLaunchUrl(url)) {
            await launchUrl(url, mode: LaunchMode.externalApplication);
          }
        },
        child: Center(
          child: Text(
            _version.isEmpty ? 'v1.4.3' : 'v$_version',
            style: FontUtils.poppins(
              context,
              fontSize: 13,
              color: widget.isDarkMode
                  ? const Color(0xFF9ca3af)
                  : const Color(0xFF6b7280),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.isDarkMode
          ? const Color(0xFF0F1117)
          : const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: widget.isDarkMode
            ? const Color(0xFF0F1117)
            : const Color(0xFFF5F5F5),
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(
            LucideIcons.arrowLeft,
            color: widget.isDarkMode
                ? const Color(0xFFffffff)
                : const Color(0xFF1f2937),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '设置',
          style: FontUtils.poppins(
            context,
            fontSize: 18,
            color: widget.isDarkMode
                ? const Color(0xFFffffff)
                : const Color(0xFF1f2937),
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 32),
        children: [
          // ===== 用户信息头部卡片 =====
          _buildUserHeader(),
          // ===== 数据源 =====
          _buildSectionHeader('数据源'),
          _buildCard(
            children: [
              // 豆瓣数据源选项
              _buildOptionSelector(
                title: '豆瓣数据源',
                currentValue: _doubanDataSource,
                options: const [
                  '直连',
                  'Cors Proxy By Zwei',
                  '豆瓣 CDN By CMLiussss（腾讯云）',
                  '豆瓣 CDN By CMLiussss（阿里云）',
                ],
                onChanged: (value) async {
                  await UserDataService.saveDoubanDataSource(value);
                  if (!mounted) return;
                  setState(() {
                    _doubanDataSource = value;
                  });
                },
                icon: LucideIcons.database,
                iconColor: const Color(0xFF10b981),
              ),
              _buildDivider(),
              // 豆瓣图片源选项
              _buildOptionSelector(
                title: '豆瓣图片源',
                currentValue: _doubanImageSource,
                options: const [
                  '直连',
                  '豆瓣官方精品 CDN',
                  '豆瓣 CDN By CMLiussss（腾讯云）',
                  '豆瓣 CDN By CMLiussss（阿里云）',
                ],
                onChanged: (value) async {
                  await UserDataService.saveDoubanImageSource(value);
                  if (!mounted) return;
                  setState(() {
                    _doubanImageSource = value;
                  });
                },
                icon: LucideIcons.image,
                iconColor: const Color(0xFF14b8a6),
              ),
              _buildDivider(),
              // Bangumi 数据源选项
              _buildOptionSelector(
                title: 'Bangumi 数据源',
                currentValue: _bangumiDataSource,
                options: const [
                  '直连',
                  'Cors Proxy By Zwei',
                  'CF Worker 加速',
                ],
                onChanged: (value) async {
                  final key = UserDataService
                      .getBangumiDataSourceKeyFromDisplayName(value);
                  await UserDataService.saveBangumiDataSource(key);
                  if (!mounted) return;
                  setState(() {
                    _bangumiDataSource = value;
                  });
                },
                icon: LucideIcons.database,
                iconColor: const Color(0xFFec4899),
              ),
              _buildDivider(),
              // Bangumi 图片源选项
              _buildOptionSelector(
                title: 'Bangumi 图片源',
                currentValue: _bangumiImageSource,
                options: const [
                  '直连',
                  'Cors Proxy By Zwei',
                  'CF Worker 加速',
                ],
                onChanged: (value) async {
                  final key = UserDataService
                      .getBangumiImageSourceKeyFromDisplayName(value);
                  await UserDataService.saveBangumiImageSource(key);
                  if (!mounted) return;
                  setState(() {
                    _bangumiImageSource = value;
                  });
                },
                icon: LucideIcons.image,
                iconColor: const Color(0xFFf43f5e),
              ),
              _buildDivider(),
              // M3U8 代理 URL 选项
              _buildInputOption(
                title: 'M3U8 代理 URL',
                currentValue: _m3u8ProxyUrl,
                onTap: _showM3u8ProxyUrlDialog,
                icon: LucideIcons.link,
                iconColor: const Color(0xFF6366f1),
              ),
            ],
          ),
          // ===== 加速 =====
          _buildSectionHeader('加速'),
          _buildCard(
            children: [
              // v2.0.17: CF 加速与优选 入口 (点击进入子页面)
              _buildInputOption(
                title: 'CF 加速与优选',
                currentValue: _cfSummary,
                onTap: _openCfAccelerationPage,
                icon: LucideIcons.rocket,
                iconColor: const Color(0xFFf59e0b),
              ),
            ],
          ),
          // ===== 其他 =====
          _buildSectionHeader('其他'),
          _buildCard(
            children: [
              // 本地搜索选项（本地模式下不显示）
              if (!_isLocalMode)
                _buildToggleOption(
                  title: '本地搜索',
                  value: _localSearch,
                  onChanged: (value) async {
                    await UserDataService.saveLocalSearch(value);
                    if (!mounted) return;
                    setState(() {
                      _localSearch = value;
                    });
                  },
                  icon: LucideIcons.search,
                  iconColor: const Color(0xFF3b82f6),
                ),
              if (!_isLocalMode) _buildDivider(),
              // 清除豆瓣缓存按钮
              _buildActionItem(
                title: '清除豆瓣缓存',
                icon: LucideIcons.trash2,
                iconColor: const Color(0xFFf59e0b),
                onTap: _handleClearDoubanCache,
              ),
              _buildDivider(),
              // 检查更新按钮
              _buildActionItem(
                title: '检查更新',
                icon: LucideIcons.download,
                iconColor: const Color(0xFF06b6d4),
                onTap: _handleCheckUpdate,
              ),
            ],
          ),
          // ===== 登出 (独立红色卡片) =====
          const SizedBox(height: 8),
          _buildLogoutCard(),
          // ===== 版本号 =====
          const SizedBox(height: 16),
          _buildVersionNumber(),
        ],
      ),
    );
  }
}
