import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

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
import 'package:luna_tv/services/douban_cache_service.dart';
import 'package:luna_tv/services/local_mode_storage_service.dart';
import 'package:luna_tv/services/subscription_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/user_data_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化 media_kit（移动端播放器仍需）
  MediaKit.ensureInitialized();

  // 初始化豆瓣缓存服务
  final cacheService = DoubanCacheService();
  await cacheService.init();

  // 启动定期清理
  cacheService.startPeriodicCleanup();

  // 异步初始化 ThemeService,恢复上次保存的主题模式
  final themeService = await ThemeService.create();

  // 预热 CF Worker 加速配置(开关+域名),后续 buildProxiedUrl 同步可用
  await UserDataService.warmupCfWorkerConfig();

  // v2.0.11: 安装 CF 优选 HttpOverrides + 预热优选 IP 缓存
  // 必须在 warmupCfWorkerConfig 之后, 才能拿到 worker 域名
  await _warmupCfOptimizer();

  runApp(LunaTVApp(themeService: themeService));
}

/// v2.0.11: 预热 CF 优选 — 装 HttpOverrides + 把优选 IP 缓存到静态变量
///
/// 触发逻辑:
/// - CF Worker 加速开关打开 + CF 优选开关打开 + 优选 IP 已缓存 → 装 override
/// - 否则 → 不装 (override 里的 _featureEnabled=false, 等于无操作)
/// - 7 天没测过 / 域名变了 → 后台跑优选, 跑完刷新缓存
Future<void> _warmupCfOptimizer() async {
  final enabled = await UserDataService.getCfWorkerEnabled();
  if (!enabled) {
    return;
  }
  final domain = await UserDataService.getCfWorkerDomain();
  if (domain.isEmpty) {
    return;
  }
  final optimizerEnabled = await CfOptimizer.getEnabled();
  if (!optimizerEnabled) {
    return;
  }

  final bestIps = await CfOptimizer.getBestIps();
  final storedDomain = await CfOptimizer.getTargetDomain();

  // 装 override (即使优选 IP 空, 装上也不影响, 内部 _featureEnabled=false)
  if (bestIps.isNotEmpty && storedDomain == domain) {
    CfOptimizerHttpOverrides.warmup(
      bestIps: bestIps,
      targetDomain: domain,
      featureEnabled: true,
    );
    CfOptimizerHttpOverrides.install();
  } else {
    // 缓存空 / 域名变了, 装个 disable 的 override
    CfOptimizerHttpOverrides.warmup(
      bestIps: const [],
      targetDomain: domain,
      featureEnabled: false,
    );
    CfOptimizerHttpOverrides.install();
  }

  // 后台跑优选 (7 天过期 或 没测过 或 域名变了)
  if (await CfOptimizer.needsRetest(currentDomain: domain)) {
    // fire-and-forget, 不 await, 让 app 启动不被优选阻塞
    unawaited(_runBackgroundOptimization(domain));
  }
}

Future<void> _runBackgroundOptimization(String domain) async {
  try {
    final ips = await CfOptimizer.runOptimization(targetDomain: domain);
    if (ips.isNotEmpty) {
      CfOptimizerHttpOverrides.refresh(
        bestIps: ips,
        targetDomain: domain,
      );
    }
  } catch (e) {
    // 静默失败, 不影响 app
  }
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
                if (content.liveSources != null &&
                    content.liveSources!.isNotEmpty) {
                  await LocalModeStorageService.saveLiveSources(
                    content.liveSources!,
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
