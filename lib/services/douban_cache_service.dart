import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

/// 缓存项数据结构
class CacheItem<T> {
  final T data;
  final DateTime timestamp;
  final Duration expiration;

  CacheItem({
    required this.data,
    required this.timestamp,
    required this.expiration,
  });

  /// 检查缓存是否过期
  bool get isExpired => DateTime.now().difference(timestamp) > expiration;

  /// 转换为JSON（用于序列化）
  Map<String, dynamic> toJson() => {
    'data': data,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'expiration': expiration.inMilliseconds,
  };

  /// 从JSON创建缓存项
  static CacheItem<T> fromJson<T>(Map<String, dynamic> json, T Function(dynamic) fromJsonFunc) {
    try {
      // 检查必需的字段
      if (!json.containsKey('data') || !json.containsKey('timestamp') || !json.containsKey('expiration')) {
        throw FormatException('缓存项缺少必需字段: ${json.keys.toList()}');
      }

      final timestampValue = json['timestamp'];
      final expirationValue = json['expiration'];
      
      int timestamp;
      if (timestampValue is int) {
        timestamp = timestampValue;
      } else if (timestampValue is String) {
        timestamp = int.parse(timestampValue);
      } else {
        throw FormatException('timestamp 字段类型错误: ${timestampValue.runtimeType}');
      }
      
      int expiration;
      if (expirationValue is int) {
        expiration = expirationValue;
      } else if (expirationValue is String) {
        expiration = int.parse(expirationValue);
      } else {
        throw FormatException('expiration 字段类型错误: ${expirationValue.runtimeType}');
      }

      return CacheItem<T>(
        data: fromJsonFunc(json['data']),
        timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
        expiration: Duration(milliseconds: expiration),
      );
    } catch (e) {
      rethrow;
    }
  }
}

/// 豆瓣缓存服务类
class DoubanCacheService {
  static final DoubanCacheService _instance = DoubanCacheService._internal();
  factory DoubanCacheService() => _instance;
  DoubanCacheService._internal();

  /// 内存缓存（保存为原始JSON结构，读取时再解码为目标类型）
  final Map<String, CacheItem<dynamic>> _memoryCache = {};

  /// 缓存文件目录
  Directory? _cacheDir;

