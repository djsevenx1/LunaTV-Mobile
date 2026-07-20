import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
// v2.2.0: 卸 media_kit (libmpv) 改 ExoPlayer (AndroidX Media3).
//   MediaKit.ensureInitialized() 不再需要 — ExoPlayer 是 AndroidX Java 库,
//   Android 进程启动时平台侧自动加载, Dart 端零额外动作.

import 'package:luna_tv/screens/bilibili_screen.dart';
import 'package:luna_tv/screens/douban_detail_screen.dart';
import 'package:luna_tv/screens/favorites_screen.dart';
import 'package:luna_tv/screens/filter_settings_screen.dart';
import 'package:luna_tv/screens/history_screen.dart';
import 'package:luna_tv/screens/home_screen.dart';
import 'package:luna_tv/screens/login_screen.dart';
import 'package:luna_tv/screens/m3u_import_screen.dart';
import 'package:luna_tv/screens/netdisk_search_screen.dart';
import 'package:luna_tv/screens/play_stats_screen.dart';
import 'package:luna_tv/screens/release_calendar_screen.dart';
import 'package:luna_tv/screens/short_drama_screen.dart';
import 'package:luna_tv/screens/youtube_screen.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/services/content_filter_service.dart';
import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/douban_cache_service.dart';
import 'package:luna_tv/services/local_mode_storage_service.dart';
import 'package:luna_tv/services/subscription_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/user_data_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // v2.4.4: 全局信任所有 SSL 证书 (跟 web Node.js undici 默认行为对齐).
  //   之前 source_browser_service.dart:44 注释撒谎说"main() 全局 HttpOverrides
  //   关 badCertificate", 但其实根本没设. 实际效果:
  //   - 自签名证书 / 过期证书 / hostname 不匹配 → HandshakeException
  //   - CF edge zone TLS 1.3 cipher 跟 dart:io OpenSSL 不兼容
  //     (luna_image_http.dart:1-14 已记录此问题, 图片走 MethodChannel+OkHttp
  //      绕开, 但 SourceBrowser / Downstream 都没绕)
  //   全部被 service 层 catch 吞成 null, UI 显示「加载失败」,
  //   这就是用户反馈「很多源都这样」(v2.4.1/v2.4.2/v2.4.3 都没修干净) 的根因.
  //   web Node.js undici 用自带 TLS 栈, cipher 支持更全, 不挂.
  //   修: 跟 web 对齐, 全局信任所有证书. 安全风险可接受 — app 只读源 API,
  //   不传敏感信息, 用户主动配的源.
  HttpOverrides.global = _AllowBadCertsOverrides();

  // v2.2.0: ExoPlayer (AndroidX Media3) 是 AndroidX Java 库, 不需要
  //   Dart 端 ensureInitialized. 之前 media_kit 的 MediaKit.ensureInitialized()
  //   是因为 libmpv .so 走 FFI 加载, 现在 ExoPlayer 走 platform channel, 启动
  //   时 Android 进程自己加载 Media3 类, Dart 端零额外动作.

  // v2.1.22: 启动时加载日记配置 (容量/退出清空/持久化) + 可选加载历史日记.
  // 必须在 add() 被任何地方调之前 load, 不然 SharedPreferences 里的配置
  // 会被默认 _maxEntries=500 / _clearOnExit=true / _persist=false 覆盖.
  await DiaryService.loadConfig();

  // 初始化豆瓣缓存服务
  final cacheService = DoubanCacheService();
  await cacheService.init();

  // 启动定期清理
  cacheService.startPeriodicCleanup();

  // 异步初始化 ThemeService,恢复上次保存的主题模式
  final themeService = await ThemeService.create();

  // v2.3.0: 只删视频加速 warmup, 保留用户配置 warmup.
  //   TMDB 幻灯片 / 详情页大背景 / GitHub 更新代理都依赖同步 getter
  //   (getTmdbApiKeySync / getTmdbProxyDomainSync), 这些字段必须启动时
  //   先从 SharedPreferences 缓存到内存; 否则首页 Hero Banner 会以为
  //   TMDB API Key 没配, 直接跳过 TMDB backdrop 升级.
  await UserDataService.warmupUserDataConfig();

  runApp(LunaTVApp(themeService: themeService));
}

