import 'dart:convert';
import 'package:bs58check/bs58check.dart' as bs58;
import '../models/search_resource.dart';
import '../models/live_source.dart';

/// 订阅内容解析结果
class SubscriptionContent {
  final List<SearchResource>? searchResources;
  final List<LiveSource>? liveSources;

  SubscriptionContent({
    this.searchResources,
    this.liveSources,
  });
}

/// 订阅服务
/// 用于解析订阅内容
class SubscriptionService {
  /// 解析订阅内容
  /// 
  /// 参数:
  /// - content: Base58 编码的订阅内容
  /// 
  /// 返回:
  /// - 成功: 返回 SubscriptionContent 对象，包含 SearchResource 和 LiveSource 列表
  /// - 失败: 返回 null
  static Future<SubscriptionContent?> parseSubscriptionContent(
      String content) async {
    try {
      // Base58 解码
      final decoded = bs58.base58.decode(content);
      final jsonString = utf8.decode(decoded);

      // 解析 JSON
      final jsonData = jsonDecode(jsonString) as Map<String, dynamic>;
      
      // 解析 api_site
      List<SearchResource>? searchResources;
      final apiSite = jsonData['api_site'] as Map<String, dynamic>?;
      if (apiSite != null) {
        searchResources = <SearchResource>[];
        apiSite.forEach((key, value) {
          final site = value as Map<String, dynamic>;
          searchResources!.add(SearchResource(
            key: site['key'] as String? ?? key,
            name: site['name'] as String? ?? '',
            api: site['api'] as String? ?? '',
            detail: site['detail'] as String? ?? '',
            from: site['from'] as String? ?? '',
            disabled: false,
          ));
        });
      }

      // 解析 live_source
      List<LiveSource>? liveSources;
      final liveSourceData = jsonData['lives'] as Map<String, dynamic>?;
      if (liveSourceData != null) {
        liveSources = <LiveSource>[];
        liveSourceData.forEach((key, value) {
          final source = value as Map<String, dynamic>;
          liveSources!.add(LiveSource(
            key: source['key'] as String? ?? key,
            name: source['name'] as String? ?? '',
            url: source['url'] as String? ?? '',
            ua: source['ua'] as String? ?? '',
            epg: source['epg'] as String? ?? '',
            from: source['from'] as String? ?? '',
            disabled: false,
          ));
        });
      }

      return SubscriptionContent(
        searchResources: searchResources,
        liveSources: liveSources,
      );
    } catch (e) {
      return null;
    }
  }
}
