import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:math';
import 'package:luna_tv/models/douban_movie.dart';
import 'package:luna_tv/api_service.dart';
import 'package:luna_tv/services/douban_cache_service.dart';
import 'package:luna_tv/services/user_data_service.dart';

/// 豆瓣推荐数据请求参数
class DoubanRecommendsParams {
  final String kind;
  final String category;
  final String format;
  final String region;
  final String year;
  final String platform;
  final String sort;
  final String label;
  final int pageLimit;
  final int page;

  const DoubanRecommendsParams({
    required this.kind,
    this.category = 'all',
    this.format = 'all',
    this.region = 'all',
    this.year = 'all',
    this.platform = 'all',
    this.sort = 'T',
    this.label = 'all',
    this.pageLimit = 20,
    this.page = 0,
  });
}

/// 豆瓣数据请求参数（保持向后兼容）
class DoubanRequestParams {
  final String kind;
  final String category;
  final String type;
  final int pageLimit;
  final int page;

  const DoubanRequestParams({
    required this.kind,
    required this.category,
    required this.type,
    this.pageLimit = 25,
    this.page = 0,
  });

  /// 构建查询参数
  Map<String, String> toQueryParams() {
    return {
      'kind': kind,
      'category': category,
      'type': type,
      'pageLimit': pageLimit.toString(),
      'page': page.toString(),
    };
  }
}

/// 豆瓣数据请求服务
class DoubanService {
  static final DoubanCacheService _cacheService = DoubanCacheService();
  static bool _cacheInitialized = false;
  static String? _uniqueOrigin;
  
  /// 生成唯一的 Origin 以避免统一限流
  static String _getUniqueOrigin() {
    if (_uniqueOrigin == null) {
      final random = Random();
      final domains = [
        'movie.douban.com',
        'm.douban.com',
        'www.douban.com',
      ];
      final subdomains = [
        'app',
        'mobile',
        'client',
        'api',
        'web',
      ];
      
      // 随机选择域名和子域名组合
      final baseDomain = domains[random.nextInt(domains.length)];
      final subdomain = subdomains[random.nextInt(subdomains.length)];
      final randomId = random.nextInt(9999).toString().padLeft(4, '0');
      
      _uniqueOrigin = 'https://$subdomain$randomId.$baseDomain';
    }
    return _uniqueOrigin!;
  }

