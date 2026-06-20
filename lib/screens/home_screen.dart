import 'dart:io';

import 'package:flutter/material.dart';
import 'package:luna_tv/widgets/continue_watching_section.dart';
import 'package:luna_tv/widgets/hot_movies_section.dart';
import 'package:luna_tv/widgets/hot_tv_section.dart';
import 'package:luna_tv/widgets/hot_show_section.dart';
import 'package:luna_tv/widgets/bangumi_section.dart';
import 'package:luna_tv/widgets/main_layout.dart';
import 'package:luna_tv/widgets/top_tab_switcher.dart';
import 'package:luna_tv/widgets/favorites_grid.dart';
import 'package:luna_tv/widgets/history_grid.dart';
import 'package:luna_tv/screens/search_screen.dart';
import 'package:luna_tv/widgets/video_menu_bottom_sheet.dart';
import 'package:luna_tv/widgets/custom_refresh_indicator.dart';
import 'package:luna_tv/models/play_record.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/utils/font_utils.dart';
import 'package:luna_tv/services/page_cache_service.dart';
import 'package:luna_tv/services/douban_service.dart';
import 'package:luna_tv/services/bangumi_service.dart';
import 'package:luna_tv/widgets/hero_banner.dart';
import 'package:luna_tv/screens/movie_screen.dart';
import 'package:luna_tv/screens/tv_screen.dart';
import 'package:luna_tv/screens/anime_screen.dart';
import 'package:luna_tv/screens/show_screen.dart';
import 'package:luna_tv/screens/player_screen.dart';
import 'package:luna_tv/screens/live_screen.dart';
import 'package:luna_tv/screens/short_drama_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentBottomNavIndex = 0;
  String _selectedTopTab = '首页';
  late PageController _pageController;
  late PageController _bottomNavPageController;

  // Hero Banner 数据
  List<HeroBannerItem> _bannerItems = [];
  bool _bannerLoaded = false;

  @override
  void initState() {
    super.initState();
    // 初始化 PageController，默认显示首页（索引0）
    _pageController = PageController(initialPage: 0);
    // 初始化底栏 PageController
    _bottomNavPageController = PageController(initialPage: 0);
    // 进入首页时直接刷新播放记录和收藏夹缓存
    _refreshCacheOnHomeEnter();
    // 加载 Hero Banner 数据
    _loadBannerData();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _bottomNavPageController.dispose();
    super.dispose();
  }

  /// 进入首页时刷新缓存
  Future<void> _refreshCacheOnHomeEnter() async {
    try {
      final cacheService = PageCacheService();

      // 异步刷新播放记录缓存
      cacheService.refreshPlayRecords(context).then((_) {
        // 刷新成功后通知继续观看组件和播放历史组件更新UI
        if (mounted) {
          ContinueWatchingSection.refreshPlayRecords();
          HistoryGrid.refreshHistory();
        }
      }).catchError((e) {
        // 静默处理错误
      });

      // 异步刷新收藏夹缓存
      cacheService.refreshFavorites(context).then((_) {
        // 刷新成功后通知收藏夹组件更新UI
        if (mounted) {
          FavoritesGrid.refreshFavorites();
        }
      }).catchError((e) {
        // 静默处理错误
      });

      // 异步刷新搜索历史缓存
      cacheService.refreshSearchHistory(context).catchError((e) {
        // 静默处理错误
      });
    } catch (e) {
      // 静默处理错误，不影响首页正常显示
    }
  }

  /// 加载 Hero Banner 数据（从热门电影/剧集/番剧取前几项）
  Future<void> _loadBannerData() async {
    if (_bannerLoaded) return;
    try {
      final moviesResult = await DoubanService.getHotMovies(context);
      final tvResult = await DoubanService.getHotTvShows(context);
      final animeResult = await BangumiService.getTodayCalendar(context);

      if (!mounted) return;

      final List<HeroBannerItem> items = [];

      if (moviesResult.success && moviesResult.data != null) {
        for (final m in moviesResult.data!.take(3)) {
          items.add(HeroBannerItem(
            id: m.id,
            title: m.title,
            subtitle: '热门电影',
            imageUrl: m.poster,
            type: 'movie',
            source: 'douban',
            id_: m.id,
            year: m.year.isNotEmpty ? m.year : null,
            rate: m.rate,
          ));
        }
      }
      if (tvResult.success && tvResult.data != null) {
        for (final t in tvResult.data!.take(2)) {
          items.add(HeroBannerItem(
            id: t.id,
            title: t.title,
            subtitle: '热播剧集',
            imageUrl: t.poster,
            type: 'tv',
            source: 'douban',
            id_: t.id,
            year: t.year.isNotEmpty ? t.year : null,
            rate: t.rate,
          ));
        }
      }
      if (animeResult.success && animeResult.data != null) {
        for (final a in animeResult.data!.take(2)) {
          final name = (a.nameCn != null && a.nameCn!.isNotEmpty)
              ? a.nameCn!
              : a.name;
          final year = a.airDate.isNotEmpty
              ? a.airDate.split('-').first
              : null;
          final imageUrl = a.images.bestImageUrl;
          if (imageUrl.isEmpty) continue;
          items.add(HeroBannerItem(
            id: a.id.toString(),
            title: name,
            subtitle: '新番放送',
            imageUrl: imageUrl,
            type: 'anime',
            source: 'bangumi',
            id_: a.id.toString(),
            year: year,
            rate: a.rating.score > 0
                ? a.rating.score.toStringAsFixed(1)
                : null,
          ));
        }
      }

      if (mounted && items.isNotEmpty) {
        setState(() {
          _bannerItems = items;
          _bannerLoaded = true;
        });
      }
    } catch (_) {
      // banner 加载失败不影响首页
    }
  }

  /// 刷新首页数据
  Future<void> _refreshHomeData() async {
    if (!mounted) return;

    try {
      // 调用各个组件的刷新方法
      // 刷新继续观看组件
      await ContinueWatchingSection.refreshPlayRecords();

      // 刷新播放历史组件
      await HistoryGrid.refreshHistory();

      // 刷新收藏夹组件
      await FavoritesGrid.refreshFavorites();

      // 刷新热门电影组件
      await HotMoviesSection.refreshHotMovies();

      // 刷新热门剧集组件
      await HotTvSection.refreshHotTvShows();

      // 刷新新番放送组件
      await BangumiSection.refreshBangumiCalendar();

      // 刷新热门综艺组件
      await HotShowSection.refreshHotShows();

      if (!mounted) return;
      // 强制重建页面
      setState(() {});
    } catch (e) {
      // 刷新失败，静默处理
    }
  }

  /// 构建首页内容（带 PageView 支持滑动切换）
  Widget _buildHomeContentWithPageView() {
    return Column(
      children: [
        // 顶部导航栏
        TopTabSwitcher(
          selectedTab: _selectedTopTab,
          onTabChanged: _onTopTabChanged,
        ),
        // PageView 支持左右滑动
        Expanded(
          child: PageView(
            controller: _pageController,
            onPageChanged: (index) {
              if (!mounted) return;

              // 根据页面索引更新选中的标签
              String newTab;
              switch (index) {
                case 0:
                  newTab = '首页';
                  break;
                case 1:
                  newTab = '播放历史';
                  break;
                case 2:
                  newTab = '收藏夹';
                  break;
                default:
                  newTab = '首页';
              }

              // 只在标签真正改变时更新状态
              if (_selectedTopTab != newTab) {
                setState(() {
                  _selectedTopTab = newTab;
                });
              }
            },
            children: [
              // 首页内容
              _buildHomeTabContent(),
              // 播放历史内容
              _buildHistoryTabContent(),
              // 收藏夹内容
              _buildFavoritesTabContent(),
            ],
          ),
        ),
      ],
    );
  }

  /// 构建首页标签内容
  Widget _buildHomeTabContent() {
    return StyledRefreshIndicator(
      onRefresh: _refreshHomeData,
      refreshText: '刷新中...',
      primaryColor: const Color(0xFF27AE60),
      child: SingleChildScrollView(
        child: Column(
          children: [
            // Hero Banner 幻灯片
            if (_bannerItems.isNotEmpty)
              HeroBanner(
                items: _bannerItems,
                onTap: (item) {
                  _navigateToPlayer(
                    PlayerScreen(
                      source: item.source,
                      id: item.id_,
                      title: item.title,
                      year: item.year ?? '',
                    ),
                  );
                },
              ),
            const SizedBox(height: 8),
            // 继续观看组件
            ContinueWatchingSection(
              onVideoTap: _onVideoTap,
              onGlobalMenuAction: _onGlobalMenuAction,
              onViewAll: () {
                // 切换到播放历史标签
                _onTopTabChanged('播放历史');
              },
            ),
            // 热门电影组件
            HotMoviesSection(
              onMovieTap: (videoInfo) {
                _navigateToPlayer(
                  PlayerScreen(
                    source: videoInfo.source,
                    id: videoInfo.id,
                    title: videoInfo.title,
                    year: videoInfo.year,
                  ),
                );
              },
              onMoreTap: () => _onBottomNavChanged(1),
              onGlobalMenuAction: (videoInfo, action) {
                if (action == VideoMenuAction.play) {
                  _navigateToPlayer(
                    PlayerScreen(
                      source: videoInfo.source,
                      id: videoInfo.id,
                      title: videoInfo.title,
                      year: videoInfo.year,
                    ),
                  );
                } else {
                  _onGlobalMenuActionFromVideoInfo(videoInfo, action);
                }
              },
            ),
            // 热门剧集组件
            HotTvSection(
              onTvTap: (videoInfo) {
                _navigateToPlayer(
                  PlayerScreen(
                    source: videoInfo.source,
                    id: videoInfo.id,
                    title: videoInfo.title,
                    year: videoInfo.year,
                  ),
                );
              },
              onMoreTap: () => _onBottomNavChanged(2),
              onGlobalMenuAction: (videoInfo, action) {
                if (action == VideoMenuAction.play) {
                  _navigateToPlayer(
                    PlayerScreen(
                      source: videoInfo.source,
                      id: videoInfo.id,
                      title: videoInfo.title,
                      year: videoInfo.year,
                    ),
                  );
                } else {
                  _onGlobalMenuActionFromVideoInfo(videoInfo, action);
                }
              },
            ),
            // 新番放送组件
            BangumiSection(
              onBangumiTap: (videoInfo) {
                _navigateToPlayer(
                  PlayerScreen(
                    source: videoInfo.source,
                    id: videoInfo.id,
                    title: videoInfo.title,
                    year: videoInfo.year,
                  ),
                );
              },
              onMoreTap: () => _onBottomNavChanged(3),
              onGlobalMenuAction: (videoInfo, action) {
                if (action == VideoMenuAction.play) {
                  _navigateToPlayer(
                    PlayerScreen(
                      source: videoInfo.source,
                      id: videoInfo.id,
                      title: videoInfo.title,
                      year: videoInfo.year,
                    ),
                  );
                } else {
                  _onGlobalMenuActionFromVideoInfo(videoInfo, action);
                }
              },
            ),
            // 热门综艺组件
            HotShowSection(
              onShowTap: (videoInfo) {
                _navigateToPlayer(
                  PlayerScreen(
                    source: videoInfo.source,
                    id: videoInfo.id,
                    title: videoInfo.title,
                    year: videoInfo.year,
                  ),
                );
              },
              onMoreTap: () => _onBottomNavChanged(5),
              onGlobalMenuAction: (videoInfo, action) {
                if (action == VideoMenuAction.play) {
                  _navigateToPlayer(
                    PlayerScreen(
                      source: videoInfo.source,
                      id: videoInfo.id,
                      title: videoInfo.title,
                      year: videoInfo.year,
                    ),
                  );
                } else {
                  _onGlobalMenuActionFromVideoInfo(videoInfo, action);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 构建播放历史标签内容
  Widget _buildHistoryTabContent() {
    return StyledRefreshIndicator(
      onRefresh: _refreshHomeData,
      refreshText: '刷新中...',
      primaryColor: const Color(0xFF27AE60),
      child: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 4),
            HistoryGrid(
              onVideoTap: _onVideoTap,
              onGlobalMenuAction: _onGlobalMenuAction,
            ),
          ],
        ),
      ),
    );
  }

  /// 构建收藏夹标签内容
  Widget _buildFavoritesTabContent() {
    return StyledRefreshIndicator(
      onRefresh: _refreshHomeData,
      refreshText: '刷新中...',
      primaryColor: const Color(0xFF27AE60),
      child: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 4),
            FavoritesGrid(
              onVideoTap: _onVideoTap,
              onGlobalMenuAction:
                  (VideoInfo videoInfo, VideoMenuAction action) {
                // 将VideoInfo转换为PlayRecord用于统一处理
                final playRecord = PlayRecord(
                  id: videoInfo.id,
                  source: videoInfo.source,
                  title: videoInfo.title,
                  sourceName: videoInfo.sourceName,
                  year: videoInfo.year,
                  cover: videoInfo.cover,
                  index: videoInfo.index,
                  totalEpisodes: videoInfo.totalEpisodes,
                  playTime: videoInfo.playTime,
                  totalTime: videoInfo.totalTime,
                  saveTime: videoInfo.saveTime,
                  searchTitle: videoInfo.searchTitle,
                );
                _onGlobalMenuAction(playRecord, action);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MainLayout(
      content: _buildBottomNavPageView(),
      currentBottomNavIndex: _currentBottomNavIndex,
      onBottomNavChanged: _onBottomNavChanged,
      selectedTopTab: _selectedTopTab,
      onTopTabChanged: _onTopTabChanged,
      onHomeTap: _onHomeTap,
      onSearchTap: _onSearchTap,
    );
  }

  /// 构建底栏 PageView，支持左右滑动切换
  Widget _buildBottomNavPageView() {
    return PageView(
      controller: _bottomNavPageController,
      onPageChanged: (index) {
        if (!mounted) return;
        if (_currentBottomNavIndex != index) {
          setState(() {
            _currentBottomNavIndex = index;
          });
        }
      },
      children: [
        _buildHomeContentWithPageView(),
        const MovieScreen(),
        const TvScreen(),
        const AnimeScreen(),
        const ShortDramaScreen(),
        const ShowScreen(),
        const LiveScreen(),
      ],
    );
  }

  /// 处理底部导航栏切换
  void _onBottomNavChanged(int index) {
    if (!mounted) return;

    // 防止重复点击同一个标签
    if (_currentBottomNavIndex == index) {
      return;
    }

    setState(() {
      _currentBottomNavIndex = index;
    });

    // 使用动画切换到对应页面
    if (_bottomNavPageController.hasClients) {
      _bottomNavPageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  /// 处理顶部标签切换
  void _onTopTabChanged(String tab) {
    if (!mounted) return;

    // 防止重复点击同一个标签
    if (_selectedTopTab == tab) {
      return;
    }

    setState(() {
      _selectedTopTab = tab;
    });

    // 同步 PageView 的页面切换
    int? pageIndex;
    switch (tab) {
      case '首页':
        pageIndex = 0;
        break;
      case '播放历史':
        // 独立页面
        if (mounted) {
          Navigator.of(context, rootNavigator: true).pushNamed('/history');
        }
        break;
      case '收藏夹':
        // 独立页面
        if (mounted) {
          Navigator.of(context, rootNavigator: true).pushNamed('/favorites');
        }
        break;
      default:
        pageIndex = 0;
    }

    // 使用动画切换到对应页面（仅首页）
    if (pageIndex != null && _pageController.hasClients) {
      _pageController.animateToPage(
        pageIndex,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  /// 处理点击搜索按钮
  void _onSearchTap() {
    if (Platform.isIOS) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => const SearchScreen(),
        ),
      ).then((_) {
        // 从搜索页面返回时刷新数据
        if (mounted) {
          _refreshOnResume();
        }
      });
    } else {
      Navigator.push(
        context,
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              const SearchScreen(),
          transitionDuration: Duration.zero, // 无打开动画
          reverseTransitionDuration: Duration.zero, // 无关闭动画
        ),
      ).then((_) {
        // 从搜索页面返回时刷新数据
        if (mounted) {
          _refreshOnResume();
        }
      });
    }
  }

  /// 处理点击 LunaTV 标题跳转到首页
  void _onHomeTap() {
    if (!mounted) return;

    setState(() {
      // 切换到首页
      _currentBottomNavIndex = 0;
      // 切换到首页标签
      _selectedTopTab = '首页';
    });

    // 使用动画切换到首页
    if (_bottomNavPageController.hasClients) {
      _bottomNavPageController.animateToPage(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }

    // 同时切换顶部标签到首页
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  /// 处理视频卡片点击
  void _onVideoTap(PlayRecord playRecord) {
    _navigateToPlayer(
      PlayerScreen(
        source: playRecord.source,
        id: playRecord.id,
        title: playRecord.title,
        year: playRecord.year,
      ),
    );
  }

  /// 处理来自VideoInfo的全局菜单操作
  void _onGlobalMenuActionFromVideoInfo(
      VideoInfo videoInfo, VideoMenuAction action) {
    // 将VideoInfo转换为PlayRecord用于统一处理
    final playRecord = PlayRecord(
      id: videoInfo.id,
      source: videoInfo.source,
      title: videoInfo.title,
      sourceName: videoInfo.sourceName,
      year: videoInfo.year,
      cover: videoInfo.cover,
      index: videoInfo.index,
      totalEpisodes: videoInfo.totalEpisodes,
      playTime: videoInfo.playTime,
      totalTime: videoInfo.totalTime,
      saveTime: videoInfo.saveTime,
      searchTitle: videoInfo.searchTitle,
    );
    _onGlobalMenuAction(playRecord, action);
  }

  /// 处理视频菜单操作
  void _onGlobalMenuAction(PlayRecord playRecord, VideoMenuAction action) {
    switch (action) {
      case VideoMenuAction.play:
        _navigateToPlayer(
          PlayerScreen(
            source: playRecord.source,
            id: playRecord.id,
            title: playRecord.title,
            year: playRecord.year,
          ),
        );
        break;
      case VideoMenuAction.favorite:
        // 收藏
        _handleFavorite(playRecord);
        break;
      case VideoMenuAction.unfavorite:
        // 取消收藏
        _handleUnfavorite(playRecord);
        break;
      case VideoMenuAction.deleteRecord:
        // 删除记录
        _deletePlayRecord(playRecord);
        break;
      case VideoMenuAction.doubanDetail:
        // 豆瓣详情 - 已在组件内部处理URL跳转
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '正在打开豆瓣详情: ${playRecord.title}',
              style: FontUtils.poppins(context, color: Colors.white),
            ),
            backgroundColor: const Color(0xFF3498DB),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
        break;
      case VideoMenuAction.bangumiDetail:
        // Bangumi详情 - 已在组件内部处理URL跳转
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '正在打开 Bangumi 详情: ${playRecord.title}',
              style: FontUtils.poppins(context, color: Colors.white),
            ),
            backgroundColor: const Color(0xFF3498DB),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
        break;
    }
  }

  /// 从继续观看UI中移除播放记录
  void _removePlayRecordFromUI(PlayRecord playRecord) {
    // 调用继续观看组件和播放历史组件的静态移除方法
    ContinueWatchingSection.removePlayRecordFromUI(
        playRecord.source, playRecord.id);
    HistoryGrid.removeHistoryFromUI(playRecord.source, playRecord.id);
  }

  /// 删除播放记录
  Future<void> _deletePlayRecord(PlayRecord playRecord) async {
    try {
      // 先从UI中移除记录
      _removePlayRecordFromUI(playRecord);

      // 使用统一的删除方法（包含缓存操作和API调用）
      final cacheService = PageCacheService();
      final result = await cacheService.deletePlayRecord(
        playRecord.source,
        playRecord.id,
        context,
      );

      if (!result.success) {
        throw Exception(result.errorMessage ?? '删除失败');
      }
    } catch (e) {
      // 删除失败时显示错误提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '删除失败: ${e.toString()}',
              style: FontUtils.poppins(context, color: Colors.white),
            ),
            backgroundColor: const Color(0xFFe74c3c),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    } finally {
      // 异步刷新播放记录缓存
      if (mounted) {
        _refreshPlayRecordsCache();
      }
    }
  }

  /// 异步刷新播放记录缓存
  Future<void> _refreshPlayRecordsCache() async {
    try {
      final cacheService = PageCacheService();
      await cacheService.refreshPlayRecords(context);
    } catch (e) {
      // 刷新缓存失败，静默处理
    }
  }

  /// 跳转到播放页的通用方法
  Future<void> _navigateToPlayer(Widget playerScreen) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => playerScreen),
    );

    if (!mounted) return;
    _refreshOnResume();
  }

  /// 从播放页返回时刷新播放记录
  Future<void> _refreshOnResume() async {
    try {
      // 通知继续观看组件和播放历史组件更新UI
      if (mounted) {
        ContinueWatchingSection.refreshPlayRecords();
        HistoryGrid.refreshHistory();
        FavoritesGrid.refreshFavorites();
      }
    } catch (e) {
      // 刷新失败，静默处理
    }
  }

  /// 处理收藏
  Future<void> _handleFavorite(PlayRecord playRecord) async {
    try {
      // 构建收藏数据
      final favoriteData = {
        'cover': playRecord.cover,
        'save_time': DateTime.now().millisecondsSinceEpoch,
        'source_name': playRecord.sourceName,
        'title': playRecord.title,
        'total_episodes': playRecord.totalEpisodes,
        'year': playRecord.year,
      };

      // 使用统一的收藏方法（包含缓存操作和API调用）
      final cacheService = PageCacheService();
      final result = await cacheService.addFavorite(
          playRecord.source, playRecord.id, favoriteData, context);

      if (result.success) {
        // 通知UI刷新收藏状态
        if (mounted) {
          setState(() {});
        }
      } else {
        // 显示错误提示
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.errorMessage ?? '收藏失败',
                style: FontUtils.poppins(context, color: Colors.white),
              ),
              backgroundColor: const Color(0xFFe74c3c),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              margin: const EdgeInsets.all(16),
            ),
          );
        }
        _refreshFavorites();
      }
    } catch (e) {
      // 显示错误提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '收藏失败: ${e.toString()}',
              style: FontUtils.poppins(context, color: Colors.white),
            ),
            backgroundColor: const Color(0xFFe74c3c),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
      _refreshFavorites();
    }
  }

  /// 处理取消收藏
  Future<void> _handleUnfavorite(PlayRecord playRecord) async {
    try {
      // 先立即从UI中移除该项目
      FavoritesGrid.removeFavoriteFromUI(playRecord.source, playRecord.id);

      // 通知继续观看组件刷新收藏状态
      if (mounted) {
        setState(() {});
      }

      // 使用统一的取消收藏方法（包含缓存操作和API调用）
      final cacheService = PageCacheService();
      final result = await cacheService.removeFavorite(
          playRecord.source, playRecord.id, context);

      if (!result.success) {
        // 显示错误提示
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.errorMessage ?? '取消收藏失败',
                style: FontUtils.poppins(context, color: Colors.white),
              ),
              backgroundColor: const Color(0xFFe74c3c),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              margin: const EdgeInsets.all(16),
            ),
          );
        }
        // API失败时重新刷新缓存以恢复数据
        _refreshFavorites();
      }
    } catch (e) {
      // 显示错误提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '取消收藏失败: ${e.toString()}',
              style: FontUtils.poppins(context, color: Colors.white),
            ),
            backgroundColor: const Color(0xFFe74c3c),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
      // 异常时重新刷新缓存以恢复数据
      _refreshFavorites();
    }
  }

  /// 异步刷新收藏夹数据
  Future<void> _refreshFavorites() async {
    try {
      // 刷新收藏夹缓存数据
      await PageCacheService().refreshFavorites(context);

      // 通知收藏夹组件刷新UI
      FavoritesGrid.refreshFavorites();
    } catch (e) {
      // 错误处理，静默处理
    }
  }
}
