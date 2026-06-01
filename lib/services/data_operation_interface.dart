import 'package:flutter/material.dart';
import '../models/play_record.dart';
import '../models/favorite_item.dart';

/// 数据操作类型枚举
enum DataType {
  playRecord,
  favorite,
  searchRecord,
}

/// 数据操作结果
class DataOperationResult<T> {
  final bool success;
  final T? data;
  final String? errorMessage;
  final int? statusCode;

  DataOperationResult({
    required this.success,
    this.data,
    this.errorMessage,
    this.statusCode,
  });

  factory DataOperationResult.success(T data, {int? statusCode}) {
    return DataOperationResult<T>(
      success: true,
      data: data,
      statusCode: statusCode,
    );
  }

  factory DataOperationResult.error(String message, {int? statusCode}) {
    return DataOperationResult<T>(
      success: false,
      errorMessage: message,
      statusCode: statusCode,
    );
  }
}

/// 播放记录操作接口
abstract class PlayRecordOperationInterface {
  /// 获取播放记录（优先从缓存，缓存未命中则从API获取）
  Future<DataOperationResult<List<PlayRecord>>> getPlayRecords(BuildContext context);
  
  /// 保存播放记录（先添加到缓存，再调用POST接口保存）
  Future<DataOperationResult<void>> savePlayRecord(PlayRecord playRecord, BuildContext context);
  
  /// 根据 source+id 删除播放记录
  Future<DataOperationResult<void>> deletePlayRecord(String source, String id, BuildContext context);

  /// 清空播放记录
  Future<DataOperationResult<void>> clearPlayRecord(BuildContext context);

  /// 刷新播放记录（强制从API获取最新数据）
  Future<void> refreshPlayRecords(BuildContext context);
}

/// 收藏操作接口
abstract class FavoriteOperationInterface {
  /// 获取收藏夹（优先从缓存，缓存未命中则从API获取）
  Future<DataOperationResult<List<FavoriteItem>>> getFavorites(BuildContext context);
  
  /// 添加收藏
  Future<DataOperationResult<void>> addFavorite(String source, String id, Map<String, dynamic> favoriteData, BuildContext context);
  
  /// 取消收藏
  Future<DataOperationResult<void>> removeFavorite(String source, String id, BuildContext context);
  
  /// 同步检查是否已收藏
  bool isFavoritedSync(String source, String id);

  /// 刷新收藏夹（强制从API获取最新数据）
  Future<void> refreshFavorites(BuildContext context);
}

/// 搜索记录操作接口
abstract class SearchRecordOperationInterface {
  /// 获取搜索历史（优先从缓存，缓存未命中则从API获取）
  Future<DataOperationResult<List<String>>> getSearchHistory(BuildContext context);
  
  /// 添加搜索历史
  Future<DataOperationResult<void>> addSearchHistory(String query, BuildContext context);
  
  /// 删除搜索历史
  Future<DataOperationResult<void>> deleteSearchHistory(String query, BuildContext context);
  
  /// 清空搜索历史
  Future<DataOperationResult<void>> clearSearchHistory(BuildContext context);

  /// 刷新搜索历史（强制从API获取最新数据）
  Future<void> refreshSearchHistory(BuildContext context);
}