  /// 初始化缓存服务
  static Future<void> _initCache() async {
    if (!_cacheInitialized) {
      await _cacheService.init();
      _cacheInitialized = true;
    }
  }
  /// 获取豆瓣分类数据
  /// 
  /// 参数说明：
  /// - kind: 类型 (movie, tv)
  /// - category: 分类 (热门, tv, show 等)
  /// - type: 子类型 (全部, tv, show 等)
  /// - pageLimit: 每页数量，默认20
  /// - page: 起始页码，默认0
  static Future<ApiResponse<List<DoubanMovie>>> getCategoryData(
    BuildContext context, {
    required String kind,
    required String category,
    required String type,
    int pageLimit = 25,
    int page = 0,
  }) async {
    // 初始化缓存服务
    await _initCache();

    // 生成缓存键
    final cacheKey = _cacheService.generateDoubanCategoryCacheKey(
      kind: kind,
      category: category,
      type: type,
      pageLimit: pageLimit,
      page: page,
    );

    // 尝试从缓存获取数据（存取均为已处理后的 DoubanMovie 列表）
    try {
      final cachedData = await _cacheService.get<List<DoubanMovie>>(
        cacheKey,
        (raw) => (raw as List<dynamic>)
            .map((m) {
              final map = m as Map<String, dynamic>;
              return DoubanMovie(
                id: map['id']?.toString() ?? '',
                title: map['title']?.toString() ?? '',
                poster: map['poster']?.toString() ?? '',
                rate: map['rate']?.toString(),
                year: map['year']?.toString() ?? '',
              );
            })
            .toList(),
      );

      if (cachedData != null) {
        return ApiResponse.success(cachedData);
      }
    } catch (e) {
      // 缓存读取失败，继续执行网络请求
      print('读取缓存失败: $e');
    }
    // 获取用户存储的豆瓣数据源选项
    final dataSourceKey = await UserDataService.getDoubanDataSourceKey();
    
    // 根据数据源选项构建不同的基础URL
    String apiUrl;
    switch (dataSourceKey) {
      case 'cdn_tencent':
        apiUrl = 'https://m.douban.cmliussss.net/rexxar/api/v2/subject/recent_hot/$kind?start=${page * pageLimit}&limit=$pageLimit&category=$category&type=$type';
        break;
      case 'cdn_aliyun':
        apiUrl = 'https://m.douban.cmliussss.com/rexxar/api/v2/subject/recent_hot/$kind?start=${page * pageLimit}&limit=$pageLimit&category=$category&type=$type';
        break;
      case 'direct':
      default:
        apiUrl = 'https://m.douban.com/rexxar/api/v2/subject/recent_hot/$kind?start=${page * pageLimit}&limit=$pageLimit&category=$category&type=$type';
        break;
    }
    if (dataSourceKey == 'cors_proxy') {
      apiUrl = 'https://ciao-cors.is-an.org/${Uri.encodeComponent(apiUrl)}';
    }
    
    try {
      final headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
        'Referer': 'https://movie.douban.com/',
        'Accept': 'application/json, text/plain, */*',
      };
      
      // 如果使用 cors_proxy，添加 Origin 头
      if (dataSourceKey == 'cors_proxy') {
        headers['Origin'] = _getUniqueOrigin();
      }
      
      final response = await http.get(
        Uri.parse(apiUrl),
        headers: headers,
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        try {
          final Map<String, dynamic> data = json.decode(response.body);
          final doubanResponse = DoubanResponse.fromJson(data);
          
          // 缓存成功的结果（保存已处理后的 DoubanMovie 列表），缓存时间为1天
          try {
            await _cacheService.set(
              cacheKey,
              doubanResponse.items.map((e) => e.toJson()).toList(),
              const Duration(hours: 6),
            );
          } catch (cacheError) {
            print('缓存数据失败: $cacheError');
          }
          
          return ApiResponse.success(doubanResponse.items, statusCode: response.statusCode);
        } catch (parseError) {
          return ApiResponse.error('豆瓣数据解析失败: ${parseError.toString()}');
        }
      } else {
        return ApiResponse.error(
          '获取豆瓣数据失败: ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
    } catch (e) {
      return ApiResponse.error('豆瓣数据请求异常: ${e.toString()}');
    }
  }

  /// 获取热门电影数据
  static Future<ApiResponse<List<DoubanMovie>>> getHotMovies(
    BuildContext context, {
    int pageLimit = 25,
    int page = 0,
  }) async {
    return getCategoryData(
      context,
      kind: 'movie',
      category: '热门',
      type: '全部',
      pageLimit: pageLimit,
      page: page,
    );
  }

  /// 获取热门剧集数据
  static Future<ApiResponse<List<DoubanMovie>>> getHotTvShows(
    BuildContext context, {
    int pageLimit = 25,
    int page = 0,
  }) async {
    return getCategoryData(
      context,
      kind: 'tv',
      category: '最近热门',
      type: 'tv',
      pageLimit: pageLimit,
      page: page,
    );
  }

  /// 获取热门综艺数据
  static Future<ApiResponse<List<DoubanMovie>>> getHotShows(
    BuildContext context, {
    int pageLimit = 25,
    int page = 0,
  }) async {
    return getCategoryData(
      context,
      kind: 'tv',
      category: 'show',
      type: 'show',
      pageLimit: pageLimit,
      page: page,
    );
  }

  /// 获取豆瓣推荐数据（新版筛选逻辑）
  static Future<ApiResponse<List<DoubanMovie>>> fetchDoubanRecommends(
    BuildContext context,
    DoubanRecommendsParams params, {
    String proxyUrl = '',
    bool useTencentCDN = false,
    bool useAliCDN = false,
  }) async {
    // 初始化缓存服务
    await _initCache();

    // 生成缓存键
    final cacheKey = _cacheService.generateDoubanRecommendsCacheKey(
      kind: params.kind,
      category: params.category,
      format: params.format,
      region: params.region,
      year: params.year,
      platform: params.platform,
      sort: params.sort,
      label: params.label,
      pageLimit: params.pageLimit,
      page: params.page,
    );

    // 尝试从缓存获取数据（存取均为已处理后的 DoubanMovie 列表）
    try {
      final cachedData = await _cacheService.get<List<DoubanMovie>>(
        cacheKey,
        (raw) => (raw as List<dynamic>)
            .map((m) {
              final map = m as Map<String, dynamic>;
              return DoubanMovie(
                id: map['id']?.toString() ?? '',
                title: map['title']?.toString() ?? '',
                poster: map['poster']?.toString() ?? '',
                rate: map['rate']?.toString(),
                year: map['year']?.toString() ?? '',
              );
            })
            .toList(),
      );

      if (cachedData != null) {
        return ApiResponse.success(cachedData);
      }
    } catch (e) {
      // 缓存读取失败，继续执行网络请求
      print('读取缓存失败: $e');
    }
    // 处理筛选参数，将 'all' 转换为空字符串
    String category = params.category == 'all' ? '' : params.category;
    String format = params.format == 'all' ? '' : params.format;
    String region = params.region == 'all' ? '' : params.region;
    String year = params.year == 'all' ? '' : params.year;
    String platform = params.platform == 'all' ? '' : params.platform;
    String label = params.label == 'all' ? '' : params.label;
    String sort = params.sort == 'T' ? '' : params.sort;

    // 构建 selected_categories
    Map<String, dynamic> selectedCategories = {'类型': category};
    if (format.isNotEmpty) {
      selectedCategories['形式'] = format;
    }
    if (region.isNotEmpty) {
      selectedCategories['地区'] = region;
    }

    // 构建 tags 数组
    List<String> tags = [];
    if (category.isNotEmpty) {
      tags.add(category);
    }
    if (category.isEmpty && format.isNotEmpty) {
      tags.add(format);
    }
    if (label.isNotEmpty) {
      tags.add(label);
    }
    if (region.isNotEmpty) {
      tags.add(region);
    }
    if (year.isNotEmpty) {
      tags.add(year);
    }
    if (platform.isNotEmpty) {
      tags.add(platform);
    }

    // 获取用户存储的豆瓣数据源选项
    final dataSourceKey = await UserDataService.getDoubanDataSourceKey();
    
    // 根据数据源选项构建不同的基础URL
    String baseUrl;
    switch (dataSourceKey) {
      case 'cdn_tencent':
        baseUrl = 'https://m.douban.cmliussss.net/rexxar/api/v2/${params.kind}/recommend';
        break;
      case 'cdn_aliyun':
        baseUrl = 'https://m.douban.cmliussss.com/rexxar/api/v2/${params.kind}/recommend';
        break;
      case 'direct':
      default:
        baseUrl = 'https://m.douban.com/rexxar/api/v2/${params.kind}/recommend';
        break;
    }
    
    // 构建查询参数
    final queryParams = <String, String>{
      'refresh': '0',
      'start': (params.page * params.pageLimit).toString(),
      'count': params.pageLimit.toString(),
      'selected_categories': json.encode(selectedCategories),
      'uncollect': 'false',
      'score_range': '0,10',
      'tags': tags.join(','),
    };
    
    if (sort.isNotEmpty) {
      queryParams['sort'] = sort;
    }

    final uri = Uri.parse(baseUrl).replace(queryParameters: queryParams);
    String target = uri.toString();
    if (dataSourceKey == 'cors_proxy') {
      target = 'https://ciao-cors.is-an.org/${Uri.encodeComponent(target)}';
    }

    try {
      final headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
        'Referer': 'https://movie.douban.com/',
        'Accept': 'application/json, text/plain, */*',
      };
      
      // 如果使用 cors_proxy，添加 Origin 头
      if (dataSourceKey == 'cors_proxy') {
        headers['Origin'] = _getUniqueOrigin();
      }
      
      final response = await http.get(
        Uri.parse(target),
        headers: headers,
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        try {
          final Map<String, dynamic> data = json.decode(response.body);
          
          // 过滤并转换数据
          final itemsData = data['items'] as List<dynamic>? ?? [];
          final filteredItems = itemsData
              .where((item) => item['type'] == 'movie' || item['type'] == 'tv')
              .map((item) => DoubanMovie.fromJson(item as Map<String, dynamic>))
              .toList();

          // 缓存成功的结果（保存已处理后的 DoubanMovie 列表），缓存时间为1天
          try {
            await _cacheService.set(
              cacheKey,
              filteredItems.map((e) => e.toJson()).toList(),
              const Duration(hours: 6),
            );
          } catch (cacheError) {
            print('缓存数据失败: $cacheError');
          }

          return ApiResponse.success(filteredItems, statusCode: response.statusCode);
        } catch (parseError) {
          return ApiResponse.error('豆瓣推荐数据解析失败: ${parseError.toString()}');
        }
      } else {
        return ApiResponse.error(
          '获取豆瓣推荐数据失败: ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
    } catch (e) {
      return ApiResponse.error('豆瓣推荐数据请求异常: ${e.toString()}');
    }
  }

  /// 获取豆瓣详情数据
  /// 
  /// 参数说明：
  /// - doubanId: 豆瓣ID
  static Future<ApiResponse<DoubanMovieDetails>> getDoubanDetails(
    BuildContext context, {
    required String doubanId,
  }) async {
    // 初始化缓存服务
    await _initCache();

    // 生成缓存键
    final cacheKey = _cacheService.generateDoubanDetailsCacheKey(
      doubanId: doubanId,
    );

    // 尝试从缓存获取数据
    try {
      final cachedData = await _cacheService.get<DoubanMovieDetails>(
        cacheKey,
        (raw) {
          final map = raw as Map<String, dynamic>;
          
          // 处理推荐列表
          List<DoubanRecommendItem> recommends = [];
          if (map['recommends'] != null) {
            final recommendsData = map['recommends'] as List<dynamic>? ?? [];
            recommends = recommendsData.map((r) => DoubanRecommendItem.fromJson(r as Map<String, dynamic>)).toList();
          }
          
          return DoubanMovieDetails(
            id: map['id']?.toString() ?? '',
            title: map['title']?.toString() ?? '',
            poster: map['poster']?.toString() ?? '',
            rate: map['rate']?.toString(),
            year: map['year']?.toString() ?? '',
            summary: map['summary']?.toString(),
            genres: (map['genres'] as List<dynamic>? ?? [])
                .map((g) => g.toString())
                .toList(),
            directors: (map['directors'] as List<dynamic>? ?? [])
                .map((d) => d.toString())
                .toList(),
            screenwriters: (map['screenwriters'] as List<dynamic>? ?? [])
                .map((s) => s.toString())
                .toList(),
            actors: (map['actors'] as List<dynamic>? ?? [])
                .map((a) => a.toString())
                .toList(),
            duration: map['duration']?.toString(),
            countries: (map['countries'] as List<dynamic>? ?? [])
                .map((c) => c.toString())
                .toList(),
            languages: (map['languages'] as List<dynamic>? ?? [])
                .map((l) => l.toString())
                .toList(),
            releaseDate: map['releaseDate']?.toString(),
            originalTitle: map['originalTitle']?.toString(),
            imdbId: map['imdbId']?.toString(),
            totalEpisodes: map['totalEpisodes'] is int
                ? map['totalEpisodes'] as int
                : int.tryParse(map['totalEpisodes']?.toString() ?? ''),
            recommends: recommends,
          );
        },
      );

      if (cachedData != null && cachedData.title.trim().isNotEmpty) {
        return ApiResponse.success(cachedData);
      } else if (cachedData != null) {
        await _cacheService.delete(cacheKey);
      }
    } catch (e) {
      // 缓存读取失败，继续执行网络请求
      print('读取豆瓣详情缓存失败: $e');
    }

    // 获取用户存储的豆瓣数据源选项
    final dataSourceKey = await UserDataService.getDoubanDataSourceKey();
    
    // 根据数据源选项构建不同的详情 API URL。HTML 页面会被豆瓣反爬跳到
    // sec.douban.com 校验页；rexxar JSON 接口和推荐列表同源，能稳定取详情。
    String apiUrl;
    switch (dataSourceKey) {
      case 'cdn_tencent':
        apiUrl = 'https://m.douban.cmliussss.net/rexxar/api/v2/subject/$doubanId';
        break;
      case 'cdn_aliyun':
        apiUrl = 'https://m.douban.cmliussss.com/rexxar/api/v2/subject/$doubanId';
        break;
      case 'direct':
      default:
        apiUrl = 'https://m.douban.com/rexxar/api/v2/subject/$doubanId';
        break;
    }
    
    if (dataSourceKey == 'cors_proxy') {
      apiUrl = 'https://ciao-cors.is-an.org/${Uri.encodeComponent(apiUrl)}';
    }
    
    try {
      final headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
        'Referer': 'https://movie.douban.com/',
        'Accept': 'application/json, text/plain, */*',
      };
      
      // 如果使用 cors_proxy，添加 Origin 头
      if (dataSourceKey == 'cors_proxy') {
        headers['Origin'] = _getUniqueOrigin();
      }
      
      final response = await http.get(
        Uri.parse(apiUrl),
        headers: headers,
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        try {
          // 解析 rexxar JSON 响应
          final data = jsonDecode(response.body);
          if (data is! Map<String, dynamic>) {
            return ApiResponse.error('豆瓣详情数据格式错误');
          }

          final details = DoubanMovieDetails.fromJson(data);
          if (details.title.trim().isEmpty) {
            return ApiResponse.error('豆瓣详情数据解析为空');
          }
          
          // 缓存成功的结果，缓存时间为3天
          try {
            await _cacheService.set(
              cacheKey,
              details.toJson(),
              const Duration(days: 3),
            );
          } catch (cacheError) {
            print('缓存豆瓣详情数据失败: $cacheError');
          }
          
          return ApiResponse.success(details, statusCode: response.statusCode);
        } catch (parseError) {
          return ApiResponse.error('豆瓣详情数据解析失败: ${parseError.toString()}');
        }
      } else {
        return ApiResponse.error(
          '获取豆瓣详情数据失败: ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
    } catch (e) {
      return ApiResponse.error('豆瓣详情数据请求异常: ${e.toString()}');
    }
  }
}