class LunaTVApp extends StatelessWidget {
  final ThemeService themeService;
  const LunaTVApp({super.key, required this.themeService});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ThemeService>.value(
      value: themeService,
      child: Consumer<ThemeService>(
        builder: (context, themeService, child) {
          return MaterialApp(
            title: 'LunaTV',
            debugShowCheckedModeBanner: false,
            theme: themeService.lightTheme,
            darkTheme: themeService.darkTheme,
            themeMode: themeService.themeMode,
            routes: {
              '/filter-settings': (_) => const FilterSettingsScreen(),
              '/m3u-import': (_) => const M3uImportScreen(),
              '/douban-detail': (ctx) => DoubanDetailScreen.fromArgs(ctx),
              '/favorites': (_) => const FavoritesScreen(),
              '/history': (_) => const HistoryScreen(),
              '/shortdrama': (_) => const ShortDramaScreen(),
              '/release-calendar': (_) => const ReleaseCalendarScreen(),
              '/play-stats': (_) => const PlayStatsScreen(),
              '/youtube': (_) => const YouTubeScreen(),
              '/bilibili': (_) => const BilibiliScreen(),
              '/netdisk': (_) => const NetdiskSearchScreen(),
            },
            home: const AppWrapper(),
          );
        },
      ),
    );
  }
}

class AppWrapper extends StatefulWidget {
  const AppWrapper({super.key});

  @override
  State<AppWrapper> createState() => _AppWrapperState();
}

class _AppWrapperState extends State<AppWrapper> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    ContentFilterService.loadUserRules();
    _checkLoginStatus();
  }

  void _checkLoginStatus() async {
    try {
      // 检查是否是本地模式
      final isLocalMode = await UserDataService.getIsLocalMode();
      if (isLocalMode) {
        // 本地模式：尝试刷新订阅内容
        try {
          final subscriptionUrl =
              await LocalModeStorageService.getSubscriptionUrl();
          if (subscriptionUrl != null && subscriptionUrl.isNotEmpty) {
            final response = await http.get(Uri.parse(subscriptionUrl));
            if (response.statusCode == 200) {
              final content =
                  await SubscriptionService.parseSubscriptionContent(
                response.body,
              );
              if (content != null) {
                if (content.searchResources != null &&
                    content.searchResources!.isNotEmpty) {
                  await LocalModeStorageService.saveSearchSources(
                    content.searchResources!,
                  );
                }
              }
            }
          }
        } catch (e) {
          // 刷新失败也继续进入首页
        }
        // 无论刷新成功与否，都进入首页
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (context) => const HomeScreen()),
          );
        }
        return;
      }

      // 检查是否有自动登录所需的数据
      final hasAutoLoginData = await UserDataService.hasAutoLoginData();
      if (hasAutoLoginData && mounted) {
        // 尝试自动登录
        try {
          final resp = await ApiService.autoLogin();
          final success = resp.success;
          if (success && mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (context) => const HomeScreen()),
            );
          } else if (mounted) {
            _showLoginPage();
          }
        } catch (e) {
          if (mounted) _showLoginPage();
        }
      } else if (mounted) {
        _showLoginPage();
      }
    } catch (e) {
      if (mounted) _showLoginPage();
    }
  }

  void _showLoginPage() {
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}

/// v2.4.4: 全局信任所有 SSL 证书, 解决:
///   - 自签名证书 / 过期证书 / hostname 不匹配 → HandshakeException
///   - CF edge zone TLS 1.3 cipher 跟 dart:io OpenSSL 不兼容
///   跟 web Node.js undici 默认行为对齐. 安全风险可接受 — app 只读源 API,
///   不传敏感信息, 用户主动配的源.
class _AllowBadCertsOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}