  /// 初始化缓存服务
  Future<void> init() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _cacheDir = Directory('${appDir.path}/douban_cache');
      
      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }

      // 启动时清理过期缓存
      await _cleanExpiredCache();
    } catch (e) {
      if (kDebugMode) {
        print('豆瓣缓存服务初始化失败: $e');
      }
    }
  }

  /// 生成缓存键
  String _generateCacheKey(String prefix, Map<String, dynamic> params) {
    final sortedKeys = params.keys.toList()..sort();
    final paramString = sortedKeys.map((key) => '$key=${params[key]}').join('&');
    return '${prefix}_$paramString';
  }

  /// 获取缓存
  /// decode: 将原始 JSON 数据(dynamic，可为 List/Map 等) 转换为目标类型 T
  Future<T?> get<T>(String key, T Function(dynamic) decode) async {
    try {
      // 先检查内存缓存
      if (_memoryCache.containsKey(key)) {
        final cacheItem = _memoryCache[key]!;
        if (!cacheItem.isExpired) {
          // 发现旧格式（Map 且含 items），直接清除并视为未命中
          final raw = cacheItem.data;
          if (raw is Map && raw.containsKey('items')) {
            _memoryCache.remove(key);
            if (_cacheDir != null) {
              final file = File('${_cacheDir!.path}/$key.json');
              if (await file.exists()) {
                try { await file.delete(); } catch (_) {}
              }
            }
          } else {
                // 使用解码器将原始 JSON 转成目标类型
                try {
                  return decode(raw);
                } catch (e) {
                  // 解码失败，删除缓存
                  _memoryCache.remove(key);
                  if (_cacheDir != null) {
                    final file = File('${_cacheDir!.path}/$key.json');
                    if (await file.exists()) {
                      try { await file.delete(); } catch (_) {}
                    }
                  }
                  rethrow;
                }
          }
        } else {
          // 过期则删除
          _memoryCache.remove(key);
        }
      }

      // 检查磁盘缓存
      if (_cacheDir != null) {
        final file = File('${_cacheDir!.path}/$key.json');
        if (await file.exists()) {
          try {
            final jsonString = await file.readAsString();
            final jsonData = json.decode(jsonString);
            
            if (jsonData is! Map<String, dynamic>) {
              try { await file.delete(); } catch (_) {}
              return null;
            }

            // 读取为原始 JSON（不做结构假设），再用 decode 转换
            final cacheItem = CacheItem.fromJson<dynamic>(jsonData, (data) => data);

            if (!cacheItem.isExpired) {
              // 发现旧格式（Map 且含 items），直接删除并视为未命中
              final raw = cacheItem.data;
              if (raw is Map && raw.containsKey('items')) {
                try { await file.delete(); } catch (_) {}
              } else {
                // 重新加载到内存缓存
                _memoryCache[key] = cacheItem;
                try {
                  return decode(raw);
                } catch (e) {
                  // 解码失败，删除缓存
                  _memoryCache.remove(key);
                  try { await file.delete(); } catch (_) {}
                  rethrow;
                }
              }
            } else {
              // 过期则删除文件
              await file.delete();
            }
          } catch (e) {
            // 文件内容不合法或旧格式，直接删除避免反复报错
            try { await file.delete(); } catch (_) {}
          }
        }
      }
    } catch (e) {
      // 静默处理缓存读取错误
    }
    return null;
  }

  /// 设置缓存
  Future<void> set<T>(String key, T data, Duration expiration) async {
    try {
      final cacheItem = CacheItem<T>(
        data: data,
        timestamp: DateTime.now(),
        expiration: expiration,
      );

      // 保存到内存缓存
      _memoryCache[key] = cacheItem;

      // 保存到磁盘缓存
      if (_cacheDir != null) {
        final file = File('${_cacheDir!.path}/$key.json');
        final jsonData = cacheItem.toJson();
        await file.writeAsString(json.encode(jsonData));
      }
    } catch (e) {
      if (kDebugMode) {
        print('设置豆瓣缓存失败: $e');
      }
    }
  }

  /// 删除缓存
  Future<void> delete(String key) async {
    try {
      // 从内存缓存删除
      _memoryCache.remove(key);

      // 从磁盘缓存删除
      if (_cacheDir != null) {
        final file = File('${_cacheDir!.path}/$key.json');
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('删除豆瓣缓存失败: $e');
      }
    }
  }

  /// 清理过期缓存
  Future<void> _cleanExpiredCache() async {
    try {
      // 清理内存缓存
      final expiredKeys = <String>[];
      _memoryCache.forEach((key, item) {
        if (item.isExpired) {
          expiredKeys.add(key);
        }
      });
      
      for (final key in expiredKeys) {
        _memoryCache.remove(key);
      }

      // 清理磁盘缓存
      if (_cacheDir != null && await _cacheDir!.exists()) {
        final files = await _cacheDir!.list().toList();
        for (final file in files) {
          if (file is File && file.path.endsWith('.json')) {
            try {
              final jsonString = await file.readAsString();
              final jsonData = json.decode(jsonString) as Map<String, dynamic>;
              final timestamp = DateTime.fromMillisecondsSinceEpoch(jsonData['timestamp']);
              final expiration = Duration(milliseconds: jsonData['expiration']);
              
              if (DateTime.now().difference(timestamp) > expiration) {
                await file.delete();
              }
            } catch (e) {
              // 如果文件损坏，直接删除
              await file.delete();
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('清理过期豆瓣缓存失败: $e');
      }
    }
  }

  /// 清空所有缓存
  Future<void> clearAll() async {
    try {
      // 清空内存缓存
      _memoryCache.clear();

      // 清空磁盘缓存
      if (_cacheDir != null && await _cacheDir!.exists()) {
        final files = await _cacheDir!.list().toList();
        for (final file in files) {
          if (file is File) {
            await file.delete();
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('清空所有豆瓣缓存失败: $e');
      }
    }
  }

  /// 定期清理过期缓存（建议在应用启动时调用）
  void startPeriodicCleanup() {
    // 每小时清理一次过期缓存
    Stream.periodic(const Duration(hours: 1)).listen((_) {
      _cleanExpiredCache();
    });
  }

  /// 豆瓣服务专用缓存方法

  /// 为豆瓣分类数据生成缓存键
  String generateDoubanCategoryCacheKey({
    required String kind,
    required String category,
    required String type,
    required int pageLimit,
    required int page,
  }) {
    return _generateCacheKey('douban_category', {
      'kind': kind,
      'category': category,
      'type': type,
      'pageLimit': pageLimit,
      'page': page,
    });
  }

  /// 为豆瓣推荐数据生成缓存键
  String generateDoubanRecommendsCacheKey({
    required String kind,
    required String category,
    required String format,
    required String region,
    required String year,
    required String platform,
    required String sort,
    required String label,
    required int pageLimit,
    required int page,
  }) {
    return _generateCacheKey('douban_recommends', {
      'kind': kind,
      'category': category,
      'format': format,
      'region': region,
      'year': year,
      'platform': platform,
      'sort': sort,
      'label': label,
      'pageLimit': pageLimit,
      'page': page,
    });
  }

  /// 为豆瓣详情数据生成缓存键
  String generateDoubanDetailsCacheKey({
    required String doubanId,
  }) {
    return _generateCacheKey('douban_details', {
      'doubanId': doubanId,
    });
  }

  /// 为 Bangumi 详情数据生成缓存键
  String generateBangumiDetailsCacheKey({
    required String bangumiId,
  }) {
    return _generateCacheKey('bangumi_details', {
      'bangumiId': bangumiId,
    });
  }

  /// 清理所有缓存（用于调试）
  Future<void> clearAllCache() async {
    try {
      _memoryCache.clear();
      if (_cacheDir != null) {
        if (await _cacheDir!.exists()) {
          await _cacheDir!.delete(recursive: true);
          await _cacheDir!.create(recursive: true);
        }
      }
      // 缓存清理成功
    } catch (e) {
      // 静默处理清理错误
    }
  }
}
