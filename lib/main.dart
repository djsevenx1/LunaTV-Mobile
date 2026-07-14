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
import 'package:luna_tv/services/cf_optimizer.dart';
import 'package:luna_tv/services/content_filter_service.dart';
import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/douban_cache_service.dart';
import 'package:luna_tv/services/local_mode_storage_service.dart';
import 'package:luna_tv/services/subscription_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/user_data_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化 media_kit（移动端播放器仍需）
  MediaKit.ensureInitialized();

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
/// v2.0.31: 装 CF 优选 HTTP override (Dart HTTP 请求强制解析到优选 IP)
/// 触发条件 (任一即可):
/// - 手动优选 IP 已填 (优先级最高, 不依赖测速 / 开关)
/// - 优选测速结果非空
/// v2.0.76: 去掉 getCfWorkerEnabled() 早 return — 该开关现在是「优选 IP 启用」,
///   CF Worker 代理本身不再有总开关, 域名配了默认就生效. featureEnabled 改成
///   跟「优选 IP 启用」开关 + 实际有没有 prefer IP 联动.
Future<void> _warmupCfOptimizer() async {
  // v2.0.76: 只要域名配了就装 override (不再被 getCfWorkerEnabled 守门)
  final domain = await UserDataService.getCfWorkerDomain();
  if (domain.isEmpty) {
    return;
  }

  // v2.0.76: 「优选 IP 启用」开关 (v2.0.75 之前叫 "代理总开关")
  final preferIpEnabled = await UserDataService.getCfWorkerEnabled();
  // v2.0.31: 手动优选 IP 不需要 CfOptimizer 开关. 只要填了就生效.
  final manualIp = await UserDataService.getCfBestIp();
  // 实际能不能走优选 IP: 开关 ON + 填了 IP (或测速结果非空)
  final hasManualIp = manualIp != null && manualIp.isNotEmpty;

  final optimizerEnabled = await CfOptimizer.getEnabled();
  final bestIps = await CfOptimizer.getBestIps();
  final storedDomain = await CfOptimizer.getTargetDomain();

  // v2.0.76: featureEnabled 含义 = "override 是否实际生效"
  //   - 优选 IP 开关关 → false (override 是 no-op, HTTP 走系统 DNS)
  //   - 优选 IP 开关开 + 有 IP / 测速结果 → true
  final hasSpeedTestIps = bestIps.isNotEmpty && storedDomain == domain;
  final featureEnabled =
      preferIpEnabled && (hasManualIp || (optimizerEnabled && hasSpeedTestIps));

  // 装 override (内部 _tryOverrideAddress 决定走手动 IP / 测速 IP / 不走)
  if (hasManualIp) {
    // 手动优选 IP / 域名 模式
    CfOptimizerHttpOverrides.warmup(
      bestIps: bestIps,
      targetDomain: domain,
      featureEnabled: featureEnabled,
      manualPreferredIp: manualIp,
    );
    CfOptimizerHttpOverrides.install();
    // v2.0.32 + v2.0.37 fix: 不管 IP 还是域名都要把 _resolvedManualIp 填上
    //
    // 之前: 只在域名模式下调, IP 模式直接跳过
    // 后果: warmup() 内部把 _resolvedManualIp 清成 null, IP 模式下永远没人再设回去
    //       → 链路图判 getResolvedManualIp() == null, 节点 3/4 全灰
    //       → VideoProxyServer.tryStart() 守门 3 永远 fail, 视频代理起不来
    //
    // 现在: IP 模式 await 一下 (1ms 立即就绪), 保证 _videoProxyActive 能正确激活
    //       域名模式 fire-and-forget, 不阻塞 5s DNS 启动, 同 v2.0.32 行为
    if (_isIpv4(manualIp)) {
      await CfOptimizerHttpOverrides.resolveManualPreferred();
    } else {
      unawaited(_resolveAndSchedule(manualIp));
    }
  } else if (hasSpeedTestIps && optimizerEnabled) {
    // 测速结果模式
    CfOptimizerHttpOverrides.warmup(
      bestIps: bestIps,
      targetDomain: domain,
      featureEnabled: featureEnabled,
    );
    CfOptimizerHttpOverrides.install();
  } else {
    // 缓存空 / 域名变了 / 优选 IP 开关关, 装个 disable 的 override (不放行任何 IP 覆盖)
    CfOptimizerHttpOverrides.warmup(
      bestIps: const [],
      targetDomain: domain,
      featureEnabled: false,
    );
    CfOptimizerHttpOverrides.install();
  }

  // 后台跑优选 (7 天过期 或 没测过 或 域名变了). 仅在测速开关开时跑.
  if (optimizerEnabled && await CfOptimizer.needsRetest(currentDomain: domain)) {
    // fire-and-forget, 不 await, 让 app 启动不被优选阻塞
    unawaited(_runBackgroundOptimization(domain));
  }
}

/// v2.0.32: 解析手动优选域名 + 启动 5min 周期 re-resolve 定时器
Timer? _resolveTimer;

Future<void> _resolveAndSchedule(String domain) async {
  await CfOptimizerHttpOverrides.resolveManualPreferred();
  // 5 分钟 re-resolve 一次
  _resolveTimer?.cancel();
  _resolveTimer = Timer.periodic(
    const Duration(minutes: 5),
    (_) async {
      if (CfOptimizerHttpOverrides.needsResolve()) {
        await CfOptimizerHttpOverrides.resolveManualPreferred();
      }
    },
  );
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
