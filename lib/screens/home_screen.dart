import 'dart:io';

import 'package:flutter/material.dart';
import 'package:luna_tv/widgets/continue_watching_section.dart';
import 'package:luna_tv/widgets/hot_movies_section.dart';
import 'package:luna_tv/widgets/hot_tv_section.dart';
import 'package:luna_tv/widgets/hot_show_section.dart';
import 'package:luna_tv/widgets/bangumi_section.dart';
import 'package:luna_tv/widgets/hot_short_drama_section.dart';
import 'package:luna_tv/widgets/main_layout.dart';
import 'package:luna_tv/widgets/section_title.dart';
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
import 'package:luna_tv/services/tmdb_service.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/widgets/hero_banner.dart';
import 'package:luna_tv/screens/movie_screen.dart';
import 'package:luna_tv/screens/tv_screen.dart';
import 'package:luna_tv/screens/anime_screen.dart';
import 'package:luna_tv/screens/show_screen.dart';
import 'package:luna_tv/screens/player_screen.dart';
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

  /// 加载 Hero Banner 数据（从豆瓣近期热门电影/剧集/综艺 + 番剧取前几项）
  /// 对齐 LunaTV web 版的动态 banner：数据来自豆瓣 recent_hot 接口，
  /// 内容随时间变化；缓存由 DoubanCacheService（6小时）管理，无需一次性守卫。
  Future<void> _loadBannerData() async {
    try {
      final moviesResult = await DoubanService.getHotMovies(context);
      final tvResult = await DoubanService.getHotTvShows(context);
      final showResult = await DoubanService.getHotShows(context);
      final animeResult = await BangumiService.getTodayCalendar(context);

      if (!mounted) return;

      final List<HeroBannerItem> items = [];

      // 热门电影 - 取前 2 部（对齐 web 版）
      if (moviesResult.success && moviesResult.data != null) {
        for (final m in moviesResult.data!.take(2)) {
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
      // 热门剧集 - 取前 2 部（对齐 web 版）
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
      // 热门综艺 - 取前 1 部（对齐 web 版）
      if (showResult.success && showResult.data != null) {
        for (final s in showResult.data!.take(1)) {
          items.add(HeroBannerItem(
            id: s.id,
            title: s.title,
            subtitle: '热门综艺',
            imageUrl: s.poster,
            type: 'show',
            source: 'douban',
            id_: s.id,
            year: s.year.isNotEmpty ? s.year : null,
            rate: s.rate,
          ));
        }
      }
      // 新番放送 - 取前 1 部（对齐 web 版）
      if (animeResult.success && animeResult.data != null) {
        for (final a in animeResult.data!.take(1)) {
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
        });
        // v2.1.19: 用 TMDB 16:9 backdrop 替换豆瓣竖海报 (banner 全屏
        //   宽屏视觉, 16:9 比 2:3 适配更好). 串行 enrich 每拉到 1 个
        //   就 setState 替换, 失败/没配 key 保留豆瓣海报 (跟之前完全一致).
        _enrichBannerItemsWithTmdb();
      }
    } catch (_) {
      // banner 加载失败不影响首页
    }
  }

  /// v2.1.37: 用 TMDB 16:9 backdrop 升级 banner 背景图.
  ///   串行处理 (避免触发 TMDB rate limit), 每个 item 拉到 backdrop 后
  ///   立即 setState 替换 imageUrl, 失败/没配 key 保留豆瓣/bangumi 原图.
  ///   v2.1.37: 去掉番剧跳过, 配置了 TMDB key 后第 6 张 (番剧) 也升级.
  Future<void> _enrichBannerItemsWithTmdb() async {
    if (!UserDataService.isTmdbConfigured()) return;
    for (int i = 0; i < _bannerItems.length; i++) {
      if (!mounted) return;
      final item = _bannerItems[i];
      try {
        // v2.1.19: 跟 _loadTmdbBackdrop 同样的 search-first 模式.
        //   7 天 TTL 缓存, 重复进首页 0 网络.
        // v2.1.21: HeroBannerItem.year 是 String? (e.g. "2023"),
        //   search 接受 int? year, 用 int.tryParse 转. 不转编译挂
        //   (v2.1.19/v2.1.20 都挂在这, 'String? can't be assigned to int?').
        //   转失败 → null, search 走不带 year 匹配 (跟 player_screen
        //   _loadTmdbBackdrop 用 RegExp 抽 4 位数字的模式一致, 更稳).
        // v2.1.21: 用 search 拿 (mediaType, id), 不用 fetchOverview —
        //   fetchOverview 返回 String? (剧情简介), 跟 fetchArt 的 int id
        //   参数没关系. v2.1.19/v2.1.20 错用 fetchOverview 当 ref 拿
        //   overview.id, 编译挂 ('String' 没 id 字段) 一直报到这里.
        //   跟 player_screen._loadTmdbBackdrop 一样的 2 步流程:
        //     ref = search(title, year)
        //     art = fetchArt(ref.id, ref.mediaType)
        final yearInt = (item.year != null && item.year!.isNotEmpty)
            ? int.tryParse(item.year!)
            : null;
        final ref = await TmdbService.search(
          title: item.title, year: yearInt);
        if (ref == null || !mounted) continue;
        final art = await TmdbService.fetchArt(
          id: ref.id, mediaType: ref.mediaType);
        // v2.1.20: 用 backdropUrl 中间变量 + null 检查, 替代
        //   art!.backdropUrl! 双重 force unwrap. 跨 await 的 nullable
        //   narrow 在 Dart 推断里可能不传递, 显式中间变量更稳.
        final backdropUrl = art?.backdropUrl;
        if (backdropUrl == null || !mounted) continue;
        if (mounted) {
          setState(() {
            // v2.1.19: 直接替换 imageUrl 字段, 其它字段 (id/title/...)
            //   全部保持. HeroBannerItem 是不可变数据类, 重新构造一次.
            _bannerItems[i] = HeroBannerItem(
              id: item.id,
              title: item.title,
              subtitle: item.subtitle,
              imageUrl: backdropUrl,
              type: item.type,
              source: 'tmdb', // 标记来源, 走 worker 加速 (跟详情页大头部一致)
              id_: item.id_,
              year: item.year,
              rate: item.rate,
              description: item.description,
            );
          });
        }
      } catch (e) {
        // v2.1.19: 静默 fallback — 拉取失败保留豆瓣海报, 不影响首页.
        DiaryService.add('[TMDB banner] enrich error: $e');
      }
    }
  }

  /// 刷新首页数据
  Future<void> _refreshHomeData() async {
    if (!mounted) return;

    try {
      // 刷新 Hero Banner（下拉刷新时重新拉取轮播数据，缓存由 DoubanCacheService 管理）
      _loadBannerData();

      // 调用各个组件的刷新方法
      // 刷新继续观看组件
      await ContinueWatchingSection.refreshPlayRecords();

      // 刷新播放历史组件
      await HistoryGrid.refreshHistory();

      // 刷新收藏夹组件
      await FavoritesGrid.refreshFavorites();

      // 刷新热门电影组件
      // v2.0.43: 砍掉首页 TMDB 替换, 永远走原 Douban section (v2.0.37 行为)
      await HotMoviesSection.refreshHotMovies();

      // 刷新热门剧集组件
      await HotTvSection.refreshHotTvShows();

      // 刷新新番放送组件
      await BangumiSection.refreshBangumiCalendar();

      // 刷新热门综艺组件
      await HotShowSection.refreshHotShows();

      // 刷新热门短剧组件
      await HotShortDramaSection.refreshHotShortDramas();

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
                    videoInfo: VideoInfo(
                      id: item.id_,
                      source: item.source,
                      title: item.title,
                      sourceName: item.source,
                      year: item.year ?? '',
                      cover: item.imageUrl,
                      index: 0,
                      totalEpisodes: 0,
                      playTime: 0,
                      totalTime: 0,
                      saveTime: 0,
                      searchTitle: item.title,
                      doubanId: item.type == 'movie' || item.type == 'tv'
                          ? item.id
                          : null,
                      rate: item.rate,
                    ),
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
            // v2.0.43: 砍掉首页「热门电影 / 热门剧集」section 的 TMDB 替换
            //   (用户反馈"热门不需要啊"). 之前 v2.0.38 + v2.0.41 配了 TMDB key
            //   切到 TmdbPosterWall 横滚海报, 但 TMDB API SSL 不稳 + 横滚海报
            //   信息密度低, 不适合首页大流量. 改回原 Douban section (v2.0.37 行为).
            //   TMDB 用法集中在「选源播放」详情页大头部 (TmdbDetailHeader v2.0.43
            //   升级为更突出的 2:3 竖海报 + 大标题 + 评分 + 简介).
            HotMoviesSection(
              onMovieTap: (playRecord) {
                _navigateToPlayer(
                  PlayerScreen(videoInfo: VideoInfo.fromPlayRecord(playRecord)),
                );
              },
              onMoreTap: () => _onBottomNavChanged(1),
              onGlobalMenuAction: (videoInfo, action) {
                if (action == VideoMenuAction.play) {
                  _navigateToPlayer(
                    PlayerScreen(videoInfo: videoInfo),
                  );
                } else {
                  _onGlobalMenuActionFromVideoInfo(videoInfo, action);
                }
              },
            ),
            HotTvSection(
              onTvTap: (playRecord) {
                _navigateToPlayer(
                  PlayerScreen(videoInfo: VideoInfo.fromPlayRecord(playRecord)),
                );
              },
              onMoreTap: () => _onBottomNavChanged(2),
              onGlobalMenuAction: (videoInfo, action) {
                if (action == VideoMenuAction.play) {
                  _navigateToPlayer(
                    PlayerScreen(videoInfo: videoInfo),
                  );
                } else {
                  _onGlobalMenuActionFromVideoInfo(videoInfo, action);
                }
              },
            ),
            // 新番放送组件
            BangumiSection(
              onBangumiTap: (playRecord) {
                _navigateToPlayer(
                  PlayerScreen(videoInfo: VideoInfo.fromPlayRecord(playRecord)),
                );
              },
              onMoreTap: () => _onBottomNavChanged(3),
              onGlobalMenuAction: (videoInfo, action) {
                if (action == VideoMenuAction.play) {
                  _navigateToPlayer(
                    PlayerScreen(videoInfo: videoInfo),
                  );
                } else {
                  _onGlobalMenuActionFromVideoInfo(videoInfo, action);
                }
              },
            ),
            // 热门综艺组件
            HotShowSection(
              onShowTap: (playRecord) {
                _navigateToPlayer(
                  PlayerScreen(videoInfo: VideoInfo.fromPlayRecord(playRecord)),
                );
              },
              onMoreTap: () => _onBottomNavChanged(5),
              onGlobalMenuAction: (videoInfo, action) {
                if (action == VideoMenuAction.play) {
                  _navigateToPlayer(
                    PlayerScreen(videoInfo: videoInfo),
                  );
                } else {
                  _onGlobalMenuActionFromVideoInfo(videoInfo, action);
                }
              },
            ),
            // 热门短剧组件 - 放在最底部
            HotShortDramaSection(
              onDramaTap: (playRecord) {
                _navigateToPlayer(
                  PlayerScreen(videoInfo: VideoInfo.fromPlayRecord(playRecord)),
                );
              },
              onMoreTap: () => _onBottomNavChanged(4),
              onGlobalMenuAction: (videoInfo, action) {
                if (action == VideoMenuAction.play) {
                  _navigateToPlayer(
                    PlayerScreen(videoInfo: videoInfo),
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
  ///
  /// v2.5.15: PageView → PageView.builder + AutomaticKeepAliveClientMixin.
  ///   之前 `PageView(children: [6 个 Screen])` 会一次性 build 所有 6 个
  ///   child 的 initState, 导致:
  ///     1. App 启动时 6 个 tab 的数据全开始拉 (短剧 / 电影 / 剧集 / 动漫 / 综艺)
  ///     2. 短剧 tab 立刻发 ~9 个 HTTP 请求拉分类/全部数据
  ///   用户反馈: 「打开app就开始加载短剧里面的内容二不是打开短剧以后加载」.
  ///   PageView.builder 只 build viewport 内的 child (默认 viewport 1 页 +
  ///   左右各 1 页预览), 远离 viewport 的 child 不会 build, 数据不会
  ///   提前拉. 配合 AutomaticKeepAliveClientMixin 保持已访问过的 child
  ///   state (避免切走再切回丢失滚动位置 / 加载状态).
  ///
  /// v2.5.16: 改回 `PageView(children: [...])` — v2.5.15 的 PageView.builder
  ///   + KeepAlive 让短剧 tab 在 app 启动时不 initState / 不拉数据, 但用户
  ///   实际想要的是:
  ///     1. 「启动app时就要开始加载短剧类容图片数据等不是我点击才开始加载」—
  ///        app 启动时短剧 tab 就要预加载, 切到时图片已缓存好
  ///     2. 「比如我打开短剧ai分类后切换到其他分类在切换回来应该是加载好
  ///        的状态不应该再次加载」— 分类切来切去, 已加载好的 tab 不应该
  ///        重新拉
  ///   改法: 改回 PageView.children 让 6 个 child 启动时全部 initState,
  ///   短剧 tab 立刻发请求拉分类 + 全部推荐; 切到其他 tab 再切回时,
  ///   short drama State 没被 dispose, _tabCache 缓存每 tab 拉到的
  ///   (list, shownNames, page, hasMore), 切回 tab 时直接 restore, 不
  ///   重新请求. 切 tab 走缓存, 启动时预加载, 缓存命中不重复拉.
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
      // 如果当前已在该标签，但页面不在对应位置（仅首页），则切回
      if (tab == '首页' &&
          _pageController.hasClients &&
          _pageController.page?.round() != 0) {
        _pageController.animateToPage(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
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
        // v2.5.7: 跟「图一」样式一致, 历史 tab 走 HomeScreen 内部
        // PageView 切换 (pageIndex=1), 不再 push 独立 HistoryScreen
        // 路由. 老逻辑: await Navigator.pushNamed('/history'), 用户
        // 反馈「应该和图一一样不用改调用新的页面」.
        pageIndex = 1;
        break;
      case '收藏夹':
        // v2.5.7: 同上, 收藏 tab 走 PageView 切换 (pageIndex=2),
        // 不再 push 独立 FavoritesScreen 路由.
        pageIndex = 2;
        break;
      default:
        pageIndex = 0;
    }

    // 使用动画切换到对应页面 (首页/历史/收藏 全部在 HomeScreen 内部 PageView)
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
        videoInfo: VideoInfo.fromPlayRecord(playRecord),
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
            videoInfo: VideoInfo.fromPlayRecord(playRecord),
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
