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

  runApp(const LunaTVApp());
}

class LunaTVApp extends StatelessWidget {
  const LunaTVApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => ThemeService(),
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
