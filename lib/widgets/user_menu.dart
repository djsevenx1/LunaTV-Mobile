import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/cf_optimizer.dart';
import 'package:luna_tv/screens/cf_acceleration_page.dart';
import 'package:luna_tv/screens/login_screen.dart';
import 'package:luna_tv/services/douban_cache_service.dart';
import 'package:luna_tv/services/page_cache_service.dart';
import 'package:luna_tv/screens/diary_screen.dart';
import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/local_search_cache_service.dart';
import 'package:luna_tv/services/tmdb_service.dart';
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
  String _version = '';
  bool _preferSpeedTest = true;
  bool _localSearch = false;
  bool _isLocalMode = false;
  // v2.0.76: 这两个字段语义已重定义
  //   - _preferIpEnabled  对应 UserDataService.getCfWorkerEnabled() = "优选 IP 启用"
  //   - _videoProxyEnabled 对应 UserDataService.getVideoProxyEnabled() = "视频代理"
  // CF Worker 代理本身不再有总开关 — 域名配了就生效, 这里只展示两个状态
  bool _preferIpEnabled = true;
  bool _videoProxyEnabled = true;
  String _cfWorkerDomain = '';
  // v2.0.30: 砍掉 IP 优选, 只留 CF Worker 开关, 摘要也简化
  String _cfSummary = '未配置';
  // v2.0.77: 豆瓣登录 cookie — 登录后给豆瓣图升到 l_ratio_poster (高清)
  bool _doubanLoggedIn = false;
  // v2.0.93: TMDB API Key (v3) — 详情页大头部走 TMDB search/multi 拿
  //   精准 w1280 backdrop 替代豆瓣 coverUrl. 配了 = true, 走精准识别.
  bool _tmdbConfigured = false;
  // v2.0.97: TMDB 数据源 (跟 Bangumi 数据源一样 UX, 默认 'direct')
  //   v2.1.40 改: 默认从 'cf_worker' 改成 'direct' (加速删了, 直连是
  //   唯一可选的 TMDB 数据源). 老用户存的 'cf_worker' / 'cors_proxy'
  //   在 saveTmdbDataSource 里 migrate 到 'direct'.
  //   v2.1.41 改: 加 'tmdb_proxy' (用户自部署 CF Worker 加速, 跟
  //   _cfWorkerDomain 视频加速是 2 个独立 worker). 删 'off' (用户
  //   反馈「这个关闭不要」). 默认值看 _tmdbProxyDomain 配没配:
  //   配了默认 'tmdb_proxy', 没配默认 'direct'.
  String _tmdbDataSource = 'direct';
  // v2.1.41: TMDB 代理 URL — 用户自部署 [djsevenx1/tmdb-proxy] 部署
  //   到 Cloudflare Pages 拿到的 https://xxx.pages.dev, 走 path-based
  //   TMDB API + 图片加速. UI 在「数据源」section TMDB 数据源 selector
  //   下面一行单独输入, 默认空, 跟 [TMDB API Key] 输入框同 UX.
  String _tmdbProxyDomain = '';

  // v2.1.22: 日记 section 配置 (跟 DiaryService 同步)
  bool _diaryClearOnExit = true;
  int _diaryMaxEntries = 500;
  bool _diaryPersist = false;

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
    final preferSpeedTest = await UserDataService.getPreferSpeedTest();
    final localSearch = await UserDataService.getLocalSearch();
    // v2.0.76: 语义重命名 — 字段名跟新语义对齐
    final preferIpEnabled = await UserDataService.getCfWorkerEnabled();
    final videoProxyEnabled = await UserDataService.getVideoProxyEnabled();
    final cfWorkerDomain = await UserDataService.getCfWorkerDomain();
    final cfBestIp = await UserDataService.getCfBestIp();
    // v2.0.77: 豆瓣登录状态 — 决定详情页 / 轮播图走 l_ratio_poster 高清
    final doubanCookie = await UserDataService.getDoubanCookie();
    final doubanLoggedIn = doubanCookie != null && doubanCookie.isNotEmpty;
    // v2.0.93: TMDB API key — 决定详情页大头部走 TMDB 精准 backdrop
    final tmdbApiKey = await UserDataService.getTmdbApiKey();
    final tmdbConfigured = tmdbApiKey != null && tmdbApiKey.isNotEmpty;
    // v2.0.97: TMDB 数据源 — 跟 Bangumi 数据源一样 UX, 2 选 1
    // v2.1.41 改: 加 'tmdb_proxy' (用户自部署 CF Worker 加速, 跟视频
    //   加速是 2 个独立 worker). 删 'off' (用户反馈「这个关闭不要」).
    final tmdbDataSource = await UserDataService.getTmdbDataSourceKey();
    // v2.1.41: TMDB 代理 URL — 用户在 UI 输入的自部署 worker 地址
    final tmdbProxyDomain = await UserDataService.getTmdbProxyDomain();

    // v2.1.22: 日记 section 配置
    final diaryClearOnExit = DiaryService.clearOnExit;
    final diaryMaxEntries = DiaryService.maxEntries;
    final diaryPersist = DiaryService.persist;

    if (mounted) {
      setState(() {
        _isLocalMode = isLocalMode;
        _username = username;
        _role = _parseRoleFromCookies(cookies);
        _doubanDataSource = doubanDataSource;
        _doubanImageSource = doubanImageSource;
        _bangumiDataSource = bangumiDataSource;
        _bangumiImageSource = bangumiImageSource;
        _preferSpeedTest = preferSpeedTest;
        _localSearch = localSearch;
        _preferIpEnabled = preferIpEnabled;
        _videoProxyEnabled = videoProxyEnabled;
        _cfWorkerDomain = cfWorkerDomain;
        _cfSummary = _computeCfSummary(
          domain: cfWorkerDomain,
          preferIpEnabled: preferIpEnabled,
          videoProxyEnabled: videoProxyEnabled,
          bestIp: cfBestIp,
          resolvedIp: CfOptimizerHttpOverrides.getResolvedManualIp(),
        );
        _doubanLoggedIn = doubanLoggedIn;
        _tmdbConfigured = tmdbConfigured;
        _tmdbDataSource = tmdbDataSource;
        _tmdbProxyDomain = tmdbProxyDomain;
        _diaryClearOnExit = diaryClearOnExit;
        _diaryMaxEntries = diaryMaxEntries;
        _diaryPersist = diaryPersist;
      });
    }
  }

  /// v2.0.17: 给 user_menu 入口行用的一行状态摘要.
  /// v2.0.30: 简化, 不再展示优选 IP 数量和测速时间.
  /// v2.0.31: 展示手动优选 IP (如有).
  /// v2.0.32: 支持优选域名, 展示"域名 → 解析 IP", 实时反映 DNS 解析结果.
  /// v2.0.76: 重写 — 不再有"总开关未开"概念 (CF Worker 配了域名就生效),
  ///   摘要反映两个独立开关: 优选 IP / 视频代理.
  String _computeCfSummary({
    required String domain,
    required bool preferIpEnabled,
    required bool videoProxyEnabled,
    String? bestIp,
    String? resolvedIp,
  }) {
    if (domain.isEmpty) return '未配置';
    final bestIpDisplay = _formatBestIpDisplay(bestIp, resolvedIp);
    final flags = <String>[];
    if (videoProxyEnabled) flags.add('视频代理');
    if (preferIpEnabled && bestIpDisplay != null) flags.add('优选 IP');
    if (flags.isEmpty) {
      // 都没启用, 显示"系统 DNS"标记
      return bestIpDisplay != null
          ? '$domain · 系统 DNS · $bestIpDisplay'
          : '$domain · 系统 DNS';
    }
    if (bestIpDisplay != null) {
      return '$domain · ${flags.join('+')} · $bestIpDisplay';
    }
    return '$domain · ${flags.join('+')}';
  }

  /// v2.0.32: 把"IP / 域名"格式化成"IP xxx" 或 "域名 → IP xxx" 形式
  String? _formatBestIpDisplay(String? bestIp, String? resolvedIp) {
    if (bestIp == null || bestIp.isEmpty) return null;
    if (_isIpv4(bestIp)) {
      return 'IP $bestIp';
    }
    // 域名模式
    if (resolvedIp != null && resolvedIp.isNotEmpty) {
      return '域名 $bestIp → $resolvedIp';
    }
    return '域名 $bestIp (解析中)';
  }

  bool _isIpv4(String s) {
    final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(s);
    if (m == null) return false;
    for (var i = 1; i <= 4; i++) {
      final n = int.parse(m.group(i)!);
      if (n < 0 || n > 255) return false;
    }
    return true;
  }

  /// v2.0.30: push CF Worker 加速 子页面, 返回时刷新一行摘要
  Future<void> _openCfAccelerationPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CfAccelerationPage()),
    );
    if (!mounted) return;
    // 从子页面返回后, 重新读 CF 状态, 刷新入口行的一行摘要
    // v2.0.76: 两个独立开关都读 — 优选 IP + 视频代理
    final preferIpEnabled = await UserDataService.getCfWorkerEnabled();
    final videoProxyEnabled = await UserDataService.getVideoProxyEnabled();
    final cfWorkerDomain = await UserDataService.getCfWorkerDomain();
    final cfBestIp = await UserDataService.getCfBestIp();
    if (!mounted) return;
    setState(() {
      _preferIpEnabled = preferIpEnabled;
      _videoProxyEnabled = videoProxyEnabled;
      _cfWorkerDomain = cfWorkerDomain;
      _cfSummary = _computeCfSummary(
        domain: cfWorkerDomain,
        preferIpEnabled: preferIpEnabled,
        videoProxyEnabled: videoProxyEnabled,
        bestIp: cfBestIp,
        resolvedIp: CfOptimizerHttpOverrides.getResolvedManualIp(),
      );
    });
  }

  // v2.0.77: 弹出豆瓣 cookie 输入对话框
  //   用户从浏览器 DevTools 复制 cookie 字符串粘进来
  Future<void> _openDoubanLoginDialog() async {
    final cookie = await UserDataService.getDoubanCookie() ?? '';
    final controller = TextEditingController(text: cookie);
    controller.selection =
        TextSelection(baseOffset: 0, extentOffset: cookie.length);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor:
            widget.isDarkMode ? const Color(0xFF2c2c2c) : Colors.white,
        title: Row(
          children: [
            const Icon(LucideIcons.cookie, size: 20, color: Color(0xFF10b981)),
            const SizedBox(width: 8),
            Text(
              '登录豆瓣',
              style: FontUtils.poppins(
                ctx,
                fontSize: 18,
                color: widget.isDarkMode
                    ? const Color(0xFFffffff)
                    : const Color(0xFF1f2937),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '从浏览器 DevTools 复制 cookie 粘进来。登录后豆瓣图自动升到 l_ratio_poster (高清)。',
              style: FontUtils.poppins(
                ctx,
                fontSize: 12,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '不登录 = 现有图片不变。',
              style: FontUtils.poppins(
                ctx,
                fontSize: 12,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 4,
              minLines: 2,
              style: FontUtils.sourceCodePro(
                ctx,
                fontSize: 12,
                color: widget.isDarkMode
                    ? const Color(0xFFffffff)
                    : const Color(0xFF1f2937),
              ),
              decoration: InputDecoration(
                hintText: 'bid=xxx; __yadk_uid=xxx; ...',
                hintStyle: FontUtils.sourceCodePro(
                  ctx,
                  fontSize: 12,
                  color: widget.isDarkMode
                      ? const Color(0xFF6b7280)
                      : const Color(0xFF9ca3af),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          if (_doubanLoggedIn)
            TextButton(
              onPressed: () async {
                await UserDataService.clearDoubanCookie();
                if (!ctx.mounted) return;
                Navigator.of(ctx).pop();
                if (!mounted) return;
                setState(() => _doubanLoggedIn = false);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已退出豆瓣登录')),
                );
              },
              child: Text(
                '退出',
                style: FontUtils.poppins(
                  ctx,
                  fontSize: 14,
                  color: const Color(0xFFef4444),
                ),
              ),
            ),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(
                text:
                    '打开 https://movie.douban.com/ 登录后 F12 → Application → Cookies → movie.douban.com → 复制所有 cookie',
              ));
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                    content: Text('已复制获取步骤 (请到豆瓣网页版登录后操作)')),
              );
            },
            child: Text(
              '查看步骤',
              style: FontUtils.poppins(
                ctx,
                fontSize: 14,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              '取消',
              style: FontUtils.poppins(
                ctx,
                fontSize: 14,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ),
          ),
          TextButton(
            onPressed: () async {
              final input = controller.text.trim();
              await UserDataService.saveDoubanCookie(
                  input.isEmpty ? null : input);
              if (!ctx.mounted) return;
              Navigator.of(ctx).pop();
              if (!mounted) return;
              setState(() {
                _doubanLoggedIn = input.isNotEmpty;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(input.isEmpty
                      ? '已退出豆瓣登录'
                      : '已保存豆瓣 cookie, 海报将自动升级到高清'),
                ),
              );
            },
            child: Text(
              '保存',
              style: FontUtils.poppins(
                ctx,
                fontSize: 14,
                color: const Color(0xFF10b981),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    controller.dispose();
  }

  /// v2.0.77: 入口行一行摘要 — 已登录 = "已登录: 高清 l_ratio_poster"
  String _computeDoubanSummary() {
    if (_doubanLoggedIn) return '已登录 · 高清 l_ratio_poster';
    return '未登录 (现有图片不变化)';
  }

  /// v2.0.93: TMDB API key 入口行摘要
  String _computeTmdbSummary() {
    if (_tmdbConfigured) return '已配 · 详情页精准识别 (w1280 backdrop)';
    return '未配 (走豆瓣 coverUrl)';
  }

  // v2.0.93: 弹出 TMDB API key 输入对话框
  //   用户从 themoviedb.org/settings/api 申请 v3 key 粘进来.
  //   配了 = 详情页大头部走 TMDB search/multi 拿精准 w1280 backdrop.
  Future<void> _openTmdbApiKeyDialog() async {
    final key = await UserDataService.getTmdbApiKey() ?? '';
    final controller = TextEditingController(text: key);
    controller.selection =
        TextSelection(baseOffset: 0, extentOffset: key.length);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor:
            widget.isDarkMode ? const Color(0xFF2c2c2c) : Colors.white,
        title: Row(
          children: [
            const Icon(LucideIcons.key, size: 20, color: Color(0xFF3b82f6)),
            const SizedBox(width: 8),
            Text(
              'TMDB API Key',
              style: FontUtils.poppins(
                ctx,
                fontSize: 18,
                color: widget.isDarkMode
                    ? const Color(0xFFffffff)
                    : const Color(0xFF1f2937),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '从 themoviedb.org 申请 v3 API key (免费) 粘进来。配了详情页大背景自动切到 TMDB 精准 16:9 剧照 (替代豆瓣 coverUrl)。',
              style: FontUtils.poppins(
                ctx,
                fontSize: 12,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '不填 = 走豆瓣 coverUrl (行为完全不变)。',
              style: FontUtils.poppins(
                ctx,
                fontSize: 12,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 1,
              style: FontUtils.sourceCodePro(
                ctx,
                fontSize: 13,
                color: widget.isDarkMode
                    ? const Color(0xFFffffff)
                    : const Color(0xFF1f2937),
              ),
              decoration: InputDecoration(
                hintText: '32 位 hex 字符串, 例: 1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p',
                hintStyle: FontUtils.sourceCodePro(
                  ctx,
                  fontSize: 12,
                  color: widget.isDarkMode
                      ? const Color(0xFF6b7280)
                      : const Color(0xFF9ca3af),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          if (_tmdbConfigured)
            TextButton(
              onPressed: () async {
                await UserDataService.clearTmdbApiKey();
                if (!ctx.mounted) return;
                Navigator.of(ctx).pop();
                if (!mounted) return;
                setState(() => _tmdbConfigured = false);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已清除 TMDB API Key')),
                );
              },
              child: Text(
                '清除',
                style: FontUtils.poppins(
                  ctx,
                  fontSize: 14,
                  color: const Color(0xFFef4444),
                ),
              ),
            ),
          TextButton(
            onPressed: () async {
              Clipboard.setData(ClipboardData(
                text:
                    '打开 https://www.themoviedb.org/settings/api → 申请 v3 API Key (免费, 需注册) → 复制 "API Key (v3 auth)" 栏的 32 位 hex 字符串',
              ));
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                    content: Text('已复制获取步骤 (请到 TMDB 官网申请)')),
              );
            },
            child: Text(
              '查看步骤',
              style: FontUtils.poppins(
                ctx,
                fontSize: 14,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              '取消',
              style: FontUtils.poppins(
                ctx,
                fontSize: 14,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ),
          ),
          TextButton(
            onPressed: () async {
              final input = controller.text.trim();
              await UserDataService.saveTmdbApiKey(
                  input.isEmpty ? null : input);
              if (!ctx.mounted) return;
              Navigator.of(ctx).pop();
              if (!mounted) return;
              setState(() {
                _tmdbConfigured = input.isNotEmpty;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(input.isEmpty
                      ? '已清除 TMDB API Key'
                      : '已保存 TMDB API Key, 详情页大背景将自动升级到精准剧照'),
                ),
              );
            },
            child: Text(
              '保存',
              style: FontUtils.poppins(
                ctx,
                fontSize: 14,
                color: const Color(0xFF3b82f6),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    controller.dispose();
  }

  // v2.1.41: 弹出 TMDB 代理 URL 输入对话框
  //   用户从 [djsevenx1/tmdb-proxy] 部署到 Cloudflare Pages 拿到的
  //   https://xxx.pages.dev 粘进来. 自动强转 https://, 去尾斜杠 / 空白.
  //   空 = 清空. 选 'TMDB Worker 加速' 但这 URL 没配 → 弹 SnackBar
  //   警告, 自动回落 '直连' (见上面 selector onChanged).
  Future<void> _openTmdbProxyDomainDialog() async {
    final current = await UserDataService.getTmdbProxyDomain();
    final controller = TextEditingController(text: current);
    controller.selection =
        TextSelection(baseOffset: 0, extentOffset: current.length);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor:
            widget.isDarkMode ? const Color(0xFF2c2c2c) : Colors.white,
        title: Row(
          children: [
            const Icon(LucideIcons.cloud, size: 20, color: Color(0xFF22C55E)),
            const SizedBox(width: 8),
            Text(
              'TMDB 代理 URL',
              style: FontUtils.poppins(
                ctx,
                fontSize: 18,
                color: widget.isDarkMode
                    ? const Color(0xFFffffff)
                    : const Color(0xFF1f2937),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '部署 [djsevenx1/tmdb-proxy] 到 Cloudflare Pages, 拿到 https://xxx.pages.dev 粘到这里. 配上后「TMDB 数据源」选「TMDB Worker 加速」即走 CF 加速, 解决国内 GFW 问题.',
              style: FontUtils.poppins(
                ctx,
                fontSize: 12,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '不填 = 走「直连」 (国内 GFW, 配 VPN 才通). 自动强转 https://, 去尾斜杠.',
              style: FontUtils.poppins(
                ctx,
                fontSize: 12,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 1,
              keyboardType: TextInputType.url,
              autocorrect: false,
              style: FontUtils.sourceCodePro(
                ctx,
                fontSize: 13,
                color: widget.isDarkMode
                    ? const Color(0xFFffffff)
                    : const Color(0xFF1f2937),
              ),
              decoration: InputDecoration(
                hintText: 'https://tmdb-8d1.pages.dev',
                hintStyle: FontUtils.sourceCodePro(
                  ctx,
                  fontSize: 12,
                  color: widget.isDarkMode
                      ? const Color(0xFF6b7280)
                      : const Color(0xFF9ca3af),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          if (current.isNotEmpty)
            TextButton(
              onPressed: () async {
                await UserDataService.saveTmdbProxyDomain('');
                // v2.1.41: 清了 URL 后如果当前选的是 tmdb_proxy, 自动
                //   切回 direct, 避免 UI 显示「TMDB Worker 加速」但
                //   URL 是空的 (点了选 direct 反而会落回 tmdb_proxy,
                //   状态错乱). await 必须在 setState 外面, setState
                //   回调是 sync 的不能用 await.
                if (_tmdbDataSource == 'tmdb_proxy') {
                  await UserDataService.saveTmdbDataSource('direct');
                }
                if (!ctx.mounted) return;
                Navigator.of(ctx).pop();
                if (!mounted) return;
                setState(() {
                  _tmdbProxyDomain = '';
                  _tmdbDataSource = (UserDataService.getTmdbDataSourceSync() == 'tmdb_proxy')
                      ? 'direct'
                      : UserDataService.getTmdbDataSourceSync();
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已清除 TMDB 代理 URL')),
                );
              },
              child: Text(
                '清除',
                style: FontUtils.poppins(
                  ctx,
                  fontSize: 14,
                  color: const Color(0xFFef4444),
                ),
              ),
            ),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(
                text:
                    '1. 打开 https://github.com/djsevenx1/tmdb-proxy\n2. Fork 或 Clone 仓库到本地\n3. 在 Cloudflare Dashboard 选 Workers & Pages → Create application → Pages → Upload assets, 把仓库根目录 (含 _worker.js) 上传\n4. 部署完拿到 https://<project>.pages.dev, 粘到这',
              ));
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                    content: Text('已复制部署步骤 (Fork djsevenx1/tmdb-proxy 上 CF Pages)')),
              );
            },
            child: Text(
              '查看步骤',
              style: FontUtils.poppins(
                ctx,
                fontSize: 14,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              '取消',
              style: FontUtils.poppins(
                ctx,
                fontSize: 14,
                color: widget.isDarkMode
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF6b7280),
              ),
            ),
          ),
          TextButton(
            onPressed: () async {
              final input = controller.text.trim();
              final cleaned =
                  await UserDataService.saveTmdbProxyDomain(input);
              if (!ctx.mounted) return;
              Navigator.of(ctx).pop();
              if (!mounted) return;
              setState(() {
                _tmdbProxyDomain = cleaned ?? '';
                // v2.1.41: 刚配的 URL, 不自动切数据源, 尊重用户原选择.
                //   万一用户只是想先存 URL 备用, 切了反而骚扰.
                //   留个 snackbar 提示一下.
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(input.isEmpty
                      ? '已清除 TMDB 代理 URL'
                      : '已保存 TMDB 代理 URL, 在「TMDB 数据源」选「TMDB Worker 加速」即生效'),
                ),
              );
            },
            child: Text(
              '保存',
              style: FontUtils.poppins(
                ctx,
                fontSize: 14,
                color: const Color(0xFF22C55E),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    controller.dispose();
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
              // v2.1.40: 删 Bangumi 数据源 / 图片源 selector — 加速代码
              //   删了 Bangumi 数据/图片只能直连, 没有"加速选项"可挑了.
              //   UI 上整个 selector 移除, 跟"删 2 选 1 / 4 选 1 选项" 一致.
              // v2.1.19: TMDB 数据源从「海报墙」挪到「数据源」section —
              //   跟豆瓣数据源 / Bangumi 数据源放一起, 跟其他数据源 1:1 UX.
              //   用户反馈 "TMDB 数据源不应该放到数据源栏目吗" — 跟 Bangumi
              //   数据源/豆瓣数据源对齐, 不再跟"豆瓣登录"+"TMDB API Key"
              //   混在"海报墙"里.
              // v2.1.19: 删「已关闭」选项, 只剩 CF Worker 加速 / 直连
              //   2 选 1. 用户反馈 "关闭应该不需要吧" — 「数据源」不该有
              //   「关闭」语义, 关了就没数据源了. 真要关 → 走 "清除 TMDB
              //   缓存"上方条件渲染行? 不, 删 API key 就走豆瓣兜底 (跟
              //   v2.0.93 行为一致). 数据源选项就专心管"怎么连".
              // v2.1.40: 删 CF Worker / CORS 公共代理, 改回 '已关闭' +
              //   '直连' 2 选 1. "已关闭" 重新加回来 — 现在没加速可挑,
              //   反而需要个明确"关闭 TMDB" 的语义, 跟"直连"区分开.
              // v2.1.41 改: 删 '已关闭' (用户反馈「这个关闭不要」),
              //   加 'TMDB Worker 加速' (用户自部署 [djsevenx1/tmdb-proxy]
              //   走 path-based 加速). 2 选 1: 'TMDB Worker 加速' / '直连'.
              //   'TMDB Worker 加速' 但 _tmdbProxyDomain 没配 → 弹
              //   SnackBar 警告 + 自动回落到 '直连' (跟 v2.1.40 之前
              //   cf_worker 没配域名兜底行为一致). 下方新加
              //   [TMDB 代理 URL] 输入行, 单独配 worker URL, 跟
              //   [TMDB API Key] (在「海报墙」section) 同 UX.
              _buildOptionSelector(
                title: 'TMDB 数据源',
                currentValue: UserDataService.getTmdbDataSourceDisplayName(
                    _tmdbDataSource),
                options: const [
                  'TMDB Worker 加速',
                  '直连',
                ],
                onChanged: (value) async {
                  final key = UserDataService
                      .getTmdbDataSourceKeyFromDisplayName(value);
                  // v2.1.41: 选了 'tmdb_proxy' 但 URL 没配 → 警告 + 落 'direct'
                  if (key == 'tmdb_proxy' && _tmdbProxyDomain.isEmpty) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          '请先在下方「TMDB 代理 URL」输入 worker 地址, 已自动回落「直连」',
                        ),
                        duration: Duration(seconds: 3),
                      ),
                    );
                    await UserDataService.saveTmdbDataSource('direct');
                    if (!mounted) return;
                    setState(() {
                      _tmdbDataSource = 'direct';
                    });
                    return;
                  }
                  await UserDataService.saveTmdbDataSource(key);
                  if (!mounted) return;
                  setState(() {
                    _tmdbDataSource = key;
                  });
                  // v2.0.98: 没配 key 时切了不生效, 告诉用户为啥.
                  //   配了 key 的用户切了直接生效, 不打扰.
                  // v2.1.19: 行为不变, 只是挪位置 + 删"已关闭".
                  // v2.1.40: 行为不变.
                  // v2.1.41: 行为不变 (没配 TMDB API Key 还是走豆瓣).
                  if (!_tmdbConfigured) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          '已切换 TMDB 数据源, 但还没配 TMDB API Key, 详情页仍走豆瓣',
                        ),
                        duration: Duration(seconds: 3),
                      ),
                    );
                  }
                },
                icon: LucideIcons.database,
                iconColor: _tmdbConfigured
                    ? const Color(0xFFec4899)
                    : const Color(0xFF9ca3af),
              ),
              _buildDivider(),
              // v2.1.41: TMDB 代理 URL 输入行 — 用户自部署 [djsevenx1/tmdb-proxy]
              //   到 Cloudflare Pages 拿到的 https://xxx.pages.dev. 配了
              //   「TMDB 数据源」选 'TMDB Worker 加速' 才会用上, 没配选
              //   '直连' 也允许配 (先存着, 切的时候不用再输一次).
              //   跟 [TMDB API Key] (在「海报墙」section) 同 UX — 点击
              //   弹 dialog, 单行 TextField, 保存.
              _buildInputOption(
                title: 'TMDB 代理 URL',
                currentValue: _tmdbProxyDomain.isEmpty
                    ? '未配置'
                    : _tmdbProxyDomain,
                onTap: _openTmdbProxyDomainDialog,
                icon: _tmdbProxyDomain.isEmpty
                    ? LucideIcons.cloudOff
                    : LucideIcons.cloud,
                iconColor: _tmdbProxyDomain.isEmpty
                    ? const Color(0xFF9ca3af)
                    : const Color(0xFF22C55E),
              ),
            ],
          ),
          // ===== 加速 =====
          _buildSectionHeader('加速'),
          _buildCard(
            children: [
              // v2.0.30: CF Worker 加速 入口 (点击进入子页面)
              _buildInputOption(
                title: 'CF Worker 加速',
                currentValue: _cfSummary,
                onTap: _openCfAccelerationPage,
                icon: LucideIcons.rocket,
                iconColor: const Color(0xFFf59e0b),
              ),
            ],
          ),
          // ===== 海报墙 (v2.0.77) =====
          //   v2.0.35~v2.0.76: TMDB 海报墙 (配 API key 启用首页海报墙)
          //   v2.0.77: 改用豆瓣登录 — 登录后自动给豆瓣图升到 l_ratio_poster (高清),
          //     没登录 = 当前图片行为不变 (回退到 v2.0.76 之前没 TMDB 时的体验).
          //   单独做一个 section 跟"加速"视觉同等级, 跟"其他"杂项分开.
          //   点进去是 cookie 输入框 + 退出按钮, 不需要子页面.
          //   v2.0.93: 重新加回 TMDB API Key (从反编译 Selene-TV v1.4.6 mk4
          //     移植精准识别) — 详情页大头部走 TMDB search/multi 拿精准
          //     16:9 backdrop, 跟豆瓣登录并列. 配了哪个就用哪个, 都没配
          //     = 走 _buildPosterHeader (110x150 小海报, 旧行为).
          _buildSectionHeader('海报墙'),
          _buildCard(
            children: [
              _buildInputOption(
                title: '豆瓣登录',
                currentValue: _computeDoubanSummary(),
                onTap: _openDoubanLoginDialog,
                icon: _doubanLoggedIn
                    ? LucideIcons.userCheck
                    : LucideIcons.user,
                iconColor: _doubanLoggedIn
                    ? const Color(0xFF10b981)
                    : const Color(0xFF9ca3af),
              ),
              _buildDivider(),
              _buildInputOption(
                title: 'TMDB API Key',
                currentValue: _computeTmdbSummary(),
                onTap: _openTmdbApiKeyDialog,
                icon: _tmdbConfigured
                    ? LucideIcons.key
                    : LucideIcons.key,
                iconColor: _tmdbConfigured
                    ? const Color(0xFF3b82f6)
                    : const Color(0xFF9ca3af),
              ),
              _buildDivider(),
              // v2.0.98: TMDB 数据源永远显示 (v2.0.97 加了 if (_tmdbConfigured)
              //   条件, 没配 key 不显示, 用户反馈 "改的啥玩意选项在哪" — 跟
              //   Bangumi 数据源一样 UX 永远显示, 切了存但没配 key 时不生效.
              //   没配 key 时 icon 灰色, 配了粉色, 一眼能看出状态.
              // v2.1.19: 整行挪到「数据源」section (跟 Bangumi 数据源
              //   并列), 删「已关闭」选项 (剩 CF Worker 加速 / 直连
              //   2 选 1). 这里不再渲染, 海报墙 section 只剩:
              //   豆瓣登录 / TMDB API Key / 清除 TMDB 缓存 / 清除豆瓣缓存.
              if (_tmdbConfigured) ...[
                _buildDivider(),
                // v2.0.99.1: 清除 TMDB 缓存 — 用户排查 TMDB 大背景没出来
                //   时一键清 7 天缓存 (ref + art 两个命名空间), 排除缓存
                //   污染 (e.g. v2.0.95 硬 year 过滤的 0 result 缓存, v2.0.96
                //   改不传 year + 软 year bonus 后仍走老缓存命中 null).
                //   跟 v2.0.93 TmdbService.clearAllCache 内部接口对齐.
                _buildInputOption(
                  title: '清除 TMDB 缓存',
                  currentValue: '清除 7 天识别/图片缓存',
                  onTap: () async {
                    await TmdbService.clearAllCache();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已清除 TMDB 缓存, 下次进详情页重新识别'),
                        duration: Duration(seconds: 3),
                      ),
                    );
                  },
                  icon: LucideIcons.trash2,
                  iconColor: const Color(0xFFef4444),
                ),
              ],
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
              // v2.0.99.2: 日记 — 跳到 DiaryScreen, 看全流程运行日志
              //   (TMDB 失败 / 网络错 / 关键事件). 跟 adb logcat 互补,
              //   不用接电脑. 跟 v2.0.91 删的「log UI」区别: 那个是开发者
              //   log 实时浮层, 这次是独立日记页 (按时间序, 用户主动点开).
              _buildActionItem(
                title: '日记',
                icon: LucideIcons.fileText,
                iconColor: const Color(0xFF8b5cf6),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const DiaryScreen(),
                    ),
                  );
                },
              ),
              // v2.1.22: 日记 section 配置 — 退出清空 / 容量上限 / 持久化
              _buildToggleOption(
                title: '退出 app 自动清空',
                subtitle: '关掉后日记会保留, 但重启 app 不会丢',
                value: _diaryClearOnExit,
                onChanged: (value) async {
                  await DiaryService.setClearOnExit(value);
                  if (!mounted) return;
                  setState(() {
                    _diaryClearOnExit = value;
                  });
                },
                icon: LucideIcons.logOut,
                iconColor: const Color(0xFF8b5cf6),
              ),
              _buildOptionSelector(
                title: '容量上限',
                currentValue: '${_diaryMaxEntries} 条',
                options: const ['100 条', '500 条', '1000 条', '2000 条'],
                onChanged: (s) async {
                  final n = int.parse(s.split(' ')[0]);
                  await DiaryService.setMaxEntries(n);
                  if (!mounted) return;
                  setState(() {
                    _diaryMaxEntries = n;
                  });
                },
                icon: LucideIcons.hardDrive,
                iconColor: const Color(0xFF8b5cf6),
              ),
              _buildToggleOption(
                title: '持久化日记',
                subtitle: '开启后写进 SharedPreferences, 跨会话保留',
                value: _diaryPersist,
                onChanged: (value) async {
                  await DiaryService.setPersist(value);
                  if (!mounted) return;
                  setState(() {
                    _diaryPersist = value;
                  });
                },
                icon: LucideIcons.save,
                iconColor: const Color(0xFF8b5cf6),
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
